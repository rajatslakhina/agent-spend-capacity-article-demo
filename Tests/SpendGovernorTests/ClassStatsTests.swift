import XCTest
@testable import SpendGovernor

final class ClassStatsTests: XCTestCase {
    func testCostPerAcceptedOutcomeNeverDividesByZero() {
        let stats = ClassStats()
        let prior = AcceptancePrior.neutral(costPerOutcome: .dollars(4))
        XCTAssertEqual(stats.costPerAcceptedOutcome(prior: prior), 4_000_000, accuracy: 1e-6)
    }

    func testPriorPseudoCountIsClampedAwayFromZero() {
        let prior = AcceptancePrior(pseudoSpend: .dollars(1), pseudoAccepted: 0)
        XCTAssertGreaterThan(prior.pseudoAccepted, 0)
        let value = ClassStats().costPerAcceptedOutcome(prior: prior)
        XCTAssertTrue(value.isFinite)
    }

    func testEvidenceWashesOutThePrior() {
        var stats = ClassStats()
        let prior = AcceptancePrior.neutral(costPerOutcome: .dollars(100))
        for _ in 0..<200 {
            stats.record(actual: .dollars(1), held: .dollars(1), outcome: .accepted)
        }
        // 200 real outcomes at $1 against one imagined outcome at $100.
        let smoothed = stats.costPerAcceptedOutcome(prior: prior)
        XCTAssertEqual(smoothed, 300_000_000.0 / 201.0, accuracy: 1.0)
        XCTAssertLessThan(smoothed, 2_000_000, "prior must not dominate after 200 samples")
    }

    func testDiscardedOutcomesRaiseCostPerAcceptedOutcome() {
        var kept = ClassStats()
        var thrownAway = ClassStats()
        let prior = AcceptancePrior.neutral(costPerOutcome: .dollars(4))
        for _ in 0..<10 {
            kept.record(actual: .dollars(2), held: .dollars(2), outcome: .accepted)
            thrownAway.record(actual: .dollars(2), held: .dollars(2), outcome: .accepted)
            thrownAway.record(actual: .dollars(2), held: .dollars(2), outcome: .discarded)
        }
        XCTAssertGreaterThan(
            thrownAway.costPerAcceptedOutcome(prior: prior),
            kept.costPerAcceptedOutcome(prior: prior),
            "money spent on discarded work still counts against the class"
        )
    }

    func testCalibrationRequiresASampleFloor() {
        var stats = ClassStats()
        stats.record(actual: .dollars(4), held: .dollars(2), outcome: .accepted)
        XCTAssertNil(stats.calibrationFactor(minimumSamples: 5))
        for _ in 0..<4 {
            stats.record(actual: .dollars(4), held: .dollars(2), outcome: .accepted)
        }
        guard let factor = stats.calibrationFactor(minimumSamples: 5) else {
            return XCTFail("expected a calibration factor at the sample floor")
        }
        XCTAssertEqual(factor, 2.0, accuracy: 1e-9)
    }

    func testZeroHeldDoesNotPoisonCalibration() {
        var stats = ClassStats()
        for _ in 0..<5 {
            stats.record(actual: .dollars(1), held: .zero, outcome: .accepted)
        }
        XCTAssertNil(stats.calibrationFactor(minimumSamples: 1),
                     "a divide-by-zero sample is dropped, not recorded as infinity")
        XCTAssertEqual(stats.acceptedCount, 5)
    }

    func testSettledCountSumsBothOutcomes() {
        var stats = ClassStats()
        stats.record(actual: .dollars(1), held: .dollars(1), outcome: .accepted)
        stats.record(actual: .dollars(1), held: .dollars(1), outcome: .discarded)
        XCTAssertEqual(stats.settledCount, 2)
        XCTAssertEqual(stats.settledSpend, .dollars(2))
    }
}
