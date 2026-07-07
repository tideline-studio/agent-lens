import Foundation

/// Splits one batched linter run's JSON output into per-file results, so running a single
/// process for many files still yields per-file output. Linters emit a JSON array of
/// entries, each naming the file it belongs to; `resultsKey` locates that array (nil = the
/// output itself is the array) and `fileField` is the dotted path to the file path within
/// an entry. Each input file maps to a JSON array of its entries — "[]" when it is clean.
public enum LintOutputPartitioner {

    /// - Returns: every input file mapped to its entries as a JSON array string. A file
    ///   with no entries gets "[]". If the output isn't the expected JSON shape, the whole
    ///   output is returned for a single-file batch (best effort) and "" for a multi-file
    ///   batch, where it can't be attributed.
    public static func partition(
        _ output: String,
        files: [String],
        resultsKey: String?,
        fileField: String
    ) -> [String: String] {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data),
              let entries = array(in: root, at: resultsKey) else {
            // Not the expected JSON: don't guess across multiple files.
            if files.count == 1 { return [files[0]: output] }
            return Dictionary(uniqueKeysWithValues: files.map { ($0, "") })
        }

        var grouped: [String: [Any]] = Dictionary(uniqueKeysWithValues: files.map { ($0, []) })
        for entry in entries {
            guard let dict = entry as? [String: Any],
                  let rawPath = string(in: dict, at: fileField),
                  let match = matchingFile(rawPath, in: files) else { continue }
            grouped[match, default: []].append(entry)
        }

        return grouped.mapValues { entries in
            guard let data = try? JSONSerialization.data(withJSONObject: entries),
                  let string = String(data: data, encoding: .utf8) else { return "[]" }
            return string
        }
    }

    /// Locates the results array, following a dotted `key` (nil/"" = the root is the array).
    private static func array(in root: Any, at key: String?) -> [Any]? {
        guard let key, !key.isEmpty else { return root as? [Any] }
        var current: Any? = root
        for part in key.split(separator: ".") {
            current = (current as? [String: Any])?[String(part)]
        }
        return current as? [Any]
    }

    /// Reads a string at a dotted `key` path within an entry (e.g. "Pos.Filename").
    private static func string(in entry: [String: Any], at key: String) -> String? {
        let parts = key.split(separator: ".")
        var current: Any? = entry
        for part in parts {
            current = (current as? [String: Any])?[String(part)]
        }
        return current as? String
    }

    /// Matches a path reported by the linter (which may be absolute or relative) to one of
    /// the input files, by standardized equality or path suffix.
    private static func matchingFile(_ reported: String, in files: [String]) -> String? {
        let standardized = URL(fileURLWithPath: reported).standardizedFileURL.path
        if let exact = files.first(where: { $0 == standardized || $0 == reported }) {
            return exact
        }
        // Relative paths from the linter: match the input file that ends with it.
        return files.first { $0.hasSuffix("/" + reported) }
    }
}
