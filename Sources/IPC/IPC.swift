import Foundation

// MARK: - Protocol version

public let protocolVersion: Int = 1

// MARK: - Wire types

public struct Request: Codable, Sendable, Equatable {
    public let v: Int
    public let id: String
    public let command: Command

    public init(id: String = UUID().uuidString, command: Command) {
        self.v = protocolVersion
        self.id = id
        self.command = command
    }
}

public struct Response: Codable, Sendable, Equatable {
    public let v: Int
    public let id: String
    public let result: ResponseResult

    public init(id: String, result: ResponseResult) {
        self.v = protocolVersion
        self.id = id
        self.result = result
    }
}

// MARK: - Command

public enum Command: Sendable, Equatable {
    /// idleSeconds: daemon auto-exits after this many seconds without a request.
    case start(idleSeconds: Double, logLevel: LogLevel)
    case stop
    case status
    /// Diagnoses exactly `files` — the daemon does not expand, filter, or prioritize.
    case diagnose(files: [String], timeoutSeconds: Double)
    case lint(files: [String])
    /// Runs diagnose and lint in one round-trip. Same params as diagnose; lint uses `files`.
    case check(files: [String], timeoutSeconds: Double)
}

extension Command: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, idle, logLevel, files, timeout
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "start":
            self = .start(
                idleSeconds: try c.decode(Double.self,   forKey: .idle),
                logLevel:    try c.decode(LogLevel.self, forKey: .logLevel)
            )
        case "stop":   self = .stop
        case "status": self = .status
        case "diagnose":
            self = .diagnose(
                files:          try c.decode([String].self, forKey: .files),
                timeoutSeconds: try c.decode(Double.self,   forKey: .timeout)
            )
        case "lint":
            self = .lint(files: try c.decode([String].self, forKey: .files))
        case "check":
            self = .check(
                files:          try c.decode([String].self, forKey: .files),
                timeoutSeconds: try c.decode(Double.self,   forKey: .timeout)
            )
        case let t:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: c,
                debugDescription: "Unknown command: \(t)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .start(let idle, let level):
            try c.encode("start",    forKey: .type)
            try c.encode(idle,       forKey: .idle)
            try c.encode(level,      forKey: .logLevel)
        case .stop:
            try c.encode("stop", forKey: .type)
        case .status:
            try c.encode("status", forKey: .type)
        case .diagnose(let files, let timeout):
            try c.encode("diagnose", forKey: .type)
            try c.encode(files,      forKey: .files)
            try c.encode(timeout,    forKey: .timeout)
        case .lint(let files):
            try c.encode("lint",  forKey: .type)
            try c.encode(files,   forKey: .files)
        case .check(let files, let timeout):
            try c.encode("check",  forKey: .type)
            try c.encode(files,    forKey: .files)
            try c.encode(timeout,  forKey: .timeout)
        }
    }
}

// MARK: - ResponseResult

public enum ResponseResult: Sendable, Equatable {
    case ok(Payload)
    case err(ErrorPayload)
}

extension ResponseResult: Codable {
    private enum CodingKeys: String, CodingKey { case ok, err }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let payload = try c.decodeIfPresent(Payload.self, forKey: .ok) {
            self = .ok(payload)
        } else {
            self = .err(try c.decode(ErrorPayload.self, forKey: .err))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .ok(let p):  try c.encode(p, forKey: .ok)
        case .err(let e): try c.encode(e, forKey: .err)
        }
    }
}

// MARK: - Payload

public enum Payload: Sendable, Equatable {
    case ack
    case status(StatusReport)
    case diagnose([String: FileDiagnostics])
    case lint([String: String])
    /// Combined result keyed by file. The two maps are kept separate by design:
    /// diagnose is structured (LSP) and may be capped/reordered; lint is raw stdout.
    /// Their key sets can differ, so we don't force a per-file join.
    case check(diagnostics: [String: FileDiagnostics], lint: [String: String])
}

extension Payload: Codable {
    private enum CodingKeys: String, CodingKey { case type, report, files, diagnostics, lint }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "ack":
            self = .ack
        case "status":
            self = .status(try c.decode(StatusReport.self, forKey: .report))
        case "diagnose":
            self = .diagnose(try c.decode([String: FileDiagnostics].self, forKey: .files))
        case "lint":
            self = .lint(try c.decode([String: String].self, forKey: .files))
        case "check":
            self = .check(
                diagnostics: try c.decode([String: FileDiagnostics].self, forKey: .diagnostics),
                lint:        try c.decode([String: String].self,          forKey: .lint)
            )
        case let t:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: c,
                debugDescription: "Unknown payload: \(t)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .ack:
            try c.encode("ack", forKey: .type)
        case .status(let r):
            try c.encode("status", forKey: .type)
            try c.encode(r,        forKey: .report)
        case .diagnose(let files):
            try c.encode("diagnose", forKey: .type)
            try c.encode(files,      forKey: .files)
        case .lint(let files):
            try c.encode("lint",  forKey: .type)
            try c.encode(files,   forKey: .files)
        case .check(let diagnostics, let lint):
            try c.encode("check",      forKey: .type)
            try c.encode(diagnostics,  forKey: .diagnostics)
            try c.encode(lint,         forKey: .lint)
        }
    }
}

// MARK: - Supporting types

public enum LogLevel: String, Codable, Sendable, Equatable, CaseIterable {
    case debug, info, warn, error
}

public enum ReadinessState: String, Codable, Sendable, Equatable {
    case initial, starting, startFailed, indexing, ready, stopping, stopped, failed
    /// The file's extension maps to no supported language — it can't be diagnosed.
    case unsupported
}

public struct StatusReport: Codable, Sendable, Equatable {
    public let servers: [ServerStatus]
    public let uptimeSeconds: Double

    public init(servers: [ServerStatus], uptimeSeconds: Double) {
        self.servers = servers
        self.uptimeSeconds = uptimeSeconds
    }
}

public struct ServerStatus: Codable, Sendable, Equatable {
    public let language: String
    public let readinessState: ReadinessState

    public init(language: String, readinessState: ReadinessState) {
        self.language = language
        self.readinessState = readinessState
    }
}

public struct FileDiagnostics: Codable, Sendable, Equatable {
    public let diagnostics: [Diagnostic]
    public let readinessState: ReadinessState
    public let stale: Bool
    public let lspVersion: Int?

    public init(
        diagnostics: [Diagnostic],
        readinessState: ReadinessState,
        stale: Bool,
        lspVersion: Int? = nil
    ) {
        self.diagnostics = diagnostics
        self.readinessState = readinessState
        self.stale = stale
        self.lspVersion = lspVersion
    }
}

public struct Diagnostic: Codable, Sendable, Equatable {
    public let range: DiagnosticRange
    public let severity: DiagnosticSeverity?
    public let message: String
    public let code: String?

    public init(
        range: DiagnosticRange,
        severity: DiagnosticSeverity?,
        message: String,
        code: String? = nil
    ) {
        self.range = range
        self.severity = severity
        self.message = message
        self.code = code
    }
}

public struct DiagnosticRange: Codable, Sendable, Equatable {
    public let start: Position
    public let end: Position

    public init(start: Position, end: Position) {
        self.start = start
        self.end = end
    }
}

public struct Position: Codable, Sendable, Equatable {
    public let line: Int
    public let character: Int

    public init(line: Int, character: Int) {
        self.line = line
        self.character = character
    }
}

public enum DiagnosticSeverity: Int, Codable, Sendable, Equatable {
    case error = 1, warning = 2, information = 3, hint = 4
}


public struct ErrorPayload: Codable, Sendable, Equatable {
    public let code: ErrorCode
    public let message: String

    public init(code: ErrorCode, message: String) {
        self.code = code
        self.message = message
    }
}

public enum ErrorCode: String, Codable, Sendable, Equatable {
    case noDaemon, noServer, serverNotReady
    case fileNotFound, pathOutsideRoot, pathIsDirectory
    case lspError, timeout, versionMismatch, internalError
}
