import ArgumentParser
import Foundation

/// Resolves `--dir` option (or CWD) to an absolute path and canonical URL.
func resolveRoot(_ dir: String?) -> URL {
    let raw = dir ?? FileManager.default.currentDirectoryPath
    return URL(fileURLWithPath: raw, isDirectory: true).standardizedFileURL
}

/// Parses a human-readable duration string ("30s", "5m", "2h", "1d") into seconds.
func parseDuration(_ str: String) throws -> Double {
    let s = str.lowercased()
    if let n = Double(s)                           { return n }
    if s.hasSuffix("s"), let n = Double(s.dropLast()) { return n }
    if s.hasSuffix("m"), let n = Double(s.dropLast()) { return n * 60 }
    if s.hasSuffix("h"), let n = Double(s.dropLast()) { return n * 3_600 }
    if s.hasSuffix("d"), let n = Double(s.dropLast()) { return n * 86_400 }
    throw CLIError.invalidDuration(str)
}

/// Resolves CLI file args to absolute paths (relative to `cwd`). Directory args are
/// rejected: the agent passes the specific files it wants checked, and the CLI does not
/// expand directories — a deep walk is exactly the large-expansion failure we removed.
func resolveInputs(_ files: [String], cwd: URL) throws -> [String] {
    try files.map { arg in
        let path =
            arg.hasPrefix("/")
            ? arg
            : URL(fileURLWithPath: arg, relativeTo: cwd).standardizedFileURL.path
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
            throw ValidationError(
                "\(arg) is a directory; pass individual files (directory expansion was removed)")
        }
        return path
    }
}

/// A command whose positional arguments are a list of target files. Shares the
/// "must pass at least one file, resolve each to an absolute path, reject
/// directories" validation that `diagnose`/`lint`/`check` all need.
protocol FileTargetCommand: AsyncParsableCommand {
    var files: [String] { get }
}

extension FileTargetCommand {
    /// Validates `files` is non-empty and resolves each to an absolute path relative
    /// to the current directory. `noun` names the action for the empty-file error
    /// message, e.g. "diagnose", "lint", "check".
    func resolvedFiles(noun: String) throws -> [String] {
        guard !files.isEmpty else {
            throw ValidationError(
                "pass one or more files to \(noun); omitting them no longer expands to the whole project"
            )
        }
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        return try resolveInputs(files, cwd: cwd)
    }
}
