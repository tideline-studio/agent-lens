import Foundation
import JSONRPC

/// In-process stand-in for an LSP server, driven over a `DataChannel.withDataActor()`
/// pair. Messages cross the pair as whole JSON-RPC payloads (no Content-Length framing —
/// that lives only in the real stdio adapter), so the mock speaks raw JSON via
/// `JSONSerialization`: no LanguageServerProtocol/JSONRPC model types needed in tests.
///
/// It auto-answers `initialize`/`shutdown` (and any other request, with null) so the
/// client's request/response calls complete; tests push notifications and server→client
/// requests explicitly to exercise diagnostics, progress, messages, and registration.
final class MockLSPServer: @unchecked Sendable {
    private let channel: DataChannel
    private var drainTask: Task<Void, Never>?
    private let recorder = Recorder()

    /// Records the document-sync notifications tests assert on.
    private actor Recorder {
        private(set) var closedURIs: [String] = []
        private(set) var openedURIs: [String] = []
        private(set) var changedURIs: [String] = []
        private(set) var pullModeEnabled = false
        // Stored as JSON-encoded Data so the value crosses actor boundaries safely.
        private(set) var scriptedPullData: [String: Data] = [:]

        func recordClose(_ uri: String) { closedURIs.append(uri) }
        func recordOpen(_ uri: String) { openedURIs.append(uri) }
        func recordChange(_ uri: String) { changedURIs.append(uri) }
        func closes() -> [String] { closedURIs }
        func opens() -> [String] { openedURIs }
        func changes() -> [String] { changedURIs }
        func enablePullMode() { pullModeEnabled = true }
        func scriptPull(uri: String, data: Data) { scriptedPullData[uri] = data }
        func isPullMode() -> Bool { pullModeEnabled }
        func pullData(for uri: String) -> Data? { scriptedPullData[uri] }
    }

    init(channel: DataChannel) {
        self.channel = channel
        let channel = self.channel
        drainTask = Task { [weak self] in
            for await data in channel.dataSequence {
                await self?.handleInbound(data)
            }
        }
    }

    func stop() { drainTask?.cancel() }

    /// URIs the client has sent `textDocument/didClose` / didOpen / didChange for.
    func closedURIs() async -> [String] { await recorder.closes() }
    func openedURIs() async -> [String] { await recorder.opens() }
    func changedURIs() async -> [String] { await recorder.changes() }

    /// Make initialize return `diagnosticProvider` so the client switches to PullStrategy.
    /// Must be called before `client.initialize`.
    func enablePullMode() async { await recorder.enablePullMode() }

    /// Script the diagnostics the mock returns for the next `textDocument/diagnostic` request.
    func scriptPullDiagnostics(uri: String, diagnostics: [[String: Any]]) async {
        guard let data = try? JSONSerialization.data(withJSONObject: diagnostics) else { return }
        await recorder.scriptPull(uri: uri, data: data)
    }

    // MARK: - Inbound (client → server)

    private func handleInbound(_ data: Data) async {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let method = obj["method"] as? String

        // Record document-sync notifications so the open/change/no-op decision is observable.
        if let method,
           let params = obj["params"] as? [String: Any],
           let doc = params["textDocument"] as? [String: Any],
           let uri = doc["uri"] as? String {
            switch method {
            case "textDocument/didOpen":   await recorder.recordOpen(uri)
            case "textDocument/didChange": await recorder.recordChange(uri)
            case "textDocument/didClose":  await recorder.recordClose(uri)
            default: break
            }
        }

        // Reply only to requests (id + method). Notifications (no id) and the client's
        // replies to our server→client requests (id but no method) are accepted silently.
        guard let id = obj["id"], let method else { return }
        let isPull = await recorder.isPullMode()
        let result: Any
        if method == "initialize" {
            var caps: [String: Any] = [:]
            if isPull {
                caps["diagnosticProvider"] = ["interFileDependencies": false, "workspaceDiagnostics": false]
            }
            result = ["capabilities": caps]
        } else if method == "textDocument/diagnostic",
                  let params = obj["params"] as? [String: Any],
                  let doc = params["textDocument"] as? [String: Any],
                  let uri = doc["uri"] as? String {
            let raw = await recorder.pullData(for: uri)
            let diags = raw.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] } ?? []
            result = ["kind": "full", "items": diags]
        } else {
            result = NSNull()
        }
        await send(["jsonrpc": "2.0", "id": id, "result": result])
    }

    // MARK: - Outbound (server → client) — the test's script

    func publishDiagnostics(uri: String, version: Int?, diagnostics: [[String: Any]]) async {
        var params: [String: Any] = ["uri": uri, "diagnostics": diagnostics]
        if let version { params["version"] = version }
        await notify("textDocument/publishDiagnostics", params)
    }

    func progress(token: String, kind: String) async {
        await notify("$/progress", ["token": token, "value": ["kind": kind]])
    }

    func showMessage(type: Int, message: String) async {
        await notify("window/showMessage", ["type": type, "message": message])
    }

    /// Server→client `client/registerCapability` request for watched files. The client
    /// replies (ignored) and surfaces a `.registerWatchedFiles` server event.
    func registerWatchedFiles(registrationID: String, requestID: Int, globs: [String]) async {
        let registration: [String: Any] = [
            "id": registrationID,
            "method": "workspace/didChangeWatchedFiles",
            "registerOptions": ["watchers": globs.map { ["globPattern": $0] }],
        ]
        await send([
            "jsonrpc": "2.0", "id": requestID, "method": "client/registerCapability",
            "params": ["registrations": [registration]],
        ])
    }

    private func notify(_ method: String, _ params: [String: Any]) async {
        await send(["jsonrpc": "2.0", "method": method, "params": params])
    }

    private func send(_ object: [String: Any]) async {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        try? await channel.writeHandler(data)
    }
}

/// A minimal LSP `Diagnostic` JSON object for `publishDiagnostics`.
func mockDiagnostic(line: Int, message: String, severity: Int = 1) -> [String: Any] {
    [
        "range": [
            "start": ["line": line, "character": 0],
            "end": ["line": line, "character": 1],
        ],
        "severity": severity,
        "message": message,
    ]
}
