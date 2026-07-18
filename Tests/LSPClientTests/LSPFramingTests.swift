import Foundation
import LSPClient
import XCTest

/// Content-Length framing is the one piece of transport logic with real edge cases —
/// partial reads, coalesced messages, headers/bodies split across chunks — and it's only
/// exercised against a real subprocess (which the test suite no longer spawns). These pin
/// the byte-level behavior directly.
final class LSPFramingTests: XCTestCase {

    private func body(_ s: String) -> Data { Data(s.utf8) }

    func testFrameThenDecodeRoundTrips() {
        let message = body(#"{"jsonrpc":"2.0","id":1}"#)
        var decoder = LSPFrameDecoder()
        let frames = decoder.push(frameJSONRPCMessage(message))
        XCTAssertEqual(frames, [message])
    }

    func testMultipleMessagesInOneChunkAllDecode() {
        let a = body(#"{"a":1}"#), b = body(#"{"b":2}"#)
        var decoder = LSPFrameDecoder()
        let frames = decoder.push(frameJSONRPCMessage(a) + frameJSONRPCMessage(b))
        XCTAssertEqual(frames, [a, b])
    }

    func testMessageSplitAcrossChunksBuffersUntilComplete() {
        let message = body(#"{"jsonrpc":"2.0","method":"x"}"#)
        let framed = frameJSONRPCMessage(message)
        let cut = framed.count - 5  // split mid-body
        var decoder = LSPFrameDecoder()

        XCTAssertEqual(decoder.push(Array(framed[0..<cut])), [], "incomplete frame yields nothing")
        XCTAssertEqual(decoder.push(Array(framed[cut...])), [message], "completes once the rest arrives")
    }

    func testHeaderSplitAcrossChunks() {
        let message = body(#"{"k":"v"}"#)
        let framed = frameJSONRPCMessage(message)
        var decoder = LSPFrameDecoder()
        // Split inside the Content-Length header line.
        XCTAssertEqual(decoder.push(Array(framed[0..<8])), [])
        XCTAssertEqual(decoder.push(Array(framed[8...])), [message])
    }

    func testTwoCompletePlusOnePartialReturnsOnlyComplete() {
        let a = body(#"{"a":1}"#), b = body(#"{"b":2}"#), c = body(#"{"c":3}"#)
        let cFramed = frameJSONRPCMessage(c)
        let chunk = frameJSONRPCMessage(a) + frameJSONRPCMessage(b) + Array(cFramed.prefix(6))
        var decoder = LSPFrameDecoder()

        XCTAssertEqual(decoder.push(chunk), [a, b], "the partial third is held back")
        XCTAssertEqual(decoder.push(Array(cFramed.dropFirst(6))), [c])
    }

    func testMalformedHeaderIsDroppedAndDecoderResyncs() {
        let valid = body(#"{"ok":true}"#)
        // A header terminator with no Content-Length, followed by a real frame.
        let malformed = Array("Content-Type: nonsense\r\n\r\n".utf8)
        var decoder = LSPFrameDecoder()
        let frames = decoder.push(malformed + frameJSONRPCMessage(valid))
        XCTAssertEqual(frames, [valid], "a bad header is skipped without losing the next frame")
    }

    func testEmptyPushReturnsNothing() {
        var decoder = LSPFrameDecoder()
        XCTAssertEqual(decoder.push([]), [])
    }
}
