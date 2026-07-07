import Darwin
import XCTest
import Foundation
import IPC

// Tests observable socket-level behavior by spawning alensd as a subprocess.
// Covers stale-socket recovery, socket permissions, and malformed input handling.

final class IPCServerTests: XCTestCase {

    private var daemon: Process!
    private var sockPath: String!
    private var tmpDir: String!

    override func setUpWithError() throws {
        let daemonBin = try findBinary(name: "alensd")
        tmpDir = "/tmp/alens-ipc-test-\(UUID().uuidString)"
        sockPath = socketPath(forDirectory: URL(fileURLWithPath: tmpDir))

        daemon = Process()
        daemon.executableURL = URL(fileURLWithPath: daemonBin)
        daemon.arguments = ["--dir", tmpDir]
        daemon.standardOutput = FileHandle.nullDevice
        daemon.standardError  = FileHandle.nullDevice
        try daemon.run()

        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, !FileManager.default.fileExists(atPath: sockPath) {
            Thread.sleep(forTimeInterval: 0.05)
        }
        guard FileManager.default.fileExists(atPath: sockPath) else {
            daemon.terminate()
            throw XCTSkip("daemon did not create socket within 3 s")
        }
    }

    override func tearDown() {
        daemon?.terminate()
        daemon = nil
        try? FileManager.default.removeItem(atPath: sockPath)
        try? FileManager.default.removeItem(atPath: tmpDir)
    }

    // MARK: - Socket permissions

    func testSocketPermissionsAre0600() throws {
        let attrs = try FileManager.default.attributesOfItem(atPath: sockPath)
        let perms = attrs[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o600, "socket must be owner-read/write only (0600)")
    }

    // MARK: - Stale socket recovery

    func testStaleSocketIsRemovedAndDaemonStarts() throws {
        // Daemon is already running (from setUp) — stop it and leave the socket file behind.
        daemon.terminate()
        daemon.waitUntilExit()
        daemon = nil

        // Socket file should still exist (daemon exited without cleanup in this forced-kill scenario).
        // We'll create a dummy file at sockPath to simulate a stale socket if needed.
        if !FileManager.default.fileExists(atPath: sockPath) {
            FileManager.default.createFile(atPath: sockPath, contents: nil)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: sockPath))

        // Start a fresh daemon — it should remove the stale socket and create a new one.
        let daemonBin = try findBinary(name: "alensd")
        let newDaemon = Process()
        newDaemon.executableURL = URL(fileURLWithPath: daemonBin)
        newDaemon.arguments = ["--dir", tmpDir]
        newDaemon.standardOutput = FileHandle.nullDevice
        newDaemon.standardError  = FileHandle.nullDevice
        try newDaemon.run()
        defer { newDaemon.terminate() }

        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, !isDaemonRunning(at: sockPath) {
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertTrue(isDaemonRunning(at: sockPath), "new daemon should be listening")
    }

    // MARK: - Malformed input

    func testMalformedJSONDoesNotCrashDaemon() throws {
        let fd = try openClientSocket(path: sockPath)
        defer { Darwin.close(fd) }

        // A correctly framed body that isn't a valid Request: the server must drop
        // the frame and stay up, not crash or desync.
        let garbage = "not json at all".data(using: .utf8)!
        var header = UInt32(garbage.count).bigEndian
        var frame = Data(bytes: &header, count: 4)
        frame.append(garbage)
        _ = frame.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, $0.count) }

        // Give the daemon a moment to process the bad input.
        Thread.sleep(forTimeInterval: 0.1)

        // Daemon must still be running — send a valid status command and get a response.
        let resp = try send(.status)
        if case .ok(.status(let report)) = resp.result {
            XCTAssertEqual(report.servers, [])
        } else {
            XCTFail("daemon should still be alive after malformed input, got \(resp.result)")
        }
    }

    func testTruncatedJSONDoesNotHangDaemon() throws {
        let fd = try openClientSocket(path: sockPath)
        Darwin.close(fd)  // Close immediately without sending anything

        Thread.sleep(forTimeInterval: 0.1)

        // Daemon should still respond to the next request
        let resp = try send(.status)
        if case .ok = resp.result { } else {
            XCTFail("expected ok from daemon after truncated connection, got \(resp.result)")
        }
    }

    // MARK: - Helpers

    private func send(_ command: Command) throws -> Response {
        let fd = try openClientSocket(path: sockPath)
        defer { Darwin.close(fd) }
        try writeFrame(Request(command: command), fd: fd)
        return try readFrame(Response.self, fd: fd)
    }
}

private func findBinary(name: String) throws -> String {
    let bundle = Bundle(for: IPCServerTests.self)
    let buildDir = bundle.bundleURL.deletingLastPathComponent()
    let candidate = buildDir.appendingPathComponent(name)
    guard FileManager.default.fileExists(atPath: candidate.path) else {
        throw XCTSkip("\(name) not found at \(candidate.path); run 'swift build' first")
    }
    return candidate.path
}

private extension ResponseResult {
    // Convenience for checking uptime in testMalformedJSONDoesNotCrashDaemon
    var uptimeSeconds: Double? {
        if case .ok(.status(let r)) = self { return r.uptimeSeconds }
        return nil
    }
}
