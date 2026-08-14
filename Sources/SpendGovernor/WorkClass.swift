import Foundation

/// A category of agent work that shares a budget policy.
///
/// The class — not the individual request — is the unit the governor reasons
/// about, because a single request carries almost no signal and a class
/// accumulates one within a day of real traffic.
public struct WorkClass: Hashable, Sendable, Identifiable {
    public let id: String
    /// Higher wins. Compared against `CapacityPolicy.Configuration.reservePriorityFloor`
    /// to decide who may spend into the reserve.
    public let priority: Int
    /// Seeds the yield estimate before the class has any settled history, so a
    /// class with one lucky outcome cannot jump to the front of the ranking.
    public let prior: AcceptancePrior

    public init(id: String, priority: Int, prior: AcceptancePrior) {
        self.id = id
        self.priority = priority
        self.prior = prior
    }
}

/// A Beta-style pseudo-count prior over "spend per accepted outcome".
///
/// `pseudoSpend / pseudoAccepted` is the cost-per-accepted-outcome the class is
/// assumed to have before any evidence arrives. `pseudoAccepted` is the strength
/// of that assumption measured in outcomes.
public struct AcceptancePrior: Hashable, Sendable {
    public let pseudoSpend: Micros
    public let pseudoAccepted: Double

    public init(pseudoSpend: Micros, pseudoAccepted: Double) {
        self.pseudoSpend = pseudoSpend
        self.pseudoAccepted = max(0.0001, pseudoAccepted)
    }

    /// A neutral prior: one imagined accepted outcome at `costPerOutcome`.
    public static func neutral(costPerOutcome: Micros) -> AcceptancePrior {
        AcceptancePrior(pseudoSpend: costPerOutcome, pseudoAccepted: 1)
    }
}
