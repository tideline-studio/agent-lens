import Foundation
import IPC

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
