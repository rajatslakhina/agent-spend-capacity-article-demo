import XCTest
@testable import SpendGovernor

final class DeterministicRandomTests: XCTestCase {
    func testSameSeedProducesTheSameStream() {
        var a = DeterministicRandom(seed: 42)
        var b = DeterministicRandom(seed: 42)
        for _ in 0..<50 { XCTAssertEqual(a.next(), b.next()) }
    }

    func testDifferentSeedsDiverge() {
        var a = DeterministicRandom(seed: 1)
        var b = DeterministicRandom(seed: 2)
        XCTAssertNotEqual(a.next(), b.next())
    }

    func testUnitStaysInRange() {
        var rng = DeterministicRandom(seed: 7)
        for _ in 0..<2_000 {
            let value = rng.unit()
            XCTAssertGreaterThanOrEqual(value, 0)
            XCTAssertLessThan(value, 1)
        }
    }

    func testIntRespectsBoundsAndHandlesInvertedRanges() {
        var rng = DeterministicRandom(seed: 9)
        for _ in 0..<2_000 {
            let value = rng.int(in: 3, 7)
            XCTAssertGreaterThanOrEqual(value, 3)
            XCTAssertLessThanOrEqual(value, 7)
        }
        XCTAssertEqual(rng.int(in: 5, 5), 5)
        XCTAssertEqual(rng.int(in: 9, 2), 9, "an inverted range returns the lower bound rather than trapping")
    }
}

final class WorkloadTests: XCTestCase {
    func testEmptyInputsProduceEmptyWorkloads() {
        XCTAssertTrue(Workload.synthetic(classes: [], count: 10, periodDuration: 100, seed: 1).items.isEmpty)
        XCTAssertTrue(Workload.synthetic(
            classes: StandardScenario.syntheticClasses, count: 0, periodDuration: 100, seed: 1
        ).items.isEmpty)
    }

    func testWorkloadIsReproducible() {
        let a = StandardScenario.workload
        let b = StandardScenario.workload
        XCTAssertEqual(a.items.count, StandardScenario.requestCount)
        XCTAssertEqual(a.items.map(\.request.id), b.items.map(\.request.id))
        XCTAssertEqual(a.items.map(\.actualCost), b.items.map(\.actualCost))
        XCTAssertEqual(a.items.map(\.wouldBeAccepted), b.items.map(\.wouldBeAccepted))
    }

    func testArrivalsAreOrderedAndInsideThePeriod() {
        let items = StandardScenario.workload.items
        var previous: TimeInterval = -1
        for item in items {
            XCTAssertGreaterThanOrEqual(item.offset, previous)
            XCTAssertLessThanOrEqual(item.offset, StandardScenario.periodDuration)
            previous = item.offset
        }
    }

    func testCostsStayInsideTheirClassBand() {
        let bands = Dictionary(
            uniqueKeysWithValues: StandardScenario.syntheticClasses.map {
                ($0.workClass.id, ($0.costFloor, $0.costCeiling))
            }
        )
        for item in StandardScenario.workload.items {
            guard let band = bands[item.request.workClassID] else {
                return XCTFail("unknown class \(item.request.workClassID)")
            }
            XCTAssertGreaterThanOrEqual(item.actualCost, band.0)
            XCTAssertLessThanOrEqual(item.actualCost, band.1)
        }
    }

    func testInvertedCostBandIsRepaired() {
        let synthetic = SyntheticClass(
            workClass: StandardScenario.feature,
            estimate: .dollars(1),
            costFloor: .dollars(9),
            costCeiling: .dollars(2),
            trueAcceptanceRate: 2.0
        )
        XCTAssertEqual(synthetic.costCeiling, .dollars(9))
        XCTAssertEqual(synthetic.trueAcceptanceRate, 1.0, "acceptance rate is clamped into 0...1")
    }
}

final class StandardScenarioTests: XCTestCase {
    /// The claim the article makes, asserted here so prose and code cannot drift.
    func testCapacityModelBuysMoreAcceptedOutcomesFromTheSameCeiling() {
        let result = StandardScenario.compare()
        XCTAssertGreaterThan(result.capacity.accepted, result.restriction.accepted)
        XCTAssertEqual(result.acceptedDelta, result.capacity.accepted - result.restriction.accepted)
    }

    func testNeitherPolicyExceedsTheCeiling() {
        let result = StandardScenario.compare()
        XCTAssertLessThanOrEqual(result.restriction.settledSpend, StandardScenario.ceiling)
        XCTAssertLessThanOrEqual(result.capacity.settledSpend, StandardScenario.ceiling)
    }

    func testRestrictionStarvesIncidentsAndTheCapacityModelDoesNot() {
        let result = StandardScenario.compare()
        let restrictionIncidentDenials = result.restriction.deniedByClass[StandardScenario.incident.id] ?? 0
        let capacityIncidentDenials = result.capacity.deniedByClass[StandardScenario.incident.id] ?? 0
        XCTAssertGreaterThan(restrictionIncidentDenials, 0)
        XCTAssertEqual(capacityIncidentDenials, 0)
    }

    func testCapacityModelLowersCostPerAcceptedOutcome() {
        let result = StandardScenario.compare()
        guard let restriction = result.restriction.costPerAcceptedOutcome,
              let capacity = result.capacity.costPerAcceptedOutcome else {
            return XCTFail("both policies should produce accepted outcomes")
        }
        XCTAssertLessThan(capacity, restriction)
    }

    func testComparisonIsDeterministic() {
        XCTAssertEqual(StandardScenario.compare(), StandardScenario.compare())
    }

    func testAdvantageSurvivesEveryRestrictionThreshold() {
        for threshold in stride(from: 0.60, through: 1.0, by: 0.05) {
            let result = StandardScenario.compare(restrictionThreshold: threshold)
            XCTAssertGreaterThan(
                result.capacity.accepted, result.restriction.accepted,
                "capacity model should win at a \(Int(threshold * 100))% cut-off too"
            )
        }
    }

    func testEveryRequestIsAccountedFor() {
        let result = StandardScenario.compare()
        for trial in [result.restriction, result.capacity] {
            XCTAssertEqual(
                trial.admitted + trial.deferred + trial.denied,
                StandardScenario.requestCount,
                "\(trial.policyName) dropped a request on the floor"
            )
            XCTAssertEqual(trial.accepted + trial.discarded, trial.admitted)
        }
    }

    func testPrintScenarioNumbersForTheWriteUp() {
        let result = StandardScenario.compare()
        func describe(_ trial: PolicyTrial) -> String {
            """
            \(trial.policyName): admitted=\(trial.admitted) deferred=\(trial.deferred) denied=\(trial.denied) \
            spent=\(trial.settledSpend) accepted=\(trial.accepted) discarded=\(trial.discarded) \
            perAccepted=\(trial.costPerAcceptedOutcome?.description ?? "-") \
            acceptedByClass=\(trial.acceptedByClass.sorted { $0.key < $1.key }) \
            deniedByClass=\(trial.deniedByClass.sorted { $0.key < $1.key })
            """
        }
        print("SCENARIO-NUMBERS " + describe(result.restriction))
        print("SCENARIO-NUMBERS " + describe(result.capacity))
        print("SCENARIO-NUMBERS delta=\(result.acceptedDelta) fraction=\(result.acceptedDeltaFraction ?? -1)")
        XCTAssertGreaterThan(result.capacity.accepted, 0)
    }
}
