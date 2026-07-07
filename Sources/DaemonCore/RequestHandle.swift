import IPC

public struct RequestHandle: Sendable {
    public let id: String
    public let receivedAt: ContinuousClock.Instant
    public let command: Command
    private let responder: @Sendable (ResponseResult) async -> Void

    public init(
        id: String,
        receivedAt: ContinuousClock.Instant,
        command: Command,
        responder: @escaping @Sendable (ResponseResult) async -> Void
    ) {
        self.id = id
        self.receivedAt = receivedAt
        self.command = command
        self.responder = responder
    }

    public func reply(_ result: ResponseResult) async {
        await responder(result)
    }
}

public protocol RequestDispatcher: Sendable {
    func dispatch(_ handle: RequestHandle) async
}

public protocol CoreProtocol: RequestDispatcher {
    func start() async throws
}
