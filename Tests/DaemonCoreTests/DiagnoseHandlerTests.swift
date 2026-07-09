import XCTest
import Foundation
import IPC
import LSPClient
import LSPServerDetection
import DaemonCore
import Dependencies

// MARK: - DiagnoseMockClient

final actor DiagnoseMockClient: LSPClient {
    nonisolated let serverID: ServerID
    private(set) var readinessState: ReadinessState = .ready
    nonisolated let serverEvents: AsyncStream<ServerEvent>

    // URIs passed to diagnose, in order. The open/change/no-op decision is the real
    // client's job now, covered by InProcessClientTests — not asserted through this mock.
    private(set) var diagnosedURIs: [String] = []
    private var pendingDiagnostics: [String: DiagnosticBatch] = [:]

    init(serverID: ServerID) {
        self.serverID = serverID
        self.serverEvents = AsyncStream { _ in }
    }

    func setDiagnostics(_ batch: DiagnosticBatch, for uri: String) {
        pendingDiagnostics[uri] = batch
    }

    func initialize(rootURI: DocumentURI) async throws {}
    func shutdown() async { readinessState = .stopped }

    func diagnose(_ documents: [DocumentInput], timeout: Duration) async -> [DocumentURI: DiagnosticBatch] {
        diagnosedURIs.append(contentsOf: documents.map(\.uri))
        var out: [DocumentURI: DiagnosticBatch] = [:]
        for doc in documents {
            out[doc.uri] = pendingDiagnostics[doc.uri] ?? DiagnosticBatch(diagnostics: [], version: nil, arrived: true)
        }
        return out
    }

    func didChangeWatchedFiles(_ events: [WatchedFileEvent]) async throws {}
    func isOpen(_ uri: DocumentURI) async -> Bool { false }
}

// MARK: - Helpers

private func makeDiagnosticCore(
    root: URL,
    client: DiagnoseMockClient,
    fileSystem: FileSystem
) -> DaemonCore {
    let serverID = client.serverID
    let config = ServerConfig(serverID: serverID, language: .swift, executable: "sourcekit-lsp")
    return withDependencies {
        $0.lspServerDetection = FixedLSPDetection(
            result: DetectionResult(lspServers: [config])
        )
        $0.lspClientFactory = { [client] _ in client }
        $0.fileSystem = fileSystem
    } operation: {
        DaemonCore(root: root, logger: .init(label: "test"))
    }
}

private func dispatch(core: DaemonCore, command: Command) async -> ResponseResult {
    await core.dispatch(Request(command: command))
}

private struct FixedLSPDetection: LSPServerDetection, Sendable {
    let result: DetectionResult
    func detect(root: URL) async throws -> DetectionResult { result }
}

// MARK: - Tests

final class DiagnoseHandlerTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("diagnose-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    func testFreshFileSendsDidOpenAndReturnsDiagnostics() async throws {
        let client = DiagnoseMockClient(serverID: "sourcekit-lsp")
        let path = root.appendingPathComponent("foo.swift").path
        let uri = "file://\(path)"

        let expectedDiag = Diagnostic(
            range: DiagnosticRange(
                start: Position(line: 0, character: 0),
                end: Position(line: 0, character: 3)
            ),
            severity: .error,
            message: "use of unresolved identifier 'foo'"
        )
        await client.setDiagnostics(
            DiagnosticBatch(diagnostics: [expectedDiag], version: 1, arrived: true),
            for: uri
        )

        let fs = FileSystem(
            contents: { _ in Data("let x = 1".utf8) },
            stat: { _ in FileStat(mtimeNs: 1000, size: 9) }
        )

        let core = makeDiagnosticCore(root: root, client: client, fileSystem: fs)
        try await core.start()

        let result = await dispatch(core: core, command: .diagnose(
            files: [path], timeoutSeconds: 5
        ))

        guard case .ok(.diagnose(let files)) = result else {
            XCTFail("expected .diagnose, got \(result)"); return
        }
        XCTAssertEqual(files[path]?.diagnostics.count, 1)
        XCTAssertEqual(files[path]?.diagnostics.first?.message, "use of unresolved identifier 'foo'")

        // DaemonCore passed the file to the client to diagnose. The open/change/no-op
        // decision itself lives in the client now (see InProcessClientTests).
        let diagnosed = await client.diagnosedURIs
        XCTAssertEqual(diagnosed, [uri])
    }

    func testTimeoutProducesStaleResult() async throws {
        let client = DiagnoseMockClient(serverID: "sourcekit-lsp")
        let path = root.appendingPathComponent("slow.swift").path
        let uri = "file://\(path)"

        // Set arrived: false to simulate a timeout.
        await client.setDiagnostics(
            DiagnosticBatch(diagnostics: [], version: 1, arrived: false),
            for: uri
        )

        let fs = FileSystem(
            contents: { _ in Data("let s = 1".utf8) },
            stat: { _ in FileStat(mtimeNs: 1000, size: 9) }
        )

        let core = makeDiagnosticCore(root: root, client: client, fileSystem: fs)
        try await core.start()

        let result = await dispatch(core: core, command: .diagnose(files: [path], timeoutSeconds: 5))

        guard case .ok(.diagnose(let files)) = result else {
            XCTFail("expected .diagnose"); return
        }
        let stale = files[path]?.stale
        XCTAssertEqual(stale, true)
    }

    func testDiagnosesEveryPassedFileWithoutTruncating() async throws {
        let client = DiagnoseMockClient(serverID: "sourcekit-lsp")
        let fs = FileSystem(
            contents: { _ in Data() },
            stat: { _ in FileStat(mtimeNs: 0, size: 0) }
        )
        let core = makeDiagnosticCore(root: root, client: client, fileSystem: fs)
        try await core.start()
        _ = await dispatch(core: core, command: .start(idleSeconds: 0, logLevel: .info))

        // The daemon checks exactly the files passed — no cap, no dropped files.
        let paths = (1...5).map { root.appendingPathComponent("File\($0).swift").path }
        let result = await dispatch(core: core, command: .diagnose(files: paths, timeoutSeconds: 5))
        guard case .ok(.diagnose(let files)) = result else {
            XCTFail("expected .diagnose, got \(result)"); return
        }
        XCTAssertEqual(files.count, 5)
        for path in paths { XCTAssertNotNil(files[path], "every passed file must be diagnosed") }
    }

    func testUnroutedFileReturnsStalePlaceholder() async throws {
        let client = DiagnoseMockClient(serverID: "sourcekit-lsp")
        let swiftPath = root.appendingPathComponent("ok.swift").path
        let txtPath = root.appendingPathComponent("readme.txt").path

        let fs = FileSystem(
            contents: { _ in Data() },
            stat: { _ in FileStat(mtimeNs: 0, size: 0) }
        )

        let core = makeDiagnosticCore(root: root, client: client, fileSystem: fs)
        try await core.start()

        let result = await dispatch(
            core: core,
            command: .diagnose(files: [swiftPath, txtPath], timeoutSeconds: 5)
        )

        guard case .ok(.diagnose(let files)) = result else {
            XCTFail("expected .diagnose"); return
        }
        // .txt maps to no language → unsupported, not stale (no result will ever come).
        XCTAssertEqual(files[txtPath]?.readinessState, .unsupported)
        XCTAssertEqual(files[txtPath]?.stale, false)
        // .swift is handled normally.
        XCTAssertNotNil(files[swiftPath])
    }
}
