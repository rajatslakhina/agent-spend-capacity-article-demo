import Foundation

/// A spending window with a hard ceiling.
public struct BudgetPeriod: Hashable, Sendable {
    public let start: Date
    public let duration: TimeInterval
    public let ceiling: Micros

    public init(start: Date, duration: TimeInterval, ceiling: Micros) {
        self.start = start
        self.duration = max(1, duration)
        self.ceiling = ceiling
    }

    public var end: Date { start.addingTimeInterval(duration) }

    /// How far through the period we are, clamped to `0...1`.
    public func elapsedFraction(at now: Date) -> Double {
        let elapsed = now.timeIntervalSince(start)
        guard elapsed.isFinite else { return 0 }
        return min(1, max(0, elapsed / duration))
    }

    /// Straight-line spend allowance at `now`. The pace line.
    public func pacedAllowance(at now: Date) -> Micros {
        ceiling.scaled(by: elapsedFraction(at: now))
    }
}
