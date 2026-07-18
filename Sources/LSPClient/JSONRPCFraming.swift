import Foundation

// LSP wire protocol: Content-Length header framing.
//
// Format:
//   Content-Length: <N>\r\n
//   \r\n
//   <N bytes of JSON>

/// Frames a JSON-RPC message body with its Content-Length header, ready to write
/// to the server's stdin.
public func frameJSONRPCMessage(_ body: Data) -> [UInt8] {
    var out = Array("Content-Length: \(body.count)\r\n\r\n".utf8)
    out.append(contentsOf: body)
    return out
}

/// Incremental Content-Length frame decoder. Feed it stdout chunks via `push`;
/// it buffers across chunk boundaries and returns whole message bodies. Unlike a
/// byte-at-a-time reader, it scans buffered chunks, so large payloads don't cost
/// one syscall/await per byte.
public struct LSPFrameDecoder {
    private var buffer: [UInt8] = []

    public init() {}

    public mutating func push(_ bytes: [UInt8]) -> [Data] {
        buffer.append(contentsOf: bytes)
        var frames: [Data] = []
        while let frame = popFrame() { frames.append(frame) }
        return frames
    }

    /// Pops one complete frame from the front of the buffer, or nil if incomplete.
    private mutating func popFrame() -> Data? {
        guard let headerEnd = headerEndIndex() else { return nil }  // start of \r\n\r\n
        let bodyStart = headerEnd + 4

        guard let length = parseContentLength(buffer[0..<headerEnd]) else {
            // Malformed header — drop it and resync rather than spin forever.
            buffer.removeFirst(bodyStart)
            return popFrame()
        }
        guard buffer.count >= bodyStart + length else { return nil }  // body still arriving

        let body = Data(buffer[bodyStart ..< bodyStart + length])
        buffer.removeFirst(bodyStart + length)
        return body
    }

    /// Index of the first byte of the `\r\n\r\n` header terminator, if present.
    private func headerEndIndex() -> Int? {
        guard buffer.count >= 4 else { return nil }
        var i = 0
        while i <= buffer.count - 4 {
            if buffer[i] == 13, buffer[i + 1] == 10, buffer[i + 2] == 13, buffer[i + 3] == 10 {
                return i
            }
            i += 1
        }
        return nil
    }
}

private func parseContentLength(_ headerBytes: ArraySlice<UInt8>) -> Int? {
    let header = String(decoding: headerBytes, as: UTF8.self)
    for line in header.components(separatedBy: "\r\n") where line.lowercased().hasPrefix("content-length:") {
        let value = line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)
        return Int(value)
    }
    return nil
}
