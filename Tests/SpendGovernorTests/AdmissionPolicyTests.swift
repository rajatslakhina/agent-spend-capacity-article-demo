import XCTest
@testable import SpendGovernor

final class AdmissionPolicyTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_767_225_600)
    private let duration: TimeInterval = 1_000

    private func state(ceiling: Micros = .dollars(100)) -> GovernorState {
        GovernorState(
            period: BudgetPeriod(start: start, duration: duration, ceiling: ceiling),
            classes: StandardScenario.classes
        )
    }

    private func spend(_ state: GovernorState, _ amount: Micros, classID: String = "feature") throws -> GovernorState {
        var next = state
        next = try next.opening(Reservation(id: UUID().uuidString + "-\(amount.raw)", workClassID: classID, held: amount, openedAt: start))
        guard let open = next.openReservations.keys.first else { return next }
        return try next.settling(reservationID: open, actual: amount, outcome: .accepted)
    }

    private func request(_ classID: String, _ estimate: Micros) -> WorkRequest {
        WorkRequest(id: "req", workClassID: classID, estimate: estimate)
    }

    // MARK: - Shared guards

    func testBothPoliciesRejectNonPositiveEstimates() {
        for policy in [AnyPolicy(AccessRestrictionPolicy()), AnyPolicy(CapacityPolicy())] {
            let decision = policy.decide(request("feature", .zero), state: state(), now: start)
            XCTAssertEqual(decision, .deny(.invalidEstimate), "\(policy.name)")
        }
    }

    func testBothPoliciesRejectUnknownClasses() {
        for policy in [AnyPolicy(AccessRestrictionPolicy()), AnyPolicy(CapacityPolicy())] {
            let decision = policy.decide(request("nope", .dollars(1)), state: state(), now: start)
            XCTAssertEqual(decision, .deny(.unknownWorkClass), "\(policy.name)")
        }
    }

    // MARK: - Access restriction

    func testRestrictionAdmitsBelowTheCutOff() {
        let policy = AccessRestrictionPolicy(restrictionThreshold: 0.85)
        XCTAssertTrue(policy.decide(request("feature", .dollars(5)), state: state(), now: start).isAdmitted)
    }

    func testRestrictionStopsEveryClassAtTheCutOff() throws {
        let policy = AccessRestrictionPolicy(restrictionThreshold: 0.85)
        let spent = try spend(state(), .dollars(86))
        XCTAssertEqual(
            policy.decide(request("incident", .dollars(1)), state: spent, now: start),
            .deny(.accessRestricted),
            "this is the failure mode: the cut-off cannot tell an incident from a doodle"
        )
        XCTAssertEqual(
            policy.decide(request("exploration", .dollars(1)), state: spent, now: start),
            .deny(.accessRestricted)
        )
    }

    func testRestrictionDeniesWhenTheRequestExceedsWhatIsLeft() throws {
        let policy = AccessRestrictionPolicy(restrictionThreshold: 1.0)
        let spent = try spend(state(), .dollars(95))
        XCTAssertEqual(
            policy.decide(request("feature", .dollars(10)), state: spent, now: start),
            .deny(.insufficientBudget)
        )
    }

    func testRestrictionThresholdIsClamped() {
        XCTAssertEqual(AccessRestrictionPolicy(restrictionThreshold: 4).restrictionThreshold, 1)
        XCTAssertEqual(AccessRestrictionPolicy(restrictionThreshold: -2).restrictionThreshold, 0)
    }

    // MARK: - Capacity: reserve

    func testReserveIsClosedToOrdinaryWorkButOpenToIncidents() throws {
        let policy = CapacityPolicy(configuration: .init(reserveFraction: 0.2, protectedRankCount: 4))
        let spent = try spend(state(), .dollars(85))  // $15 left, all of it inside the $20 reserve

        XCTAssertEqual(
            policy.decide(request("feature", .dollars(5)), state: spent, now: start),
            .deny(.insufficientBudget),
            "ordinary work cannot draw from the reserve"
        )
        XCTAssertTrue(
            policy.decide(request("incident", .dollars(5)), state: spent, now: start).isAdmitted,
            "the reserve exists precisely for this request"
        )
    }

    func testIncidentIsStillDeniedOnceTheCeilingItselfIsGone() throws {
        let policy = CapacityPolicy()
        let spent = try spend(state(), .dollars(99))
        XCTAssertEqual(
            policy.decide(request("incident", .dollars(5)), state: spent, now: start),
            .deny(.insufficientBudget),
            "a reserve is not an overdraft"
        )
    }

    func testReserveFractionIsClamped() {
        XCTAssertEqual(CapacityPolicy.Configuration(reserveFraction: 9).reserveFraction, 1)
        XCTAssertEqual(CapacityPolicy.Configuration(reserveFraction: -9).reserveFraction, 0)
    }

    // MARK: - Capacity: pace

    func testWarmupSuppressesThePaceGate() throws {
        let policy = CapacityPolicy(configuration: .init(protectedRankCount: 0, paceWarmupFraction: 0.05))
        var spent = try spend(state(), .dollars(40))
        spent = try spend(spent, .dollars(1))
        // 2% into the period, far over the pace line, but inside warmup.
        let now = start.addingTimeInterval(duration * 0.02)
        XCTAssertFalse(policy.isOverPace(state: spent, now: now))
        XCTAssertTrue(policy.decide(request("feature", .dollars(1)), state: spent, now: now).isAdmitted)
    }

    func testOverPaceDefersClassesOutsideTheProtectedSet() throws {
        let policy = CapacityPolicy(configuration: .init(protectedRankCount: 1))
        let spent = try spend(state(), .dollars(40))
        let now = start.addingTimeInterval(duration * 0.10) // pace line is $10, spend is $40

        XCTAssertTrue(policy.isOverPace(state: spent, now: now))
        let ranking = spent.yieldRanking()
        guard let best = ranking.first, let worst = ranking.last else {
            return XCTFail("expected a ranking")
        }
        XCTAssertNotEqual(best, worst)
        XCTAssertEqual(
            policy.decide(request(worst, .dollars(1)), state: spent, now: now),
            .deferred(retryAfter: 900, reason: .overPaceLowYield)
        )
        XCTAssertTrue(policy.decide(request(best, .dollars(1)), state: spent, now: now).isAdmitted)
    }

    func testOverPaceNeverDefersAPrivilegedClass() throws {
        let policy = CapacityPolicy(configuration: .init(protectedRankCount: 0))
        let spent = try spend(state(), .dollars(40))
        let now = start.addingTimeInterval(duration * 0.10)
        XCTAssertTrue(policy.isOverPace(state: spent, now: now))
        XCTAssertTrue(
            policy.decide(request("incident", .dollars(1)), state: spent, now: now).isAdmitted,
            "pace pressure must never queue an incident"
        )
    }

    func testUnderPaceAdmitsEvenTheWorstClass() throws {
        let policy = CapacityPolicy(configuration: .init(protectedRankCount: 1))
        let spent = try spend(state(), .dollars(5))
        let now = start.addingTimeInterval(duration * 0.9) // pace line is $90, spend is $5
        XCTAssertFalse(policy.isOverPace(state: spent, now: now))
        guard let worst = spent.yieldRanking().last else { return XCTFail("expected a ranking") }
        XCTAssertTrue(policy.decide(request(worst, .dollars(1)), state: spent, now: now).isAdmitted,
                      "being under pace is not a reason to be selective")
    }

    func testDeferralIsNotADenial() throws {
        let policy = CapacityPolicy(configuration: .init(protectedRankCount: 0, deferralRetryInterval: 60))
        let spent = try spend(state(), .dollars(40))
        let now = start.addingTimeInterval(duration * 0.10)
        let decision = policy.decide(request("exploration", .dollars(1)), state: spent, now: now)
        guard case .deferred(let retryAfter, let reason) = decision else {
            return XCTFail("expected a deferral, got \(decision)")
        }
        XCTAssertEqual(retryAfter, 60)
        XCTAssertEqual(reason, .overPaceLowYield)
        XCTAssertNil(decision.reservation)
    }

    // MARK: - Capacity: calibration feeds the hold

    func testCapacityHoldsTheCalibratedAmountNotTheClaimedOne() throws {
        var s = state(ceiling: .dollars(10_000))
        for index in 0..<6 {
            s = try s.opening(Reservation(id: "r\(index)", workClassID: "feature", held: .dollars(1), openedAt: start))
            s = try s.settling(reservationID: "r\(index)", actual: .dollars(2), outcome: .accepted)
        }
        let policy = CapacityPolicy(configuration: .init(protectedRankCount: 4))
        let decision = policy.decide(request("feature", .dollars(10)), state: s, now: start)
        guard let reservation = decision.reservation else {
            return XCTFail("expected admission, got \(decision)")
        }
        XCTAssertEqual(reservation.held, .dollars(20),
                       "a class that reliably doubles is held at double, not at what it claimed")
    }
}

/// Small type eraser so shared guards can be table-tested across both policies.
private struct AnyPolicy: AdmissionPolicy {
    let name: String
    private let body: @Sendable (WorkRequest, GovernorState, Date) -> AdmissionDecision

    init<P: AdmissionPolicy>(_ policy: P) {
        self.name = policy.name
        self.body = { policy.decide($0, state: $1, now: $2) }
    }

    func decide(_ request: WorkRequest, state: GovernorState, now: Date) -> AdmissionDecision {
        body(request, state, now)
    }
}
