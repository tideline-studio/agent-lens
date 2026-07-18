import DaemonCore
import Dependencies
import Foundation
import IPC
import XCTest

final class MissingBinaryTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("missing-binary-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    func testMissingLinterReturnsEmptyNotError() async throws {
        // linterFactory returns nil for all languages (simulates missing binary)
        let core = withDependencies {
            $0.linterFactory = { _, _ in nil }
        } operation: {
            DaemonCore(root: root, logger: .init(label: "test"))
        }

        let path = root.appendingPathComponent("foo.swift").path
        let result = await core.dispatch(Request(command: .lint(files: [path])))

        guard case .ok(.lint(let files)) = result else {
            XCTFail("expected .ok(.lint), got \(result)"); return
        }
        // File is present in the map with empty output — not an error.
        XCTAssertNotNil(files[path])
        XCTAssertEqual(files[path], "")
    }

    func testUnknownExtensionWithMissingBinaryReturnsEmpty() async throws {
        let core = withDependencies {
            $0.linterFactory = { _, _ in nil }
        } operation: {
            DaemonCore(root: root, logger: .init(label: "test"))
        }

        let path = root.appendingPathComponent("readme.txt").path
        let result = await core.dispatch(Request(command: .lint(files: [path])))

        guard case .ok(.lint(let files)) = result else {
            XCTFail("expected .ok(.lint), got \(result)"); return
        }
        XCTAssertEqual(files[path], "")
    }
}
