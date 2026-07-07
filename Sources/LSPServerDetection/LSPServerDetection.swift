import Foundation
import LSPClient

// MARK: - Protocol

public protocol LSPServerDetection: Sendable {
    func detect(root: URL) async throws -> DetectionResult
}

// MARK: - Result

public struct DetectionResult: Sendable {
    public let lspServers: [ServerConfig]
    public let availableLinters: [Language]

    public init(lspServers: [ServerConfig], availableLinters: [Language] = []) {
        self.lspServers = lspServers
        self.availableLinters = availableLinters
    }
}

// MARK: - Default implementation

/// Scans the root directory for project markers and returns matching server configs.
/// Linter availability is detected separately in Chunk 7 — returns empty for now.
public final class DefaultLSPServerDetection: LSPServerDetection, Sendable {
    public init() {}

    public func detect(root: URL) async throws -> DetectionResult {
        // Explicit config wins: a project that declares `lspServers` in .alens.json
        // launches exactly those servers — marker detection is not consulted.
        if let config = LSPConfig.load(from: root) {
            return DetectionResult(lspServers: config.serverConfigs())
        }

        let path = root.standardizedFileURL.path
        var servers: [ServerConfig] = []

        if hasMarker(in: path, name: "Package.swift") ||
           hasXcodeproj(in: path) {
            servers.append(ServerConfig(
                serverID: "sourcekit-lsp",
                language: .swift,
                executable: "sourcekit-lsp",
                args: []
            ))
        }

        if hasMarker(in: path, name: "tsconfig.json") ||
           hasMarker(in: path, name: "package.json") {
            servers.append(ServerConfig(
                serverID: "typescript-language-server",
                language: .typescript,
                executable: "typescript-language-server",
                args: ["--stdio"]
            ))
        }

        if hasMarker(in: path, name: "pyproject.toml") ||
           hasMarker(in: path, name: "setup.py") ||
           hasMarker(in: path, name: "requirements.txt") {
            servers.append(ServerConfig(
                serverID: "pyright-langserver",
                language: .python,
                executable: "pyright-langserver",
                args: ["--stdio"]
            ))
        }

        if hasMarker(in: path, name: "go.mod") {
            servers.append(ServerConfig(
                serverID: "gopls",
                language: .go,
                executable: "gopls",
                args: []
            ))
        }

        if hasMarker(in: path, name: "Cargo.toml") {
            servers.append(ServerConfig(
                serverID: "rust-analyzer",
                language: .rust,
                executable: "rust-analyzer",
                args: []
            ))
        }

        return DetectionResult(lspServers: servers)
    }

    private func hasMarker(in path: String, name: String) -> Bool {
        FileManager.default.fileExists(atPath: path + "/" + name)
    }

    private func hasXcodeproj(in path: String) -> Bool {
        let items = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
        return items.contains { $0.hasSuffix(".xcodeproj") }
    }
}
