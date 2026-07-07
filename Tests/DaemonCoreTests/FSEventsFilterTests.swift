import XCTest
import Foundation
import IPC
import LSPClient
import LSPServerDetection
import FileSystemWatcher
import DaemonCore
import Dependencies

// MARK: - FilterMockClient

final actor FilterMockClient: LSPClient {
    nonisolated let serverID: ServerID
    private(set) var readinessState: ReadinessState = .ready
    nonisolated let serverEvents: AsyncStream<ServerEvent>
    private let eventsContinuation: AsyncStream<ServerEvent>.Continuation

    private(set) var watchedFilesEvents: [[WatchedFileEvent]] = []
    // Mirrors the real client: diagnose opens the document, isOpen reports it. The
    // FSEvents suppression test relies on this.
    private var openURIs: Set<DocumentURI> = []

    init(serverID: ServerID) {
        self.serverID = serverID
        var cont: AsyncStream<ServerEvent>.Continuation!
        self.serverEvents = AsyncStream { cont = $0 }
        self.eventsContinuation = cont
    }

    func sendServerEvent(_ event: ServerEvent) { eventsContinuation.yield(event) }

    func initialize(rootURI: DocumentURI) async throws {}
    func shutdown() async { readinessState = .stopped }
    func diagnose(_ documents: [DocumentInput], timeout: Duration) async -> [DocumentURI: DiagnosticBatch] {
        for doc in documents { openURIs.insert(doc.uri) }
        return Dictionary(uniqueKeysWithValues: documents.map { ($0.uri, DiagnosticBatch(diagnostics: [], version: nil, arrived: false)) })
    }
    func didChangeWatchedFiles(_ events: [WatchedFileEvent]) async throws {
        watchedFilesEvents.append(events)
    }
    func isOpen(_ uri: DocumentURI) async -> Bool { openURIs.contains(uri) }
}

// MARK: - Helpers

private func makeWatchCore(root: URL, client: FilterMockClient, watcher: FakeFileSystemWatcher) -> DaemonCore {
    let serverID = client.serverID
    let config = ServerConfig(serverID: serverID, language: .swift, executable: "sourcekit-lsp")
    return withDependencies {
        $0.lspServerDetection = FSFixedDetection(result: DetectionResult(lspServers: [config]))
        $0.lspClientFactory   = { [client] _ in client }
        $0.fileSystemWatcher  = watcher
        $0.fileSystem         = FileSystem(contents: { _ in Data() }, stat: { _ in FileStat(mtimeNs: 0, size: 0) })
    } operation: {
        DaemonCore(root: root, logger: .init(label: "test"))
    }
}

private struct FSFixedDetection: LSPServerDetection, Sendable {
    let result: DetectionResult
    func detect(root: URL) async throws -> DetectionResult { result }
}

// MARK: - Tests

final class FSEventsFilterTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fsevents-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    func testExcludedPathDropped() async throws {
        let watcher = FakeFileSystemWatcher()
        let client = FilterMockClient(serverID: "sourcekit-lsp")
        let core = makeWatchCore(root: root, client: client, watcher: watcher)
        try await core.start()

        // Register a glob that would match .swift files.
        await client.sendServerEvent(.registerWatchedFiles(id: "r1", globs: ["**/*.swift"]))
        try await Task.sleep(for: .milliseconds(50))  // let server-event task process

        // Emit an event inside .git — must be dropped.
        let gitPath = root.appendingPathComponent(".git/COMMIT_EDITMSG").path
        await watcher.emit(FileEvent(path: gitPath, kind: .modified))
        try await Task.sleep(for: .milliseconds(50))

        let calls = await client.watchedFilesEvents
        XCTAssertTrue(calls.isEmpty, "events under .git must be filtered out")
    }

    func testWatchedPatternMatchDispatches() async throws {
        let watcher = FakeFileSystemWatcher()
        let client = FilterMockClient(serverID: "sourcekit-lsp")
        let core = makeWatchCore(root: root, client: client, watcher: watcher)
        try await core.start()

        await client.sendServerEvent(.registerWatchedFiles(id: "r1", globs: ["**/Package.swift"]))
        try await Task.sleep(for: .milliseconds(50))

        let pkgPath = root.appendingPathComponent("Package.swift").path
        await watcher.emit(FileEvent(path: pkgPath, kind: .modified))
        try await Task.sleep(for: .milliseconds(100))

        let calls = await client.watchedFilesEvents
        XCTAssertFalse(calls.isEmpty, "Package.swift event should dispatch to swift server")
        XCTAssertEqual(calls.first?.first?.uri, "file://\(pkgPath)")
    }

    func testOpenFileSuppression() async throws {
        let watcher = FakeFileSystemWatcher()
        let client = FilterMockClient(serverID: "sourcekit-lsp")
        let core = makeWatchCore(root: root, client: client, watcher: watcher)
        try await core.start()

        await client.sendServerEvent(.registerWatchedFiles(id: "r1", globs: ["**/*.swift"]))
        try await Task.sleep(for: .milliseconds(50))

        // Simulate the file being already-open via FilesState.
        // We dispatch a diagnose command so DaemonCore records the file as open.
        let path = root.appendingPathComponent("Foo.swift").path
        let box = FSResultBox()
        let handle = RequestHandle(
            id: "1", receivedAt: ContinuousClock().now,
            command: .diagnose(files: [path], timeoutSeconds: 1)
        ) { r in await box.set(r) }
        await core.dispatch(handle)
        _ = await box.get()

        // Now emit an FSEvents event for the same file.
        await watcher.emit(FileEvent(path: path, kind: .modified))
        try await Task.sleep(for: .milliseconds(100))

        let calls = await client.watchedFilesEvents
        XCTAssertTrue(calls.isEmpty, "open file must be suppressed from didChangeWatchedFiles")
    }

    func testUnregisteredPatternDoesNotDispatch() async throws {
        let watcher = FakeFileSystemWatcher()
        let client = FilterMockClient(serverID: "sourcekit-lsp")
        let core = makeWatchCore(root: root, client: client, watcher: watcher)
        try await core.start()

        // Register then immediately unregister.
        await client.sendServerEvent(.registerWatchedFiles(id: "r1", globs: ["**/*.swift"]))
        try await Task.sleep(for: .milliseconds(50))
        await client.sendServerEvent(.unregisterWatchedFiles(id: "r1"))
        try await Task.sleep(for: .milliseconds(50))

        let path = root.appendingPathComponent("Foo.swift").path
        await watcher.emit(FileEvent(path: path, kind: .modified))
        try await Task.sleep(for: .milliseconds(100))

        let calls = await client.watchedFilesEvents
        XCTAssertTrue(calls.isEmpty, "after unregister, no events should dispatch")
    }
}

private actor FSResultBox {
    private var value: ResponseResult?
    func set(_ v: ResponseResult) { value = v }
    func get() -> ResponseResult? { value }
}
