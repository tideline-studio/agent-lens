/// Directory names that are excluded from file scanning and FSEvents processing.
/// Single source of truth used by both the CLI expansion and the daemon watcher.
public let excludedDirectoryNames: Set<String> = [
    ".git", ".hg", ".svn",
    ".build", ".swiftpm",
    "node_modules", ".yarn",
    "DerivedData",
    "__pycache__", ".venv", "venv",
    "vendor", "dist", "build",
]

/// Returns true if any path component of `path` is in `excludedDirectoryNames`.
public func isExcludedPath(_ path: String) -> Bool {
    path.split(separator: "/").contains { excludedDirectoryNames.contains(String($0)) }
}
