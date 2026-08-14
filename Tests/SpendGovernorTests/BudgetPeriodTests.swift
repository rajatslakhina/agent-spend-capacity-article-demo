import XCTest
@testable import SpendGovernor

final class BudgetPeriodTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_767_225_600)

    private func period(ceiling: Micros = .dollars(1_000)) -> BudgetPeriod {
        BudgetPeriod(start: start, duration: 100, ceiling: ceiling)
    }

    func testElapsedFractionClampsBothEnds() {
        let p = period()
        XCTAssertEqual(p.elapsedFraction(at: start.addingTimeInterval(-50)), 0)
        XCTAssertEqual(p.elapsedFraction(at: start.addingTimeInterval(25)), 0.25, accuracy: 1e-12)
        XCTAssertEqual(p.elapsedFraction(at: start.addingTimeInterval(500)), 1)
    }

    func testZeroDurationIsCoercedRatherThanDividingByZero() {
        let p = BudgetPeriod(start: start, duration: 0, ceiling: .dollars(10))
        XCTAssertEqual(p.duration, 1)
        XCTAssertEqual(p.elapsedFraction(at: start.addingTimeInterval(10)), 1)
    }

    func testPacedAllowanceTracksElapsedFraction() {
        let p = period()
        XCTAssertEqual(p.pacedAllowance(at: start), .zero)
        XCTAssertEqual(p.pacedAllowance(at: start.addingTimeInterval(50)), .dollars(500))
        XCTAssertEqual(p.pacedAllowance(at: p.end), .dollars(1_000))
    }
}
