import Darwin
import Foundation
import IPC
import Logging
import NIOCore
import NIOPosix
import os

/// Server-channel handler that swallows errors raised while accepting/configuring
/// a single connection, so one bad client can't terminate the accept loop.
/// Sits ahead of the NIOAsyncChannel handler in the pipeline; by not re-firing the
/// error, it keeps it from finishing the inbound child-channel stream.
private final class AcceptErrorHandler: ChannelInboundHandler, Sendable {
    typealias InboundIn = Channel  // accepted child channels pass straight through

    private let logger: Logging.Logger
    init(logger: Logging.Logger) { self.logger = logger }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        logger.debug("ignoring transient accept error: \(error)")
        // Intentionally not calling context.fireErrorCaught — swallow it.
    }
}

/// NIO-based Unix-socket server. Each accepted connection runs as its own
/// structured task on the event-loop group — reads are non-blocking, so a slow
/// or idle client never ties up a thread (the previous design did blocking
/// reads inside Tasks on the cooperative pool, which could starve it).
public final class IPCServer: Sendable {
    private let sockPath: String
    private let dispatcher: any RequestDispatcher
    let logger: Logging.Logger
    private let group: MultiThreadedEventLoopGroup
    // Holds the bound listener channel so stop() can close it from another task.
    private let listenerChannel: OSAllocatedUnfairLock<Channel?>

    public init(sockPath: String, dispatcher: any RequestDispatcher, logger: Logging.Logger) {
        self.sockPath = sockPath
        self.dispatcher = dispatcher
        self.logger = logger
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.listenerChannel = OSAllocatedUnfairLock(initialState: nil)
    }

    /// Binds the Unix socket and serves connections until `stop()` closes it.
    public func run() async throws {
        // Don't clobber a socket a live daemon already owns.
        if FileManager.default.fileExists(atPath: sockPath), isDaemonRunning(at: sockPath) {
            fputs("alensd: daemon already running at \(sockPath)\n", stderr)
            Foundation.exit(0)
        }

        let logger = self.logger
        let listener = try await ServerBootstrap(group: group)
            // Swallow transient accept-path errors (e.g. NIOFcntlFailedError when a
            // client connects then closes before the socket is configured — which is
            // exactly what every isDaemonRunning() health check does). Without this,
            // the error reaches the NIOAsyncChannel handler and terminates the whole
            // accept stream, taking the daemon down on the first probe.
            .serverChannelInitializer { channel in
                channel.pipeline.addHandler(AcceptErrorHandler(logger: logger))
            }
            .bind(
                unixDomainSocketPath: sockPath,
                cleanupExistingSocketFile: true
            ) { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(ByteToMessageHandler(IPCFrameDecoder()))
                    return try NIOAsyncChannel<ByteBuffer, ByteBuffer>(wrappingChannelSynchronously: channel)
                }
            }

        // bind() creates the socket group/other-accessible; restrict to owner-only.
        Darwin.chmod(sockPath, 0o600)
        listenerChannel.withLock { $0 = listener.channel }
        logger.info("listening on \(sockPath)")

        let dispatcher = self.dispatcher
        do {
            try await withThrowingDiscardingTaskGroup { group in
                try await listener.executeThenClose { inbound in
                    for try await connection in inbound {
                        group.addTask {
                            await IPCServer.handle(connection, dispatcher: dispatcher, logger: logger)
                        }
                    }
                }
            }
        } catch {
            // The inbound stream throws when stop() closes the listener — normal shutdown.
            logger.debug("accept loop ended: \(error)")
        }
    }

    /// Closes the listening socket, ending the accept loop in `run()`.
    public func stop() {
        let channel = listenerChannel.withLock { $0 }
        channel?.close(promise: nil)
    }

    private static func handle(
        _ connection: NIOAsyncChannel<ByteBuffer, ByteBuffer>,
        dispatcher: any RequestDispatcher,
        logger: Logging.Logger
    ) async {
        do {
            try await connection.executeThenClose { inbound, outbound in
                for try await var frame in inbound {
                    let request: Request
                    do {
                        request = try decodeFrame(Request.self, from: &frame)
                    } catch {
                        logger.debug("dropping undecodable frame: \(error)")
                        continue
                    }

                    guard request.v == protocolVersion else {
                        let resp = Response(id: request.id, result: .err(ErrorPayload(
                            code: .versionMismatch,
                            message: "expected v\(protocolVersion), got v\(request.v)"
                        )))
                        try await outbound.write(encodeFrame(resp, allocator: ByteBufferAllocator()))
                        continue
                    }

                    let result = await dispatcher.dispatch(request)
                    try await outbound.write(encodeFrame(Response(id: request.id, result: result), allocator: ByteBufferAllocator()))

                    if case .stop = request.command { break }
                }
            }
        } catch {
            logger.debug("connection error: \(error)")
        }
    }
}
