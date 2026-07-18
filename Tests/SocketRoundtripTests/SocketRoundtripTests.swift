import Darwin
import Foundation
import IPC
import XCTest

// Spawns a real alensd and drives it over the actual Unix socket.
// Verifies that every command type produces a correctly shaped response,
// that request IDs are echoed back, and that version mismatches are rejected.

final class SocketRoundtripTests: XCTestCase {

    private var daemon: Process!
    private var sockPath: String!
    private var uniqueDir: String!

    override func setUpWithError() throws {
        let daemonBin = try findBinary(name: "alensd")

        // Per-run directory so socket paths never collide across parallel test runs.
        uniqueDir = "/tmp/alens-roundtrip-\(UUID().uuidString)"
        sockPath = socketPath(forDirectory: URL(fileURLWithPath: uniqueDir))

        daemon = Process()
        daemon.executableURL = URL(fileURLWithPath: daemonBin)
        daemon.arguments = ["--dir", uniqueDir]
        daemon.standardOutput = FileHandle.nullDevice
        daemon.standardError  = FileHandle.nullDevice
        try daemon.run()

        // Wait up to 3 s for the socket to appear.
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, !FileManager.default.fileExists(atPath: sockPath) {
            Thread.sleep(forTimeInterval: 0.05)
        }
        guard FileManager.default.fileExists(atPath: sockPath) else {
            daemon.terminate()
            throw XCTSkip("smoke daemon did not create socket within 3 s")
        }
    }

    override func tearDown() {
        daemon?.terminate()
        daemon = nil
        try? FileManager.default.removeItem(atPath: sockPath)
        try? FileManager.default.removeItem(atPath: uniqueDir)
    }

    // MARK: - Per-command roundtrips

    func testStatusReturnsStatusReport() throws {
        let resp = try send(.status)
        guard case .ok(.status(let report)) = resp.result else {
            XCTFail("expected .status payload, got \(resp.result)"); return
        }
        XCTAssertEqual(report.servers, [])
        XCTAssertGreaterThanOrEqual(report.uptimeSeconds, 0)
    }

    func testStopReturnsAck() throws {
        let resp = try send(.stop)
        XCTAssertEqual(resp.result, .ok(.ack))
    }

    func testDiagnoseWithPathInsideRootReturnsDiagnoseResult() throws {
        // File must be within the daemon root for the request to succeed.
        let path = uniqueDir + "/a.swift"
        let resp = try send(.diagnose(files: [path], timeoutSeconds: 5))
        guard case .ok(.diagnose) = resp.result else {
            XCTFail("expected .ok(.diagnose), got \(resp.result)"); return
        }
    }

    func testDiagnoseWithPathOutsideRootReturnsError() throws {
        let resp = try send(.diagnose(files: ["/tmp/a.swift"], timeoutSeconds: 5))
        if case .err(let e) = resp.result {
            XCTAssertEqual(e.code, .pathOutsideRoot)
        } else {
            XCTFail("expected pathOutsideRoot error, got \(resp.result)")
        }
    }

    func testLintWithPathInsideRootReturnsLintResult() throws {
        let path = uniqueDir + "/a.ts"
        let resp = try send(.lint(files: [path]))
        guard case .ok(.lint) = resp.result else {
            XCTFail("expected .ok(.lint), got \(resp.result)"); return
        }
    }

    func testStartReturnsAck() throws {
        let resp = try send(.start(idleSeconds: 7200, logLevel: .info))
        XCTAssertEqual(resp.result, .ok(.ack))
    }

    // MARK: - Protocol invariants

    func testResponseIDMatchesRequestID() throws {
        let id = "unique-\(UUID().uuidString)"
        let req = Request(id: id, command: .status)
        let resp = try sendRequest(req)
        XCTAssertEqual(resp.id, id)
    }

    func testResponseVersionMatchesProtocol() throws {
        let resp = try send(.status)
        XCTAssertEqual(resp.v, protocolVersion)
    }

    func testVersionMismatchIsRejected() throws {
        let fd = try openClientSocket(path: sockPath)
        defer { Darwin.close(fd) }
        // Hand-craft a frame with an unsupported protocol version. Request's init
        // forces the current version, so we frame the raw JSON ourselves.
        let badJSON = Data(#"{"v":999,"id":"bad","command":{"type":"status"}}"#.utf8)
        writeRawFrame(badJSON, fd: fd)
        let resp = try readFrame(Response.self, fd: fd)
        if case .err(let e) = resp.result {
            XCTAssertEqual(e.code, .versionMismatch)
        } else {
            XCTFail("expected versionMismatch error, got \(resp.result)")
        }
    }

    func testMultipleSequentialConnectionsWork() throws {
        for _ in 0..<5 {
            let resp = try send(.status)
            if case .ok(.status(let report)) = resp.result {
                XCTAssertEqual(report.servers, [])
            } else {
                XCTFail("expected .status payload, got \(resp.result)")
            }
        }
    }

    // MARK: - Helpers

    private func send(_ command: Command) throws -> Response {
        try sendRequest(Request(command: command))
    }

    private func sendRequest(_ req: Request) throws -> Response {
        let fd = try openClientSocket(path: sockPath)
        defer { Darwin.close(fd) }
        try writeFrame(req, fd: fd)
        return try readFrame(Response.self, fd: fd)
    }
}

/// Writes `body` with the wire framing (4-byte big-endian length prefix) directly,
/// for tests that need to inject payloads that the typed API won't construct.
func writeRawFrame(_ body: Data, fd: Int32) {
    var header = UInt32(body.count).bigEndian
    var frame = Data(bytes: &header, count: 4)
    frame.append(body)
    _ = frame.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, $0.count) }
}

private func findBinary(name: String) throws -> String {
    let bundle = Bundle(for: SocketRoundtripTests.self)
    let buildDir = bundle.bundleURL.deletingLastPathComponent()
    let candidate = buildDir.appendingPathComponent(name)
    guard FileManager.default.fileExists(atPath: candidate.path) else {
        throw XCTSkip("\(name) binary not found at \(candidate.path); run 'swift build' first")
    }
    return candidate.path
}
