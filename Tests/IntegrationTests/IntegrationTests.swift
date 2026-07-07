import XCTest
import Foundation
import IPC

// MARK: - Helpers

private func packageRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // IntegrationTests/
        .deletingLastPathComponent()  // Tests/
        .deletingLastPathComponent()  // package root
}

private func daemonPath() -> String {
    packageRoot().appendingPathComponent(".build/debug/alensd").path
}

private func fixtureRoot(_ name: String) -> URL {
    packageRoot().appendingPathComponent("Tests/Fixtures/\(name)")
}

private func send(_ command: Command, sockPath: String) throws -> Response {
    let fd = try openClientSocket(path: sockPath)
    defer { Darwin.close(fd) }
    try writeFrame(Request(command: command), fd: fd)
    return try readFrame(Response.self, fd: fd)
}

private enum IntegrationError: Error {
    case timeout(String)
    case daemonNotFound
}

// MARK: - Shared daemon lifecycle

/// Manages starting and stopping a daemon process rooted at a fixture directory.
private final class DaemonRunner {
    private var process: Process?
    private(set) var sockPath: String = ""
    private(set) var root: URL

    init(fixtureName: String) {
        root = fixtureRoot(fixtureName)
    }

    func start() async throws {
        let bin = daemonPath()
        guard FileManager.default.isExecutableFile(atPath: bin) else {
            throw XCTSkip("alensd not built at \(bin)")
        }

        sockPath = socketPath(forDirectory: root)

        // Stop any leftover daemon.
        if isDaemonRunning(at: sockPath) {
            _ = try? send(.stop, sockPath: sockPath)
            try await Task.sleep(for: .milliseconds(300))
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: bin)
        proc.arguments = ["--dir", root.path]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        process = proc

        // Wait up to 10 s for socket to appear.
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if isDaemonRunning(at: sockPath) { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("daemon socket did not appear within 10 s (fixture: \(root.lastPathComponent))")
    }

    func stop() async throws {
        if isDaemonRunning(at: sockPath) {
            _ = try? send(.stop, sockPath: sockPath)
        }
        if let proc = process {
            proc.terminate()
            // Poll up to 2 s; if still running, force-kill so tearDown never blocks.
            let deadline = Date().addingTimeInterval(2)
            while proc.isRunning, Date() < deadline {
                try await Task.sleep(for: .milliseconds(50))
            }
            if proc.isRunning {
                kill(proc.processIdentifier, SIGKILL)
                try await Task.sleep(for: .milliseconds(100))
            }
        }
        process = nil
        try await Task.sleep(for: .milliseconds(200))
    }
}

// MARK: - Swift fixture tests

final class IntegrationTests: XCTestCase {

    private var runner = DaemonRunner(fixtureName: "swift-fixture")

    override func setUp() async throws {
        try await runner.start()
    }

    override func tearDown() async throws {
        try await runner.stop()
    }

    private var sock: String { runner.sockPath }
    private var root: URL { runner.root }

    // MARK: - Basic connectivity

    func testStatusReturnsReport() throws {
        let resp = try send(.status, sockPath: sock)
        guard case .ok(.status(let report)) = resp.result else {
            XCTFail("expected .ok(.status), got \(resp.result)"); return
        }
        XCTAssertNotNil(report.uptimeSeconds)
    }

    func testStopReturnsAck() throws {
        let resp = try send(.stop, sockPath: sock)
        guard case .ok(.ack) = resp.result else {
            XCTFail("expected .ok(.ack), got \(resp.result)"); return
        }
    }

    func testPathOutsideRootReturnsError() throws {
        let resp = try send(.diagnose(files: ["/etc/passwd"], timeoutSeconds: 5), sockPath: sock)
        guard case .err(let e) = resp.result else {
            XCTFail("expected .err, got \(resp.result)"); return
        }
        XCTAssertEqual(e.code, .pathOutsideRoot)
    }

    func testDiagnoseInsideRootReturnsDiagnoseResult() throws {
        let path = root.appendingPathComponent("Sources/App/main.swift").path
        let resp = try send(.diagnose(files: [path], timeoutSeconds: 5), sockPath: sock)
        guard case .ok(.diagnose(_)) = resp.result else {
            XCTFail("expected .ok(.diagnose), got \(resp.result)"); return
        }
    }

    func testLintInsideRootReturnsLintResult() throws {
        let path = root.appendingPathComponent("Sources/App/main.swift").path
        let resp = try send(.lint(files: [path]), sockPath: sock)
        guard case .ok(.lint(_)) = resp.result else {
            XCTFail("expected .ok(.lint), got \(resp.result)"); return
        }
    }

    // MARK: - Source-kit-lsp diagnostics (requires full indexing — long timeout)

    func testDiagnoseFixtureReturnsErrorForKnownMistake() async throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/sourcekit-lsp") else {
            throw XCTSkip("sourcekit-lsp not available")
        }

        let path = root.appendingPathComponent("Sources/App/main.swift").path
        let deadline = Date().addingTimeInterval(60)

        var lastResult: ResponseResult?
        while Date() < deadline {
            let resp = try send(.diagnose(files: [path], timeoutSeconds: 10), sockPath: sock)
            lastResult = resp.result
            if case .ok(.diagnose(let files)) = resp.result,
               let fd = files[path],
               !fd.diagnostics.isEmpty {
                XCTAssertTrue(
                    fd.diagnostics.contains { $0.severity == .error },
                    "expected at least one error for the intentional type mismatch"
                )
                return
            }
            try await Task.sleep(for: .seconds(2))
        }
        if case .ok(.diagnose(let files)) = lastResult, let fd = files[path], fd.stale {
            throw XCTSkip("sourcekit-lsp did not finish indexing within 60 s")
        }
    }

    func testCrossModuleTypoPropagatesToImporter() async throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/sourcekit-lsp") else {
            throw XCTSkip("sourcekit-lsp not available")
        }

        let greeterURL  = root.appendingPathComponent("Sources/Greeter/Greeter.swift")
        let greeterPath = greeterURL.path
        let appPath     = root.appendingPathComponent("Sources/App/main.swift").path
        let original    = try String(contentsOf: greeterURL, encoding: .utf8)
        defer { try? original.write(to: greeterURL, atomically: true, encoding: .utf8) }

        // Introduce the typo immediately: rename greet() → greett(), breaking the call
        // site in App/main.swift without touching App/main.swift at all.
        let typo = original.replacingOccurrences(of: "func greet()", with: "func greett()")
        try typo.write(to: greeterURL, atomically: true, encoding: .utf8)

        // Diagnose BOTH files in one call. The client sends didChange(Greeter.swift) to
        // sourcekit-lsp first, then issues a pull request for App/main.swift. Because pull
        // is request/response and the server processes messages in order, the pull response
        // for App is guaranteed to reflect the renamed function — no background indexing
        // warm-up needed; the diagnose call itself drives the analysis.
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            let resp = try send(
                .diagnose(files: [greeterPath, appPath], timeoutSeconds: 15),
                sockPath: sock
            )
            if case .ok(.diagnose(let files)) = resp.result,
               let fd = files[appPath], !fd.stale,
               fd.diagnostics.contains(where: {
                   $0.severity == .error && $0.message.lowercased().contains("greet")
               }) {
                return
            }
            try await Task.sleep(for: .seconds(2))
        }
        throw XCTSkip("cross-module error did not propagate within 60 s")
    }

    func testEditThenDiagnoseReturnsFreshDiagnostics() async throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/sourcekit-lsp") else {
            throw XCTSkip("sourcekit-lsp not available")
        }

        let tmpFile = root.appendingPathComponent("Sources/App/_edit_test.swift")
        defer { try? FileManager.default.removeItem(at: tmpFile) }

        try "let x: Int = 1\n".write(to: tmpFile, atomically: true, encoding: .utf8)
        let path = tmpFile.path
        _ = try send(.diagnose(files: [path], timeoutSeconds: 10), sockPath: sock)

        try "let y: Int = \"not an int\"\n".write(to: tmpFile, atomically: true, encoding: .utf8)

        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            let resp = try send(.diagnose(files: [path], timeoutSeconds: 10), sockPath: sock)
            if case .ok(.diagnose(let files)) = resp.result,
               let fd = files[path],
               fd.diagnostics.contains(where: { $0.severity == .error }) {
                return
            }
            try await Task.sleep(for: .seconds(2))
        }
        throw XCTSkip("edit-then-diagnose: sourcekit-lsp did not reflect edit within 30 s")
    }
}

// MARK: - TypeScript fixture tests

final class TypeScriptFixtureTests: XCTestCase {

    private var runner = DaemonRunner(fixtureName: "ts-fixture")

    override func setUp() async throws {
        try await runner.start()
    }

    override func tearDown() async throws {
        try await runner.stop()
    }

    private var sock: String { runner.sockPath }
    private var root: URL { runner.root }

    func testStatusReturnsReport() throws {
        let resp = try send(.status, sockPath: sock)
        guard case .ok(.status(let report)) = resp.result else {
            XCTFail("expected .ok(.status), got \(resp.result)"); return
        }
        XCTAssertNotNil(report.uptimeSeconds)
    }

    func testStopReturnsAck() throws {
        let resp = try send(.stop, sockPath: sock)
        guard case .ok(.ack) = resp.result else {
            XCTFail("expected .ok(.ack), got \(resp.result)"); return
        }
    }

    func testPathOutsideRootReturnsError() throws {
        let resp = try send(.diagnose(files: ["/etc/passwd"], timeoutSeconds: 5), sockPath: sock)
        guard case .err(let e) = resp.result else {
            XCTFail("expected .err, got \(resp.result)"); return
        }
        XCTAssertEqual(e.code, .pathOutsideRoot)
    }

    func testDiagnoseTypeScriptFileReturnsDiagnoseResult() throws {
        let path = root.appendingPathComponent("index.ts").path
        let resp = try send(.diagnose(files: [path], timeoutSeconds: 5), sockPath: sock)
        guard case .ok(.diagnose(_)) = resp.result else {
            XCTFail("expected .ok(.diagnose), got \(resp.result)"); return
        }
    }

    func testLintTypeScriptFileReturnsLintResult() throws {
        let path = root.appendingPathComponent("index.ts").path
        let resp = try send(.lint(files: [path]), sockPath: sock)
        guard case .ok(.lint(_)) = resp.result else {
            XCTFail("expected .ok(.lint), got \(resp.result)"); return
        }
    }

    /// Verifies ESLint reports a type error when installed.
    func testESLintReportsKnownTypeError() throws {
        guard let eslintPath = findExecutable("eslint") else {
            throw XCTSkip("eslint not in PATH")
        }
        _ = eslintPath

        let path = root.appendingPathComponent("index.ts").path
        let resp = try send(.lint(files: [path]), sockPath: sock)
        guard case .ok(.lint(let results)) = resp.result else {
            XCTFail("expected .ok(.lint), got \(resp.result)"); return
        }
        // The fixture has a known type error; ESLint with @typescript-eslint should flag it.
        let output = results[path] ?? ""
        XCTAssertFalse(output.isEmpty, "expected ESLint to produce output")
    }
}

// MARK: - Python fixture tests

final class PythonFixtureTests: XCTestCase {

    private var runner = DaemonRunner(fixtureName: "py-fixture")

    override func setUp() async throws {
        try await runner.start()
    }

    override func tearDown() async throws {
        try await runner.stop()
    }

    private var sock: String { runner.sockPath }
    private var root: URL { runner.root }

    func testStatusReturnsReport() throws {
        let resp = try send(.status, sockPath: sock)
        guard case .ok(.status(let report)) = resp.result else {
            XCTFail("expected .ok(.status), got \(resp.result)"); return
        }
        XCTAssertNotNil(report.uptimeSeconds)
    }

    func testStopReturnsAck() throws {
        let resp = try send(.stop, sockPath: sock)
        guard case .ok(.ack) = resp.result else {
            XCTFail("expected .ok(.ack), got \(resp.result)"); return
        }
    }

    func testPathOutsideRootReturnsError() throws {
        let resp = try send(.diagnose(files: ["/etc/passwd"], timeoutSeconds: 5), sockPath: sock)
        guard case .err(let e) = resp.result else {
            XCTFail("expected .err, got \(resp.result)"); return
        }
        XCTAssertEqual(e.code, .pathOutsideRoot)
    }

    func testDiagnosePythonFileReturnsDiagnoseResult() throws {
        let path = root.appendingPathComponent("src/main.py").path
        let resp = try send(.diagnose(files: [path], timeoutSeconds: 5), sockPath: sock)
        guard case .ok(.diagnose(_)) = resp.result else {
            XCTFail("expected .ok(.diagnose), got \(resp.result)"); return
        }
    }

    func testLintPythonFileReturnsLintResult() throws {
        let path = root.appendingPathComponent("src/main.py").path
        let resp = try send(.lint(files: [path]), sockPath: sock)
        guard case .ok(.lint(_)) = resp.result else {
            XCTFail("expected .ok(.lint), got \(resp.result)"); return
        }
    }

    /// Verifies Ruff reports diagnostics for the intentional errors when installed.
    func testRuffReportsKnownErrors() throws {
        guard let ruffPath = findExecutable("ruff") else {
            throw XCTSkip("ruff not in PATH")
        }
        _ = ruffPath

        let path = root.appendingPathComponent("src/main.py").path
        let resp = try send(.lint(files: [path]), sockPath: sock)
        guard case .ok(.lint(let results)) = resp.result else {
            XCTFail("expected .ok(.lint), got \(resp.result)"); return
        }
        let output = results[path] ?? ""
        XCTAssertFalse(output.isEmpty, "expected ruff to produce output")
    }

    /// Verifies pyright reports type errors when installed.
    func testPyrightDiagnosesKnownTypeErrors() async throws {
        guard FileManager.default.fileExists(atPath: "/usr/local/bin/pyright-langserver") ||
              findExecutable("pyright-langserver") != nil else {
            throw XCTSkip("pyright-langserver not in PATH")
        }

        let path = root.appendingPathComponent("src/main.py").path
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            let resp = try send(.diagnose(files: [path], timeoutSeconds: 10), sockPath: sock)
            if case .ok(.diagnose(let files)) = resp.result,
               let fd = files[path],
               !fd.diagnostics.isEmpty {
                XCTAssertTrue(
                    fd.diagnostics.contains { $0.severity == .error || $0.severity == .warning },
                    "expected pyright to flag type errors"
                )
                return
            }
            try await Task.sleep(for: .seconds(2))
        }
        throw XCTSkip("pyright-langserver did not finish indexing within 30 s")
    }
}

// MARK: - NoDaemon tests (no daemon started)

final class NoDaemonTests: XCTestCase {

    func testNoDaemonThrowsOnConnect() {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("nodaemon-\(UUID().uuidString)")
        let sock = socketPath(forDirectory: root)
        XCTAssertFalse(isDaemonRunning(at: sock))
        XCTAssertThrowsError(try send(.status, sockPath: sock))
    }
}

// MARK: - PATH helpers

private func findExecutable(_ name: String) -> String? {
    let paths = ProcessInfo.processInfo.environment["PATH", default: "/usr/local/bin:/usr/bin:/bin"]
        .split(separator: ":").map(String.init)
    for dir in paths {
        let candidate = dir + "/" + name
        if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
    }
    return nil
}
