import Foundation

/// Trips after `maxCrashes` crashes within `windowSeconds`.
/// Mirrors VSCode's DefaultErrorHandler (5 crashes / 3 min).
public actor CircuitBreaker {
    private var crashTimes: [Date] = []
    public let maxCrashes: Int
    public let windowSeconds: TimeInterval

    public init(maxCrashes: Int = 5, windowSeconds: TimeInterval = 180) {
        self.maxCrashes = maxCrashes
        self.windowSeconds = windowSeconds
    }

    /// Records a crash at `time` and returns whether the breaker has tripped.
    @discardableResult
    public func recordCrash(at time: Date = Date()) -> Bool {
        let cutoff = time.addingTimeInterval(-windowSeconds)
        crashTimes = crashTimes.filter { $0 > cutoff }
        crashTimes.append(time)
        return crashTimes.count >= maxCrashes
    }

    public func isTripped(at time: Date = Date()) -> Bool {
        let cutoff = time.addingTimeInterval(-windowSeconds)
        return crashTimes.filter({ $0 > cutoff }).count >= maxCrashes
    }
}
