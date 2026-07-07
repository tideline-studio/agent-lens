import ArgumentParser
import Foundation
import IPC
import NIOCore
import NIOPosix

struct Alens: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "alens",
        abstract: "Live code intelligence for agents.",
        subcommands: [
            StartCommand.self,
            StopCommand.self,
            StatusCommand.self,
            DiagnoseCommand.self,
            LintCommand.self,
            CheckCommand.self,
        ]
    )
}

struct GlobalFlags: ParsableArguments {
    @Flag(name: .long, help: "Emit raw JSON instead of human-readable output.")
    var json = false
}

// MARK: - Shared helpers

enum CLIError: Error, CustomStringConvertible {
    case noDaemon(socketPath: String)
    case daemonBinaryNotFound
    case invalidDuration(String)
    case timeout

    var description: String {
        switch self {
        case .noDaemon(let p):      return "no daemon running (tried \(p)); run 'alens start' first"
        case .daemonBinaryNotFound: return "alensd binary not found next to alens or on PATH"
        case .invalidDuration(let s): return "invalid duration '\(s)'; use e.g. 30s, 5m, 2h, 1d"
        case .timeout:              return "timed out waiting for daemon response; try increasing --timeout"
        }
    }
}

/// Races `work` against a deadline. Throws `CLIError.timeout` if `seconds` elapse first.
func withTimeout<T: Sendable>(
    seconds: Double,
    _ work: @Sendable @escaping () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await work() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw CLIError.timeout
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}

/// Connects to the daemon socket, sends `command`, and returns its response.
/// Throws `CLIError.noDaemon` if the socket is unreachable or closes without replying.
func roundTrip(command: Command, socketPath: String) async throws -> Response {
    let channel: NIOAsyncChannel<ByteBuffer, ByteBuffer>
    do {
        channel = try await ClientBootstrap(group: NIOSingletons.posixEventLoopGroup)
            .connect(unixDomainSocketPath: socketPath) { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(ByteToMessageHandler(IPCFrameDecoder()))
                    return try NIOAsyncChannel<ByteBuffer, ByteBuffer>(wrappingChannelSynchronously: channel)
                }
            }
    } catch {
        throw CLIError.noDaemon(socketPath: socketPath)
    }

    return try await channel.executeThenClose { inbound, outbound in
        try await outbound.write(encodeFrame(Request(command: command), allocator: ByteBufferAllocator()))
        var iterator = inbound.makeAsyncIterator()
        guard var frame = try await iterator.next() else {
            throw CLIError.noDaemon(socketPath: socketPath)
        }
        return try decodeFrame(Response.self, from: &frame)
    }
}

/// Prints `response` in JSON or human-readable form.
/// On `.err`, writes to stderr and terminates with exit code 1.
func printResponse(_ response: Response, json: Bool) throws {
    if json {
        let data = try JSONEncoder().encode(response)
        print(String(data: data, encoding: .utf8)!)
        return
    }
    switch response.result {
    case .ok(let payload):
        printPayload(payload)
    case .err(let err):
        fputs("error: \(err.code.rawValue): \(err.message)\n", stderr)
        Foundation.exit(1)
    }
}

private func printPayload(_ payload: Payload) {
    switch payload {
    case .ack:
        break
    case .status(let report):
        if report.servers.isEmpty {
            print("Servers: none")
        } else {
            for s in report.servers {
                print("  \(s.language): \(s.readinessState.rawValue)")
            }
        }
        print("Uptime: \(formatDuration(report.uptimeSeconds))")
    case .diagnose(let files):
        for (path, fd) in files.sorted(by: { $0.key < $1.key }) {
            printFileDiagnostics(path, fd)
        }
    case .lint(let files):
        for (path, output) in files.sorted(by: { $0.key < $1.key }) where !output.isEmpty {
            print("\(path):")
            print(output)
        }
    case .check(let diagnostics, let lint):
        // Group by file so each path's diagnostics and lint output appear together.
        let paths = Set(diagnostics.keys).union(lint.keys).sorted()
        for path in paths {
            if let fd = diagnostics[path] { printFileDiagnostics(path, fd) }
            // Label lint output so its provenance stays distinct from compiler diagnostics.
            if let output = lint[path], !output.isEmpty {
                print("\(path) [lint]:")
                print(output)
            }
        }
    }
}

private func printFileDiagnostics(_ path: String, _ fd: FileDiagnostics) {
    if fd.readinessState == .unsupported {
        print("\(path): (no language support)")
    } else if fd.stale {
        let reason = fd.readinessState == .initial
            ? "no language server configured"
            : "stale — deadline elapsed"
        print("\(path): (\(reason))")
    }
    for d in fd.diagnostics {
        let sev = d.severity.map(severityLabel) ?? "note"
        print("\(path):\(d.range.start.line + 1):\(d.range.start.character + 1): \(sev): \(d.message)")
    }
}

private func severityLabel(_ s: DiagnosticSeverity) -> String {
    switch s {
    case .error:       return "error"
    case .warning:     return "warning"
    case .information: return "note"
    case .hint:        return "hint"
    }
}

private func formatDuration(_ s: Double) -> String {
    if s < 60   { return String(format: "%.1fs", s) }
    if s < 3600 { return String(format: "%.1fm", s / 60) }
    return String(format: "%.1fh", s / 3600)
}

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
