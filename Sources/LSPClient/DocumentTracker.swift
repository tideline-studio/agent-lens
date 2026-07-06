import IPC

// Encapsulates per-document open/version state for the LSP client.
// All mutations are synchronous (no async) so callers can safely mutate
// between await points inside actor-isolated methods.
struct DocumentTracker {
    private struct DocState {
        var mtimeNs: UInt64
        var size: UInt64
        var version: Int
    }

    enum SyncDecision {
        case open(languageId: String, text: String)
        case change(text: String)
        case noOp
    }

    private var documents: [DocumentURI: DocState] = [:]
    private(set) var openRecency: [DocumentURI] = []
    private var versionCounter = 0
    let maxOpenDocuments: Int

    init(maxOpenDocuments: Int) {
        self.maxOpenDocuments = max(1, maxOpenDocuments)
    }

    mutating func sync(_ input: DocumentInput) -> (decision: SyncDecision, version: Int) {
        if let existing = documents[input.uri] {
            guard existing.mtimeNs != input.mtimeNs || existing.size != input.size else {
                return (.noOp, existing.version)
            }
            let v = bump()
            documents[input.uri] = DocState(mtimeNs: input.mtimeNs, size: input.size, version: v)
            noteUsed(input.uri)
            return (.change(text: input.text), v)
        } else {
            let v = bump()
            documents[input.uri] = DocState(mtimeNs: input.mtimeNs, size: input.size, version: v)
            noteUsed(input.uri)
            return (.open(languageId: input.languageId, text: input.text), v)
        }
    }

    mutating func noteUsed(_ uri: DocumentURI) {
        openRecency.removeAll { $0 == uri }
        openRecency.append(uri)
    }

    mutating func forget(_ uri: DocumentURI) {
        openRecency.removeAll { $0 == uri }
        documents[uri] = nil
    }

    func isOpen(_ uri: DocumentURI) -> Bool { openRecency.contains(uri) }

    var isOverBound: Bool { openRecency.count > maxOpenDocuments }

    private mutating func bump() -> Int {
        versionCounter += 1
        return versionCounter
    }
}
