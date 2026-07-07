import ArgumentParser
import Foundation
import IPC
import DaemonCore
import Logging

@main
struct Alensd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "alensd",
        abstract: "Live code intelligence daemon (one per working directory)."
    )

    @Option(name: .shortAndLong, help: "Working directory the daemon is rooted at (default: CWD).")
    var dir: String?

    @Option(name: .customLong("log-file"), help: "Write logs to this file. Omit to log to the system log (os_log).")
    var logFile: String?

    mutating func run() async throws {
        let root = resolveRoot(dir)
        let logger = makeLogger(logFile: logFile)

        logger.info("alensd starting for \(root.path)")

        let core = DaemonCore(root: root, logger: logger)
        let decorator = IdleDecorator(inner: core, logger: logger)
        let sockPath = socketPath(forDirectory: root)
        let server = IPCServer(sockPath: sockPath, dispatcher: decorator, logger: logger)

        // Detect project languages and start LSP servers in the background.
        // The IPC socket comes up in server.run() below so agents can connect
        // immediately; status will show 'starting' until detection completes.
        Task {
            do { try await decorator.start() }
            catch { logger.error("LSP startup failed: \(error)") }
        }

        // On stop/idle, close the listener and let run() drain in-flight connections
        // (so the stop ack flushes) before exiting. A timed fallback guarantees the
        // daemon still terminates if a held-open connection stalls the drain.
        Task {
            for await reason in decorator.shutdownStream {
                logger.info("shutting down: \(reason.rawValue)")
                server.stop()
                Task {
                    try? await Task.sleep(for: .seconds(3))
                    Foundation.exit(0)
                }
            }
        }

        try await server.run()
        Foundation.exit(0)
    }
}
