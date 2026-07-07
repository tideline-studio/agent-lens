import XCTest
import Foundation
import LSPClient
import LSPServerDetection

final class LSPServerDetectionTests: XCTestCase {

    private var tmp: URL!
    private let detection = DefaultLSPServerDetection()

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lsp-detection-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: - Single-language detection

    func testSwiftPackageDetected() async throws {
        FileManager.default.createFile(atPath: tmp.appendingPathComponent("Package.swift").path,
                                       contents: nil)
        let result = try await detection.detect(root: tmp)
        let langs = result.lspServers.map(\.language)
        XCTAssertTrue(langs.contains(.swift))
    }

    func testTypeScriptDetectedViaTsconfig() async throws {
        FileManager.default.createFile(atPath: tmp.appendingPathComponent("tsconfig.json").path,
                                       contents: nil)
        let result = try await detection.detect(root: tmp)
        XCTAssertTrue(result.lspServers.map(\.language).contains(.typescript))
    }

    func testTypeScriptDetectedViaPackageJSON() async throws {
        FileManager.default.createFile(atPath: tmp.appendingPathComponent("package.json").path,
                                       contents: nil)
        let result = try await detection.detect(root: tmp)
        XCTAssertTrue(result.lspServers.map(\.language).contains(.typescript))
    }

    func testPythonDetectedViaPyprojectToml() async throws {
        FileManager.default.createFile(atPath: tmp.appendingPathComponent("pyproject.toml").path,
                                       contents: nil)
        let result = try await detection.detect(root: tmp)
        XCTAssertTrue(result.lspServers.map(\.language).contains(.python))
    }

    func testGoDetectedViaGoMod() async throws {
        FileManager.default.createFile(atPath: tmp.appendingPathComponent("go.mod").path,
                                       contents: nil)
        let result = try await detection.detect(root: tmp)
        XCTAssertTrue(result.lspServers.map(\.language).contains(.go))
    }

    func testRustDetectedViaCargoToml() async throws {
        FileManager.default.createFile(atPath: tmp.appendingPathComponent("Cargo.toml").path,
                                       contents: nil)
        let result = try await detection.detect(root: tmp)
        XCTAssertTrue(result.lspServers.map(\.language).contains(.rust))
    }

    // MARK: - Multi-language and empty

    func testMultiLanguageProjectDetectsAll() async throws {
        for name in ["Package.swift", "tsconfig.json", "go.mod"] {
            FileManager.default.createFile(atPath: tmp.appendingPathComponent(name).path,
                                           contents: nil)
        }
        let result = try await detection.detect(root: tmp)
        let langs = result.lspServers.map(\.language)
        XCTAssertTrue(langs.contains(.swift))
        XCTAssertTrue(langs.contains(.typescript))
        XCTAssertTrue(langs.contains(.go))
    }

    func testEmptyDirectoryReturnsNoServers() async throws {
        let result = try await detection.detect(root: tmp)
        XCTAssertTrue(result.lspServers.isEmpty)
    }

    // MARK: - Config shape

    func testSwiftServerConfigHasCorrectExecutable() async throws {
        FileManager.default.createFile(atPath: tmp.appendingPathComponent("Package.swift").path,
                                       contents: nil)
        let result = try await detection.detect(root: tmp)
        let swift = result.lspServers.first { $0.language == .swift }
        XCTAssertNotNil(swift)
        XCTAssertEqual(swift?.executable, "sourcekit-lsp")
    }

    // MARK: - Config (.alens.json `lspServers`) replaces marker detection

    private func writeConfig(_ json: String) {
        FileManager.default.createFile(
            atPath: tmp.appendingPathComponent(".alens.json").path,
            contents: Data(json.utf8)
        )
    }

    /// With `lspServers` declared, detection launches exactly those — even when a marker
    /// (Package.swift) would otherwise add the built-in sourcekit-lsp.
    func testConfigReplacesMarkerDetection() async throws {
        FileManager.default.createFile(atPath: tmp.appendingPathComponent("Package.swift").path,
                                       contents: nil)
        writeConfig("""
        { "lspServers": { "swift": { "command": "my-sourcekit", "args": ["--stdio"] } } }
        """)

        let result = try await detection.detect(root: tmp)
        XCTAssertEqual(result.lspServers.count, 1, "config fully replaces detection")
        let swift = result.lspServers.first { $0.language == .swift }
        XCTAssertEqual(swift?.executable, "my-sourcekit")
        XCTAssertEqual(swift?.args, ["--stdio"])
    }

    /// A configured server is launched even with no project marker present.
    func testConfigLaunchesServerWithoutMarker() async throws {
        writeConfig("""
        { "lspServers": { "go": { "command": "gopls" } } }
        """)
        let result = try await detection.detect(root: tmp)
        XCTAssertEqual(result.lspServers.map(\.language), [.go])
        XCTAssertEqual(result.lspServers.first?.args, [], "args default to empty")
    }

    /// An explicit empty `lspServers` is a deliberate "run no servers" — it suppresses the
    /// marker that would otherwise be detected.
    func testEmptyLspServersDisablesDetection() async throws {
        FileManager.default.createFile(atPath: tmp.appendingPathComponent("Package.swift").path,
                                       contents: nil)
        writeConfig("""
        { "lspServers": {} }
        """)
        let result = try await detection.detect(root: tmp)
        XCTAssertTrue(result.lspServers.isEmpty, "empty lspServers runs nothing")
    }

    /// A config carrying only `linters` (no `lspServers` key) must NOT disable LSP — the
    /// two sections share one file and are independent. Marker detection still runs.
    func testLintersOnlyConfigFallsBackToMarkerDetection() async throws {
        FileManager.default.createFile(atPath: tmp.appendingPathComponent("Package.swift").path,
                                       contents: nil)
        writeConfig("""
        { "linters": { "swift": { "command": "swiftlint", "args": [] } } }
        """)
        let result = try await detection.detect(root: tmp)
        XCTAssertTrue(result.lspServers.map(\.language).contains(.swift),
                      "no lspServers key → marker detection still applies")
    }

    /// An unknown language key disables only itself; the rest of the config stands.
    func testUnknownLanguageKeyIsSkipped() async throws {
        writeConfig("""
        {
          "lspServers": {
            "klingon": { "command": "tlhIngan-lsp" },
            "swift": { "command": "sourcekit-lsp" }
          }
        }
        """)
        let result = try await detection.detect(root: tmp)
        XCTAssertEqual(result.lspServers.map(\.language), [.swift],
                       "unrecognized language is skipped, known ones remain")
    }

    /// Per-server env from config reaches the ServerConfig.
    func testConfigEnvIsPassedThrough() async throws {
        writeConfig("""
        { "lspServers": { "swift": { "command": "sourcekit-lsp", "env": { "TOOLCHAINS": "swift" } } } }
        """)
        let result = try await detection.detect(root: tmp)
        XCTAssertEqual(result.lspServers.first?.env["TOOLCHAINS"], "swift")
    }
}
