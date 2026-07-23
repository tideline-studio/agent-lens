import FileSystemWatcher
import IPC
import LSPClient
import Logging

/// Owns the file-watch registry and the FSEvents→LSP watch pipeline: which LSP
/// servers asked to be told about which globs, and turning raw filesystem events
/// into `didChangeWatchedFiles` notifications for the interested servers.
actor WatchCoordinator {
    private let registry = WatchRegistry()
    private let logger: Logger

    init(logger: Logger) {
        self.logger = logger
    }

    // MARK: - LSP server registration

    func registerServerEvent(_ event: ServerEvent, serverID: ServerID) async {
        switch event {
        case .registerWatchedFiles(let id, let globs):
            await registry.register(id, serverID: serverID, globs: globs)
        case .unregisterWatchedFiles(let id):
            await registry.unregister(id)
        case .showMessage(let level, let text):
            logger.info("[LSP:\(serverID)] \(level): \(text)")
        case .progress:
            break
        }
    }

    // MARK: - FSEvents filter pipeline

    func handlePathEvent(_ event: FileEvent, router: ServerRouter) async {
        let path = event.path

        // 1. Drop excluded directories (.git, node_modules, .build, DerivedData).
        guard !isExcludedPath(path) else { return }

        // 2. Find interested servers via their registered watch globs.
        let serverIDs = await registry.serversMatching(path: path)
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
}
