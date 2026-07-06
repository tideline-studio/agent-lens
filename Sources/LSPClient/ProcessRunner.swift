import Foundation
import Dependencies
import Subprocess

public enum ProcessRunnerError: Error, Sendable {
    case timeout(executable: String)
}

private let maxLinterOutputBytes = 16 * 1024 * 1024

/// Async abstraction over running short-lived external processes (linters).
/// Long-lived processes (LSP servers) are owned directly by `StdioLSPClient`.
public struct ProcessRunner: Sendable {
    public var run: @Sendable (
        _ executable: String,
        _ args: [String],
        _ env: [String: String],
        _ stdin: Data?
    ) async throws -> String

    public init(
        run: @escaping @Sendable (String, [String], [String: String], Data?) async throws -> String
    ) {
        self.run = run
    }
}

extension ProcessRunner {
    public static let live = ProcessRunner(
        run: { executable, args, env, stdin in
            // swift-subprocess resolves the executable against PATH itself and streams
            // output with proper buffering — no manual Process/Pipe/env shim. `.name`
            // returns an absolute path directly when given one, so it covers both.
            let exe: Executable = .name(executable)
            let environment: Environment = env.isEmpty
                ? .inherit
                : .inherit.updating(Dictionary(
                    uniqueKeysWithValues: env.map { (Environment.Key(stringLiteral: $0.key), Optional($0.value)) }
                ))

            // Preserve the 30s cap: cancelling the run terminates the child.
            return try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask {
                    let result: ExecutionResult<Void, StringOutput<UTF8>, DiscardedOutput>
                    if let stdin {
                        result = try await Subprocess.run(
                            exe, arguments: Arguments(args), environment: environment,
                            input: .data(stdin),
                            output: .string(limit: maxLinterOutputBytes), error: .discarded
                        )
                    } else {
                        result = try await Subprocess.run(
                            exe, arguments: Arguments(args), environment: environment,
                            output: .string(limit: maxLinterOutputBytes), error: .discarded
                        )
                    }
                    return result.standardOutput ?? ""
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(30 * 1_000_000_000))
                    throw ProcessRunnerError.timeout(executable: executable)
                }
                defer { group.cancelAll() }
                return try await group.next()!
            }
        }
    )
}

// MARK: - Dependency

extension DependencyValues {
    public var processRunner: ProcessRunner {
        get { self[ProcessRunnerKey.self] }
        set { self[ProcessRunnerKey.self] = newValue }
    }
}

private enum ProcessRunnerKey: DependencyKey {
    static let liveValue: ProcessRunner = .live
    static let testValue: ProcessRunner = ProcessRunner(run: { _, _, _, _ in "" })
}
