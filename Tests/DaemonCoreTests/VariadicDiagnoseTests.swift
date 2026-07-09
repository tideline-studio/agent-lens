import XCTest
import Foundation
import IPC
import LSPClient
import LSPServerDetection
import DaemonCore
import Dependencies

// MARK: - Helpers (local copies; not shared across test files due to access control)

private func variadicDispatch(core: DaemonCore, command: Command) async -> ResponseResult {
    await core.dispatch(Request(command: command))
}

private struct FixedDetection2: LSPServerDetection, Sendable {
    let result: DetectionResult
    func detect(root: URL) async throws -> DetectionResult { result }
}

// MARK: - VariadicDiagnoseTests

final class VariadicDiagnoseTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("variadic-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    func testMixedLanguageFanOutDiagnosesAllFiles() async throws {
        let swiftClient = DiagnoseMockClient2(serverID: "sourcekit-lsp")
        let tsClient = DiagnoseMockClient2(serverID: "typescript-language-server")

        let detection = DetectionResult(lspServers: [
            ServerConfig(serverID: "sourcekit-lsp", language: .swift, executable: "sourcekit-lsp"),
            ServerConfig(serverID: "ts-lsp",         language: .typescript, executable: "ts-lsp"),
        ])
        let factory: @Sendable (ServerConfig) async throws -> any LSPClient = { config in
            config.language == .swift ? swiftClient : tsClient
        }

        let swiftPath = root.appendingPathComponent("Main.swift").path
        let tsPath    = root.appendingPathComponent("index.ts").path

        let core = withDependencies {
            $0.lspServerDetection = FixedDetection2(result: detection)
            $0.lspClientFactory   = factory
            $0.fileSystem         = FileSystem(
                contents: { _ in Data("// ok".utf8) },
                stat: { _ in FileStat(mtimeNs: 1000, size: 5) }
            )
        } operation: {
            DaemonCore(root: root, logger: .init(label: "test"))
        }

        try await core.start()

        let result = await variadicDispatch(
            core: core,
            command: .diagnose(files: [swiftPath, tsPath], timeoutSeconds: 5)
        )

        guard case .ok(.diagnose(let files)) = result else {
            XCTFail("expected .diagnose, got \(result)"); return
        }
        XCTAssertNotNil(files[swiftPath], "swift file should have a result")
        XCTAssertNotNil(files[tsPath],    "ts file should have a result")
        XCTAssertEqual(files.count, 2)
    }

    func testPartialTimeoutMarksOneGroupStale() async throws {
        let swiftClient = DiagnoseMockClient2(serverID: "sourcekit-lsp")
        let tsClient    = DiagnoseMockClient2(serverID: "typescript-language-server")

        let swiftPath = root.appendingPathComponent("Main.swift").path
        let tsPath    = root.appendingPathComponent("index.ts").path
        let swiftURI  = "file://\(swiftPath)"
        let tsURI     = "file://\(tsPath)"

        // swift responds arrived=true; ts responds arrived=false (simulates timeout)
        await swiftClient.setDiagnostics(
            DiagnosticBatch(diagnostics: [], version: 1, arrived: true), for: swiftURI
        )
        await tsClient.setDiagnostics(
            DiagnosticBatch(diagnostics: [], version: 1, arrived: false), for: tsURI
        )

        let detection = DetectionResult(lspServers: [
            ServerConfig(serverID: "sourcekit-lsp", language: .swift, executable: "sourcekit-lsp"),
            ServerConfig(serverID: "ts-lsp",         language: .typescript, executable: "ts-lsp"),
        ])
        let factory: @Sendable (ServerConfig) async throws -> any LSPClient = { config in
            config.language == .swift ? swiftClient : tsClient
        }

        let core = withDependencies {
            $0.lspServerDetection = FixedDetection2(result: detection)
            $0.lspClientFactory   = factory
            $0.fileSystem         = FileSystem(
                contents: { _ in Data() },
                stat: { _ in FileStat(mtimeNs: 1, size: 0) }
            )
        } operation: {
            DaemonCore(root: root, logger: .init(label: "test"))
        }
        try await core.start()

        let result = await variadicDispatch(
            core: core,
            command: .diagnose(files: [swiftPath, tsPath], timeoutSeconds: 5)
        )

        guard case .ok(.diagnose(let files)) = result else {
            XCTFail("expected .diagnose"); return
        }
        XCTAssertEqual(files[swiftPath]?.stale, false, "swift arrived → not stale")
        XCTAssertEqual(files[tsPath]?.stale, true, "ts timed out → stale")
    }

    func testSameLanguageThreeFilesAllDiagnosed() async throws {
        let swiftClient = DiagnoseMockClient2(serverID: "sourcekit-lsp")
        let detection = DetectionResult(lspServers: [
            ServerConfig(serverID: "sourcekit-lsp", language: .swift, executable: "sourcekit-lsp"),
        ])

        let paths = (1...3).map { root.appendingPathComponent("File\($0).swift").path }

        let core = withDependencies {
            $0.lspServerDetection = FixedDetection2(result: detection)
            $0.lspClientFactory   = { _ in swiftClient }
            $0.fileSystem         = FileSystem(
                contents: { _ in Data("// ok".utf8) },
                stat: { _ in FileStat(mtimeNs: 1000, size: 5) }
            )
        } operation: {
            DaemonCore(root: root, logger: .init(label: "test"))
        }
        try await core.start()

        let result = await variadicDispatch(
            core: core,
            command: .diagnose(files: paths, timeoutSeconds: 5)
        )

        guard case .ok(.diagnose(let files)) = result else {
            XCTFail("expected .diagnose"); return
        }
        XCTAssertEqual(files.count, 3)
        for path in paths {
            XCTAssertNotNil(files[path], "\(path) should be diagnosed")
        }

        let diagnosed = await swiftClient.diagnosedURIs
        XCTAssertEqual(diagnosed.count, 3, "each file is passed to diagnose")
    }

    func testUnknownExtensionGetsStalePlaceholderRestSucceed() async throws {
        let swiftClient = DiagnoseMockClient2(serverID: "sourcekit-lsp")
        let detection = DetectionResult(lspServers: [
            ServerConfig(serverID: "sourcekit-lsp", language: .swift, executable: "sourcekit-lsp"),
        ])

        let swiftPath = root.appendingPathComponent("Valid.swift").path
        let txtPath   = root.appendingPathComponent("readme.txt").path

        let core = withDependencies {
            $0.lspServerDetection = FixedDetection2(result: detection)
            $0.lspClientFactory   = { _ in swiftClient }
            $0.fileSystem         = FileSystem(
                contents: { _ in Data() },
                stat: { _ in FileStat(mtimeNs: 1, size: 0) }
            )
        } operation: {
            DaemonCore(root: root, logger: .init(label: "test"))
        }
        try await core.start()

        let result = await variadicDispatch(
            core: core,
            command: .diagnose(files: [swiftPath, txtPath], timeoutSeconds: 5)
        )

        guard case .ok(.diagnose(let files)) = result else {
            XCTFail("expected .diagnose"); return
        }
        XCTAssertEqual(files[txtPath]?.readinessState, .unsupported, ".txt maps to no language → unsupported")
        XCTAssertEqual(files[txtPath]?.stale, false, "unsupported files are not stale")
        XCTAssertNotNil(files[swiftPath], ".swift is routed normally")
        XCTAssertEqual(files[swiftPath]?.stale, false)
    }
}

// MARK: - DiagnoseMockClient2 (local copy for this target)

final actor DiagnoseMockClient2: LSPClient {
    nonisolated let serverID: ServerID
    private(set) var readinessState: ReadinessState = .ready
    nonisolated let serverEvents: AsyncStream<ServerEvent>

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
