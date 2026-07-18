import Foundation
import LSPClient

// MARK: - WatchRegistry

public actor WatchRegistry {
    private struct Entry {
        let serverID: ServerID
        let globs: [GlobPattern]
    }

    private var entries: [String: Entry] = [:]  // keyed by registration ID

    public init() {}

    public func register(_ registrationID: String, serverID: ServerID, globs: [GlobPattern]) {
        entries[registrationID] = Entry(serverID: serverID, globs: globs)
    }

    public func unregister(_ registrationID: String) {
        entries.removeValue(forKey: registrationID)
    }

    /// Returns all serverIDs whose registered globs match the given absolute path.
    public func serversMatching(path: String) -> [ServerID] {
        entries.values.compactMap { entry in
            entry.globs.contains { globMatches(pattern: $0, path: path) } ? entry.serverID : nil
        }
    }
}

// MARK: - Glob matching

/// Matches an absolute path against an LSP glob pattern.
/// Handles: literal, *, ** (path-agnostic wildcard), ? (single char).
func globMatches(pattern: String, path: String) -> Bool {
    matchGlob(p: pattern[...], s: path[...])
}

private func matchGlob(p: Substring, s: Substring) -> Bool {
    var p = p, s = s

    while true {
        guard !p.isEmpty else { return s.isEmpty }

        if p.hasPrefix("**") {
            let rest = p.dropFirst(2)
            // Skip optional slash after **
            let restAfterSlash = rest.hasPrefix("/") ? rest.dropFirst() : rest
            // Try matching rest against every suffix of s
            var si = s.startIndex
            while true {
                if matchGlob(p: restAfterSlash, s: s[si...]) { return true }
                if si == s.endIndex { break }
                si = s.index(after: si)
            }
            return false
        }

        if p.first == "*" {
            let rest = p.dropFirst()
            // * matches any chars except /
            var si = s.startIndex
            while true {
                if matchGlob(p: rest, s: s[si...]) { return true }
                if si == s.endIndex || s[si] == "/" { break }
                si = s.index(after: si)
            }
            return false
        }

        guard !s.isEmpty else { return false }

        if p.first == "?" {
            guard s.first != "/" else { return false }
        } else {
            guard p.first == s.first else { return false }
        }
        p = p.dropFirst()
        s = s.dropFirst()
    }
}
