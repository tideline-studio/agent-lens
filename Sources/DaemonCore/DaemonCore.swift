import Dependencies
import FileSystemWatcher
import Foundation
import IPC
import LSPClient
import Linter
import Logging

public actor DaemonCore: CoreProtocol {
    private let root: URL
    private let startDate: Date

    @Dependency(\.fileSystem) private var fileSystem
    @Dependency(\.lspServerDetection) private var detection
    @Dependency(\.linterFactory) private var linterFactory
    @Dependency(\.fileSystemWatcher) private var fileSystemWatcher

    private var linterConfig: LinterConfig = .defaults
    private var serverRouter: ServerRouter?
    private let watchRegistry = WatchRegistry()
    private let logger: Logger

    public init(root: URL, logger: Logger) {
        self.root = root
        self.startDate = Date()
        self.logger = logger
    }

    // MARK: - Startup

    /// Detects project languages and starts LSP clients.
    /// Called once from the daemon executable; safe to skip in tests that don't need routing.
    public func start() async throws {
        let result = try await detection.detect(root: root)
        let router = withDependencies(from: self) {
            ServerRouter(detection: result, logger: logger)
        }
        serverRouter = router
        await router.start()
        logger.info("started \(result.lspServers.count) LSP server(s)")

        // Send the LSP initialize handshake so each server can begin indexing.
        let clients = await router.allClients()
        for client in clients {
            let sid = await client.serverID
            do {
                try await client.initialize(rootURI: root.absoluteString)
            } catch {
                logger.warning("LSP initialize failed for \(sid): \(error)")
            }
        }

        // Subscribe to each client's server-initiated events.
        for client in clients {
            let serverID = await client.serverID
            let events = await client.serverEvents
            Task { [weak self] in
                for await event in events {
                    await self?.handleServerEvent(event, serverID: serverID)
                }
            }
        }

        // Load linter config from .alens.json (falls back to built-in defaults).
        linterConfig = LinterConfig.load(from: root) ?? .defaults

        // Start FSEvents watcher.
        let wr = watchRegistry
        let rt = router
        let log = logger
        try await fileSystemWatcher.start(root: root) { [weak self] event in
            await self?.handlePathEvent(event, watchRegistry: wr, router: rt, logger: log)
        }
    }

    // MARK: - RequestDispatcher

    public func dispatch(_ request: Request) async -> ResponseResult {
        switch request.command {

        case .start:
            return .ok(.ack)

        case .stop:
            logger.info("stop command received")
            return .ok(.ack)

        case .status:
            let uptime = Date().timeIntervalSince(startDate)
            let allClients = await serverRouter?.allClients() ?? []
            var statuses: [ServerStatus] = []
            for client in allClients {
                let sid = await client.serverID
                let state = await client.readinessState
                statuses.append(ServerStatus(language: sid, readinessState: state))
            }
            return .ok(.status(StatusReport(servers: statuses, uptimeSeconds: uptime)))

        case .diagnose(let files, let timeoutSeconds):
            if let err = firstPathError(in: files) { return .err(err) }
            return .ok(.diagnose(await computeDiagnose(files: files, timeoutSeconds: timeoutSeconds)))

        case .lint(let files):
            if let err = firstPathError(in: files) { return .err(err) }
            return .ok(.lint(await computeLint(files: files)))

        case .check(let files, let timeoutSeconds):
            if let err = firstPathError(in: files) { return .err(err) }
            async let diags = computeDiagnose(files: files, timeoutSeconds: timeoutSeconds)
            async let lints = computeLint(files: files)
            return .ok(.check(diagnostics: await diags, lint: await lints))
        }
    }

    private func firstPathError(in paths: [String]) -> ErrorPayload? {
        for path in paths {
            if !isWithinRoot(path, root: root) {
                return ErrorPayload(
                    code: .pathOutsideRoot, message: "\(path) is outside daemon root \(root.path)")
            }
            guard let stat = try? fileSystem.stat(path) else {
                return ErrorPayload(
                    code: .fileNotFound, message: "\(path) does not exist")
            }
            if stat.isDirectory {
                return ErrorPayload(
                    code: .pathIsDirectory, message: "\(path) is a directory, not a file")
            }
        }
        return nil
    }

    // MARK: - Diagnose

    private func computeDiagnose(
        files: [String],
        timeoutSeconds: Double
    ) async -> [String: FileDiagnostics] {
        guard let router = serverRouter else {
            return [:]
        }

        // Diagnose exactly the files the caller passed — no expansion, ordering, or cap.
        // Group by language. Files whose extension maps to no language aren't
        // diagnosable at all — report them as unsupported (not stale, which implies
        // a result might still arrive).
        var groups: [Language: [String]] = [:]
        var results: [String: FileDiagnostics] = [:]
        for path in files {
            if let lang = Language.from(path: path) {
                groups[lang, default: []].append(path)
            } else {
                results[path] = FileDiagnostics(
                    diagnostics: [],
                    readinessState: .unsupported,
                    stale: false
                )
            }
        }

        let timeout = Duration.seconds(timeoutSeconds)

        let grouped = await withTaskGroup(of: [String: FileDiagnostics].self) { tg in
            for (_, paths) in groups {
                guard let client = await router.lspClient(for: paths[0]) else {
                    // No LSP client for this (supported) language — return stale so
                    // callers know "no server" rather than getting a silent omission.
                    tg.addTask {
                        Dictionary(
                            uniqueKeysWithValues: paths.map { path in
                                (
                                    path,
                                    FileDiagnostics(
                                        diagnostics: [], readinessState: .initial, stale: true)
                                )
                            })
                    }
                    continue
                }
                let fs = fileSystem
                tg.addTask {
                    await self.diagnoseGroup(
                        client: client, paths: paths, timeout: timeout, fileSystem: fs)
                }
            }
            var combined: [String: FileDiagnostics] = [:]
            for await partial in tg { combined.merge(partial) { _, new in new } }
            return combined
        }
        results.merge(grouped) { _, new in new }
        return results
    }

    private func diagnoseGroup(
        client: any LSPClient,
        paths: [String],
        timeout: Duration,
        fileSystem: FileSystem
    ) async -> [String: FileDiagnostics] {
        // Read each file into a DocumentInput; the client owns the open/change/version
        // decision. Files that can't be stat'd are reported stale (we never saw them).
        var inputs: [DocumentInput] = []
        var uriToPath: [String: String] = [:]
        var result: [String: FileDiagnostics] = [:]
        for path in paths {
            guard let stat = try? fileSystem.stat(path) else {
                result[path] = FileDiagnostics(diagnostics: [], readinessState: .ready, stale: true)
                continue
            }
            let uri = "file://\(path)"
            let text =
                (try? fileSystem.contents(path)).map { String(data: $0, encoding: .utf8) ?? "" }
                ?? ""
            inputs.append(
                DocumentInput(
                    uri: uri, languageId: languageID(for: path), text: text,
                    mtimeNs: stat.mtimeNs, size: stat.size
                ))
            uriToPath[uri] = path
        }

        let batches = await client.diagnose(inputs, timeout: timeout)
        let readiness = await client.readinessState
        for (uri, batch) in batches {
            guard let path = uriToPath[uri] else { continue }
            result[path] = FileDiagnostics(
                diagnostics: batch.diagnostics,
                readinessState: readiness,
                stale: !batch.arrived
            )
        }
        return result
    }

    // MARK: - Lint

    private func computeLint(files: [String]) async -> [String: String] {
        let factory = linterFactory
        let config = linterConfig

        // Group by language so each linter runs once for its whole batch, not once per
        // file. Files with no linter still get an empty result so callers see them.
        var byLanguage: [Language: [String]] = [:]
        var results: [String: String] = [:]
        for path in files {
            if let lang = Language.from(path: path), factory(lang, config) != nil {
                byLanguage[lang, default: []].append(path)
            } else {
                results[path] = ""
            }
        }

        let batched = await withTaskGroup(of: [String: String].self) { tg in
            for (lang, paths) in byLanguage {
                guard let linter = factory(lang, config) else { continue }
                tg.addTask {
                    if let out = try? await linter.lint(files: paths) { return out }
                    return Dictionary(uniqueKeysWithValues: paths.map { ($0, "") })
                }
            }
            var combined: [String: String] = [:]
            for await partial in tg { combined.merge(partial) { _, new in new } }
            return combined
        }
        results.merge(batched) { _, new in new }
        return results
    }

    // MARK: - Server event handling

    private func handleServerEvent(_ event: ServerEvent, serverID: ServerID) async {
        switch event {
        case .registerWatchedFiles(let id, let globs):
            await watchRegistry.register(id, serverID: serverID, globs: globs)
        case .unregisterWatchedFiles(let id):
            await watchRegistry.unregister(id)
        case .showMessage(let level, let text):
            logger.info("[LSP:\(serverID)] \(level): \(text)")
        case .progress:
            break
        }
    }

    // MARK: - FSEvents filter pipeline

    private func handlePathEvent(
        _ event: FileEvent,
        watchRegistry: WatchRegistry,
        router: ServerRouter,
        logger: Logger
    ) async {
        let path = event.path

        // 1. Drop excluded directories (.git, node_modules, .build, DerivedData).
        guard !isExcludedPath(path) else { return }

        // 2. Find interested servers via their registered watch globs.
        let serverIDs = await watchRegistry.serversMatching(path: path)
        guard !serverIDs.isEmpty else { return }

        // 3. Open-file suppression: if an interested server already holds the file open,
        //    its edits are handled via stat-on-demand didChange during diagnose.
        let uri = "file://\(path)"
        let allClients = await router.allClients()
        for client in allClients where serverIDs.contains(await client.serverID) {
            if await client.isOpen(uri) { return }
        }

        // 4. Dispatch didChangeWatchedFiles to each interested server.
        let watchedEvent = WatchedFileEvent(uri: uri, kind: watchedKind(for: event.kind))
        for client in allClients {
            let sid = await client.serverID
            guard serverIDs.contains(sid) else { continue }
            try? await client.didChangeWatchedFiles([watchedEvent])
        }
    }

    private func watchedKind(for kind: FileEvent.Kind) -> WatchedFileEvent.Kind {
        switch kind {
        case .created: return .created
        case .modified: return .changed
        case .deleted: return .deleted
        }
    }

    private func languageID(for path: String) -> String {
        // The LSP languageId matches the Language raw value for every supported case.
        Language.from(path: path)?.rawValue ?? "plaintext"
    }
}
