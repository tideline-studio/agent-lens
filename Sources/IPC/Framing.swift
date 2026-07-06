import Darwin
import Foundation
import NIOCore

// Length-prefixed framing: a 4-byte big-endian UInt32 body length, then that many
// bytes of JSON. Chosen over newline-delimited JSON because it is binary-safe
// (payloads may contain any byte, including Unicode line separators that a
// line splitter would wrongly break on), needs no delimiter scan, and lets us
// enforce a hard size cap before buffering. 10 MB cap guards against runaway reads.

public enum FramingError: Error, Sendable {
    case connectionClosed
    case messageTooBig(byteCount: Int)
}

public let maxFrameBytes = 10 * 1024 * 1024
let lengthHeaderBytes = 4

// MARK: - Synchronous fd helpers
//
// Used by the socket tests (which drive a real daemon over a raw fd) and any
// caller that wants a blocking round-trip. Reads are bulk — never byte-at-a-time.

/// Encodes `value` as a length-prefixed JSON frame and writes it to `fd`.
public func writeFrame<T: Encodable>(_ value: T, fd: Int32) throws {
    let body = try JSONEncoder().encode(value)
    guard body.count <= maxFrameBytes else { throw FramingError.messageTooBig(byteCount: body.count) }
    var header = UInt32(body.count).bigEndian
    var frame = Data(bytes: &header, count: lengthHeaderBytes)
    frame.append(body)
    try writeAll(frame, to: fd)
}

/// Reads one length-prefixed frame from `fd` and decodes it as `T`.
public func readFrame<T: Decodable>(_ type: T.Type, fd: Int32) throws -> T {
    let header = try readExactly(lengthHeaderBytes, from: fd)
    let length = Int(header.withUnsafeBytes { UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self)) })
    guard length <= maxFrameBytes else { throw FramingError.messageTooBig(byteCount: length) }
    let body = try readExactly(length, from: fd)
    return try JSONDecoder().decode(type, from: body)
}

private func writeAll(_ data: Data, to fd: Int32) throws {
    var slice = data[...]
    while !slice.isEmpty {
        let n = slice.withUnsafeBytes { buf in
            Darwin.write(fd, buf.baseAddress!, buf.count)
        }
        guard n > 0 else { throw FramingError.connectionClosed }
        slice = slice.dropFirst(n)
    }
}

/// Reads exactly `count` bytes, looping over bulk `read()` calls.
private func readExactly(_ count: Int, from fd: Int32) throws -> Data {
    guard count > 0 else { return Data() }
    var result = Data(capacity: count)
    var buffer = [UInt8](repeating: 0, count: min(count, 64 * 1024))
    while result.count < count {
        let want = min(buffer.count, count - result.count)
        let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!, want) }
        guard n > 0 else { throw FramingError.connectionClosed }
        result.append(contentsOf: buffer[0..<n])
    }
    return result
}

// MARK: - NIO frame codec

/// Splits the inbound byte stream into whole JSON frames using the length prefix,
/// enforcing the size cap before buffering the body.
public struct IPCFrameDecoder: ByteToMessageDecoder {
    public typealias InboundOut = ByteBuffer

    public init() {}

    public mutating func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        guard let length = buffer.getInteger(at: buffer.readerIndex, as: UInt32.self) else {
            return .needMoreData  // header not fully arrived yet
        }
        let bodyLength = Int(length)
        guard bodyLength <= maxFrameBytes else {
            throw FramingError.messageTooBig(byteCount: bodyLength)
        }
        guard buffer.readableBytes >= lengthHeaderBytes + bodyLength else {
            return .needMoreData  // body still in flight
        }
        buffer.moveReaderIndex(forwardBy: lengthHeaderBytes)
        let frame = buffer.readSlice(length: bodyLength)!
        context.fireChannelRead(wrapInboundOut(frame))
        return .continue
    }
}

/// Encodes `value` as a length-prefixed JSON frame into a ByteBuffer ready to write.
public func encodeFrame<T: Encodable>(_ value: T, allocator: ByteBufferAllocator) throws -> ByteBuffer {
    let body = try JSONEncoder().encode(value)
    guard body.count <= maxFrameBytes else { throw FramingError.messageTooBig(byteCount: body.count) }
    var buffer = allocator.buffer(capacity: lengthHeaderBytes + body.count)
    buffer.writeInteger(UInt32(body.count))  // big-endian by default
    buffer.writeBytes(body)
    return buffer
}

/// Decodes a `T` from a frame body ByteBuffer (length prefix already stripped).
public func decodeFrame<T: Decodable>(_ type: T.Type, from buffer: inout ByteBuffer) throws -> T {
    let bytes = buffer.readBytes(length: buffer.readableBytes) ?? []
    return try JSONDecoder().decode(type, from: Data(bytes))
}
