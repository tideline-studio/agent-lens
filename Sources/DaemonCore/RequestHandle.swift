import IPC

public protocol RequestDispatcher: Sendable {
    func dispatch(_ request: Request) async -> ResponseResult
}

public protocol CoreProtocol: RequestDispatcher {
    func start() async throws
}
