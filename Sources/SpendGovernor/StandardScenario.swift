import Foundation

/// The scenario the article's numbers come from.
///
/// Four classes with different economics, one month, one ceiling, one seeded
/// request stream. `compare()` produces the head-to-head figures; the
/// leave-one-out variants come from `AblationTests` and the day-of-month
/// figures from `TimelineTests`. Nothing quoted in the write-up is invented —
/// but three test files, not this one, produce it.
public enum StandardScenario {
    public static let incident = WorkClass(
        id: "incident",
        priority: 100,
        prior: .neutral(costPerOutcome: .dollars(4))
    )
    public static let review = WorkClass(
        id: "review",
        priority: 60,
        prior: .neutral(costPerOutcome: .dollars(4))
    )
    public static let feature = WorkClass(
        id: "feature",
        priority: 50,
        prior: .neutral(costPerOutcome: .dollars(4))
    )
    public static let exploration = WorkClass(
        id: "exploration",
        priority: 10,
        prior: .neutral(costPerOutcome: .dollars(4))
    )

    public static var classes: [WorkClass] { [incident, review, feature, exploration] }

    /// Ground truth. Exploration is expensive and usually thrown away; review is
    /// cheap and usually kept. Neither fact is given to the governor.
    public static var syntheticClasses: [SyntheticClass] {
        [
            SyntheticClass(
                workClass: incident, estimate: .dollars(3),
                costFloor: .dollars(2), costCeiling: .dollars(6),
                trueAcceptanceRate: 0.85
            ),
            SyntheticClass(
                workClass: review, estimate: .dollars(1),
                costFloor: .cents(60), costCeiling: .dollars(2),
                trueAcceptanceRate: 0.70
            ),
            SyntheticClass(
                workClass: feature, estimate: .dollars(4),
                costFloor: .dollars(3), costCeiling: .dollars(9),
                trueAcceptanceRate: 0.45
            ),
            SyntheticClass(
                workClass: exploration, estimate: .dollars(5),
                costFloor: .dollars(4), costCeiling: .dollars(14),
                trueAcceptanceRate: 0.12
            )
        ]
    }

    public static let requestCount = 400
    public static let seed: UInt64 = 0xA17E_5EED
    public static let periodDuration: TimeInterval = 30 * 24 * 60 * 60
    public static let ceiling = Micros.dollars(1_200)
    public static let periodStart = Date(timeIntervalSince1970: 1_767_225_600) // 2026-01-01T00:00:00Z

    public static var period: BudgetPeriod {
        BudgetPeriod(start: periodStart, duration: periodDuration, ceiling: ceiling)
    }

    public static var workload: Workload {
        Workload.synthetic(
            classes: syntheticClasses,
            count: requestCount,
            periodDuration: periodDuration,
            seed: seed
        )
    }

    public struct Comparison: Sendable, Equatable {
        public let restriction: PolicyTrial
        public let capacity: PolicyTrial

        /// Extra accepted outcomes the capacity model bought with the same ceiling.
        public var acceptedDelta: Int { capacity.accepted - restriction.accepted }

        public var acceptedDeltaFraction: Double? {
            guard restriction.accepted > 0 else { return nil }
            return Double(acceptedDelta) / Double(restriction.accepted)
        }
    }

    public static func compare(
        restrictionThreshold: Double = 0.85,
        capacityConfiguration: CapacityPolicy.Configuration = .standard
    ) -> Comparison {
        let load = workload
        return Comparison(
            restriction: PolicyHarness.run(
                workload: load, classes: classes, period: period,
                policy: AccessRestrictionPolicy(restrictionThreshold: restrictionThreshold)
            ),
            capacity: PolicyHarness.run(
                workload: load, classes: classes, period: period,
                policy: CapacityPolicy(configuration: capacityConfiguration)
            )
        )
    }
}
