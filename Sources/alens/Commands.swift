import ArgumentParser
import Darwin
import Foundation
import IPC

// MARK: - start

struct StartCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "start")

    @OptionGroup var global: GlobalFlags
    @Option(help: "Daemon working directory (default: CWD).")
    var dir: String?
    @Option(help: "Idle timeout before auto-exit, e.g. 30m, 2h, 1d.")
    var idle: String = "2h"
    @Option(name: .customLong("log-level"), help: "Log level: debug, info, warn, error.")
    var logLevel: String = "info"
    @Option(
        name: .customLong("log-file"),
        help: "Daemon log file. Omit to log to the system log (os_log).")
    var logFile: String?

    mutating func run() async throws {
        let root = resolveRoot(dir)
        let sockPath = socketPath(forDirectory: root)
        let idleSecs = try parseDuration(idle)
        let level = LogLevel(rawValue: logLevel) ?? .info

        if isDaemonRunning(at: sockPath) {
            print("alensd already running for \(root.path)")
            return
        }

        let daemonBin = try findDaemonBinary()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: daemonBin)
        var daemonArgs = ["--dir", root.path]
        if let logFile {
            // Resolve against the client's CWD now; the daemon runs detached and
            // shouldn't reinterpret a relative path against its own directory.
            daemonArgs += ["--log-file", URL(fileURLWithPath: logFile).path]
        }
        process.arguments = daemonArgs
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()

        // Poll until socket appears (up to 5 s).
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, !isDaemonRunning(at: sockPath) {
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        guard isDaemonRunning(at: sockPath) else {
            fputs("error: daemon did not start within 5 s\n", stderr)
            Foundation.exit(1)
        }

        // Send the start command so the daemon can record the configured idle timeout.
        let resp = try await roundTrip(
            command: .start(idleSeconds: idleSecs, logLevel: level),
            socketPath: sockPath
        )
        try printResponse(resp, json: global.json)
        if !global.json { print("alensd started for \(root.path)") }
    }

    private func findDaemonBinary() throws -> String {
        let selfURL = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0])
            .resolvingSymlinksInPath()
        let candidate = selfURL.deletingLastPathComponent().appendingPathComponent("alensd")
        if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate.path }
        if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
            for dir in pathEnv.split(separator: ":") {
                let p = URL(fileURLWithPath: String(dir)).appendingPathComponent("alensd").path
                if FileManager.default.isExecutableFile(atPath: p) { return p }
            }
        }
        throw CLIError.daemonBinaryNotFound
    }
}

// MARK: - stop

struct StopCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "stop")

    @OptionGroup var global: GlobalFlags
    @Option(help: "Daemon working directory (default: CWD).")
    var dir: String?

    mutating func run() async throws {
        let root = resolveRoot(dir)
        let sockPath = socketPath(forDirectory: root)
        let resp = try await roundTrip(command: .stop, socketPath: sockPath)
        try printResponse(resp, json: global.json)
        if !global.json { print("daemon stopped") }
    }
}

// MARK: - status

struct StatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "status")

    @OptionGroup var global: GlobalFlags
    @Option(help: "Daemon working directory (default: CWD).")
    var dir: String?

    mutating func run() async throws {
        let root = resolveRoot(dir)
        let sockPath = socketPath(forDirectory: root)
        let resp = try await roundTrip(command: .status, socketPath: sockPath)
        try printResponse(resp, json: global.json)
    }
}

// MARK: - diagnose

struct DiagnoseCommand: FileTargetCommand {
    static let configuration = CommandConfiguration(commandName: "diagnose")

    @OptionGroup var global: GlobalFlags
    @Argument(help: "Files to diagnose (directories are not expanded).")
    var files: [String] = []
    @Option(help: "Total time budget in seconds (daemon gets 90% for LSP, 10% reserved for IPC).")
    var timeout: Double = 5
    @Option(help: "Daemon working directory (default: CWD).")
    var dir: String?

    mutating func run() async throws {
        let root = resolveRoot(dir)
        let sockPath = socketPath(forDirectory: root)

        let allPaths = try resolvedFiles(noun: "diagnose")
        guard !allPaths.isEmpty else {
            if !global.json { print("No diagnosable files found.") }
            return
        }

        let command = Command.diagnose(files: allPaths, timeoutSeconds: max(1, timeout * 0.9))
        let sock = sockPath
        let resp = try await withTimeout(seconds: timeout) {
            try await roundTrip(command: command, socketPath: sock)
        }
        try printResponse(resp, json: global.json)
    }
}

// MARK: - lint

struct LintCommand: FileTargetCommand {
    static let configuration = CommandConfiguration(commandName: "lint")

    @OptionGroup var global: GlobalFlags
    @Argument(help: "Files to lint (directories are not expanded).")
    var files: [String] = []
    @Option(help: "Daemon working directory (default: CWD).")
    var dir: String?

    mutating func run() async throws {
        let root = resolveRoot(dir)
        let sockPath = socketPath(forDirectory: root)

        let resolved = try resolvedFiles(noun: "lint")
        guard !resolved.isEmpty else {
            if !global.json { print("No lintable files found.") }
            return
        }
        let resp = try await roundTrip(command: .lint(files: resolved), socketPath: sockPath)
        try printResponse(resp, json: global.json)
    }
}

// MARK: - check

struct CheckCommand: FileTargetCommand {
    static let configuration = CommandConfiguration(
        commandName: "check",
        abstract: "Run diagnose and lint together in one pass."
    )

    @OptionGroup var global: GlobalFlags
    @Argument(help: "Files to check (directories are not expanded).")
    var files: [String] = []
    @Option(help: "Total time budget in seconds (daemon gets 90% for LSP, 10% reserved for IPC).")
    var timeout: Double = 5
    @Option(help: "Daemon working directory (default: CWD).")
    var dir: String?

    mutating func run() async throws {
        let root = resolveRoot(dir)
        let sockPath = socketPath(forDirectory: root)

        let allPaths = try resolvedFiles(noun: "check")
        guard !allPaths.isEmpty else {
            if !global.json { print("No checkable files found.") }
            return
        }

        let command = Command.check(files: allPaths, timeoutSeconds: max(1, timeout * 0.9))
        let sock = sockPath
        let resp = try await withTimeout(seconds: timeout) {
            try await roundTrip(command: command, socketPath: sock)
        }
        try printResponse(resp, json: global.json)
    }
}
