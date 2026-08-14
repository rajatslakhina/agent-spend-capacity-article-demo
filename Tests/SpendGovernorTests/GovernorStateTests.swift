import XCTest
@testable import SpendGovernor

final class GovernorStateTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_767_225_600)

    private func makeState(ceiling: Micros = .dollars(100)) -> GovernorState {
        GovernorState(
            period: BudgetPeriod(start: start, duration: 1_000, ceiling: ceiling),
            classes: StandardScenario.classes
        )
    }

    private func reservation(_ id: String, _ classID: String, _ held: Micros) -> Reservation {
        Reservation(id: id, workClassID: classID, held: held, openedAt: start)
    }

    func testInFlightHoldsCountAgainstRemaining() throws {
        var state = makeState()
        XCTAssertEqual(state.remaining, .dollars(100))
        state = try state.opening(reservation("a", "feature", .dollars(30)))
        XCTAssertEqual(state.heldInFlight, .dollars(30))
        XCTAssertEqual(state.encumbered, .dollars(30))
        XCTAssertEqual(state.remaining, .dollars(70),
                       "money held by a running agent is not available to the next one")
    }

    func testDuplicateReservationThrows() throws {
        var state = makeState()
        state = try state.opening(reservation("a", "feature", .dollars(1)))
        XCTAssertThrowsError(try state.opening(reservation("a", "feature", .dollars(1)))) { error in
            XCTAssertEqual(error as? GovernorError, .duplicateReservation("a"))
        }
    }

    func testSettlingUnknownReservationThrows() {
        let state = makeState()
        XCTAssertThrowsError(
            try state.settling(reservationID: "ghost", actual: .dollars(1), outcome: .accepted)
        ) { error in
            XCTAssertEqual(error as? GovernorError, .unknownReservation("ghost"))
        }
    }

    func testSettlingReleasesTheHoldAndBooksTheActual() throws {
        var state = makeState()
        state = try state.opening(reservation("a", "feature", .dollars(30)))
        state = try state.settling(reservationID: "a", actual: .dollars(12), outcome: .accepted)
        XCTAssertEqual(state.heldInFlight, .zero)
        XCTAssertEqual(state.settledThisPeriod, .dollars(12))
        XCTAssertEqual(state.remaining, .dollars(88),
                       "over-holding is refunded when the real number arrives")
    }

    func testOverrunIsBookedAtActualNotAtHold() throws {
        var state = makeState()
        state = try state.opening(reservation("a", "feature", .dollars(10)))
        state = try state.settling(reservationID: "a", actual: .dollars(25), outcome: .accepted)
        XCTAssertEqual(state.settledThisPeriod, .dollars(25))
        XCTAssertEqual(state.remaining, .dollars(75))
    }

    func testRollingResetsMoneyAndKeepsEvidence() throws {
        var state = makeState()
        state = try state.opening(reservation("a", "review", .dollars(4)))
        state = try state.settling(reservationID: "a", actual: .dollars(4), outcome: .accepted)
        state = try state.opening(reservation("b", "feature", .dollars(9)))

        let next = BudgetPeriod(start: start.addingTimeInterval(1_000), duration: 1_000, ceiling: .dollars(100))
        let rolled = state.rolling(into: next)

        XCTAssertEqual(rolled.settledThisPeriod, .zero, "money resets at the boundary")
        XCTAssertEqual(rolled.stats(for: "review").acceptedCount, 1, "evidence does not")
        XCTAssertEqual(rolled.openReservations.count, 1,
                       "an agent mid-run does not lose its hold to the calendar")
        XCTAssertEqual(rolled.remaining, .dollars(91))
    }

    func testCalibratedEstimateScalesByObservedError() throws {
        var state = makeState(ceiling: .dollars(10_000))
        for index in 0..<6 {
            state = try state.opening(reservation("r\(index)", "feature", .dollars(10)))
            state = try state.settling(reservationID: "r\(index)", actual: .dollars(20), outcome: .accepted)
        }
        let request = WorkRequest(id: "next", workClassID: "feature", estimate: .dollars(10))
        XCTAssertEqual(
            state.calibratedEstimate(for: request, calibration: .standard),
            .dollars(20),
            "a class that consistently doubles its estimate gets held at double"
        )
    }

    func testCalibrationIsClampedAtTheUpperBound() throws {
        var state = makeState(ceiling: .dollars(10_000))
        for index in 0..<6 {
            state = try state.opening(reservation("r\(index)", "feature", .dollars(1)))
            state = try state.settling(reservationID: "r\(index)", actual: .dollars(50), outcome: .accepted)
        }
        let request = WorkRequest(id: "next", workClassID: "feature", estimate: .dollars(10))
        XCTAssertEqual(
            state.calibratedEstimate(for: request, calibration: .standard),
            .dollars(30),
            "clamped at 3x so one pathological run cannot lock the class out"
        )
    }

    func testCalibrationNoneLeavesTheEstimateAlone() throws {
        var state = makeState(ceiling: .dollars(10_000))
        for index in 0..<10 {
            state = try state.opening(reservation("r\(index)", "feature", .dollars(1)))
            state = try state.settling(reservationID: "r\(index)", actual: .dollars(5), outcome: .accepted)
        }
        let request = WorkRequest(id: "next", workClassID: "feature", estimate: .dollars(7))
        XCTAssertEqual(state.calibratedEstimate(for: request, calibration: .none), .dollars(7))
    }

    func testYieldRankingIsTotalAndTieBreaksOnID() {
        let state = makeState()
        let ranking = state.yieldRanking()
        XCTAssertEqual(ranking.count, 4)
        XCTAssertEqual(ranking, ["exploration", "feature", "incident", "review"],
                       "with identical priors the order is alphabetical, not arbitrary")
        XCTAssertEqual(state.yieldRanking(), ranking, "ranking is stable across calls")
    }

    func testYieldRankingFollowsEvidence() throws {
        var state = makeState(ceiling: .dollars(10_000))
        // review: cheap and kept. exploration: expensive and thrown away.
        for index in 0..<20 {
            state = try state.opening(reservation("rv\(index)", "review", .dollars(1)))
            state = try state.settling(reservationID: "rv\(index)", actual: .dollars(1), outcome: .accepted)
            state = try state.opening(reservation("ex\(index)", "exploration", .dollars(8)))
            state = try state.settling(reservationID: "ex\(index)", actual: .dollars(8), outcome: .discarded)
        }
        let ranking = state.yieldRanking()
        XCTAssertEqual(ranking.first, "review")
        XCTAssertEqual(ranking.last, "exploration")
    }

    func testUnknownWorkClassLookupIsNilNotACrash() {
        XCTAssertNil(makeState().workClass("does-not-exist"))
        XCTAssertEqual(makeState().stats(for: "does-not-exist").settledCount, 0)
    }
}
