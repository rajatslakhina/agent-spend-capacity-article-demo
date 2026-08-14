import Foundation

/// The actor shell. Owns the snapshot, applies a policy, records settlements.
///
/// Everything interesting lives in `GovernorState` and the policy. This type
/// exists to serialise mutation, which is what stops two concurrent agent runs
/// from both being told there is room for one more.
public actor Governor {
    private var state: GovernorState
    private let policy: AdmissionPolicy

    public init(state: GovernorState, policy: AdmissionPolicy) {
        self.state = state
        self.policy = policy
    }

    public var snapshot: GovernorState { state }
    public nonisolated var policyName: String { policy.name }

    /// Ask for permission to spend. Admission opens the reservation atomically,
    /// so the answer a caller receives is already reflected in what the next
    /// caller sees.
    public func request(_ request: WorkRequest, now: Date) -> AdmissionDecision {
        let decision = policy.decide(request, state: state, now: now)
        if let reservation = decision.reservation {
            guard let opened = try? state.opening(reservation) else {
                return .deny(.invalidEstimate)
            }
            state = opened
        }
        return decision
    }

    /// Close a reservation with what it really cost and what it produced.
    @discardableResult
    public func settle(
        reservationID: String,
        actual: Micros,
        outcome: Outcome
    ) throws -> GovernorState {
        state = try state.settling(reservationID: reservationID, actual: actual, outcome: outcome)
        return state
    }

    public func rollPeriod(into period: BudgetPeriod) {
        state = state.rolling(into: period)
    }

    public func report() -> SpendReport { SpendReport(state: state) }
}

/// What a lead actually wants on a Monday: not tokens, but what the tokens bought.
public struct SpendReport: Sendable, Equatable {
    public struct Line: Sendable, Equatable {
        public let workClassID: String
        public let settledSpend: Micros
        public let accepted: Int
        public let discarded: Int
        /// Realised cost per accepted outcome, unsmoothed. `nil` when the class
        /// has produced nothing — reported as unknown rather than as infinity,
        /// because "we spent money and learned nothing" is a distinct state.
        public let costPerAcceptedOutcome: Micros?
    }

    public let ceiling: Micros
    public let settled: Micros
    public let lines: [Line]

    public init(state: GovernorState) {
        self.ceiling = state.period.ceiling
        self.settled = state.settledThisPeriod
        self.lines = state.classes.keys.sorted().map { id in
            let stats = state.stats(for: id)
            let perOutcome: Micros? = stats.acceptedCount > 0
                ? Micros(stats.settledSpend.raw / stats.acceptedCount)
                : nil
            return Line(
                workClassID: id,
                settledSpend: stats.settledSpend,
                accepted: stats.acceptedCount,
                discarded: stats.discardedCount,
                costPerAcceptedOutcome: perOutcome
            )
        }
    }

    public var totalAccepted: Int { lines.reduce(0) { $0 + $1.accepted } }
    public var totalDiscarded: Int { lines.reduce(0) { $0 + $1.discarded } }

    public func line(_ workClassID: String) -> Line? {
        lines.first { $0.workClassID == workClassID }
    }
}
