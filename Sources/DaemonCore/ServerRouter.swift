import Dependencies
import Foundation
import IPC
import Logging
import LSPClient
import LSPServerDetection

public actor ServerRouter {
    @Dependency(\.lspClientFactory) private var lspClientFactory

    private let root: URL
    // nil = no lspServers key in .alens.json → use built-in defaults
    // non-nil (even empty) = use exactly these servers, no fallback to defaults
    private let customConfigs: [Language: ServerConfig]?
    private let logger: Logger
    private let onClientStarted: @Sendable (any LSPClient) async -> Void

    // Completed starts
    private var clients: [Language: any LSPClient] = [:]
    // In-flight starts — stored synchronously before any await so concurrent
    // callers for the same language join the same task instead of double-starting.
    private var startTasks: [Language: Task<(any LSPClient)?, Never>] = [:]
    private var isStopped = false

    private static let defaults: [Language: ServerConfig] = [
        .swift: ServerConfig(serverID: "sourcekit-lsp", language: .swift, executable: "sourcekit-lsp"),
        .typescript: ServerConfig(serverID: "typescript-language-server", language: .typescript, executable: "typescript-language-server", args: ["--stdio"]),
        .python: ServerConfig(serverID: "pyright-langserver", language: .python, executable: "pyright-langserver", args: ["--stdio"]),
        .go: ServerConfig(serverID: "gopls", language: .go, executable: "gopls"),
        .rust: ServerConfig(serverID: "rust-analyzer", language: .rust, executable: "rust-analyzer")
    ]

    public init(
        root: URL,
        lspConfig: LSPConfig?,
        logger: Logger,
        onClientStarted: @escaping @Sendable (any LSPClient) async -> Void
    ) {
        self.root = root
        self.customConfigs = lspConfig.map { config in
            Dictionary(
                config.serverConfigs().map { ($0.language, $0) },
                uniquingKeysWith: { first, _ in first }
            )
        }
        self.logger = logger
        self.onClientStarted = onClientStarted
    }

    // MARK: - Client access

    public func lspClient(for path: String) async -> (any LSPClient)? {
        guard let lang = Language.from(path: path) else { return nil }
        return await clientForLanguage(lang)
    }

    private func clientForLanguage(_ language: Language) async -> (any LSPClient)? {
        // Fast path: already running.
        if let client = clients[language] { return client }

        // In-flight: join existing start task instead of spawning a second server.
        if let task = startTasks[language] { return await task.value }

        // No config for this language → can't start.
        guard let config = configForLanguage(language) else { return nil }

        // Capture actor-isolated state before the unstructured Task so the
        // closure is Sendable and doesn't need actor isolation itself.
        let factory = lspClientFactory
        let root = self.root
        let logger = self.logger
        let onClientStarted = self.onClientStarted
        let langName = language.rawValue

        // Store the task *synchronously* (before any await) so any concurrent
        // caller that enters between now and task completion joins this task.
        let task = Task<(any LSPClient)?, Never> {
            do {
                let configWithRoot = ServerConfig(
                    serverID: config.serverID,
                    language: config.language,
                    executable: config.executable,
                    args: config.args,
                    env: config.env,
                    initializationOptions: config.initializationOptions,
                    workingDirectory: root
                )
                let client = try await factory(configWithRoot)
                do {
                    try await client.initialize(rootURI: root.absoluteString)
                } catch {
                    logger.warning("LSP handshake failed for \(langName): \(error)")
                }
                await onClientStarted(client)
                return client
            } catch {
                logger.error("failed to start \(langName) LSP: \(error)")
                return nil
            }
        }
        startTasks[language] = task

        let client = await task.value
        startTasks.removeValue(forKey: language)
        // If stop() ran while we were awaiting, it already captured this task in its
        // inflight set and will shut down the client — don't store or return it.
        if let client, !isStopped {
            clients[language] = client
        }
        return isStopped ? nil : client
    }

    private func configForLanguage(_ language: Language) -> ServerConfig? {
        if let custom = customConfigs {
            return custom[language]  // explicit declaration — no fallback
        }
        return Self.defaults[language]
    }

    // MARK: - Accessors

    public func allClients() -> [any LSPClient] { Array(clients.values) }

    // MARK: - Shutdown

    public func stop() async {
        let inflight = Array(startTasks.values)
        let running  = Array(clients.values)
        startTasks = [:]
        clients    = [:]
        isStopped  = true
        inflight.forEach { $0.cancel() }
        // Await in-flight starts so any client the factory already returned is shut down,
        // not leaked. clientForLanguage checks isStopped after its own await and skips
        // the store, so there is no double-shutdown with a concurrent caller.
        await withTaskGroup(of: Void.self) { group in
            for task in inflight {
                group.addTask { if let c = await task.value { await c.shutdown() } }
            }
            for client in running {
                group.addTask { await client.shutdown() }
            }
        }
    }
}
