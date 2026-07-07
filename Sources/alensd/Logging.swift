import Foundation
import IPC
import Logging
import os

/// Builds the daemon's logger.
///
/// With an explicit `logFile`, appends plain-text lines to that path. Otherwise
/// logs to the unified system log via os_log — viewable in Console.app or with
/// `log stream --predicate 'subsystem == "\(logSubsystem)"'`. os_log is the
/// default because the daemon has no controlling terminal; the system log gives
/// durable, queryable output without us inventing a log-file location or rotation.
func makeLogger(logFile: String?) -> Logging.Logger {
    if let logFile {
        bootstrapFileLogging(path: logFile)
    } else {
        LoggingSystem.bootstrap { OSLogHandler(label: $0) }
    }
    return Logging.Logger(label: "alensd")
}

let logSubsystem = "com.agent-lens.daemon"

private func bootstrapFileLogging(path: String) {
    FileManager.default.createFile(atPath: path, contents: nil)
    let handle = FileHandle(forWritingAtPath: path) ?? FileHandle.standardError
    handle.seekToEndOfFile()
    LoggingSystem.bootstrap { FileLogHandler(label: $0, fileHandle: handle) }
}

// MARK: - os_log handler

private struct OSLogHandler: LogHandler {
    private let osLogger: os.Logger
    var metadata: Logging.Logger.Metadata = [:]
    var logLevel: Logging.Logger.Level = .info

    init(label: String) {
        osLogger = os.Logger(subsystem: logSubsystem, category: label)
    }

    subscript(metadataKey key: String) -> Logging.Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(
        level: Logging.Logger.Level,
        message: Logging.Logger.Message,
        metadata: Logging.Logger.Metadata?,
        source: String,
        file: String,
        function: String,
        line: UInt
    ) {
        // Daemon logs are developer diagnostics (paths, server status), not user
        // PII — mark public so they aren't redacted to <private> in the system log.
        osLogger.log(level: Self.osType(level), "\(message.description, privacy: .public)")
    }

    private static func osType(_ level: Logging.Logger.Level) -> OSLogType {
        switch level {
        case .trace, .debug:    return .debug
        case .info, .notice:    return .info
        case .warning:          return .default
        case .error:            return .error
        case .critical:         return .fault
        }
    }
}

// MARK: - File handler

private struct FileLogHandler: LogHandler {
    let label: String
    let fileHandle: FileHandle
    var metadata: Logging.Logger.Metadata = [:]
    var logLevel: Logging.Logger.Level = .info

    subscript(metadataKey key: String) -> Logging.Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(
        level: Logging.Logger.Level,
        message: Logging.Logger.Message,
        metadata: Logging.Logger.Metadata?,
        source: String,
        file: String,
        function: String,
        line: UInt
    ) {
        let ts = ISO8601DateFormatter().string(from: Date())
        let entry = "\(ts) [\(level)] \(message)\n"
        if let data = entry.data(using: .utf8) {
            fileHandle.write(data)
        }
    }
}

// MARK: - Helpers shared with alens

/// Resolves `dir` (or CWD) to an absolute, standardized URL.
func resolveRoot(_ dir: String?) -> URL {
    let raw = dir ?? FileManager.default.currentDirectoryPath
    return URL(fileURLWithPath: raw, isDirectory: true).standardizedFileURL
}
