@testable import DaemonCore
import Dependencies
import Foundation
import IPC
import XCTest

// MARK: - Helpers (file-level so async let can capture them without non-Sendable self)

private func daemonDispatch(core: DaemonCore, command: Command) async -> ResponseResult {
    await core.dispatch(Request(command: command))
}

// MARK: - Tests

final class DaemonLifecycleTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("alens-lifecycle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Status

    func testStatusReturnsNoServersAndApproxUptime() async throws {
        let core = DaemonCore(root: root, logger: .init(label: "test"))
        let result = await daemonDispatch(core: core, command: .status)
        guard case .ok(.status(let report)) = result else {
            XCTFail("expected .status, got \(result)"); return
        }
        XCTAssertEqual(report.servers, [])
        XCTAssertGreaterThanOrEqual(report.uptimeSeconds, 0)
        XCTAssertLessThan(report.uptimeSeconds, 5)
    }

    // MARK: - Stop

    func testStopRepliesAck() async throws {
        let core = DaemonCore(root: root, logger: .init(label: "test"))
        let result = await daemonDispatch(core: core, command: .stop)
        XCTAssertEqual(result, .ok(.ack))
    }

    // MARK: - Path validation

    func testDiagnosePathInsideRootReturnsDiagnoseResult() async throws {
        let core = DaemonCore(root: root, logger: .init(label: "test"))
        let path = root.appendingPathComponent("foo.swift").path
        let result = await daemonDispatch(core: core, command: .diagnose(files: [path], timeoutSeconds: 5))
        guard case .ok(.diagnose) = result else {
            XCTFail("expected .ok(.diagnose), got \(result)"); return
        }
    }

    func testDiagnosePathOutsideRootReturnsError() async throws {
        let core = DaemonCore(root: root, logger: .init(label: "test"))
        let result = await daemonDispatch(core: core, command: .diagnose(files: ["/etc/passwd"], timeoutSeconds: 5))
        guard case .err(let e) = result else {
            XCTFail("expected .err, got \(result)"); return
        }
        XCTAssertEqual(e.code, .pathOutsideRoot)
    }

    func testLintPathOutsideRootReturnsError() async throws {
        let core = DaemonCore(root: root, logger: .init(label: "test"))
        let result = await daemonDispatch(core: core, command: .lint(files: ["/etc/passwd"]))
        guard case .err(let e) = result else {
            XCTFail("expected .err, got \(result)"); return
        }
        XCTAssertEqual(e.code, .pathOutsideRoot)
    }

    func testCheckPathInsideRootReturnsCheckResult() async throws {
        let core = DaemonCore(root: root, logger: .init(label: "test"))
        let path = root.appendingPathComponent("foo.swift").path
        let result = await daemonDispatch(core: core, command: .check(files: [path], timeoutSeconds: 5))
        guard case .ok(.check) = result else {
            XCTFail("expected .ok(.check), got \(result)"); return
        }
    }

    func testCheckPathOutsideRootReturnsError() async throws {
        let core = DaemonCore(root: root, logger: .init(label: "test"))
        let result = await daemonDispatch(core: core, command: .check(files: ["/etc/passwd"], timeoutSeconds: 5))
        guard case .err(let e) = result else {
            XCTFail("expected .err, got \(result)"); return
        }
        XCTAssertEqual(e.code, .pathOutsideRoot)
    }
}
