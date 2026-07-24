import Foundation
import IPC
import LSPClient

/// Groups files by language, routes each group to its LSP client, and turns the
/// client's response into per-file `FileDiagnostics`. `router` and `fileSystem` are
/// fixed at construction — `DaemonCore` constructs one per call, only once its
/// `ServerRouter` exists (nil before `start()` runs).
struct DiagnosticsService: Sendable {
    private let router: ServerRouter
    private let fileSystem: FileSystem

    init(router: ServerRouter, fileSystem: FileSystem) {
        self.router = router
        self.fileSystem = fileSystem
    }

    func diagnose(
        files: [String],
        timeoutSeconds: Double
    ) async -> [String: FileDiagnostics] {
        // Diagnose exactly the files the caller passed — no expansion, ordering, or cap.
        // Group by language. Files whose extension maps to no language aren't
        // diagnosable at all — report them as unsupported (not stale, which implies
        // a result might still arrive).
        var groups: [Language: [String]] = [:]
        var results: [String: FileDiagnostics] = [:]
        for path in files {
            if let lang = Language.from(path: path) {
                groups[lang, default: []].append(path)
            } else {
                results[path] = FileDiagnostics(
                    diagnostics: [],
                    readinessState: .unsupported,
                    stale: false
                )
            }
        }

        let timeout = Duration.seconds(timeoutSeconds)

        let grouped = await withTaskGroup(of: [String: FileDiagnostics].self) { tg in
            for (_, paths) in groups {
                guard let client = await router.lspClient(for: paths[0]) else {
                    // No LSP client for this (supported) language — return stale so
                    // callers know "no server" rather than getting a silent omission.
                    tg.addTask {
                        Dictionary(
                            uniqueKeysWithValues: paths.map { path in
                                (
                                    path,
                                    FileDiagnostics(
                                        diagnostics: [], readinessState: .initial, stale: true)
                                )
                            })
                    }
                    continue
                }
                tg.addTask {
                    await diagnoseGroup(client: client, paths: paths, timeout: timeout)
                }
            }
            var combined: [String: FileDiagnostics] = [:]
            for await partial in tg { combined.merge(partial) { _, new in new } }
            return combined
        }
        results.merge(grouped) { _, new in new }
        return results
    }

    private func diagnoseGroup(
        client: any LSPClient,
        paths: [String],
        timeout: Duration
    ) async -> [String: FileDiagnostics] {
        // Read each file into a DocumentInput; the client owns the open/change/version
        // decision. Files that can't be stat'd are reported stale (we never saw them).
        var inputs: [DocumentInput] = []
        var uriToPath: [String: String] = [:]
        var result: [String: FileDiagnostics] = [:]
        for path in paths {
            guard let stat = try? fileSystem.stat(path) else {
                result[path] = FileDiagnostics(diagnostics: [], readinessState: .ready, stale: true)
                continue
            }
            let uri = "file://\(path)"
            let text =
                (try? fileSystem.contents(path)).map { String(data: $0, encoding: .utf8) ?? "" }
                ?? ""
            inputs.append(
                DocumentInput(
                    uri: uri, languageId: languageID(for: path), text: text,
                    mtimeNs: stat.mtimeNs, size: stat.size
                ))
            uriToPath[uri] = path
        }

        let batches = await client.diagnose(inputs, timeout: timeout)
        let readiness = await client.readinessState
        for (uri, batch) in batches {
            guard let path = uriToPath[uri] else { continue }
            result[path] = FileDiagnostics(
                diagnostics: batch.diagnostics,
                readinessState: readiness,
                stale: !batch.arrived
            )
        }
        return result
    }

    private func languageID(for path: String) -> String {
        // The LSP languageId matches the Language raw value for every supported case.
        Language.from(path: path)?.rawValue ?? "plaintext"
    }
}
