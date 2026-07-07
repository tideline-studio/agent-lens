import Foundation
import IPC
import LSPClient
import LSPServerDetection
import Dependencies
import Logging

/// Routes file paths to their LSP client and linter by extension.
/// Owns the lifecycle of started LSP clients.
public actor ServerRouter {
    @Dependency(\.lspClientFactory) private var lspClientFactory

    private let detection: DetectionResult
    private let logger: Logger
    private var clients: [Language: any LSPClient] = [:]
    private var didStart = false

    public init(detection: DetectionResult, logger: Logger = Logger(label: "ServerRouter")) {
        self.detection = detection
        self.logger = logger
    }

    // MARK: - Lifecycle

    /// Boots every detected LSP client concurrently. Idempotent: a second call is
    /// a programming error and is logged and ignored rather than double-booting.
    public func start() async {
        guard !didStart else {
            logger.error("ServerRouter.start() called more than once; ignoring")
            return
        }
        didStart = true

        let factory = lspClientFactory
        let logger = self.logger
        await withTaskGroup(of: Void.self) { group in
            for config in detection.lspServers {
                group.addTask {
                    do {
                        let client = try await factory(config)
                        await self.storeClient(client, for: config.language)
                    } catch {
                        logger.error("failed to start LSP server for \(config.language.rawValue): \(error)")
                    }
                }
            }
        }
    }

    /// Shuts down all clients in parallel.
    public func stop() async {
        let all = Array(clients.values)
        clients = [:]
        await withTaskGroup(of: Void.self) { group in
            for client in all { group.addTask { await client.shutdown() } }
        }
    }

    // MARK: - Routing

    /// Returns the LSP client for the file's extension, or nil if unrouted.
    public func lspClient(for path: String) -> (any LSPClient)? {
        guard let lang = Language.from(path: path) else { return nil }
        return clients[lang]
    }

    /// All currently-started clients (used by `status` and graceful shutdown).
    public func allClients() -> [any LSPClient] {
        Array(clients.values)
    }

    private func storeClient(_ client: any LSPClient, for language: Language) {
        clients[language] = client
    }
}
