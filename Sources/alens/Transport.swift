import Foundation
import IPC
import NIOCore
import NIOPosix

/// Races `work` against a deadline. Throws `CLIError.timeout` if `seconds` elapse first.
func withTimeout<T: Sendable>(
    seconds: Double,
    _ work: @Sendable @escaping () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await work() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw CLIError.timeout
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}

/// Connects to the daemon socket, sends `command`, and returns its response.
/// Throws `CLIError.noDaemon` if the socket is unreachable or closes without replying.
func roundTrip(command: Command, socketPath: String) async throws -> Response {
    let channel: NIOAsyncChannel<ByteBuffer, ByteBuffer>
    do {
        channel = try await ClientBootstrap(group: NIOSingletons.posixEventLoopGroup)
            .connect(unixDomainSocketPath: socketPath) { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(ByteToMessageHandler(IPCFrameDecoder()))
                    return try NIOAsyncChannel<ByteBuffer, ByteBuffer>(wrappingChannelSynchronously: channel)
                }
            }
    } catch {
        throw CLIError.noDaemon(socketPath: socketPath)
    }

    return try await channel.executeThenClose { inbound, outbound in
        try await outbound.write(encodeFrame(Request(command: command), allocator: ByteBufferAllocator()))
        var iterator = inbound.makeAsyncIterator()
        guard var frame = try await iterator.next() else {
            throw CLIError.noDaemon(socketPath: socketPath)
        }
        return try decodeFrame(Response.self, from: &frame)
    }
}
