import Clocks
import IPC
import JSONRPC
@testable import LSPClient
import XCTest

/// Exercises StdioLSPClient's protocol logic over an in-process channel + MockLSPServer —
/// no subprocess, no real stdio. Deterministic where the old FakeLSPServer tests were slow
/// and flaky. Covers the behaviors that matter: diagnostics round-trip + correlation,
/// timeout, and progress→readiness.
final class InProcessClientTests: XCTestCase {

    private func makeClient(
        clock: any Clock<Duration> = ContinuousClock(),
        maxOpenDocuments: Int = 48
    ) async -> (StdioLSPClient, MockLSPServer) {
        let (clientChannel, serverChannel) = DataChannel.withDataActor()
        let server = MockLSPServer(channel: serverChannel)
        let client = await StdioLSPClient.connect(
            serverID: "swift", channel: clientChannel, clock: clock, maxOpenDocuments: maxOpenDocuments
        )
        return (client, server)
    }

    private func waitUntil(
        _ condition: () async -> Bool, _ message: String,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        for _ in 0..<200 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail(message, file: file, line: line)
    }

    private func input(_ uri: String, mtimeNs: UInt64, size: UInt64, text: String = "") -> DocumentInput {
        DocumentInput(uri: uri, languageId: "swift", text: text, mtimeNs: mtimeNs, size: size)
    }

    // MARK: - Open / change / no-op decision

    func testDiagnoseOpensUnseenDocument() async throws {
        let (client, server) = await makeClient()
        try await client.initialize(rootURI: "file:///proj")
        let uri = "file:///proj/A.swift"

        let docs = [input(uri, mtimeNs: 1, size: 1)]
        let task = Task { await client.diagnose(docs, timeout: .seconds(2)) }
        await server.publishDiagnostics(uri: uri, version: nil, diagnostics: [])
        _ = await task.value

        let opens = await server.openedURIs()
        let changes = await server.changedURIs()
        XCTAssertEqual(opens, [uri], "an unseen document is opened")
        XCTAssertTrue(changes.isEmpty, "no didChange on first sight")

        await client.shutdown(); server.stop()
    }

    func testDiagnoseNoOpsUnchangedDocument() async throws {
        let (client, server) = await makeClient()
        try await client.initialize(rootURI: "file:///proj")
        let uri = "file:///proj/A.swift"
        let docs = [input(uri, mtimeNs: 5, size: 5)]

        let first = Task { await client.diagnose(docs, timeout: .seconds(2)) }
        await server.publishDiagnostics(uri: uri, version: nil, diagnostics: [])
        _ = await first.value
        // Same mtime/size → no new didOpen or didChange.
        _ = await client.diagnose(docs, timeout: .seconds(2))

        let opens = await server.openedURIs()
        let changes = await server.changedURIs()
        XCTAssertEqual(opens, [uri], "unchanged document is not reopened")
        XCTAssertTrue(changes.isEmpty, "unchanged document sends no didChange")

        await client.shutdown(); server.stop()
    }

    func testDiagnoseSendsDidChangeWhenContentChanges() async throws {
        let (client, server) = await makeClient()
        try await client.initialize(rootURI: "file:///proj")
        let uri = "file:///proj/A.swift"

        let firstDocs = [input(uri, mtimeNs: 1, size: 1)]
        let first = Task { await client.diagnose(firstDocs, timeout: .seconds(2)) }
        await server.publishDiagnostics(uri: uri, version: nil, diagnostics: [])
        _ = await first.value

        // Changed mtime/size → didChange (not a second didOpen).
        let secondDocs = [input(uri, mtimeNs: 2, size: 9)]
        let second = Task { await client.diagnose(secondDocs, timeout: .seconds(2)) }
        await server.publishDiagnostics(uri: uri, version: nil, diagnostics: [])
        _ = await second.value

        let opens = await server.openedURIs()
        let changes = await server.changedURIs()
        XCTAssertEqual(opens, [uri], "changed document is not reopened")
        XCTAssertEqual(changes, [uri], "changed document sends didChange")

        await client.shutdown(); server.stop()
    }

    // MARK: - Diagnostics delivery

    func testDiagnoseReturnsStaleBatchOnTimeout() async throws {
        // ImmediateClock fires the timeout deadline at once, so this is deterministic.
        let (client, server) = await makeClient(clock: ImmediateClock())
        try await client.initialize(rootURI: "file:///proj")
        let uri = "file:///proj/a.swift"
        let result = await client.diagnose([input(uri, mtimeNs: 1, size: 1)], timeout: .seconds(30))
        let batch = try XCTUnwrap(result[uri])
        XCTAssertFalse(batch.arrived, "no publish arrived; the batch must be marked stale")
        XCTAssertTrue(batch.diagnostics.isEmpty)

        await client.shutdown(); server.stop()
    }

    func testDiagnoseDeliversFreshDiagnosticsAfterContentChange() async throws {
        let (client, server) = await makeClient()
        try await client.initialize(rootURI: "file:///proj")
        let uri = "file:///proj/a.swift"

        let firstDocs = [input(uri, mtimeNs: 1, size: 1)]
        let first = Task { await client.diagnose(firstDocs, timeout: .seconds(5)) }
        await server.publishDiagnostics(uri: uri, version: nil, diagnostics: [mockDiagnostic(line: 0, message: "v1")])
        _ = await first.value

        // Changed content → strategy invalidates the waiter and sends didChange.
        let secondDocs = [input(uri, mtimeNs: 2, size: 9, text: "let y = 2")]
        let second = Task { await client.diagnose(secondDocs, timeout: .seconds(5)) }
        await server.publishDiagnostics(uri: uri, version: nil, diagnostics: [mockDiagnostic(line: 1, message: "v2")])
        let result = await second.value
        let batch = try XCTUnwrap(result[uri])
        XCTAssertEqual(batch.diagnostics.map(\.message), ["v2"])

        await client.shutdown(); server.stop()
    }

    // MARK: - LRU eviction

    func testBoundedOpenSetClosesLeastRecentlyUsedResolvedDocument() async throws {
        let (client, server) = await makeClient(maxOpenDocuments: 2)
        try await client.initialize(rootURI: "file:///proj")
        let a = "file:///proj/A.swift", b = "file:///proj/B.swift", c = "file:///proj/C.swift"

        // Diagnose A to open + resolved (diagnostics arrived and collected).
        let docsA = [input(a, mtimeNs: 1, size: 1)]
        let taskA = Task { await client.diagnose(docsA, timeout: .seconds(5)) }
        await server.publishDiagnostics(uri: a, version: nil, diagnostics: [])
        _ = await taskA.value

        let docsB = [input(b, mtimeNs: 1, size: 1)]
        let taskB = Task { await client.diagnose(docsB, timeout: .seconds(5)) }
        await server.publishDiagnostics(uri: b, version: nil, diagnostics: [])
        _ = await taskB.value

        // Opening a third doc past the cap of 2 evicts the LRU resolved one (A).
        let docsC = [input(c, mtimeNs: 1, size: 1)]
        let taskC = Task { await client.diagnose(docsC, timeout: .seconds(5)) }
        await server.publishDiagnostics(uri: c, version: nil, diagnostics: [])
        _ = await taskC.value

        try await waitUntil({ await server.closedURIs().contains(a) }, "A should be closed on eviction")
        let closed = await server.closedURIs()
        let aOpen = await client.isOpen(a)
        let bOpen = await client.isOpen(b)
        let cOpen = await client.isOpen(c)
        XCTAssertEqual(closed, [a], "only the least-recently-used doc is closed")
        XCTAssertFalse(aOpen)
        XCTAssertTrue(bOpen)
        XCTAssertTrue(cOpen)

        await client.shutdown(); server.stop()
    }

    // MARK: - Pull diagnostics (textDocument/diagnostic)

    func testPullModeUsedWhenServerDeclaresProvider() async throws {
        let (client, server) = await makeClient()
        await server.enablePullMode()
        let uri = "file:///proj/A.swift"
        await server.scriptPullDiagnostics(uri: uri, diagnostics: [
            mockDiagnostic(line: 2, message: "unused variable")
        ])

        try await client.initialize(rootURI: "file:///proj")
        let result = await client.diagnose([input(uri, mtimeNs: 1, size: 1)], timeout: .seconds(5))

        let batch = try XCTUnwrap(result[uri])
        XCTAssertTrue(batch.arrived)
        XCTAssertEqual(batch.diagnostics.map(\.message), ["unused variable"])

        await client.shutdown(); server.stop()
    }

    func testPullModeReturnsEmptyWhenNoScriptedDiagnostics() async throws {
        let (client, server) = await makeClient()
        await server.enablePullMode()
        try await client.initialize(rootURI: "file:///proj")
        let uri = "file:///proj/B.swift"

        let result = await client.diagnose([input(uri, mtimeNs: 1, size: 1)], timeout: .seconds(5))

        let batch = try XCTUnwrap(result[uri])
        XCTAssertTrue(batch.arrived)
        XCTAssertTrue(batch.diagnostics.isEmpty)

        await client.shutdown(); server.stop()
    }

    func testPullModeDiscardsStrayPublishDiagnostics() async throws {
        // In pull mode, a stray publishDiagnostics must NOT resolve the fetch — the
        // pull request alone should produce the result.
        let (client, server) = await makeClient()
        await server.enablePullMode()
        let uri = "file:///proj/C.swift"
        await server.scriptPullDiagnostics(uri: uri, diagnostics: [mockDiagnostic(line: 0, message: "real")])

        try await client.initialize(rootURI: "file:///proj")
        // Fire a stray push with a different message — pull mode must ignore it.
        await server.publishDiagnostics(uri: uri, version: nil, diagnostics: [mockDiagnostic(line: 0, message: "stale-push")])
        let result = await client.diagnose([input(uri, mtimeNs: 1, size: 1)], timeout: .seconds(5))

        let batch = try XCTUnwrap(result[uri])
        XCTAssertEqual(batch.diagnostics.map(\.message), ["real"], "pull result wins; push is discarded")

        await client.shutdown(); server.stop()
    }

    func testPushModeUsedWhenServerHasNoProvider() async throws {
        // Default mock returns empty capabilities → no diagnosticProvider → PushStrategy.
        let (client, server) = await makeClient()
        try await client.initialize(rootURI: "file:///proj")
        let uri = "file:///proj/D.swift"

        let docs = [input(uri, mtimeNs: 1, size: 1)]
        let task = Task { await client.diagnose(docs, timeout: .seconds(2)) }
        await server.publishDiagnostics(uri: uri, version: nil, diagnostics: [mockDiagnostic(line: 0, message: "pushed")])
        let result = await task.value

        let batch = try XCTUnwrap(result[uri])
        XCTAssertEqual(batch.diagnostics.map(\.message), ["pushed"])

        await client.shutdown(); server.stop()
    }

    // MARK: - Server capabilities / progress

    func testRegisterCapabilitySurfacesAsServerEvent() async throws {
        let (client, server) = await makeClient()
        try await client.initialize(rootURI: "file:///proj")

        let received = Task { () -> (String, [String])? in
            for await event in client.serverEvents {
                if case let .registerWatchedFiles(id, globs) = event { return (id, globs) }
            }
            return nil
        }
        await server.registerWatchedFiles(registrationID: "watch-1", requestID: 99, globs: ["**/*.swift"])

        let result = await received.value
        XCTAssertEqual(result?.0, "watch-1")
        XCTAssertEqual(result?.1, ["**/*.swift"])

        await client.shutdown()
        server.stop()
    }

    func testProgressDrivesReadinessIndexingThenReady() async throws {
        let (client, server) = await makeClient()
        try await client.initialize(rootURI: "file:///proj")
        // No progress in flight after initialize → ready.
        let initial = await client.readinessState
        XCTAssertEqual(initial, .ready)

        await server.progress(token: "idx", kind: "begin")
        try await waitForReadiness(.indexing, on: client)

        await server.progress(token: "idx", kind: "end")
        try await waitForReadiness(.ready, on: client)

        await client.shutdown()
        server.stop()
    }

    /// Polls readiness until it reaches `expected`, since notification handling is async.
    /// Fails (rather than hanging) if it never gets there.
    private func waitForReadiness(
        _ expected: ReadinessState, on client: StdioLSPClient,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        for _ in 0..<200 {
            if await client.readinessState == expected { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        let actual = await client.readinessState
        XCTFail("readiness never reached \(expected); last was \(actual)", file: file, line: line)
    }
}
