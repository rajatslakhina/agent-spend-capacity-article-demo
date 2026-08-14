import Foundation

/// Everything a policy is allowed to see, as a value.
///
/// The load-bearing structural decision in this library: admission is a **pure
/// function of a snapshot**, and the actor owns nothing but the snapshot. A
/// policy cannot await, cannot read a clock, and cannot reach a network. That
/// makes every decision reproducible from a struct you can print into a test
/// failure — which matters, because the first question anyone asks a budget
/// system is "why did it say no to me."
public struct GovernorState: Sendable {
    public let period: BudgetPeriod
    public private(set) var classes: [String: WorkClass]
    public private(set) var stats: [String: ClassStats]
    public private(set) var openReservations: [String: Reservation]
    /// Sum of settled actuals inside the current period.
    public private(set) var settledThisPeriod: Micros

    public init(period: BudgetPeriod, classes: [WorkClass]) {
        self.period = period
        self.classes = Dictionary(uniqueKeysWithValues: classes.map { ($0.id, $0) })
        self.stats = Dictionary(uniqueKeysWithValues: classes.map { ($0.id, ClassStats()) })
        self.openReservations = [:]
        self.settledThisPeriod = .zero
    }

    private init(
        period: BudgetPeriod,
        classes: [String: WorkClass],
        stats: [String: ClassStats],
        openReservations: [String: Reservation],
        settledThisPeriod: Micros
    ) {
        self.period = period
        self.classes = classes
        self.stats = stats
        self.openReservations = openReservations
        self.settledThisPeriod = settledThisPeriod
    }

    /// Held-but-unsettled money. Counted against the ceiling, because a
    /// reservation that has not landed is still money you cannot spend twice.
    public var heldInFlight: Micros {
        openReservations.values.reduce(Micros.zero) { $0 + $1.held }
    }

    /// Everything the period has claimed: settled plus in-flight.
    public var encumbered: Micros { settledThisPeriod + heldInFlight }

    public var remaining: Micros { period.ceiling - encumbered }

    public func workClass(_ id: String) -> WorkClass? { classes[id] }
    public func stats(for id: String) -> ClassStats { stats[id] ?? ClassStats() }

    /// Calibrated cost estimate for a request: the caller's number multiplied by
    /// how wrong that class's estimates have actually been, clamped so one
    /// pathological settlement cannot lock a class out.
    public func calibratedEstimate(
        for request: WorkRequest,
        calibration: CalibrationBounds
    ) -> Micros {
        let observed = stats(for: request.workClassID)
            .calibrationFactor(minimumSamples: calibration.minimumSamples)
        guard let observed else { return request.estimate }
        let clamped = min(calibration.upperBound, max(calibration.lowerBound, observed))
        return request.estimate.scaled(by: clamped)
    }

    /// Classes ordered cheapest-first by smoothed cost per accepted outcome.
    /// Ties break on class id so the ordering is total and reproducible.
    public func yieldRanking() -> [String] {
        var scored: [(id: String, cost: Double)] = []
        scored.reserveCapacity(classes.count)
        for workClass in classes.values {
            let cost = stats(for: workClass.id).costPerAcceptedOutcome(prior: workClass.prior)
            scored.append((id: workClass.id, cost: cost))
        }
        scored.sort { lhs, rhs in
            if lhs.cost == rhs.cost { return lhs.id < rhs.id }
            return lhs.cost < rhs.cost
        }
        return scored.map { $0.id }
    }

    // MARK: - Transitions

    public func opening(_ reservation: Reservation) throws -> GovernorState {
        guard openReservations[reservation.id] == nil else {
            throw GovernorError.duplicateReservation(reservation.id)
        }
        var next = openReservations
        next[reservation.id] = reservation
        return GovernorState(
            period: period, classes: classes, stats: stats,
            openReservations: next, settledThisPeriod: settledThisPeriod
        )
    }

    public func settling(reservationID: String, actual: Micros, outcome: Outcome) throws -> GovernorState {
        guard let reservation = openReservations[reservationID] else {
            throw GovernorError.unknownReservation(reservationID)
        }
        var nextOpen = openReservations
        nextOpen.removeValue(forKey: reservationID)

        var nextStats = stats
        var classStats = nextStats[reservation.workClassID] ?? ClassStats()
        classStats.record(actual: actual, held: reservation.held, outcome: outcome)
        nextStats[reservation.workClassID] = classStats

        return GovernorState(
            period: period, classes: classes, stats: nextStats,
            openReservations: nextOpen, settledThisPeriod: settledThisPeriod + actual
        )
    }

    /// Rolls into a new period. Money resets, evidence carries, and anything
    /// still in flight carries too — an agent mid-run does not lose its hold
    /// because a calendar boundary passed.
    public func rolling(into newPeriod: BudgetPeriod) -> GovernorState {
        GovernorState(
            period: newPeriod, classes: classes, stats: stats,
            openReservations: openReservations, settledThisPeriod: .zero
        )
    }
}

public struct CalibrationBounds: Hashable, Sendable {
    public let minimumSamples: Int
    public let lowerBound: Double
    public let upperBound: Double

    public init(minimumSamples: Int = 5, lowerBound: Double = 0.5, upperBound: Double = 3.0) {
        self.minimumSamples = max(1, minimumSamples)
        self.lowerBound = max(0.0001, min(lowerBound, upperBound))
        self.upperBound = max(lowerBound, upperBound)
    }

    public static let standard = CalibrationBounds()
    /// No recalibration — takes the caller's estimate at face value.
    public static let none = CalibrationBounds(minimumSamples: Int.max, lowerBound: 1, upperBound: 1)
}
