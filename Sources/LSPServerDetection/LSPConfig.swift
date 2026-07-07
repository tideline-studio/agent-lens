import Foundation
import LSPClient

/// User-declared LSP server selection, read from the project-root `.alens.json` —
/// the same file linters use, under the sibling `lspServers` key.
///
/// Presence of `lspServers` fully replaces marker-based detection: the daemon launches
/// exactly the servers listed, nothing more. Absence of the key falls back to scanning
/// project markers (`Package.swift`, `tsconfig.json`, …). This mirrors `LinterConfig` —
/// each model decodes only its own top-level key and ignores the other's, so the two share
/// one file without coupling.
public struct LSPConfig: Codable, Sendable {
    /// One LSP server, keyed by language (rawValue) in the parent dictionary.
    public struct ServerSpec: Codable, Sendable {
        /// The server executable, resolved on PATH. e.g. "sourcekit-lsp".
        public let command: String
        /// Launch arguments. e.g. ["--stdio"].
        public let args: [String]
        /// Extra environment for the server process, merged over the inherited env.
        public let env: [String: String]

        public init(command: String, args: [String] = [], env: [String: String] = [:]) {
            self.command = command
            self.args = args
            self.env = env
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            command = try c.decode(String.self, forKey: .command)
            args = (try c.decodeIfPresent([String].self, forKey: .args)) ?? []
            env = (try c.decodeIfPresent([String: String].self, forKey: .env)) ?? [:]
        }
    }

    /// Language rawValue → server. The key's *presence* (even as `{}`) is the signal that
    /// the project declares its servers explicitly; an empty map deliberately runs none.
    public var lspServers: [String: ServerSpec]

    public init(lspServers: [String: ServerSpec]) {
        self.lspServers = lspServers
    }

    /// Loads the `lspServers` section of `.alens.json` from the project root.
    /// Returns nil when the file is absent OR carries no `lspServers` key — both mean
    /// "fall back to marker detection". A present-but-empty `{}` decodes to an empty,
    /// non-nil config: a deliberate "run no servers".
    public static func load(from root: URL) -> LSPConfig? {
        let url = root.appendingPathComponent(".alens.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(LSPConfig.self, from: data)
    }

    /// The configured servers as `ServerConfig`s. An entry whose key is not a known
    /// `Language` is skipped — a typo'd language disables only itself, not the whole file.
    public func serverConfigs() -> [ServerConfig] {
        lspServers.compactMap { key, spec in
            guard let language = Language(rawValue: key) else { return nil }
            return ServerConfig(
                serverID: spec.command,
                language: language,
                executable: spec.command,
                args: spec.args,
                env: spec.env
            )
        }
    }
}
