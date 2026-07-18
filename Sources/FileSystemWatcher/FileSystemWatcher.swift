import Foundation

// MARK: - FileEvent

public struct FileEvent: Sendable, Equatable {
    public let path: String
    public let kind: Kind

    public enum Kind: Sendable, Equatable {
        case created, modified, deleted
    }

    public init(path: String, kind: Kind) {
        self.path = path
        self.kind = kind
    }
}

// MARK: - FileSystemWatcher protocol

public protocol FileSystemWatcher: Sendable {
    func start(root: URL, sink: @Sendable @escaping (FileEvent) async -> Void) async throws
    func stop() async
}

// MARK: - NoOpWatcher

public struct NoOpWatcher: FileSystemWatcher, Sendable {
    public init() {}
    public func start(root: URL, sink: @Sendable @escaping (FileEvent) async -> Void) async throws {}
    public func stop() async {}
}
