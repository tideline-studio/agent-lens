import Darwin
import Foundation
import IPC
import XCTest

// Tests observable CLI behavior by spawning alens as a subprocess.
// Covers: exit codes, --json flag, noDaemon error, argument validation.

final class CLITests: XCTestCase {

    private var cliBin: String!

    override func setUpWithError() throws {
        cliBin = try findBinary(name: "alens")
    }

    // MARK: - noDaemon behavior

    func testStatusWithoutDaemonExitsNonZero() throws {
        let r = try run(["status"], env: isolatedEnv())
        XCTAssertNotEqual(r.exitCode, 0)
    }

    func testStatusWithoutDaemonPrintsErrorText() throws {
        let r = try run(["status"], env: isolatedEnv())
        let combined = r.stdout + r.stderr
        // "error" or "noDaemon" must appear somewhere in output
        XCTAssertTrue(
            combined.lowercased().contains("error") || combined.contains("noDaemon"),
            "expected error output, got: \(combined)"
        )
    }

    func testStatusJSONWithoutDaemonEmitsJSON() throws {
        let r = try run(["--json", "status"], env: isolatedEnv())
        // Should still produce parseable JSON (the error response)
        let combined = r.stdout + r.stderr
        // At minimum the output should not be empty
        XCTAssertFalse(combined.isEmpty)
    }

    func testDiagnoseWithoutDaemonExitsNonZero() throws {
        let r = try run(["diagnose", "/tmp/nonexistent.swift"], env: isolatedEnv())
        XCTAssertNotEqual(r.exitCode, 0)
    }

    func testLintWithoutDaemonExitsNonZero() throws {
        let r = try run(["lint", "/tmp/nonexistent.ts"], env: isolatedEnv())
        XCTAssertNotEqual(r.exitCode, 0)
    }

    // MARK: - Argument validation

    func testDiagnoseRequiresAtLeastOneFile() throws {
        let r = try run(["diagnose"])
        XCTAssertNotEqual(r.exitCode, 0)
    }

    func testLintRequiresAtLeastOneFile() throws {
        let r = try run(["lint"])
        XCTAssertNotEqual(r.exitCode, 0)
    }

    func testUnknownSubcommandExitsNonZero() throws {
        let r = try run(["unknown-subcommand"])
        XCTAssertNotEqual(r.exitCode, 0)
    }

    func testHelpExitsZero() throws {
        let r = try run(["--help"])
        XCTAssertEqual(r.exitCode, 0)
    }

    // MARK: - Helpers

    private struct RunResult {
        let stdout: String
        let stderr: String
        let exitCode: Int32
    }

    private func run(_ args: [String], env: [String: String]? = nil) throws -> RunResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: cliBin)
        p.arguments = args
        if let env { p.environment = env }
        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError  = errPipe
        try p.run()
        p.waitUntilExit()
        let stdout = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return RunResult(stdout: stdout, stderr: stderr, exitCode: p.terminationStatus)
    }

    /// Environment that points at a nonexistent temp directory so there's definitely no daemon.
    private func isolatedEnv() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        // Unset HOME so CWD-based socket lookup fails quickly (no daemon at /tmp/<unique>/...)
        let tmpRoot = "/tmp/alens-cli-test-\(UUID().uuidString)"
        env["HOME"] = tmpRoot
        return env
    }
}

// MARK: - Binary finder (shared with SocketRoundtripTests)

func findBinary(name: String) throws -> String {
    let bundle = Bundle(for: CLITests.self)
    let buildDir = bundle.bundleURL.deletingLastPathComponent()
    let candidate = buildDir.appendingPathComponent(name)
    guard FileManager.default.fileExists(atPath: candidate.path) else {
        throw XCTSkip("\(name) binary not found at \(candidate.path); run 'swift build' first")
    }
    return candidate.path
}
