import XCTest
@testable import SpendGovernor

final class MicrosTests: XCTestCase {
    func testDollarsAndCentsConstruction() {
        XCTAssertEqual(Micros.dollars(12).raw, 12_000_000)
        XCTAssertEqual(Micros.cents(60).raw, 600_000)
        XCTAssertEqual(Micros.dollars(0), .zero)
    }

    func testArithmeticIsExact() {
        let sum = Micros.cents(10) + Micros.cents(20)
        XCTAssertEqual(sum, Micros.cents(30))
        XCTAssertEqual(Micros.dollars(5) - Micros.dollars(2), Micros.dollars(3))
        XCTAssertEqual(Micros.dollars(3) * 4, Micros.dollars(12))
    }

    func testScaledRoundsTowardZeroAndRejectsNonsense() {
        XCTAssertEqual(Micros.dollars(100).scaled(by: 0.2), Micros.dollars(20))
        XCTAssertEqual(Micros(7).scaled(by: 0.5), Micros(3), "rounds toward zero, never up")
        XCTAssertEqual(Micros.dollars(100).scaled(by: -1), .zero)
        XCTAssertEqual(Micros.dollars(100).scaled(by: .nan), .zero)
        XCTAssertEqual(Micros.dollars(100).scaled(by: .infinity), .zero)
    }

    func testRatioReturnsNilRatherThanInfinity() {
        XCTAssertNil(Micros.dollars(5).ratio(to: .zero))
        guard let ratio = Micros.dollars(6).ratio(to: .dollars(3)) else {
            return XCTFail("expected a ratio")
        }
        XCTAssertEqual(ratio, 2.0, accuracy: 1e-9)
    }

    func testDescriptionPadsCents() {
        XCTAssertEqual(Micros.dollars(12).description, "$12.00")
        XCTAssertEqual(Micros.cents(1205).description, "$12.05")
        XCTAssertEqual(Micros(-1_500_000).description, "-$1.50")
    }

    func testOrdering() {
        XCTAssertTrue(Micros.cents(99) < Micros.dollars(1))
        XCTAssertEqual(min(Micros.dollars(2), Micros.dollars(1)), Micros.dollars(1))
    }
}
