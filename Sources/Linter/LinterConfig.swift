import Foundation

public struct LinterConfig: Codable, Sendable {
    public struct LinterSpec: Codable, Sendable {
        public let command: String
        /// Argument template. `$FILE` is replaced with the absolute paths of every file
        /// in the batch (one process per language, not per file); linters run against the
        /// real paths on disk.
        public let args: [String]
        /// Dotted key locating the results array in the linter's JSON output (nil = the
        /// output is itself the array). e.g. golangci-lint nests under "Issues".
        public let resultsKey: String?
        /// Dotted key, within one result entry, to the file path it belongs to — used to
        /// split a batch run back into per-file output. e.g. "file" (SwiftLint),
        /// "filePath" (eslint), "filename" (ruff), "Pos.Filename" (golangci-lint).
        public let fileField: String

        public init(command: String, args: [String], resultsKey: String? = nil, fileField: String = "file") {
            self.command = command
            self.args = args
            self.resultsKey = resultsKey
            self.fileField = fileField
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            command = try c.decode(String.self, forKey: .command)
            args = try c.decode([String].self, forKey: .args)
            resultsKey = try c.decodeIfPresent(String.self, forKey: .resultsKey)
            fileField = (try c.decodeIfPresent(String.self, forKey: .fileField)) ?? "file"
        }
    }

    public var linters: [String: LinterSpec]

    public init(linters: [String: LinterSpec] = [:]) {
        self.linters = linters
    }

    /// Loads `.alens.json` from the project root.
    /// Returns nil (not throws) if the file is absent — callers fall back to `.defaults`.
    public static func load(from root: URL) -> LinterConfig? {
        let url = root.appendingPathComponent(".alens.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(LinterConfig.self, from: data)
    }

    public static let defaults = LinterConfig(linters: [
        // Pass the file paths positionally (not --use-stdin): SwiftLint needs the real
        // paths to honor included/excluded globs in .swiftlint.yml.
        "swift": LinterSpec(
            command: "swiftlint",
            args: ["lint", "--reporter", "json", "$FILE"],
            fileField: "file"
        ),
        "typescript": LinterSpec(
            command: "eslint",
            args: ["--format", "json", "$FILE"],
            fileField: "filePath"
        ),
        "javascript": LinterSpec(
            command: "eslint",
            args: ["--format", "json", "$FILE"],
            fileField: "filePath"
        ),
        "python": LinterSpec(
            command: "ruff",
            args: ["check", "--output-format", "json", "$FILE"],
            fileField: "filename"
        ),
        "go": LinterSpec(
            command: "golangci-lint",
            args: ["run", "--out-format", "json", "$FILE"],
            resultsKey: "Issues",
            fileField: "Pos.Filename"
        )
    ])
}
