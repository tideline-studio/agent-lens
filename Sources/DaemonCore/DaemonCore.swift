import Dependencies
import FileSystemWatcher
import Foundation
import IPC
import Linter
import Logging
import LSPClient
import LSPServerDetection

public actor DaemonCore: CoreProtocol {
    private let root: URL
    private let startDate: Date

    @Dependency(\.fileSystem) private var fileSystem
    @Dependency(\.linterFactory) private var linterFactory
    @Dependency(\.fileSystemWatcher) private var fileSystemWatcher

    private var linterConfig: LinterConfig = .defaults
    private var serverRouter: ServerRouter?
    private let watchCoordinator: WatchCoordinator
    private let logger: Logger

    public init(root: URL, logger: Logger) {
        self.root = root
        self.startDate = Date()
        self.logger = logger
        self.watchCoordinator = WatchCoordinator(logger: logger)
    }

    // MARK: - Services

    // Constructed from current state rather than cached: `serverRouter` starts nil and
    // is set once in `start()`, so this naturally stays nil until then; lint must keep
    // working before `start()` runs, so `linterConfig` defaults until it's loaded from disk.
    private var diagnosticsService: DiagnosticsService? {
        serverRouter.map { DiagnosticsService(router: $0, fileSystem: fileSystem) }
    }

    private var lintService: LintService {
        LintService(config: linterConfig, factory: linterFactory)
    }

    // MARK: - Startup

    /// Sets up the server router and infrastructure. LSP clients start lazily on first use.
    /// Called once from the daemon executable; safe to skip in tests that don't need routing.
    public func start() async throws {
        let router = withDependencies(from: self) {
            ServerRouter(
                root: root,
                lspConfig: LSPConfig.load(from: root),
                logger: logger,
                onClientStarted: { [weak self] client in
                    await self?.subscribeToEvents(from: client)
                }
            )
        }
        serverRouter = router

        linterConfig = LinterConfig.load(from: root) ?? .defaults

        let coordinator = watchCoordinator
        try await fileSystemWatcher.start(root: root) { event in
            await coordinator.handlePathEvent(event, router: router)
        }
    }

    private func subscribeToEvents(from client: any LSPClient) async {
        let serverID = await client.serverID
        let events = await client.serverEvents
        let coordinator = watchCoordinator
        Task {
            for await event in events {
                await coordinator.registerServerEvent(event, serverID: serverID)
            }
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

    // MARK: - Command handlers

    private func computeDiagnose(
        files: [String],
        timeoutSeconds: Double
    ) async -> [String: FileDiagnostics] {
        guard let diagnosticsService else { return [:] }
        return await diagnosticsService.diagnose(files: files, timeoutSeconds: timeoutSeconds)
    }

    private func computeLint(files: [String]) async -> [String: String] {
        await lintService.lint(files: files)
    }
}
