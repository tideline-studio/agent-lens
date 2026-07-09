import XCTest
import Foundation
import IPC
import Dependencies
import Clocks
@testable import DaemonCore

// MARK: - Helpers

private actor MockCore: CoreProtocol {
    func start() async throws {}
    func dispatch(_ request: Request) async -> ResponseResult { .ok(.ack) }
}

private func decoratorDispatch(decorator: IdleDecorator, command: Command) async -> ResponseResult {
    await decorator.dispatch(Request(command: command))
}

// MARK: - Tests

final class IdleDecoratorTests: XCTestCase {

    // MARK: - Stop

    func testStopCommandSignalsShutdown() async throws {
        let decorator = IdleDecorator(inner: MockCore(), logger: .init(label: "test"))
        async let _ = decoratorDispatch(decorator: decorator, command: .stop)
        var iter = decorator.shutdownStream.makeAsyncIterator()
        let reason = await iter.next()
        XCTAssertEqual(reason, .stop)
    }

    func testStopForwardsAckFromInner() async throws {
        let decorator = IdleDecorator(inner: MockCore(), logger: .init(label: "test"))
        let result = await decoratorDispatch(decorator: decorator, command: .stop)
        XCTAssertEqual(result, .ok(.ack))
    }

    // MARK: - Idle timer

    func testIdleTimerFiresAfterConfiguredTimeout() async throws {
        let testClock = TestClock()
        let decorator = withDependencies { $0.continuousClock = testClock } operation: {
            IdleDecorator(inner: MockCore(), logger: .init(label: "test"))
        }
        _ = await decoratorDispatch(decorator: decorator, command: .start(idleSeconds: 10, logLevel: .info))
        var iter = decorator.shutdownStream.makeAsyncIterator()
        await testClock.advance(by: .seconds(10))
        let reason = await iter.next()
        XCTAssertEqual(reason, .idle)
    }

    func testActivityResetsIdleTimer() async throws {
        let testClock = TestClock()
        let decorator = withDependencies { $0.continuousClock = testClock } operation: {
            IdleDecorator(inner: MockCore(), logger: .init(label: "test"))
        }
        _ = await decoratorDispatch(decorator: decorator, command: .start(idleSeconds: 10, logLevel: .info))

        // Advance 8s — still in the first sleep window
        await testClock.advance(by: .seconds(8))
        // Activity: generation changes; task still sleeping until T=10
        _ = await decoratorDispatch(decorator: decorator, command: .status)

        // Advance 2s more — completes the first sleep (total 10s). Task wakes, sees the
        // generation changed, sets lastAccess = clock.now (T=10), sleeps until T=20.
        await testClock.advance(by: .seconds(2))

        var iter = decorator.shutdownStream.makeAsyncIterator()
        // Advance 10s — completes the second sleep. No activity → shutdown.
        await testClock.advance(by: .seconds(10))
        let reason = await iter.next()
        XCTAssertEqual(reason, .idle)
    }

    func testIdleTimerDoesNotFireWithZeroTimeout() async throws {
        let testClock = TestClock()
        let decorator = withDependencies { $0.continuousClock = testClock } operation: {
            IdleDecorator(inner: MockCore(), logger: .init(label: "test"))
        }
        _ = await decoratorDispatch(decorator: decorator, command: .start(idleSeconds: 0, logLevel: .info))
        await testClock.advance(by: .seconds(9999))

        // Decorator must still be alive — stop it and verify via the shutdown signal
        async let _ = decoratorDispatch(decorator: decorator, command: .stop)
        var iter = decorator.shutdownStream.makeAsyncIterator()
        let reason = await iter.next()
        XCTAssertEqual(reason, .stop)
    }
}
