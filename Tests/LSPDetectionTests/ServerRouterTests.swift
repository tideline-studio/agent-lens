import DaemonCore
import Dependencies
import Foundation
import IPC
import Logging
import LSPClient
import LSPServerDetection
import XCTest

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

    private let root = URL(fileURLWithPath: NSTemporaryDirectory())
    private let logger = Logger(label: "test")

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

    // MARK: - Lazy start via lspClient(for:)

    func testLazyStartCallsFactoryOnFirstUse() async throws {
        let collector = IDCollector()
        let lspConfig = LSPConfig(lspServers: [
            "swift": LSPConfig.ServerSpec(command: "sk-lsp"),
            "typescript": LSPConfig.ServerSpec(command: "ts-lsp")
        ])
        let factory: @Sendable (ServerConfig) async throws -> any LSPClient = { config in
            await collector.add(config.serverID)
            return MockLSPClient(serverID: config.serverID)
        }
        let router = withDependencies { $0.lspClientFactory = factory } operation: {
            ServerRouter(root: root, lspConfig: lspConfig, logger: logger, onClientStarted: { _ in })
        }

        _ = await router.lspClient(for: "/tmp/foo.swift")
        _ = await router.lspClient(for: "/tmp/index.ts")

        let createdIDs = await collector.ids
        XCTAssertEqual(Set(createdIDs), Set(["sk-lsp", "ts-lsp"]))
        let clients = await router.allClients()
        XCTAssertEqual(clients.count, 2)
    }

    func testLspClientForPathReturnsCorrectClient() async throws {
        // Explicit config: only swift. Python has no entry → nil.
        let lspConfig = LSPConfig(lspServers: [
            "swift": LSPConfig.ServerSpec(command: "sourcekit-lsp")
        ])
        let factory: @Sendable (ServerConfig) async throws -> any LSPClient = { config in
            MockLSPClient(serverID: config.serverID)
        }
        let router = withDependencies { $0.lspClientFactory = factory } operation: {
            ServerRouter(root: root, lspConfig: lspConfig, logger: logger, onClientStarted: { _ in })
        }

        let client = await router.lspClient(for: "/tmp/foo.swift")
        XCTAssertNotNil(client)
        let noClient = await router.lspClient(for: "/tmp/foo.py")
        XCTAssertNil(noClient)
    }

    func testDefaultConfigsUsedWhenNoLspConfig() async throws {
        // nil lspConfig → static defaults → all standard languages routable
        let factory: @Sendable (ServerConfig) async throws -> any LSPClient = { config in
            MockLSPClient(serverID: config.serverID)
        }
        let router = withDependencies { $0.lspClientFactory = factory } operation: {
            ServerRouter(root: root, lspConfig: nil, logger: logger, onClientStarted: { _ in })
        }

        let swiftClient = await router.lspClient(for: "/tmp/foo.swift")
        let pyClient = await router.lspClient(for: "/tmp/foo.py")
        let noClient = await router.lspClient(for: "/tmp/foo.txt")
        XCTAssertNotNil(swiftClient)
        XCTAssertNotNil(pyClient)
        XCTAssertNil(noClient)
    }

    func testStopShutdownsAllClients() async throws {
        let lspConfig = LSPConfig(lspServers: [
            "swift": LSPConfig.ServerSpec(command: "sk-lsp")
        ])
        let box = MockClientBox()
        let factory: @Sendable (ServerConfig) async throws -> any LSPClient = { config in
            let m = MockLSPClient(serverID: config.serverID)
            await box.set(m)
            return m
        }
        let router = withDependencies { $0.lspClientFactory = factory } operation: {
            ServerRouter(root: root, lspConfig: lspConfig, logger: logger, onClientStarted: { _ in })
        }

        _ = await router.lspClient(for: "/tmp/foo.swift")
        await router.stop()

        let mock = await box.get()!
        let didShutdown = await mock.shutdownCalled
        let remaining = await router.allClients()
        XCTAssertTrue(didShutdown)
        XCTAssertTrue(remaining.isEmpty)
    }

    func testClientLaunchedWithProjectRootAsWorkingDirectory() async throws {
        let lspConfig = LSPConfig(lspServers: [
            "swift": LSPConfig.ServerSpec(command: "sourcekit-lsp")
        ])
        let capturedConfig = CapturedConfigBox()
        let factory: @Sendable (ServerConfig) async throws -> any LSPClient = { config in
            await capturedConfig.set(config)
            return MockLSPClient(serverID: config.serverID)
        }
        let router = withDependencies { $0.lspClientFactory = factory } operation: {
            ServerRouter(root: root, lspConfig: lspConfig, logger: logger, onClientStarted: { _ in })
        }

        _ = await router.lspClient(for: "/tmp/foo.swift")

        let captured = await capturedConfig.get()
        XCTAssertEqual(captured?.workingDirectory, root)
    }

    func testFactoryFailureReturnsNilWithoutThrowing() async throws {
        let lspConfig = LSPConfig(lspServers: [
            "swift": LSPConfig.ServerSpec(command: "/nonexistent")
        ])
        let factory: @Sendable (ServerConfig) async throws -> any LSPClient = { _ in
            throw LSPClientError.processExited
        }
        let router = withDependencies { $0.lspClientFactory = factory } operation: {
            ServerRouter(root: root, lspConfig: lspConfig, logger: logger, onClientStarted: { _ in })
        }

        let client = await router.lspClient(for: "/tmp/foo.swift")
        let clients = await router.allClients()
        XCTAssertNil(client)
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

private actor CapturedConfigBox {
    private var value: ServerConfig?
    func set(_ c: ServerConfig) { value = c }
    func get() -> ServerConfig? { value }
}
