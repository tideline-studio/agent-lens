import Foundation
import IPC

// MARK: - LSP aliases

public typealias DocumentURI = String
public typealias ServerID = String
public typealias GlobPattern = String

// MARK: - Protocol-level types

public struct WatchedFileEvent: Sendable {
    public enum Kind: Sendable { case created, changed, deleted }
    public let uri: DocumentURI
    public let kind: Kind

    public init(uri: DocumentURI, kind: Kind) {
        self.uri = uri
        self.kind = kind
    }
}

public enum MessageLevel: Sendable { case error, warning, info, log }
public enum ProgressKind: String, Sendable { case begin, report, end }

public struct DiagnosticBatch: Sendable {
    public let diagnostics: [Diagnostic]
    public let version: Int?
    /// `false` when the deadline elapsed and this is a cached (possibly empty) fallback.
    public let arrived: Bool

    public init(diagnostics: [Diagnostic], version: Int?, arrived: Bool) {
        self.diagnostics = diagnostics
        self.version = version
        self.arrived = arrived
    }
}

public enum ServerEvent: Sendable {
    case registerWatchedFiles(id: String, globs: [GlobPattern])
    case unregisterWatchedFiles(id: String)
    case showMessage(level: MessageLevel, text: String)
    case progress(token: String, kind: ProgressKind)
}

// MARK: - LSPClient protocol

public protocol LSPClient: Actor {
    var serverID: ServerID { get }
    var readinessState: ReadinessState { get }

    func initialize(rootURI: DocumentURI) async throws
    func shutdown() async

    /// Diagnoses a batch of documents. The client owns the open-document lifecycle: it
    /// opens unseen documents, sends didChange for changed ones (by mtime/size), no-ops
    /// unchanged ones, allocates versions, bounds its open set, and waits up to `timeout`
    /// for each document's diagnostics. Returns one batch per input URI (stale when the
    /// deadline elapses).
    func diagnose(_ documents: [DocumentInput], timeout: Duration) async -> [DocumentURI: DiagnosticBatch]

    func didChangeWatchedFiles(_ events: [WatchedFileEvent]) async throws

    /// Whether the client currently holds `uri` open in the server. Used by the FSEvents
    /// pipeline to suppress redundant didChangeWatchedFiles for files diagnose already syncs.
    func isOpen(_ uri: DocumentURI) async -> Bool

    var serverEvents: AsyncStream<ServerEvent> { get }
}

/// One document to diagnose. `mtimeNs`/`size` are the change signal the client compares
/// against what it last sent, to choose didOpen vs didChange vs no-op — the client never
/// touches disk itself.
public struct DocumentInput: Sendable {
    public let uri: DocumentURI
    public let languageId: String
    public let text: String
    public let mtimeNs: UInt64
    public let size: UInt64

    public init(uri: DocumentURI, languageId: String, text: String, mtimeNs: UInt64, size: UInt64) {
        self.uri = uri
        self.languageId = languageId
        self.text = text
        self.mtimeNs = mtimeNs
        self.size = size
    }
}

// MARK: - Server config (used by StdioLSPClient factory and LSPServerDetection)

public struct ServerConfig: Sendable {
    public let serverID: ServerID
    public let language: Language
    public let executable: String
    public let args: [String]
    public let env: [String: String]
    public let initializationOptions: JSONValue?

    public init(
        serverID: ServerID,
        language: Language,
        executable: String,
        args: [String] = [],
        env: [String: String] = [:],
        initializationOptions: JSONValue? = nil
    ) {
        self.serverID = serverID
        self.language = language
        self.executable = executable
        self.args = args
        self.env = env
        self.initializationOptions = initializationOptions
    }
}
