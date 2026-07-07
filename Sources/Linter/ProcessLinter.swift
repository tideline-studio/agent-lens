import Foundation
import IPC
import LSPClient
import Dependencies

/// Single out-of-process linter runner driven by a LinterConfig.LinterSpec.
/// Returns the raw stdout from the linter process — parsing is left to the consumer.
public struct ProcessLinter: LinterRunner, Sendable {
    public let language: Language
    private let spec: LinterConfig.LinterSpec
    @Dependency(\.processRunner) private var runner

    public init(language: Language, spec: LinterConfig.LinterSpec) {
        self.language = language
        self.spec = spec
    }

    public func lint(files: [String]) async throws -> [String: String] {
        guard !files.isEmpty else { return [:] }
        // Always pass the real file paths (via $FILE) rather than piping content on
        // stdin. SwiftLint's --use-stdin reports a null path, so it can't evaluate
        // included/excluded globs in .swiftlint.yml and applies rules unconditionally;
        // giving it the paths lets those filters work. One run for the whole batch; the
        // `$FILE` placeholder expands to every path.
        let resolvedArgs = spec.args.flatMap { $0 == "$FILE" ? files : [$0] }
        let output = try await runner.run(spec.command, resolvedArgs, [:], nil)
        return LintOutputPartitioner.partition(
            output, files: files, resultsKey: spec.resultsKey, fileField: spec.fileField
        )
    }
}
