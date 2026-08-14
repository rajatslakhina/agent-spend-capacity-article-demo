import Foundation

/// A request for permission to spend, made *before* the agent runs.
public struct WorkRequest: Hashable, Sendable, Identifiable {
    public let id: String
    public let workClassID: String
    /// What the caller thinks this will cost. Deliberately untrusted — the
    /// governor recalibrates it against what that class has actually cost.
    public let estimate: Micros

    public init(id: String, workClassID: String, estimate: Micros) {
        self.id = id
        self.workClassID = workClassID
        self.estimate = estimate
    }
}

/// An admitted request, holding budget until it settles.
public struct Reservation: Hashable, Sendable, Identifiable {
    public let id: String
    public let workClassID: String
    /// The calibrated figure that was actually held — not the caller's estimate.
    public let held: Micros
    public let openedAt: Date

    public init(id: String, workClassID: String, held: Micros, openedAt: Date) {
        self.id = id
        self.workClassID = workClassID
        self.held = held
        self.openedAt = openedAt
    }
}

/// What the spend bought. The whole point of the library is that this, not the
/// token count, is the denominator.
public enum Outcome: String, Hashable, Sendable, CaseIterable {
    /// The change was accepted — merged, shipped, kept.
    case accepted
    /// Money was spent and nothing was kept.
    case discarded
}

public enum DenialReason: String, Hashable, Sendable {
    case invalidEstimate
    /// Not enough budget left in the pool this class may draw from.
    case insufficientBudget
    /// An access-restriction policy tripped its threshold and stopped everything.
    case accessRestricted
    case unknownWorkClass
}

public enum AdmissionDecision: Hashable, Sendable {
    case admit(Reservation)
    /// Budget exists but pace says not now. Callers retry after the interval.
    case deferred(retryAfter: TimeInterval, reason: DeferralReason)
    case deny(DenialReason)

    public var isAdmitted: Bool {
        if case .admit = self { return true }
        return false
    }

    public var reservation: Reservation? {
        if case .admit(let r) = self { return r }
        return nil
    }
}

public enum DeferralReason: String, Hashable, Sendable {
    /// Spend is ahead of the pace line and this class is not in the protected set.
    case overPaceLowYield
}

public enum GovernorError: Error, Hashable, Sendable {
    case duplicateReservation(String)
    case unknownReservation(String)
    case unknownWorkClass(String)
}
