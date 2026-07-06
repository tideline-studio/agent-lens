import Darwin
import Foundation

public enum SocketError: Error, Sendable {
    case createFailed
    case connectFailed(path: String)
}

/// Opens a connected client socket to the daemon at `path`.
/// Returns the file descriptor — caller must close it.
public func openClientSocket(path: String) throws -> Int32 {
    let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw SocketError.createFailed }
    var addr = makeSockaddr(path: path)
    let rc = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    if rc != 0 { Darwin.close(fd); throw SocketError.connectFailed(path: path) }
    return fd
}

/// Returns true if a daemon is already answering on `path`.
public func isDaemonRunning(at path: String) -> Bool {
    guard let fd = try? openClientSocket(path: path) else { return false }
    Darwin.close(fd)
    return true
}

// MARK: -

private func makeSockaddr(path: String) -> sockaddr_un {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &addr.sun_path) { dst in
        path.withCString { src in
            let len = min(Int(Darwin.strlen(src)) + 1, dst.count)
            dst.copyMemory(from: UnsafeRawBufferPointer(start: src, count: len))
        }
    }
    return addr
}
