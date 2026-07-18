import FileSystemWatcher
import Foundation

/// Drives FSEvents tests by emitting synthetic events on demand.
actor FakeFileSystemWatcher: FileSystemWatcher {
    private var sink: (@Sendable (FileEvent) async -> Void)?

    func start(root: URL, sink: @Sendable @escaping (FileEvent) async -> Void) async throws {
        self.sink = sink
    }

    func stop() async { sink = nil }

    func emit(_ event: FileEvent) async {
        await sink?(event)
    }
}
