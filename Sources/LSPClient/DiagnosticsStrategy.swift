import IPC
import JSONRPC
import LanguageServerProtocol

// MARK: - DiagnosticsStrategy
//
// Each strategy owns the full document lifecycle: open/change/close decisions,
// LRU eviction, and diagnostic delivery. StdioLSPClient delegates entirely.

protocol DiagnosticsStrategy: AnyObject, Sendable {
    /// Opens/changes/no-ops each input document, evicts stale docs, then waits for
    /// or fetches diagnostics for each URI concurrently. One batch per input URI.
    func diagnose(_ inputs: [DocumentInput], timeout: Duration) async -> [DocumentURI: DiagnosticBatch]
    /// Route an incoming textDocument/publishDiagnostics notification. Push mode
    /// resolves pending awaiters; pull mode discards stray pushes.
    func receivePublish(uri: DocumentURI, batch: DiagnosticBatch) async
    /// Whether this strategy currently holds uri open in the server.
    func isOpen(_ uri: DocumentURI) async -> Bool
}

// MARK: - PushStrategy

/// Resolves diagnostics from server-initiated publishDiagnostics notifications.
actor PushStrategy: DiagnosticsStrategy {
    private let session: JSONRPCSession
    private let waiter = DiagnosticsWaiter()
    private let clock: any Clock<Duration>
    private var tracker: DocumentTracker
    private var nextID: UInt64 = 0

    init(session: JSONRPCSession, clock: any Clock<Duration>, maxOpenDocuments: Int) {
        self.session = session
        self.clock = clock
        self.tracker = DocumentTracker(maxOpenDocuments: maxOpenDocuments)
    }

    func diagnose(_ inputs: [DocumentInput], timeout: Duration) async -> [DocumentURI: DiagnosticBatch] {
        struct WaitItem { let uri: DocumentURI; let id: UInt64; let version: Int }
        var waitItems: [WaitItem] = []

        // Phase 1: serial sync + send notifications.
        for input in inputs {
            let (decision, version) = tracker.sync(input)
            let id = nextID; nextID += 1
            switch decision {
            case .open(let langId, let text):
                try? await lspDidOpen(session: session, uri: input.uri, languageId: langId, version: version, text: text)
            case .change(let text):
                await waiter.invalidate(uri: input.uri)
                try? await lspDidChange(session: session, uri: input.uri, version: version, text: text)
            case .noOp:
                break
            }
            waitItems.append(WaitItem(uri: input.uri, id: id, version: version))
        }

        // Phase 2: evict LRU docs to bound. isIdleResolved is false for docs with no
        // cached batch (fresh opens, invalidated changes) so they're naturally protected.
        await evictToBound()

        // Phase 3: concurrent wait — each task races its waiter against the deadline.
        let w = waiter; let c = clock
        return await withTaskGroup(of: (DocumentURI, DiagnosticBatch).self) { tg in
            for item in waitItems {
                tg.addTask {
                    let batch = await withTaskGroup(of: DiagnosticBatch.self) { inner in
                        inner.addTask { await w.wait(id: item.id, uri: item.uri, expectedVersion: item.version) }
                        inner.addTask {
                            try? await lspSleep(timeout, on: c)
                            return await w.timeout(id: item.id, uri: item.uri)
                        }
                        let b = await inner.next() ?? DiagnosticBatch(diagnostics: [], version: nil, arrived: false)
                        inner.cancelAll()
                        return b
                    }
                    return (item.uri, batch)
                }
            }
            var out: [DocumentURI: DiagnosticBatch] = [:]
            for await (uri, batch) in tg { out[uri] = batch }
            return out
        }
    }

    func receivePublish(uri: DocumentURI, batch: DiagnosticBatch) async {
        await waiter.publish(uri: uri, batch: batch)
    }

    func isOpen(_ uri: DocumentURI) async -> Bool { tracker.isOpen(uri) }

    private func evictToBound() async {
        while tracker.isOverBound {
            var evicted = false
            for uri in tracker.openRecency {
                if await waiter.isIdleResolved(uri: uri) {
                    try? await lspDidClose(session: session, uri: uri)
                    tracker.forget(uri)
                    evicted = true
                    break
                }
            }
            if !evicted { break }
        }
    }
}

// MARK: - PullStrategy

/// Resolves diagnostics via textDocument/diagnostic (LSP 3.17 pull model).
/// Stray publishDiagnostics notifications are silently dropped — only explicit
/// pull results are trusted.
actor PullStrategy: DiagnosticsStrategy {
    private let session: JSONRPCSession
    private let clock: any Clock<Duration>
    private var tracker: DocumentTracker
    private var previousResultIds: [DocumentURI: String] = [:]
    private var cache: [DocumentURI: DiagnosticBatch] = [:]

    init(session: JSONRPCSession, clock: any Clock<Duration>, maxOpenDocuments: Int) {
        self.session = session
        self.clock = clock
        self.tracker = DocumentTracker(maxOpenDocuments: maxOpenDocuments)
    }

    func diagnose(_ inputs: [DocumentInput], timeout: Duration) async -> [DocumentURI: DiagnosticBatch] {
        let batchURIs = Set(inputs.map(\.uri))
        struct FetchItem { let uri: DocumentURI; let version: Int }
        var fetchItems: [FetchItem] = []

        // Phase 1: serial sync + send notifications.
        for input in inputs {
            let (decision, version) = tracker.sync(input)
            switch decision {
            case .open(let langId, let text):
                try? await lspDidOpen(session: session, uri: input.uri, languageId: langId, version: version, text: text)
            case .change(let text):
                previousResultIds[input.uri] = nil
                cache[input.uri] = nil
                try? await lspDidChange(session: session, uri: input.uri, version: version, text: text)
            case .noOp:
                break
            }
            fetchItems.append(FetchItem(uri: input.uri, version: version))
        }

        // Phase 2: evict LRU docs to bound, skipping current batch (fetch still pending).
        while tracker.isOverBound {
            guard let uri = tracker.openRecency.first(where: { !batchURIs.contains($0) }) else { break }
            try? await lspDidClose(session: session, uri: uri)
            tracker.forget(uri)
        }

        // Phase 3: concurrent pull — one request per URI, sharing the actor's serial executor
        // but interleaving at the session response suspension point.
        return await withTaskGroup(of: (DocumentURI, DiagnosticBatch).self) { tg in
            for item in fetchItems {
                tg.addTask { (item.uri, await self.fetchOne(uri: item.uri, version: item.version, timeout: timeout)) }
            }
            var out: [DocumentURI: DiagnosticBatch] = [:]
            for await (uri, batch) in tg { out[uri] = batch }
            return out
        }
    }

    func receivePublish(uri: DocumentURI, batch: DiagnosticBatch) async {
        // Pull mode: discard. The server may still emit publishDiagnostics (e.g. from
        // pre-switch notifications or unconditional emitters), but we only trust what
        // we explicitly requested via textDocument/diagnostic.
    }

    func isOpen(_ uri: DocumentURI) async -> Bool { tracker.isOpen(uri) }

    private func fetchOne(uri: DocumentURI, version: Int, timeout: Duration) async -> DiagnosticBatch {
        let previousId = previousResultIds[uri]
        let params = DocumentDiagnosticParams(
            textDocument: TextDocumentIdentifier(uri: uri),
            previousResultId: previousId
        )
        let s = session
        let c = clock

        let outcome: PullOutcome = await withTaskGroup(of: PullOutcome.self) { group in
            group.addTask {
                do {
                    let report: DocumentDiagnosticReport = try await s.response(
                        to: "textDocument/diagnostic", params: params
                    )
                    switch report.kind {
                    case .full:
                        let diags = (report.items ?? []).map(mapLSPDiagnostic)
                        let batch = DiagnosticBatch(diagnostics: diags, version: version, arrived: true)
                        var related: [DocumentURI: PullOutcome.RelatedEntry] = [:]
                        for (relUri, relReport) in (report.relatedDocuments ?? [:]) where relReport.kind == .full {
                            let relDiags = (relReport.items ?? []).map(mapLSPDiagnostic)
                            related[relUri] = PullOutcome.RelatedEntry(
                                batch: DiagnosticBatch(diagnostics: relDiags, version: nil, arrived: true),
                                resultId: relReport.resultId
                            )
                        }
                        return PullOutcome(batch: batch, resultId: report.resultId, related: related)
                    case .unchanged:
                        return PullOutcome(batch: nil, resultId: nil, related: [:])
                    }
                } catch {
                    return PullOutcome(
                        batch: DiagnosticBatch(diagnostics: [], version: nil, arrived: false),
                        resultId: nil, related: [:]
                    )
                }
            }
            group.addTask {
                try? await lspSleep(timeout, on: c)
                return PullOutcome(
                    batch: DiagnosticBatch(diagnostics: [], version: nil, arrived: false),
                    resultId: nil, related: [:]
                )
            }
            let first = await group.next() ?? PullOutcome(
                batch: DiagnosticBatch(diagnostics: [], version: nil, arrived: false),
                resultId: nil, related: [:]
            )
            group.cancelAll()
            return first
        }

        for (relUri, entry) in outcome.related {
            cache[relUri] = entry.batch
            if let id = entry.resultId { previousResultIds[relUri] = id }
        }

        if let resultId = outcome.resultId, let batch = outcome.batch {
            previousResultIds[uri] = resultId
            cache[uri] = batch
            return batch
        }
        if outcome.batch == nil {
            return cache[uri] ?? DiagnosticBatch(diagnostics: [], version: version, arrived: true)
        }
        return outcome.batch!
    }
}

// MARK: - Shared notification helpers

private func lspDidOpen(
    session: JSONRPCSession, uri: DocumentURI,
    languageId: String, version: Int, text: String
) async throws {
    try await session.sendNotification(
        DidOpenTextDocumentParams(textDocument: TextDocumentItem(uri: uri, languageId: languageId, version: version, text: text)),
        method: "textDocument/didOpen"
    )
}

private func lspDidChange(
    session: JSONRPCSession, uri: DocumentURI, version: Int, text: String
) async throws {
    try await session.sendNotification(
        DidChangeTextDocumentParams(
            uri: uri, version: version,
            contentChange: TextDocumentContentChangeEvent(range: nil, rangeLength: nil, text: text)
        ),
        method: "textDocument/didChange"
    )
}

private func lspDidClose(session: JSONRPCSession, uri: DocumentURI) async throws {
    try await session.sendNotification(
        DidCloseTextDocumentParams(uri: uri),
        method: "textDocument/didClose"
    )
}

// MARK: - Shared helpers

private struct PullOutcome: Sendable {
    let batch: DiagnosticBatch?
    let resultId: String?
    let related: [DocumentURI: RelatedEntry]

    struct RelatedEntry: Sendable {
        let batch: DiagnosticBatch
        let resultId: String?
    }
}

func mapLSPDiagnostic(_ d: LanguageServerProtocol.Diagnostic) -> IPC.Diagnostic {
    IPC.Diagnostic(
        range: DiagnosticRange(
            start: IPC.Position(line: d.range.start.line, character: d.range.start.character),
            end: IPC.Position(line: d.range.end.line, character: d.range.end.character)
        ),
        severity: d.severity.flatMap { IPC.DiagnosticSeverity(rawValue: $0.rawValue) },
        message: d.message,
        code: nil
    )
}

private func lspSleep<C: Clock>(_ duration: Duration, on clock: C) async throws
where C.Duration == Duration {
    try await Task.sleep(until: clock.now.advanced(by: duration), tolerance: nil, clock: clock)
}
