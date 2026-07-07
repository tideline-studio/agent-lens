import Dependencies
import IPC
import Logging

public enum ShutdownReason: String, Sendable, Equatable {
    case stop  // .stop command received
    case idle  // idle timeout elapsed
}

public actor IdleDecorator: CoreProtocol {
    private let inner: any CoreProtocol
    private let logger: Logger

    @Dependency(\.continuousClock) private var clock

    // Shutdown signal — nonisolated so callers don't need to await the property access.
    nonisolated public let shutdownStream: AsyncStream<ShutdownReason>
    private let _shutdown: AsyncStream<ShutdownReason>.Continuation

    private var idleTask: Task<Void, Never>?
    private var idleSeconds: Double = 0
    private var activityGeneration: UInt64 = 0
    private var isShuttingDown = false

    public init(inner: any CoreProtocol, logger: Logger) {
        self.inner = inner
        self.logger = logger
        let (stream, cont) = AsyncStream.makeStream(of: ShutdownReason.self)
        self.shutdownStream = stream
        self._shutdown = cont
    }

    // MARK: - CoreProtocol

    public func start() async throws {
        try await inner.start()
    }

    public func dispatch(_ handle: RequestHandle) async {
        activityGeneration += 1

        switch handle.command {
        case .start(let idleSecs, _):
            idleSeconds = idleSecs
            startIdleLoop()
            await inner.dispatch(handle)

        case .stop:
            await inner.dispatch(handle)
            triggerShutdown(.stop)

        default:
            await inner.dispatch(handle)
        }
    }

    // MARK: - Idle timer

    private struct IdleParams {
        let idleSeconds: Double
        let generation: UInt64
        let isShuttingDown: Bool
    }

    private var idleParams: IdleParams {
        IdleParams(
            idleSeconds: idleSeconds, generation: activityGeneration, isShuttingDown: isShuttingDown
        )
    }

    private func startIdleLoop() {
        idleTask?.cancel()
        idleTask = nil
        guard idleSeconds > 0, !isShuttingDown else { return }
        let c = clock
        // The Task body is non-isolated, so Swift can open `any Clock<Duration>` when
        // passing to the generic method — giving a concrete C.Instant for storage
        // and comparison without needing a separate Date dependency.
        idleTask = Task { [weak self] in
            await self?.idleLoop(clock: c)
        }
    }

    private func triggerShutdown(_ reason: ShutdownReason) {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        idleTask?.cancel()
        idleTask = nil
        _shutdown.yield(reason)
        _shutdown.finish()
    }

    private func idleLoop<C: Clock>(clock: C) async
    where C.Duration == Duration {
        var lastAccess = clock.now
        var seenGeneration: UInt64 = 0
        while true {
            let p = idleParams
            guard p.idleSeconds > 0, !p.isShuttingDown else { return }
            if p.generation != seenGeneration {
                lastAccess = clock.now
                seenGeneration = p.generation
            }
            let deadline = lastAccess.advanced(by: .seconds(p.idleSeconds))
            if clock.now >= deadline {
                logger.info("idle timeout after \(Int(p.idleSeconds))s, shutting down")
                triggerShutdown(.idle)
                return
            }
            try? await clock.sleep(until: deadline, tolerance: nil)
        }
    }
}
