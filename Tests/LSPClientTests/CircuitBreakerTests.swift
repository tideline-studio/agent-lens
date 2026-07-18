import LSPClient
import XCTest

final class CircuitBreakerTests: XCTestCase {

    func testFiresAfterFiveCrashesInWindow() async throws {
        let cb = CircuitBreaker(maxCrashes: 5, windowSeconds: 180)
        let anchor = Date(timeIntervalSinceReferenceDate: 1_000_000)

        for i in 0..<4 {
            let tripped = await cb.recordCrash(at: anchor.addingTimeInterval(Double(i) * 30))
            XCTAssertFalse(tripped, "should not trip on crash \(i + 1)")
        }
        // 5th crash at t=120s — still within 180s window
        let tripped = await cb.recordCrash(at: anchor.addingTimeInterval(120))
        XCTAssertTrue(tripped, "should trip on the 5th crash within window")
        let isTripped = await cb.isTripped(at: anchor.addingTimeInterval(120))
        XCTAssertTrue(isTripped)
    }

    func testDoesNotFireForSpreadOutCrashes() async throws {
        let cb = CircuitBreaker(maxCrashes: 5, windowSeconds: 180)
        let anchor = Date(timeIntervalSinceReferenceDate: 1_000_000)

        // Crashes at 0, 60, 120, 181, 191 seconds.
        // At t=181 the first crash (t=0) falls outside the 180s window.
        // At t=191: window is [11, 191], so only crashes at 60, 120, 181, 191 remain — 4 < 5.
        let offsets: [Double] = [0, 60, 120, 181, 191]
        for offset in offsets {
            _ = await cb.recordCrash(at: anchor.addingTimeInterval(offset))
        }
        let notTripped = await cb.isTripped(at: anchor.addingTimeInterval(191))
        XCTAssertFalse(notTripped)
    }

    func testResetAfterWindowExpires() async throws {
        let cb = CircuitBreaker(maxCrashes: 5, windowSeconds: 180)
        let anchor = Date(timeIntervalSinceReferenceDate: 1_000_000)

        // Trip the breaker
        for i in 0..<5 {
            _ = await cb.recordCrash(at: anchor.addingTimeInterval(Double(i)))
        }
        let trippedAt4 = await cb.isTripped(at: anchor.addingTimeInterval(4))
        XCTAssertTrue(trippedAt4)

        // 200 seconds later all crashes have expired
        let resetAt200 = await cb.isTripped(at: anchor.addingTimeInterval(200))
        XCTAssertFalse(resetAt200)
    }
}
