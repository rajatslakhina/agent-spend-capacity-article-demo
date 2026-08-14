import Foundation

/// Deterministic pseudo-random source (SplitMix64), so every number this
/// library reports is reproducible from a seed on any machine.
public struct DeterministicRandom: Sendable {
    private var state: UInt64
    public init(seed: UInt64) { self.state = seed }

    public mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    /// Uniform in `0..<1`.
    public mutating func unit() -> Double {
        Double(next() >> 11) * (1.0 / 9007199254740992.0)
    }

    /// Uniform integer in `lower...upper`. Returns `lower` for an inverted range.
    public mutating func int(in lower: Int, _ upper: Int) -> Int {
        guard upper > lower else { return lower }
        let span = UInt64(upper - lower + 1)
        return lower + Int(next() % span)
    }
}

/// A synthetic month of agent traffic, used to compare policies on identical input.
public struct Workload: Sendable {
    public struct Item: Sendable {
        public let request: WorkRequest
        public let offset: TimeInterval
        /// What the run really costs if it is allowed to happen.
        public let actualCost: Micros
        /// Whether this run would produce something worth keeping.
        public let wouldBeAccepted: Bool
    }

    public let items: [Item]

    public init(items: [Item]) { self.items = items }

    /// Builds a month of traffic across the supplied classes.
    ///
    /// Each class carries a true acceptance rate and a true cost band. The
    /// governor is never told either — it has to infer them from settlements,
    /// which is the entire point.
    public static func synthetic(
        classes: [SyntheticClass],
        count: Int,
        periodDuration: TimeInterval,
        seed: UInt64
    ) -> Workload {
        guard !classes.isEmpty, count > 0 else { return Workload(items: []) }
        var rng = DeterministicRandom(seed: seed)
        var items: [Item] = []
        items.reserveCapacity(count)

        for index in 0..<count {
            let pick = rng.int(in: 0, classes.count - 1)
            guard pick >= 0, pick < classes.count else { continue }
            let synthetic = classes[pick]
            let cost = Micros(rng.int(in: synthetic.costFloor.raw, synthetic.costCeiling.raw))
            let accepted = rng.unit() < synthetic.trueAcceptanceRate
            // Requests arrive evenly across the period, plus jitter inside the slot.
            let slot = periodDuration / Double(count)
            let offset = slot * Double(index) + slot * rng.unit()
            items.append(Item(
                request: WorkRequest(
                    id: "req-\(index)",
                    workClassID: synthetic.workClass.id,
                    estimate: synthetic.estimate
                ),
                offset: offset,
                actualCost: cost,
                wouldBeAccepted: accepted
            ))
        }
        return Workload(items: items)
    }
}

public struct SyntheticClass: Sendable {
    public let workClass: WorkClass
    /// What callers claim a run will cost.
    public let estimate: Micros
    public let costFloor: Micros
    public let costCeiling: Micros
    /// Ground truth the governor never sees.
    public let trueAcceptanceRate: Double

    public init(
        workClass: WorkClass,
        estimate: Micros,
        costFloor: Micros,
        costCeiling: Micros,
        trueAcceptanceRate: Double
    ) {
        self.workClass = workClass
        self.estimate = estimate
        self.costFloor = costFloor
        self.costCeiling = max(costFloor, costCeiling)
        self.trueAcceptanceRate = min(1, max(0, trueAcceptanceRate))
    }
}

/// Replays one workload against one policy and reports what the budget bought.
public struct PolicyTrial: Sendable, Equatable {
    public let policyName: String
    public let admitted: Int
    public let deferred: Int
    public let denied: Int
    public let settledSpend: Micros
    public let accepted: Int
    public let discarded: Int
    public let acceptedByClass: [String: Int]
    public let deniedByClass: [String: Int]

    /// Realised cost per accepted outcome across the whole period.
    public var costPerAcceptedOutcome: Micros? {
        guard accepted > 0 else { return nil }
        return Micros(settledSpend.raw / accepted)
    }
}

public enum PolicyHarness {
    /// Runs `workload` against `policy` synchronously and deterministically.
    ///
    /// Settlement happens immediately after admission, which models a serial
    /// agent queue. That is a simplification and it is stated rather than
    /// hidden: it removes in-flight overlap, so both policies are compared on
    /// the same, slightly optimistic, footing.
    public static func run(
        workload: Workload,
        classes: [WorkClass],
        period: BudgetPeriod,
        policy: AdmissionPolicy
    ) -> PolicyTrial {
        var state = GovernorState(period: period, classes: classes)
        var admitted = 0, deferredCount = 0, denied = 0
        var acceptedByClass: [String: Int] = [:]
        var deniedByClass: [String: Int] = [:]

        for item in workload.items {
            let now = period.start.addingTimeInterval(item.offset)
            let decision = policy.decide(item.request, state: state, now: now)

            switch decision {
            case .admit(let reservation):
                admitted += 1
                guard let opened = try? state.opening(reservation) else { continue }
                state = opened
                let outcome: Outcome = item.wouldBeAccepted ? .accepted : .discarded
                guard let settled = try? state.settling(
                    reservationID: reservation.id,
                    actual: item.actualCost,
                    outcome: outcome
                ) else { continue }
                state = settled
                if outcome == .accepted {
                    acceptedByClass[item.request.workClassID, default: 0] += 1
                }
            case .deferred:
                deferredCount += 1
            case .deny:
                denied += 1
                deniedByClass[item.request.workClassID, default: 0] += 1
            }
        }

        let report = SpendReport(state: state)
        return PolicyTrial(
            policyName: policy.name,
            admitted: admitted,
            deferred: deferredCount,
            denied: denied,
            settledSpend: report.settled,
            accepted: report.totalAccepted,
            discarded: report.totalDiscarded,
            acceptedByClass: acceptedByClass,
            deniedByClass: deniedByClass
        )
    }
}
