import IPC
import LSPClient

public protocol LinterRunner: Sendable {
    var language: Language { get }
    /// Lints a batch of files in one run and returns per-file output. Batching is the
    /// linter's own concern — typically one subprocess for all files, then split by file.
    func lint(files: [String]) async throws -> [String: String]
}
