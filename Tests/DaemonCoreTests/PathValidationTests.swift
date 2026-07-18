@testable import DaemonCore
import Foundation
import XCTest

final class PathValidationTests: XCTestCase {

    private var root: URL!
    private var tmpDir: URL!

    override func setUpWithError() throws {
        tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("alens-path-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        root = tmpDir
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    func testPathEqualToRootIsAccepted() {
        XCTAssertTrue(isWithinRoot(root.path, root: root))
    }

    func testPathDirectlyInsideRootIsAccepted() {
        let path = root.appendingPathComponent("foo.swift").path
        XCTAssertTrue(isWithinRoot(path, root: root))
    }

    func testPathDeepInsideRootIsAccepted() {
        let path = root.appendingPathComponent("a/b/c/d.swift").path
        XCTAssertTrue(isWithinRoot(path, root: root))
    }

    func testAbsolutePathOutsideRootIsRejected() {
        XCTAssertFalse(isWithinRoot("/etc/passwd", root: root))
    }

    func testDotDotEscapeIsRejected() throws {
        // /tmp/test/subdir/../../.. resolves to /tmp, which is above root.
        let sub = root.appendingPathComponent("subdir")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let escaped = sub.appendingPathComponent("../../..").path
        XCTAssertFalse(isWithinRoot(escaped, root: root))
    }

    func testDotDotThatStaysInsideRootIsAccepted() throws {
        let sub = root.appendingPathComponent("a/b")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        // root/a/b/../c.swift → root/a/c.swift — still inside root
        let path = sub.appendingPathComponent("../c.swift").path
        XCTAssertTrue(isWithinRoot(path, root: root))
    }

    func testSymlinkInsideRootIsAccepted() throws {
        let real = root.appendingPathComponent("real.swift")
        FileManager.default.createFile(atPath: real.path, contents: nil)
        let link = root.appendingPathComponent("link.swift")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        XCTAssertTrue(isWithinRoot(link.path, root: root))
    }

    func testSymlinkOutsideRootIsRejected() throws {
        // Create a symlink inside root that points to /tmp (above root)
        let link = root.appendingPathComponent("escape.swift")
        try FileManager.default.createSymbolicLink(
            atPath: link.path,
            withDestinationPath: NSTemporaryDirectory()
        )
        XCTAssertFalse(isWithinRoot(link.path, root: root))
    }

    func testPrefixCollisionIsRejected() throws {
        // /tmp/alens-test should not be accepted when root is /tmp/alens
        let sibling = URL(fileURLWithPath: tmpDir.path + "-sibling")
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sibling) }
        XCTAssertFalse(isWithinRoot(sibling.path, root: root))
    }
}
