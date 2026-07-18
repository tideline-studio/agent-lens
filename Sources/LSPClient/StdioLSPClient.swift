import Foundation
import IPC
import JSONRPC
import LanguageServerProtocol
import Subprocess
import System

public enum LSPClientError: Error, Sendable {
    case serverError(code: Int?, message: String)
    case processExited
}

/// Actor-based LSP client. The subprocess is owned via swift-subprocess; JSON-RPC
/// request/response correlation and notification dispatch come from ChimeHQ's
/// JSONRPCSession over a DataChannel wired to the process's stdio. Content-Length
/// framing is applied in the DataChannel adapter (see frameJSONRPCMessage /
/// LSPFrameDecoder). LSP message params use LanguageServerProtocol types except
/// where those are type-erased (LSPAny), where small local structs are clearer.
public actor StdioLSPClient: LSPClient {
    public nonisolated let serverID: ServerID
    public private(set) var readinessState: ReadinessState = .initial
    public nonisolated let serverEvents: AsyncStream<ServerEvent>

    private var strategy: any DiagnosticsStrategy
    private let serverEventsCont: AsyncStream<ServerEvent>.Continuation
    private let session: JSONRPCSession
    /// Closes the subprocess's stdin stream on shutdown. `nil` when the transport is
    /// caller-provided (see `connect`) and there is no subprocess stdin to close.
    private let outbound: AsyncStream<[UInt8]>.Continuation?
    /// Drives diagnostics timeouts. Injectable so the wait/timeout path is testable on a
    /// fake clock instead of wall time; defaults to the real monotonic clock.
    private let clock: any Clock<Duration>
    private var runTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?

    private var progressTokens: Set<String> = []
    private var hasInitialized = false
    /// Kept to pass to PullStrategy when initialize detects diagnosticProvider.
    private let maxOpenDocuments: Int

    private init(
        serverID: ServerID,
        serverEvents: AsyncStream<ServerEvent>,
        serverEventsCont: AsyncStream<ServerEvent>.Continuation,
        session: JSONRPCSession,
        outbound: AsyncStream<[UInt8]>.Continuation?,
        clock: any Clock<Duration>,
        maxOpenDocuments: Int
    ) {
        self.serverID = serverID
        self.serverEvents = serverEvents
        self.serverEventsCont = serverEventsCont
        self.session = session
        self.outbound = outbound
        self.clock = clock
        self.maxOpenDocuments = max(1, maxOpenDocuments)
        self.strategy = PushStrategy(session: session, clock: clock, maxOpenDocuments: maxOpenDocuments)
        self.readinessState = .starting
    }

    // MARK: - Factory

    public static func start(
        config: ServerConfig,
        clock: any Clock<Duration> = ContinuousClock(),
        maxOpenDocuments: Int = 48
    ) async throws -> StdioLSPClient {
        let (outStream, outboundCont) = AsyncStream.makeStream(of: [UInt8].self)
        let (inStream, inboundCont) = AsyncStream.makeStream(of: Data.self)

        // DataChannel bridges JSONRPCSession to the process: writes are framed and
        // queued for stdin; reads are whole messages decoded from stdout.
        let channel = DataChannel(
            writeHandler: { data in outboundCont.yield([UInt8](frameJSONRPCMessage(data))) },
            dataSequence: inStream
        )
        let session = JSONRPCSession(channel: channel)

        let (evStream, evCont) = AsyncStream.makeStream(of: ServerEvent.self)

        let client = StdioLSPClient(
            serverID: config.serverID,
            serverEvents: evStream,
            serverEventsCont: evCont,
            session: session,
            outbound: outboundCont,
            clock: clock,
            maxOpenDocuments: maxOpenDocuments
        )
        await client.startEventLoop()
        await client.spawn(
            executable: config.executable, args: config.args, env: config.env,
            workingDirectory: config.workingDirectory,
            outStream: outStream, inboundCont: inboundCont
        )
        return client
    }

    /// Connects over a caller-provided JSON-RPC channel instead of spawning a subprocess.
    /// The transport and its lifecycle belong to the caller; this only runs the protocol
    /// loop. Used by tests to drive the client from an in-process mock server (and a seam
    /// for any future non-subprocess transport).
    static func connect(
        serverID: ServerID,
        channel: DataChannel,
        clock: any Clock<Duration> = ContinuousClock(),
        maxOpenDocuments: Int = 48
    ) async -> StdioLSPClient {
        let session = JSONRPCSession(channel: channel)
        let (evStream, evCont) = AsyncStream.makeStream(of: ServerEvent.self)
        let client = StdioLSPClient(
            serverID: serverID,
            serverEvents: evStream,
            serverEventsCont: evCont,
            session: session,
            outbound: nil,
            clock: clock,
            maxOpenDocuments: maxOpenDocuments
        )
        await client.startEventLoop()
        return client
    }

    /// Drains the JSON-RPC session's inbound events into `handle`. Transport-agnostic.
    private func startEventLoop() {
        let session = self.session
        eventTask = Task { [weak self] in
            let events = await session.eventSequence
            for await event in events {
                await self?.handle(event)
            }
        }
    }

    private func spawn(
        executable: String, args: [String], env: [String: String],
        workingDirectory: URL?,
        outStream: AsyncStream<[UInt8]>, inboundCont: AsyncStream<Data>.Continuation
    ) {
        let environment: Environment = env.isEmpty
            ? .inherit
            : .inherit.updating(Dictionary(
                uniqueKeysWithValues: env.map { (Environment.Key(stringLiteral: $0.key), Optional($0.value)) }
            ))
        let cwd = workingDirectory.map { FilePath($0.path) }

        runTask = Task { [weak self] in
            do {
                _ = try await Subprocess.run(
                    .name(executable),
                    arguments: Arguments(args),
                    environment: environment,
                    workingDirectory: cwd,
                    input: .inputWriter,
                    output: .sequence,
                    error: .discarded
                ) { execution in
                    await withTaskGroup(of: Void.self) { group in
                        group.addTask {
                            for await bytes in outStream {
                                _ = try? await execution.standardInputWriter.write(bytes)
                            }
                            try? await execution.standardInputWriter.finish()
                        }
                        group.addTask {
                            var decoder = LSPFrameDecoder()
                            do {
                                for try await chunk in execution.standardOutput {
                                    for data in decoder.push(chunk.withUnsafeBytes { Array($0) }) {
                                        inboundCont.yield(data)
                                    }
                                }
                            } catch { /* server exited mid-stream */ }
                        }
                        await group.next()
                        group.cancelAll()
                    }
                }
            } catch { /* failed to launch or process error */ }
            inboundCont.finish()
            await self?.handleServerExit()
        }
    }

    // MARK: - LSPClient protocol

    public func initialize(rootURI: DocumentURI) async throws {
        struct DiagCaps: Encodable { let relatedDocumentSupport = true }
        struct TextDocCaps: Encodable { let diagnostic = DiagCaps() }
        struct Capabilities: Encodable { let textDocument = TextDocCaps() }
        struct Params: Encodable {
            let processId: Int
            let rootUri: String
            let capabilities = Capabilities()
        }
        // Parse enough of the response to detect pull-diagnostic support.
        struct InitCaps: Decodable { var diagnosticProvider: JSONRPC.JSONValue? }
        struct InitResult: Decodable { var capabilities: InitCaps? }
        let result: InitResult? = try await session.response(
            to: "initialize",
            params: Params(processId: Int(ProcessInfo.processInfo.processIdentifier), rootUri: rootURI)
        )
        // Switch to pull strategy when the server declares diagnosticProvider.
        if result?.capabilities?.diagnosticProvider != nil {
            strategy = PullStrategy(session: session, clock: clock, maxOpenDocuments: maxOpenDocuments)
        }
        hasInitialized = true
        readinessState = .indexing
        if progressTokens.isEmpty { readinessState = .ready }
        try? await session.sendNotification(InitializedParams(), method: "initialized")
    }

    public func shutdown() async {
        let _: AnyResult? = try? await session.response(to: "shutdown")
        try? await session.sendNotification(method: "exit")
        outbound?.finish()
        runTask?.cancel()
        eventTask?.cancel()
    }

    public func diagnose(_ inputs: [DocumentInput], timeout: Duration) async -> [DocumentURI: DiagnosticBatch] {
        await strategy.diagnose(inputs, timeout: timeout)
    }

    public func isOpen(_ uri: DocumentURI) async -> Bool {
        await strategy.isOpen(uri)
    }

    public func didChangeWatchedFiles(_ events: [WatchedFileEvent]) async throws {
        let changes = events.map { e -> LanguageServerProtocol.FileEvent in
            let type: FileChangeType
            switch e.kind {
            case .created: type = .created
            case .changed: type = .changed
            case .deleted: type = .deleted
            }
            return LanguageServerProtocol.FileEvent(uri: e.uri, type: type)
        }
        try await session.sendNotification(
            DidChangeWatchedFilesParams(changes: changes),
            method: "workspace/didChangeWatchedFiles"
        )
    }

    // MARK: - Server→client dispatch

    func handleServerExit() async {
        readinessState = .stopped
        serverEventsCont.finish()
    }

    private func handle(_ event: JSONRPCEvent) async {
        switch event {
        case .notification(let note, let data):
            await handleNotification(method: note.method, data: data)
        case .request(_, let reply, let data):
            await handleServerRequest(data: data, reply: reply)
        case .error:
            break
        }
    }

    private func handleNotification(method: String, data: Data) async {
        switch method {
        case "textDocument/publishDiagnostics":
            guard let note = try? JSONDecoder().decode(JSONRPCNotification<PublishDiagnosticsParams>.self, from: data),
                  let params = note.params else { return }
            await strategy.receivePublish(
                uri: params.uri,
                batch: DiagnosticBatch(
                    diagnostics: params.diagnostics.map(mapLSPDiagnostic),
                    version: params.version,
                    arrived: true
                )
            )
        case "window/showMessage", "window/logMessage":
            guard let note = try? JSONDecoder().decode(JSONRPCNotification<ShowMessageParams>.self, from: data),
                  let params = note.params else { return }
            serverEventsCont.yield(.showMessage(level: messageLevel(params.type.rawValue), text: params.message))
        case "$/progress":
            guard let note = try? JSONDecoder().decode(JSONRPCNotification<ProgressNote>.self, from: data),
                  let params = note.params else { return }
            handleProgress(token: params.token, kind: params.value.kind)
        default:
            break
        }
    }

    private func handleServerRequest(data: Data, reply: JSONRPCEvent.RequestHandler) async {
        // Parse the watched-files (un)registration we care about; reply null to all,
        // mirroring the prior behaviour (servers expect a response to every request).
        if let req = try? JSONDecoder().decode(JSONRPCRequest<RegistrationNote>.self, from: data),
           let regs = req.params?.registrations {
            for reg in regs where reg.method == "workspace/didChangeWatchedFiles" {
                let globs = (reg.registerOptions?.watchers ?? []).compactMap { $0.globPattern }
                serverEventsCont.yield(.registerWatchedFiles(id: reg.id, globs: globs))
            }
        } else if let req = try? JSONDecoder().decode(JSONRPCRequest<UnregistrationNote>.self, from: data) {
            for unreg in req.params?.unregisterations ?? [] {
                serverEventsCont.yield(.unregisterWatchedFiles(id: unreg.id))
            }
        }
        await reply(.success(JSONRPC.JSONValue.null))
    }

    private func handleProgress(token: String, kind: String) {
        guard let progressKind = ProgressKind(rawValue: kind) else { return }
        switch progressKind {
        case .begin:
            progressTokens.insert(token)
            if hasInitialized && readinessState == .ready { readinessState = .indexing }
        case .report:
            break
        case .end:
            progressTokens.remove(token)
            if progressTokens.isEmpty && hasInitialized { readinessState = .ready }
        }
        serverEventsCont.yield(.progress(token: token, kind: progressKind))
    }

    private func messageLevel(_ type: Int) -> MessageLevel {
        switch type {
        case 1: return .error
        case 2: return .warning
        case 3: return .info
        default: return .log
        }
    }
}

// MARK: - Local shapes for type-erased LSP payloads
//
// LanguageServerProtocol models these with LSPAny / TwoTypeOption, so digging out
// the one field we need is cleaner with a focused local type.

private struct ProgressNote: Decodable { let token: String; let value: ProgressValue }
private struct ProgressValue: Decodable { let kind: String }
private struct RegistrationNote: Decodable { let registrations: [Reg] }
private struct Reg: Decodable { let id: String; let method: String; let registerOptions: RegOptions? }
private struct RegOptions: Decodable { let watchers: [Watcher]? }
private struct Watcher: Decodable { let globPattern: String? }  // string form only
private struct UnregistrationNote: Decodable { let unregisterations: [Unreg]? }
private struct Unreg: Decodable { let id: String }
private struct AnyResult: Decodable {}  // decode-and-ignore for results we don't use
