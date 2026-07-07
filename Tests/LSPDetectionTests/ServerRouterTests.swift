import XCTest
import Foundation
import IPC
import LSPClient
import LSPServerDetection
import DaemonCore
import Dependencies

// MARK: - MockLSPClient

final actor MockLSPClient: LSPClient {
    nonisolated let serverID: ServerID
    private(set) var readinessState: ReadinessState = .starting
    nonisolated let serverEvents: AsyncStream<ServerEvent>
    private let eventsCont: AsyncStream<ServerEvent>.Continuation
    var shutdownCalled = false

    init(serverID: ServerID) {
        self.serverID = serverID
        var cont: AsyncStream<ServerEvent>.Continuation!
        self.serverEvents = AsyncStream { cont = $0 }
        self.eventsCont = cont
    }

    func initialize(rootURI: DocumentURI) async throws {}
    func shutdown() async { shutdownCalled = true; readinessState = .stopped }
    func diagnose(_ documents: [DocumentInput], timeout: Duration) async -> [DocumentURI: DiagnosticBatch] {
        Dictionary(uniqueKeysWithValues: documents.map { ($0.uri, DiagnosticBatch(diagnostics: [], version: nil, arrived: false)) })
    }
    func didChangeWatchedFiles(_ events: [WatchedFileEvent]) async throws {}
    func isOpen(_ uri: DocumentURI) async -> Bool { false }
}

// MARK: - Tests

final class ServerRouterTests: XCTestCase {

    // MARK: - language(for:) routing table

    func testSwiftExtensionRoutesToSwift() {
        XCTAssertEqual(Language.from(path: "/tmp/foo.swift"), .swift)
    }

    func testTsExtensionRoutesToTypescript() {
        XCTAssertEqual(Language.from(path: "/tmp/foo.ts"), .typescript)
    }

    func testTsxExtensionRoutesToTypescript() {
        XCTAssertEqual(Language.from(path: "/tmp/foo.tsx"), .typescript)
    }

    func testJsExtensionRoutesToTypescript() {
        XCTAssertEqual(Language.from(path: "/tmp/foo.js"), .typescript)
    }

    func testPyExtensionRoutesToPython() {
        XCTAssertEqual(Language.from(path: "/tmp/foo.py"), .python)
    }

    func testGoExtensionRoutesToGo() {
        XCTAssertEqual(Language.from(path: "/tmp/foo.go"), .go)
    }

    func testRsExtensionRoutesToRust() {
        XCTAssertEqual(Language.from(path: "/tmp/foo.rs"), .rust)
    }

    func testUnknownExtensionReturnsNil() {
        XCTAssertNil(Language.from(path: "/tmp/foo.txt"))
        XCTAssertNil(Language.from(path: "/tmp/foo.md"))
        XCTAssertNil(Language.from(path: "/tmp/foo"))
    }

    // MARK: - start / routing / allClients

    func testStartCallsFactoryForEachDetectedServer() async throws {
        let swiftConfig = ServerConfig(serverID: "sk-lsp", language: .swift, executable: "sourcekit-lsp")
        let tsConfig = ServerConfig(serverID: "ts-lsp", language: .typescript, executable: "typescript-language-server")
        let detection = DetectionResult(lspServers: [swiftConfig, tsConfig])

        let collector = IDCollector()
        let factory: @Sendable (ServerConfig) async throws -> any LSPClient = { config in
            await collector.add(config.serverID)
            return MockLSPClient(serverID: config.serverID)
        }

        let router = withDependencies {
            $0.lspClientFactory = factory
        } operation: {
            ServerRouter(detection: detection)
        }

        await router.start()

        let createdIDs = await collector.ids
        XCTAssertEqual(Set(createdIDs), Set(["sk-lsp", "ts-lsp"]))
        let clients = await router.allClients()
        XCTAssertEqual(clients.count, 2)
    }

    func testLspClientForPathReturnsCorrectClient() async throws {
        let swiftConfig = ServerConfig(serverID: "sk-lsp", language: .swift, executable: "sourcekit-lsp")
        let detection = DetectionResult(lspServers: [swiftConfig])

        let factory: @Sendable (ServerConfig) async throws -> any LSPClient = { config in
            MockLSPClient(serverID: config.serverID)
        }
        let router = withDependencies { $0.lspClientFactory = factory } operation: {
            ServerRouter(detection: detection)
        }
        await router.start()

        let client = await router.lspClient(for: "/tmp/foo.swift")
        XCTAssertNotNil(client)
        let noClient = await router.lspClient(for: "/tmp/foo.py")
        XCTAssertNil(noClient)
    }

    func testStopShutdownsAllClients() async throws {
        let swiftConfig = ServerConfig(serverID: "sk-lsp", language: .swift, executable: "sourcekit-lsp")
        let detection = DetectionResult(lspServers: [swiftConfig])

        let box = MockClientBox()
        let factory: @Sendable (ServerConfig) async throws -> any LSPClient = { config in
            let m = MockLSPClient(serverID: config.serverID)
            await box.set(m)
            return m
        }
        let router = withDependencies { $0.lspClientFactory = factory } operation: {
            ServerRouter(detection: detection)
        }
        await router.start()
        await router.stop()

        let mock = await box.get()!
        let didShutdown = await mock.shutdownCalled
        XCTAssertTrue(didShutdown)
        let clients = await router.allClients()
        XCTAssertTrue(clients.isEmpty)
    }

    func testStartIgnoresFactoryFailures() async throws {
        let config = ServerConfig(serverID: "fails", language: .swift, executable: "/nonexistent")
        let detection = DetectionResult(lspServers: [config])

        let factory: @Sendable (ServerConfig) async throws -> any LSPClient = { _ in
            throw LSPClientError.processExited
        }
        let router = withDependencies { $0.lspClientFactory = factory } operation: {
            ServerRouter(detection: detection)
        }

        // Should complete without throwing even if all clients fail to start.
        await router.start()
        let clients = await router.allClients()
        XCTAssertTrue(clients.isEmpty)
    }
}

// MARK: - Test helpers

private actor IDCollector {
    private(set) var ids: [String] = []
    func add(_ id: String) { ids.append(id) }
}

private actor MockClientBox {
    private var value: MockLSPClient?
    func set(_ m: MockLSPClient) { value = m }
    func get() -> MockLSPClient? { value }
}
