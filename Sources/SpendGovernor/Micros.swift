import Foundation

/// Money in millionths of a unit of currency.
///
/// Integer money on purpose. Every number this library reports — remaining
/// budget, pace allowance, cost per accepted outcome — is either compared for
/// ordering or summed across thousands of entries, and both operations are
/// exact in `Int` and only approximately exact in `Double`. A capacity model
/// whose arithmetic drifts is a capacity model nobody trusts twice.
public struct Micros: Hashable, Comparable, Sendable, ExpressibleByIntegerLiteral, CustomStringConvertible {
    public let raw: Int

    public init(_ raw: Int) { self.raw = raw }
    public init(integerLiteral value: Int) { self.raw = value }

    /// Construct from whole currency units (e.g. `Micros.dollars(12)` == 12_000_000).
    public static func dollars(_ whole: Int) -> Micros { Micros(whole * 1_000_000) }
    /// Construct from cents.
    public static func cents(_ cents: Int) -> Micros { Micros(cents * 10_000) }

    public static let zero = Micros(0)

    public static func < (lhs: Micros, rhs: Micros) -> Bool { lhs.raw < rhs.raw }
    public static func + (lhs: Micros, rhs: Micros) -> Micros { Micros(lhs.raw + rhs.raw) }
    public static func - (lhs: Micros, rhs: Micros) -> Micros { Micros(lhs.raw - rhs.raw) }
    public static func * (lhs: Micros, rhs: Int) -> Micros { Micros(lhs.raw * rhs) }

    /// Scales by a fraction using integer arithmetic, rounding toward zero.
    /// Negative and non-finite fractions collapse to `.zero` rather than trapping.
    public func scaled(by fraction: Double) -> Micros {
        guard fraction.isFinite, fraction > 0 else { return .zero }
        return Micros(Int((Double(raw) * fraction).rounded(.towardZero)))
    }

    /// `self / other` as a ratio. Returns `nil` when `other` is zero, so callers
    /// have to decide what a divide-by-zero means instead of inheriting `inf`.
    public func ratio(to other: Micros) -> Double? {
        guard other.raw != 0 else { return nil }
        return Double(raw) / Double(other.raw)
    }

    public var dollarsValue: Double { Double(raw) / 1_000_000 }

    public var description: String {
        let sign = raw < 0 ? "-" : ""
        let magnitude = abs(raw)
        let whole = magnitude / 1_000_000
        let cents = (magnitude % 1_000_000) / 10_000
        return "\(sign)$\(whole).\(cents < 10 ? "0" : "")\(cents)"
    }
}
