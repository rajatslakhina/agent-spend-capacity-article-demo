import XCTest
@testable import SpendGovernor

final class GovernorActorTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_767_225_600)

    private func makeGovernor(ceiling: Micros, policy: AdmissionPolicy) -> Governor {
        Governor(
            state: GovernorState(
                period: BudgetPeriod(start: start, duration: 1_000, ceiling: ceiling),
                classes: StandardScenario.classes
            ),
            policy: policy
        )
    }

    func testConcurrentRequestsCannotOversubscribeTheCeiling() async {
        // $100 ceiling, no reserve, pace disabled by protecting every class.
        let governor = makeGovernor(
            ceiling: .dollars(100),
            policy: CapacityPolicy(configuration: .init(reserveFraction: 0, protectedRankCount: 4))
        )
        let start = self.start

        let admitted = await withTaskGroup(of: Bool.self) { group -> Int in
            for index in 0..<200 {
                group.addTask {
                    let request = WorkRequest(id: "c\(index)", workClassID: "feature", estimate: .dollars(10))
                    return await governor.request(request, now: start).isAdmitted
                }
            }
            var count = 0
            for await wasAdmitted in group where wasAdmitted { count += 1 }
            return count
        }

        XCTAssertEqual(admitted, 10, "exactly ten $10 holds fit in a $100 ceiling")
        let snapshot = await governor.snapshot
        XCTAssertEqual(snapshot.heldInFlight, .dollars(100))
        XCTAssertEqual(snapshot.remaining, .zero)
    }

    func testAdmissionIsVisibleToTheNextCallerImmediately() async {
        let governor = makeGovernor(
            ceiling: .dollars(10),
            policy: CapacityPolicy(configuration: .init(reserveFraction: 0, protectedRankCount: 4))
        )
        let first = await governor.request(
            WorkRequest(id: "a", workClassID: "feature", estimate: .dollars(9)), now: start
        )
        XCTAssertTrue(first.isAdmitted)
        let second = await governor.request(
            WorkRequest(id: "b", workClassID: "feature", estimate: .dollars(9)), now: start
        )
        XCTAssertEqual(second, .deny(.insufficientBudget))
    }

    func testSettlementFlowsIntoTheReport() async throws {
        let governor = makeGovernor(
            ceiling: .dollars(100),
            policy: CapacityPolicy(configuration: .init(reserveFraction: 0, protectedRankCount: 4))
        )
        let decision = await governor.request(
            WorkRequest(id: "a", workClassID: "review", estimate: .dollars(2)), now: start
        )
        guard let reservation = decision.reservation else { return XCTFail("expected admission") }
        try await governor.settle(reservationID: reservation.id, actual: .dollars(3), outcome: .accepted)

        let report = await governor.report()
        XCTAssertEqual(report.settled, .dollars(3))
        XCTAssertEqual(report.totalAccepted, 1)
        XCTAssertEqual(report.line("review")?.costPerAcceptedOutcome, .dollars(3))
        XCTAssertNil(report.line("feature")?.costPerAcceptedOutcome,
                     "a class with no accepted work reports unknown, not zero and not infinity")
    }

    func testSettlingTwiceThrows() async throws {
        let governor = makeGovernor(ceiling: .dollars(100), policy: AccessRestrictionPolicy())
        let decision = await governor.request(
            WorkRequest(id: "a", workClassID: "feature", estimate: .dollars(2)), now: start
        )
        guard let reservation = decision.reservation else { return XCTFail("expected admission") }
        try await governor.settle(reservationID: reservation.id, actual: .dollars(2), outcome: .accepted)
        do {
            try await governor.settle(reservationID: reservation.id, actual: .dollars(2), outcome: .accepted)
            XCTFail("expected a throw on double settlement")
        } catch {
            XCTAssertEqual(error as? GovernorError, .unknownReservation("a"))
        }
    }

    func testRollPeriodClearsSpendButNotHistory() async throws {
        let governor = makeGovernor(ceiling: .dollars(100), policy: AccessRestrictionPolicy())
        let decision = await governor.request(
            WorkRequest(id: "a", workClassID: "review", estimate: .dollars(4)), now: start
        )
        guard let reservation = decision.reservation else { return XCTFail("expected admission") }
        try await governor.settle(reservationID: reservation.id, actual: .dollars(4), outcome: .accepted)

        await governor.rollPeriod(into: BudgetPeriod(
            start: start.addingTimeInterval(1_000), duration: 1_000, ceiling: .dollars(100)
        ))
        let report = await governor.report()
        XCTAssertEqual(report.settled, .zero)
        let snapshot = await governor.snapshot
        XCTAssertEqual(snapshot.stats(for: "review").acceptedCount, 1)
    }

    func testPolicyNameIsReadableWithoutAwaiting() {
        let governor = makeGovernor(ceiling: .dollars(1), policy: CapacityPolicy())
        XCTAssertEqual(governor.policyName, "capacity-model")
    }
}
