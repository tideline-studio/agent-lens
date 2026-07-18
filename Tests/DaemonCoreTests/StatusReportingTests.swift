import DaemonCore
import Dependencies
import Foundation
import IPC
import LSPClient
import XCTest

// Re-uses MockLSPClient from ServerRouterTests — duplicated here to avoid cross-target sharing.
private final actor StatusMockClient: LSPClient {
    nonisolated let serverID: ServerID
    private(set) var readinessState: ReadinessState
    nonisolated let serverEvents: AsyncStream<ServerEvent>

    init(serverID: ServerID, state: ReadinessState) {
        self.serverID = serverID
        self.readinessState = state
        self.serverEvents = AsyncStream { _ in }
    }

    func initialize(rootURI: DocumentURI) async throws {}
    func shutdown() async { readinessState = .stopped }
    func diagnose(_ documents: [DocumentInput], timeout: Duration) async -> [DocumentURI: DiagnosticBatch] {
        Dictionary(uniqueKeysWithValues: documents.map { ($0.uri, DiagnosticBatch(diagnostics: [], version: nil, arrived: false)) })
    }
    func didChangeWatchedFiles(_ events: [WatchedFileEvent]) async throws {}
    func isOpen(_ uri: DocumentURI) async -> Bool { false }
}

private func dispatch(core: DaemonCore, command: Command) async -> ResponseResult {
    await core.dispatch(Request(command: command))
}

final class StatusReportingTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("status-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    func testStatusWithNoRouterReturnsEmptyServers() async throws {
        let core = DaemonCore(root: root, logger: .init(label: "test"))
        let result = await dispatch(core: core, command: .status)
        guard case .ok(.status(let report)) = result else {
            XCTFail("expected .status, got \(result)"); return
        }
        XCTAssertTrue(report.servers.isEmpty)
    }

    func testStatusReportsPerLanguageReadinessState() async throws {
        let swiftMock = StatusMockClient(serverID: "sourcekit-lsp", state: .ready)
        let tsMock = StatusMockClient(serverID: "typescript-language-server", state: .indexing)

        let factory: @Sendable (ServerConfig) async throws -> any LSPClient = { config in
            if config.language == .swift { return swiftMock }
            return tsMock
        }

        let core = withDependencies {
            $0.lspClientFactory = factory
            $0.fileSystem = FileSystem(
                contents: { _ in Data() },
                stat: { _ in FileStat(mtimeNs: 1, size: 0) }
            )
        } operation: {
            DaemonCore(root: root, logger: .init(label: "test"))
        }

        try await core.start()

        // Trigger lazy start for both languages so status sees them.
        let swiftPath = root.appendingPathComponent("foo.swift").path
        let tsPath = root.appendingPathComponent("index.ts").path
        _ = await dispatch(core: core, command: .diagnose(files: [swiftPath, tsPath], timeoutSeconds: 1))

        let result = await dispatch(core: core, command: .status)

        guard case .ok(.status(let report)) = result else {
            XCTFail("expected .status, got \(result)"); return
        }
        XCTAssertEqual(report.servers.count, 2)

        let swiftStatus = report.servers.first { $0.language == "sourcekit-lsp" }
        XCTAssertEqual(swiftStatus?.readinessState, .ready)

        let tsStatus = report.servers.first { $0.language == "typescript-language-server" }
        XCTAssertEqual(tsStatus?.readinessState, .indexing)
    }
}
