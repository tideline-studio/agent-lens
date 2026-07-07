import Foundation

/// Returns true if `path` resolves to a location within `root` (inclusive of root itself).
/// Resolves symlinks and `..` components before comparing.
public func isWithinRoot(_ path: String, root: URL) -> Bool {
    let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath()
    let rootPath = root.resolvingSymlinksInPath().path
    return resolved.path == rootPath || resolved.path.hasPrefix(rootPath + "/")
}
