import ArgumentParser

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
