import XCTest
@testable import SpendGovernor

/// When, in the month, does each policy start saying no?
///
/// The article quotes a day number. This test is where that number comes from,
/// so the prose and the simulation cannot drift apart.
final class TimelineTests: XCTestCase {
    private struct FirstRefusals {
        var firstDenialDay: Double?
        var firstIncidentDenialDay: Double?
        var deferredCount: Int
        var deferredSpendClaim: Micros
    }

    private func firstRefusals(policy: AdmissionPolicy) -> FirstRefusals {
        var state = GovernorState(period: StandardScenario.period, classes: StandardScenario.classes)
        var result = FirstRefusals(
            firstDenialDay: nil, firstIncidentDenialDay: nil,
            deferredCount: 0, deferredSpendClaim: .zero
        )
        let day = 24.0 * 60 * 60

        for item in StandardScenario.workload.items {
            let now = StandardScenario.periodStart.addingTimeInterval(item.offset)
            switch policy.decide(item.request, state: state, now: now) {
            case .admit(let reservation):
                guard let opened = try? state.opening(reservation) else { continue }
                state = opened
                guard let settled = try? state.settling(
                    reservationID: reservation.id,
                    actual: item.actualCost,
                    outcome: item.wouldBeAccepted ? .accepted : .discarded
                ) else { continue }
                state = settled
            case .deferred:
                result.deferredCount += 1
                result.deferredSpendClaim = result.deferredSpendClaim + item.actualCost
            case .deny:
                if result.firstDenialDay == nil {
                    result.firstDenialDay = item.offset / day
                }
                if item.request.workClassID == StandardScenario.incident.id,
                   result.firstIncidentDenialDay == nil {
                    result.firstIncidentDenialDay = item.offset / day
                }
            }
        }
        return result
    }

    func testThresholdStartsRefusingBeforeTheMonthIsHalfSpent() {
        let refusals = firstRefusals(policy: AccessRestrictionPolicy(restrictionThreshold: 0.85))
        guard let firstDenial = refusals.firstDenialDay,
              let firstIncident = refusals.firstIncidentDenialDay else {
            return XCTFail("expected the 85% cut-off to deny something")
        }
        XCTAssertLessThan(firstDenial, 16.0, "the cap trips around the middle of the month, not near the end")
        XCTAssertLessThan(firstIncident, 16.0)
        XCTAssertGreaterThan(firstDenial, 14.0)
    }

    func testCapacityModelNeverDeniesAnIncidentAtAnyPointInTheMonth() {
        let refusals = firstRefusals(policy: CapacityPolicy())
        XCTAssertNil(refusals.firstIncidentDenialDay)
    }

    /// The harness never retries a deferral, so a deferred request is a request
    /// that never ran. Recorded here rather than glossed over in the write-up.
    func testDeferredRequestsAreNeverRetriedByTheHarness() {
        let refusals = firstRefusals(policy: CapacityPolicy())
        XCTAssertGreaterThan(refusals.deferredCount, 0)
        XCTAssertEqual(refusals.deferredCount, 82)
        XCTAssertGreaterThan(refusals.deferredSpendClaim, .zero,
                             "work worth this much was shelved, not paid for")
    }

    func testPrintTimelineForTheWriteUp() {
        for (name, policy) in [
            ("restriction-85", AnyAdmissionPolicy(AccessRestrictionPolicy(restrictionThreshold: 0.85))),
            ("restriction-100", AnyAdmissionPolicy(AccessRestrictionPolicy(restrictionThreshold: 1.0))),
            ("capacity-full", AnyAdmissionPolicy(CapacityPolicy()))
        ] {
            let r = firstRefusals(policy: policy)
            print("TIMELINE \(name) firstDenialDay=\(r.firstDenialDay.map { String(format: "%.2f", $0) } ?? "-") " +
                  "firstIncidentDenialDay=\(r.firstIncidentDenialDay.map { String(format: "%.2f", $0) } ?? "-") " +
                  "deferred=\(r.deferredCount) deferredWorkValue=\(r.deferredSpendClaim)")
        }
        XCTAssertTrue(true)
    }
}

private struct AnyAdmissionPolicy: AdmissionPolicy {
    let name: String
    private let body: @Sendable (WorkRequest, GovernorState, Date) -> AdmissionDecision
    init<P: AdmissionPolicy>(_ p: P) { name = p.name; body = { p.decide($0, state: $1, now: $2) } }
    func decide(_ r: WorkRequest, state: GovernorState, now: Date) -> AdmissionDecision { body(r, state, now) }
}
