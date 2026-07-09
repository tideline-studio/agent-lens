import Foundation
import LSPClient
import FileSystemWatcher
import Linter
import Dependencies

extension DependencyValues {
    public var fileSystem: FileSystem {
        get { self[FileSystemKey.self] }
        set { self[FileSystemKey.self] = newValue }
    }

    public var lspClientFactory: @Sendable (ServerConfig) async throws -> any LSPClient {
        get { self[LSPClientFactoryKey.self] }
        set { self[LSPClientFactoryKey.self] = newValue }
    }

    public var linterFactory: @Sendable (Language, LinterConfig) -> (any LinterRunner)? {
        get { self[LinterFactoryKey.self] }
        set { self[LinterFactoryKey.self] = newValue }
    }

    public var fileSystemWatcher: any FileSystemWatcher {
        get { self[FileSystemWatcherKey.self] }
        set { self[FileSystemWatcherKey.self] = newValue }
    }
}

// MARK: - Keys

private enum FileSystemKey: DependencyKey {
    static let liveValue = FileSystem.live
    static let testValue = FileSystem(
        contents: { _ in Data() },
        stat: { _ in FileStat(mtimeNs: 0, size: 0) }
    )
}

private enum LSPClientFactoryKey: DependencyKey {
    static let liveValue: @Sendable (ServerConfig) async throws -> any LSPClient = {
        try await StdioLSPClient.start(config: $0)
    }
    // Test default: no factory — tests must override with withDependencies.
    static let testValue: @Sendable (ServerConfig) async throws -> any LSPClient = { config in
        throw LSPClientError.processExited
    }
}

private enum LinterFactoryKey: DependencyKey {
    static let liveValue: @Sendable (Language, LinterConfig) -> (any LinterRunner)? = { lang, config in
        guard let spec = config.linters[lang.rawValue] else { return nil }
        return ProcessLinter(language: lang, spec: spec)
    }
    static let testValue: @Sendable (Language, LinterConfig) -> (any LinterRunner)? = { _, _ in nil }
}

private enum FileSystemWatcherKey: DependencyKey {
    static let liveValue: any FileSystemWatcher = FSEventsWatcher()
    static let testValue: any FileSystemWatcher = NoOpWatcher()
}

