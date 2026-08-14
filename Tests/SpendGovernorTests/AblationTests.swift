import XCTest
@testable import SpendGovernor

/// Leave-one-out over the capacity policy's three ideas.
///
/// A design is only worth writing about if you know which part of it is doing
/// the work. These tests turn each component off in turn and record what the
/// budget bought without it.
final class AblationTests: XCTestCase {
    private func trial(_ configuration: CapacityPolicy.Configuration) -> PolicyTrial {
        PolicyHarness.run(
            workload: StandardScenario.workload,
            classes: StandardScenario.classes,
            period: StandardScenario.period,
            policy: CapacityPolicy(configuration: configuration)
        )
    }

    private var restriction: PolicyTrial {
        PolicyHarness.run(
            workload: StandardScenario.workload,
            classes: StandardScenario.classes,
            period: StandardScenario.period,
            policy: AccessRestrictionPolicy(restrictionThreshold: 0.85)
        )
    }

    func testEveryVariantStaysUnderTheCeiling() {
        let variants: [CapacityPolicy.Configuration] = [
            .standard,
            .init(reserveFraction: 0),
            .init(protectedRankCount: 4),
            .init(calibration: .none)
        ]
        for configuration in variants {
            XCTAssertLessThanOrEqual(trial(configuration).settledSpend, StandardScenario.ceiling)
        }
    }

    func testDroppingTheReserveReintroducesIncidentDenials() {
        let withoutReserve = trial(.init(reserveFraction: 0))
        XCTAssertGreaterThan(
            withoutReserve.deniedByClass[StandardScenario.incident.id] ?? 0, 0,
            "the reserve is the component that protects incidents — remove it and they starve again"
        )
    }

    func testDroppingYieldGatingCostsAcceptedOutcomes() {
        // protectedRankCount == class count means the pace gate never defers anyone.
        let withoutYieldGate = trial(.init(protectedRankCount: StandardScenario.classes.count))
        XCTAssertLessThan(
            withoutYieldGate.accepted, trial(.standard).accepted,
            "yield ranking is load-bearing, not decoration"
        )
    }

    /// The reserve is not free, and pretending otherwise would be the easy lie.
    ///
    /// Holding 20% of the ceiling back for incidents means some of it goes
    /// unspent, which costs accepted outcomes. This test pins the direction of
    /// that trade so nobody can quietly claim the design wins on every axis.
    func testTheReserveCostsAcceptedOutcomesAndBuysIncidentProtection() {
        let full = trial(.standard)
        let withoutReserve = trial(.init(reserveFraction: 0))

        XCTAssertGreaterThan(withoutReserve.accepted, full.accepted,
                             "unreserved money buys more total work — that is the cost of the reserve")
        XCTAssertLessThan(full.settledSpend, withoutReserve.settledSpend,
                          "the reserve leaves money on the table by design")
        XCTAssertEqual(full.deniedByClass[StandardScenario.incident.id] ?? 0, 0)
        XCTAssertGreaterThan(withoutReserve.deniedByClass[StandardScenario.incident.id] ?? 0, 0,
                             "and that is what the reserve is buying")
    }

    func testYieldGatingIsTheComponentThatCarriesTheResult() {
        let full = trial(.standard)
        let withoutYieldGate = trial(.init(protectedRankCount: StandardScenario.classes.count))
        XCTAssertGreaterThan(full.accepted, withoutYieldGate.accepted)
        guard let fullCost = full.costPerAcceptedOutcome,
              let ungatedCost = withoutYieldGate.costPerAcceptedOutcome else {
            return XCTFail("expected both variants to produce accepted outcomes")
        }
        XCTAssertLessThan(fullCost, ungatedCost)
    }

    /// Calibration does nothing in this harness, and the harness is the reason.
    ///
    /// `PolicyHarness` settles each reservation immediately, so holds never
    /// overlap and the held amount never binds. Recorded as a test rather than
    /// as a footnote nobody reads.
    func testCalibrationIsInertUnderSerialSettlement() {
        XCTAssertEqual(trial(.init(calibration: .none)).accepted, trial(.standard).accepted)
        XCTAssertEqual(trial(.init(calibration: .none)).settledSpend, trial(.standard).settledSpend)
    }

    func testPrintAblationForTheWriteUp() {
        let rows: [(String, PolicyTrial)] = [
            ("restriction-85", restriction),
            ("restriction-100", PolicyHarness.run(
                workload: StandardScenario.workload, classes: StandardScenario.classes,
                period: StandardScenario.period, policy: AccessRestrictionPolicy(restrictionThreshold: 1.0)
            )),
            ("capacity-full", trial(.standard)),
            ("capacity-no-reserve", trial(.init(reserveFraction: 0))),
            ("capacity-no-yield-gate", trial(.init(protectedRankCount: StandardScenario.classes.count))),
            ("capacity-no-calibration", trial(.init(calibration: .none)))
        ]
        for (label, trial) in rows {
            let incidentDenials = trial.deniedByClass[StandardScenario.incident.id] ?? 0
            print("ABLATION \(label) accepted=\(trial.accepted) spent=\(trial.settledSpend) " +
                  "perAccepted=\(trial.costPerAcceptedOutcome?.description ?? "-") " +
                  "incidentDenials=\(incidentDenials) deferred=\(trial.deferred) denied=\(trial.denied)")
        }
        XCTAssertFalse(rows.isEmpty)
    }
}
