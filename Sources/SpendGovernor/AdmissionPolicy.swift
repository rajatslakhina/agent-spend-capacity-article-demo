import Foundation

public protocol AdmissionPolicy: Sendable {
    var name: String { get }
    func decide(_ request: WorkRequest, state: GovernorState, now: Date) -> AdmissionDecision
}

// MARK: - The thing most teams actually shipped

/// Spend until a threshold, then stop everything.
///
/// This is not a straw man — it is the shape of a monthly cap, a seat
/// suspension, and a gateway spend limit, and it is where most teams start.
/// It has exactly one virtue: the bill stops. It has one structural flaw,
/// which is the subject of this library: the threshold is indifferent to what
/// the money was buying.
public struct AccessRestrictionPolicy: AdmissionPolicy {
    public let name = "access-restriction"
    /// Fraction of the ceiling at which everything is cut off.
    public let restrictionThreshold: Double

    public init(restrictionThreshold: Double = 0.85) {
        self.restrictionThreshold = min(1, max(0, restrictionThreshold))
    }

    public func decide(_ request: WorkRequest, state: GovernorState, now: Date) -> AdmissionDecision {
        guard request.estimate > .zero else { return .deny(.invalidEstimate) }
        guard state.workClass(request.workClassID) != nil else { return .deny(.unknownWorkClass) }

        let cutoff = state.period.ceiling.scaled(by: restrictionThreshold)
        if state.encumbered >= cutoff { return .deny(.accessRestricted) }
        guard request.estimate <= state.remaining else { return .deny(.insufficientBudget) }

        return .admit(Reservation(
            id: request.id,
            workClassID: request.workClassID,
            held: request.estimate,
            openedAt: now
        ))
    }
}

// MARK: - The capacity model

/// Admission by pace, reserve and yield.
///
/// Three ideas, in the order they are evaluated:
///
/// 1. **Reserve.** A fraction of the ceiling only high-priority classes may
///    touch. This is what stops an incident being denied in the last week of
///    the month because exploratory work spent the pool.
/// 2. **Pace.** Compare spend against the straight-line allowance. Being over
///    pace is not an error; it is a signal to become selective.
/// 3. **Yield.** When over pace, admit only the classes with the best observed
///    cost per accepted outcome. Not the cheapest requests — the classes whose
///    money keeps turning into merged work.
public struct CapacityPolicy: AdmissionPolicy {
    public struct Configuration: Hashable, Sendable {
        /// Fraction of the ceiling only privileged classes may draw from.
        public let reserveFraction: Double
        /// Minimum `WorkClass.priority` to draw from the reserve.
        public let reservePriorityFloor: Int
        /// How many classes stay admitted while over pace.
        public let protectedRankCount: Int
        /// Ignore pace before this much of the period has elapsed, so the first
        /// request of the month cannot trip the gate against a near-zero line.
        public let paceWarmupFraction: Double
        public let deferralRetryInterval: TimeInterval
        public let calibration: CalibrationBounds

        public init(
            reserveFraction: Double = 0.2,
            reservePriorityFloor: Int = 100,
            protectedRankCount: Int = 2,
            paceWarmupFraction: Double = 0.05,
            deferralRetryInterval: TimeInterval = 900,
            calibration: CalibrationBounds = .standard
        ) {
            self.reserveFraction = min(1, max(0, reserveFraction))
            self.reservePriorityFloor = reservePriorityFloor
            self.protectedRankCount = max(0, protectedRankCount)
            self.paceWarmupFraction = min(1, max(0, paceWarmupFraction))
            self.deferralRetryInterval = max(1, deferralRetryInterval)
            self.calibration = calibration
        }

        public static let standard = Configuration()
    }

    public let name = "capacity-model"
    public let configuration: Configuration

    public init(configuration: Configuration = .standard) {
        self.configuration = configuration
    }

    public func decide(_ request: WorkRequest, state: GovernorState, now: Date) -> AdmissionDecision {
        guard request.estimate > .zero else { return .deny(.invalidEstimate) }
        guard let workClass = state.workClass(request.workClassID) else {
            return .deny(.unknownWorkClass)
        }

        let cost = state.calibratedEstimate(for: request, calibration: configuration.calibration)
        let privileged = workClass.priority >= configuration.reservePriorityFloor

        // 1. Reserve.
        let reserve = state.period.ceiling.scaled(by: configuration.reserveFraction)
        let available = privileged ? state.remaining : state.remaining - reserve
        guard cost <= available else { return .deny(.insufficientBudget) }

        // 2. Pace. 3. Yield.
        if !privileged, isOverPace(state: state, now: now) {
            let ranking = state.yieldRanking()
            let protectedIDs = Set(ranking.prefix(configuration.protectedRankCount))
            if !protectedIDs.contains(workClass.id) {
                return .deferred(
                    retryAfter: configuration.deferralRetryInterval,
                    reason: .overPaceLowYield
                )
            }
        }

        return .admit(Reservation(
            id: request.id,
            workClassID: request.workClassID,
            held: cost,
            openedAt: now
        ))
    }

    func isOverPace(state: GovernorState, now: Date) -> Bool {
        let elapsed = state.period.elapsedFraction(at: now)
        guard elapsed >= configuration.paceWarmupFraction else { return false }
        return state.encumbered > state.period.pacedAllowance(at: now)
    }
}
