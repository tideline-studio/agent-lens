import IPC
@testable import LSPClient
import XCTest

/// DiagnosticsWaiter is the keyed demux from pushed `publishDiagnostics` to per-(uri,
/// version) awaiters. These protect its contract: version correlation, the publish-before-
/// wait race, invalidation, and — the property that prevents a memory leak — that every
/// awaiter is resolved exactly once and reaped on timeout.
final class DiagnosticsWaiterTests: XCTestCase {

    private func batch(diagnostics: Int = 0, version: Int?, arrived: Bool = true) -> DiagnosticBatch {
        let diags = (0..<diagnostics).map { _ in
            Diagnostic(
                range: DiagnosticRange(start: Position(line: 0, character: 0),
                                       end: Position(line: 0, character: 1)),
                severity: .error, message: "x"
            )
        }
        return DiagnosticBatch(diagnostics: diags, version: version, arrived: arrived)
    }

    func testPublishSatisfyingVersionResolvesWait() async {
        let waiter = DiagnosticsWaiter()
        await waiter.publish(uri: "f", batch: batch(version: 1))   // cached before wait
        let result = await waiter.wait(id: 0, uri: "f", expectedVersion: 1)
        XCTAssertTrue(result.arrived)
        XCTAssertEqual(result.version, 1)
    }

    func testLowerVersionIsNotAcceptedButSatisfyingVersionIs() async {
        let waiter = DiagnosticsWaiter()
        await waiter.publish(uri: "f", batch: batch(version: 1))   // cached v1, below expectation
        let pending = Task { await waiter.wait(id: 0, uri: "f", expectedVersion: 2) }
        // Either order is safe: if the wait has parked, this resolves it; if not, it caches
        // v2 and the wait returns it. A v1 result would prove v1 was wrongly accepted.
        await waiter.publish(uri: "f", batch: batch(version: 2))
        let result = await pending.value
        XCTAssertEqual(result.version, 2, "must not accept a batch below the expected version")
    }

    func testNilVersionSatisfiesAnyExpectedVersion() async {
        let waiter = DiagnosticsWaiter()
        await waiter.publish(uri: "f", batch: batch(version: nil))
        let result = await waiter.wait(id: 0, uri: "f", expectedVersion: 99)
        XCTAssertTrue(result.arrived, "a nil-version batch is the whole-file set; it satisfies any version")
    }

    func testInvalidateDropsCachedBatchSoWaitAwaitsAFreshPublish() async {
        let waiter = DiagnosticsWaiter()
        await waiter.publish(uri: "f", batch: batch(diagnostics: 1, version: 1))  // stale set
        await waiter.invalidate(uri: "f")
        let pending = Task { await waiter.wait(id: 0, uri: "f", expectedVersion: 1) }
        await waiter.publish(uri: "f", batch: batch(diagnostics: 2, version: 1))  // fresh set
        let result = await pending.value
        XCTAssertEqual(result.diagnostics.count, 2, "must surface the post-invalidate batch, not the dropped one")
    }

    func testOnePublishResolvesAllWaitersForTheURI() async {
        let waiter = DiagnosticsWaiter()
        let a = Task { await waiter.wait(id: 0, uri: "f", expectedVersion: 1) }
        let b = Task { await waiter.wait(id: 1, uri: "f", expectedVersion: 1) }
        await waiter.publish(uri: "f", batch: batch(version: 1))
        let ra = await a.value
        let rb = await b.value
        XCTAssertTrue(ra.arrived)
        XCTAssertTrue(rb.arrived)
    }

    func testTimeoutOnAbsentWaiterIsSafeNoOp() async {
        let waiter = DiagnosticsWaiter()
        let result = await waiter.timeout(id: 42, uri: "never-waited")
        XCTAssertFalse(result.arrived)
    }

    func testTimeoutResolvesReapsAndPreventsDoubleResume() async {
        let waiter = DiagnosticsWaiter()

        // Resolve a parked waiter via timeout. The retry task keeps calling timeout until
        // the sibling has registered (no sleeps); the wait task completes first because the
        // retry task only returns once cancelled.
        let result = await withTaskGroup(of: DiagnosticBatch?.self) { group -> DiagnosticBatch? in
            group.addTask { await waiter.wait(id: 7, uri: "f", expectedVersion: 1) }
            group.addTask {
                while !Task.isCancelled {
                    _ = await waiter.timeout(id: 7, uri: "f")
                    await Task.yield()
                }
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        XCTAssertEqual(result?.arrived, false, "a timed-out waiter resolves as not-arrived")

        // The waiter must have been reaped: a later publish for the same uri must not
        // double-resume a continuation (which would trap), and must still cache normally.
        await waiter.publish(uri: "f", batch: batch(version: 1))
        let fresh = await waiter.wait(id: 8, uri: "f", expectedVersion: 1)
        XCTAssertTrue(fresh.arrived, "publish after timeout caches and serves a fresh waiter")
    }
}
