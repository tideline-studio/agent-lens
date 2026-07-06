import Darwin
import Foundation
import IPC
import XCTest

// Length-prefixed framing must carry arbitrary payload bytes verbatim (the reason
// we moved off newline-delimited framing) and enforce a hard size cap.

final class FramingTests: XCTestCase {

    private var fds = [Int32](repeating: -1, count: 2)

    override func setUpWithError() throws {
        let rc = socketpair(AF_UNIX, SOCK_STREAM, 0, &fds)
        try XCTSkipIf(rc != 0, "socketpair() failed")
    }

    override func tearDown() {
        for fd in fds where fd >= 0 { Darwin.close(fd) }
    }

    func testFrameWithEmbeddedNewlinesAndUnicodeSeparatorsRoundTrips() throws {
        // U+2028 / U+2029 are legal *unescaped* inside JSON strings and would break a
        // Unicode-aware line splitter; \n / \r\n would break a naive one. Framing must
        // pass all of them through untouched.
        let nasty = "line1\nline2\u{2028}line3\u{2029}line4\r\nend"
        let payload = Response(id: "x", result: .ok(.lint(["f.swift": nasty])))

        let received = try roundTripOverSocketpair(payload)
        guard case .ok(.lint(let files)) = received.result else {
            return XCTFail("unexpected payload: \(received.result)")
        }
        XCTAssertEqual(files["f.swift"], nasty)
        XCTAssertEqual(received.id, "x")
    }

    func testMultiMegabytePayloadRoundTrips() throws {
        let big = String(repeating: "diagnostic ", count: 300_000)  // ~3.3 MB
        let payload = Response(id: "big", result: .ok(.lint(["f": big])))

        let received = try roundTripOverSocketpair(payload)
        guard case .ok(.lint(let files)) = received.result else {
            return XCTFail("unexpected payload")
        }
        XCTAssertEqual(files["f"], big)
    }

    func testOversizeLengthHeaderIsRejectedBeforeBuffering() throws {
        // A header claiming more than the cap must be rejected without reading a body.
        var header = UInt32(maxFrameBytes + 1).bigEndian
        _ = withUnsafeBytes(of: &header) { Darwin.write(fds[0], $0.baseAddress!, 4) }

        XCTAssertThrowsError(try readFrame(Response.self, fd: fds[1])) { error in
            guard case FramingError.messageTooBig = error else {
                return XCTFail("expected messageTooBig, got \(error)")
            }
        }
    }

    // Writes from a background thread so a large frame can't deadlock against the
    // socket's send buffer while this thread reads.
    private func roundTripOverSocketpair(_ value: Response) throws -> Response {
        let writeFd = fds[0]
        Thread.detachNewThread { try? writeFrame(value, fd: writeFd) }
        return try readFrame(Response.self, fd: fds[1])
    }
}
