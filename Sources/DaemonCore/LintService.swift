import IPC
import Linter
import LSPClient

/// Groups files by language and runs each language's linter once for its whole
/// batch. `config` and `factory` are fixed at construction — `DaemonCore` constructs
/// one per call from its current `linterConfig`, which is `.defaults` until `start()`
/// loads it from disk, so lint keeps working before `start()` runs.
struct LintService: Sendable {
    private let config: LinterConfig
    private let factory: @Sendable (Language, LinterConfig) -> (any LinterRunner)?

    init(
        config: LinterConfig,
        factory: @escaping @Sendable (Language, LinterConfig) -> (any LinterRunner)?
    ) {
        self.config = config
        self.factory = factory
    }

    func lint(files: [String]) async -> [String: String] {
        // Group by language so each linter runs once for its whole batch, not once per
        // file. Files with no linter still get an empty result so callers see them.
        var byLanguage: [Language: [String]] = [:]
        var results: [String: String] = [:]
        for path in files {
            if let lang = Language.from(path: path), factory(lang, config) != nil {
                byLanguage[lang, default: []].append(path)
            } else {
                results[path] = ""
            }
        }

        let batched = await withTaskGroup(of: [String: String].self) { tg in
            for (lang, paths) in byLanguage {
                guard let linter = factory(lang, config) else { continue }
                tg.addTask {
                    if let out = try? await linter.lint(files: paths) { return out }
                    return Dictionary(uniqueKeysWithValues: paths.map { ($0, "") })
                }
            }
            var combined: [String: String] = [:]
            for await partial in tg { combined.merge(partial) { _, new in new } }
            return combined
        }
        results.merge(batched) { _, new in new }
        return results
    }
}
