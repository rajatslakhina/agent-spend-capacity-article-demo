import XCTest
@testable import SpendGovernor

/// Where estimate calibration actually earns its place: overlapping holds.
///
/// A cap that holds the caller's claimed number and settles the real one is not
/// a cap. These tests show the breach happening and show calibration closing it.
final class CalibrationEffectTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_767_225_600)

    /// Every request systematically claims $1 and really costs $4.
    private func underestimatingWorkload(count: Int) -> Workload {
        let items = (0..<count).map { index in
            Workload.Item(
                request: WorkRequest(id: "u\(index)", workClassID: "feature", estimate: .dollars(1)),
                offset: TimeInterval(index),
                actualCost: .dollars(4),
                wouldBeAccepted: true
            )
        }
        return Workload(items: items)
    }

    private var period: BudgetPeriod {
        BudgetPeriod(start: start, duration: 1_000, ceiling: .dollars(30))
    }

    func testAnUncalibratedCapCanOverrunItsOwnCeiling() {
        let trial = PolicyHarness.run(
            workload: underestimatingWorkload(count: 40),
            classes: StandardScenario.classes,
            period: period,
            policy: AccessRestrictionPolicy(restrictionThreshold: 1.0)
        )
        XCTAssertGreaterThan(
            trial.settledSpend, period.ceiling,
            "holding the claimed number and settling the real one lets spend walk past the ceiling"
        )
    }

    func testCalibrationPullsSpendBackUnderTheCeiling() {
        let calibrated = PolicyHarness.run(
            workload: underestimatingWorkload(count: 40),
            classes: StandardScenario.classes,
            period: period,
            policy: CapacityPolicy(configuration: .init(
                reserveFraction: 0,
                protectedRankCount: StandardScenario.classes.count,
                calibration: CalibrationBounds(minimumSamples: 3)
            ))
        )
        let uncalibrated = PolicyHarness.run(
            workload: underestimatingWorkload(count: 40),
            classes: StandardScenario.classes,
            period: period,
            policy: CapacityPolicy(configuration: .init(
                reserveFraction: 0,
                protectedRankCount: StandardScenario.classes.count,
                calibration: .none
            ))
        )
        XCTAssertLessThan(calibrated.settledSpend, uncalibrated.settledSpend)
        XCTAssertLessThanOrEqual(calibrated.settledSpend, period.ceiling,
                                 "once the class has three samples, the hold reflects reality")
    }

    func testOverlappingHoldsAreSizedByCalibrationNotByTheClaim() async {
        let governor = Governor(
            state: GovernorState(period: period, classes: StandardScenario.classes),
            policy: CapacityPolicy(configuration: .init(
                reserveFraction: 0,
                protectedRankCount: StandardScenario.classes.count,
                calibration: CalibrationBounds(minimumSamples: 3)
            ))
        )
        // Teach the class that $1 claims really cost $3.
        for index in 0..<3 {
            let decision = await governor.request(
                WorkRequest(id: "warm\(index)", workClassID: "feature", estimate: .dollars(1)), now: start
            )
            guard let reservation = decision.reservation else { return XCTFail("expected admission") }
            try? await governor.settle(reservationID: reservation.id, actual: .dollars(3), outcome: .accepted)
        }
        let decision = await governor.request(
            WorkRequest(id: "next", workClassID: "feature", estimate: .dollars(1)), now: start
        )
        guard let reservation = decision.reservation else { return XCTFail("expected admission") }
        XCTAssertEqual(reservation.held, .dollars(3),
                       "the hold is what the class actually costs, not what the caller hoped")
    }
}
