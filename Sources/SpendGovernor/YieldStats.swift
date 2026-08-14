import Foundation

/// Per-class evidence that survives the period boundary.
///
/// Deliberate design decision: money resets when the month rolls over, evidence
/// does not. A class does not become a mystery again on the first of the month.
public struct ClassStats: Hashable, Sendable {
    public private(set) var settledSpend: Micros
    public private(set) var acceptedCount: Int
    public private(set) var discardedCount: Int
    /// Sum of (actual / held) over settlements, used for estimate calibration.
    public private(set) var estimateErrorSum: Double
    public private(set) var estimateErrorSamples: Int

    public init() {
        self.settledSpend = .zero
        self.acceptedCount = 0
        self.discardedCount = 0
        self.estimateErrorSum = 0
        self.estimateErrorSamples = 0
    }

    public var settledCount: Int { acceptedCount + discardedCount }

    public mutating func record(actual: Micros, held: Micros, outcome: Outcome) {
        settledSpend = settledSpend + actual
        switch outcome {
        case .accepted: acceptedCount += 1
        case .discarded: discardedCount += 1
        }
        if let ratio = actual.ratio(to: held), ratio.isFinite, ratio > 0 {
            estimateErrorSum += ratio
            estimateErrorSamples += 1
        }
    }

    /// Mean observed actual-over-estimate ratio, or `nil` below the sample floor.
    public func calibrationFactor(minimumSamples: Int) -> Double? {
        guard estimateErrorSamples >= max(1, minimumSamples) else { return nil }
        return estimateErrorSum / Double(estimateErrorSamples)
    }

    /// Spend per accepted outcome, smoothed by the class prior.
    ///
    /// This is the number the ranking is built on. Note what it does *not* do:
    /// it never divides by zero and it never lets a class with two lucky
    /// outcomes outrank a class with two hundred, because the prior only washes
    /// out once real evidence exceeds its pseudo-count.
    public func costPerAcceptedOutcome(prior: AcceptancePrior) -> Double {
        let numerator = Double(settledSpend.raw + prior.pseudoSpend.raw)
        let denominator = Double(acceptedCount) + prior.pseudoAccepted
        guard denominator > 0 else { return .greatestFiniteMagnitude }
        return numerator / denominator
    }
}
