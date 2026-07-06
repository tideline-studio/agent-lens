import Foundation

/// Returns the Unix socket path for a daemon rooted at `dir`.
/// Format: /tmp/alensd-<djb2-hex>.sock
public func socketPath(forDirectory dir: URL) -> String {
    let canonical = dir.standardizedFileURL.path
    return "/tmp/alensd-\(djb2Hex(canonical)).sock"
}

// DJB2 hash encoded as hex — short, fixed-length, collision-resistant enough for socket names.
public func djb2Hex(_ string: String) -> String {
    var hash: UInt64 = 5381
    for byte in string.utf8 {
        hash = hash &* 33 &+ UInt64(byte)
    }
    return String(hash, radix: 16)
}
