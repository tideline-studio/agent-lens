import IPC

/// Correlates server-pushed `publishDiagnostics` notifications to per-(uri, version)
/// awaiters. The LSP has no diagnostics *request* — diagnostics arrive as pushes — so
/// this is the keyed demux that turns the push into an `await` for a specific file/version.
///
/// Each awaiter is a one-shot `CheckedContinuation` (not an `AsyncStream`): we deliver
/// exactly one batch then drop it. An awaiter is resolved by exactly one of:
///   - `publish`, when a notification satisfies its expected version, or
///   - `timeout`, when its deadline elapses (the caller owns the deadline; see
///     StdioLSPClient.waitForDiagnostics).
/// Either path removes the awaiter under actor isolation, which both guarantees a single
/// resume and reaps the entry — so abandoned/timed-out awaiters can't accumulate.
actor DiagnosticsWaiter {
    private struct Waiter {
        let id: UInt64
        let expectedVersion: Int
        let continuation: CheckedContinuation<DiagnosticBatch, Never>
    }

    private var waiters: [DocumentURI: [Waiter]] = [:]
    /// The cache exists only to win the race where a publish arrives before its waiter.
    /// It is bounded so a long-lived daemon that opens many files doesn't grow it without
    /// limit; evicting a cached batch is safe because pending awaiters live in `waiters`
    /// and are resolved by publish/timeout, never from the cache.
    private var cache: BoundedCache<DocumentURI, DiagnosticBatch>

    init(cacheCapacity: Int = 256) {
        self.cache = BoundedCache(capacity: cacheCapacity)
    }

    /// Removes a URI's cached batch so the next `wait` must wait for a fresh publish.
    /// Call this after sending didChange so stale nil-version batches aren't served.
    func invalidate(uri: DocumentURI) {
        cache.removeValue(forKey: uri)
    }

    /// Called when a `publishDiagnostics` notification arrives. Caches the batch and
    /// resolves every pending awaiter whose expected version it satisfies.
    func publish(uri: DocumentURI, batch: DiagnosticBatch) {
        cache.set(uri, batch)
        guard let pending = waiters[uri] else { return }
        var remaining: [Waiter] = []
        for waiter in pending {
            if satisfies(batch: batch, expectedVersion: waiter.expectedVersion) {
                waiter.continuation.resume(returning: batch)
            } else {
                remaining.append(waiter)
            }
        }
        waiters[uri] = remaining.isEmpty ? nil : remaining
    }

    /// Awaits the first batch for `uri` at or past `expectedVersion`. Returns a cached
    /// batch immediately if one already satisfies (the publish-before-wait race), else
    /// parks until `publish` or `timeout` resolves `id`.
    func wait(id: UInt64, uri: DocumentURI, expectedVersion: Int) async -> DiagnosticBatch {
        if let cached = cache[uri], satisfies(batch: cached, expectedVersion: expectedVersion) {
            return cached
        }
        return await withCheckedContinuation { continuation in
            waiters[uri, default: []].append(
                Waiter(id: id, expectedVersion: expectedVersion, continuation: continuation)
            )
        }
    }

    /// Resolves a still-pending awaiter as timed-out (arrived: false) and reaps it.
    /// No-op if the awaiter was already resolved by a publish. Returns the batch the
    /// caller should surface for a timeout.
    @discardableResult
    func timeout(id: UInt64, uri: DocumentURI) -> DiagnosticBatch {
        let timedOut = DiagnosticBatch(diagnostics: [], version: nil, arrived: false)
        guard var pending = waiters[uri],
              let index = pending.firstIndex(where: { $0.id == id }) else { return timedOut }
        let waiter = pending.remove(at: index)
        waiter.continuation.resume(returning: timedOut)
        waiters[uri] = pending.isEmpty ? nil : pending
        return timedOut
    }

    /// True if `uri` already has a cached diagnostics result and nothing is awaiting it —
    /// i.e. closing the document now wouldn't drop an in-flight or not-yet-produced result.
    /// Used by the client to pick safe eviction victims for its bounded open-document set.
    func isIdleResolved(uri: DocumentURI) -> Bool {
        cache[uri] != nil && (waiters[uri]?.isEmpty ?? true)
    }

    private func satisfies(batch: DiagnosticBatch, expectedVersion: Int) -> Bool {
        guard let batchVersion = batch.version else { return true }
        return batchVersion >= expectedVersion
    }
}
