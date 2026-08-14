#if canImport(SwiftUI)
import SwiftUI
import SpendGovernor

/// Side-by-side replay of one month of agent traffic under two budget policies.
///
/// The slider is the point of the screen: drag the cut-off and watch the
/// access-restriction column stop paying for incidents while the capacity
/// column keeps clearing them out of the reserve.
public struct GovernorDemoView: View {
    @State private var restrictionThreshold: Double = 0.85
    @State private var reserveFraction: Double = 0.2

    public init() {}

    private var comparison: StandardScenario.Comparison {
        StandardScenario.compare(
            restrictionThreshold: restrictionThreshold,
            capacityConfiguration: .init(reserveFraction: reserveFraction)
        )
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    controls
                    let result = comparison
                    HStack(alignment: .top, spacing: 12) {
                        TrialCard(title: "Access restriction", subtitle: "cap, then stop", trial: result.restriction, tint: .orange)
                        TrialCard(title: "Capacity model", subtitle: "reserve · pace · yield", trial: result.capacity, tint: .green)
                    }
                    verdict(result)
                    starvation(result)
                }
                .padding(20)
            }
            .navigationTitle("Spend Governor")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Same ceiling. Same requests.")
                .font(.title2.bold())
            Text("\(StandardScenario.requestCount) agent runs across 30 days against a \(StandardScenario.ceiling.description) ceiling, replayed under both policies from one seeded stream. Deferred runs are shelved, not retried.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 14) {
            LabeledSlider(
                label: "Restriction cut-off",
                value: $restrictionThreshold,
                range: 0.5...1.0,
                display: "\(Int(restrictionThreshold * 100))% of ceiling"
            )
            LabeledSlider(
                label: "Reserve for priority work",
                value: $reserveFraction,
                range: 0.0...0.5,
                display: "\(Int(reserveFraction * 100))% of ceiling"
            )
        }
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private func verdict(_ result: StandardScenario.Comparison) -> some View {
        let delta = result.acceptedDelta
        let pct = result.acceptedDeltaFraction.map { "\(Int(($0 * 100).rounded()))%" } ?? "—"
        return VStack(alignment: .leading, spacing: 6) {
            Text(delta >= 0 ? "Capacity model bought \(delta) more accepted outcomes (\(pct))"
                            : "Capacity model bought \(-delta) fewer accepted outcomes")
                .font(.headline)
            Text("Both policies draw on the same ceiling — though a threshold that holds the caller's estimate and settles the real cost can overshoot it. The difference is which requests got the money.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
    }

    private func starvation(_ result: StandardScenario.Comparison) -> some View {
        let restrictionIncidents = result.restriction.deniedByClass[StandardScenario.incident.id] ?? 0
        let capacityIncidents = result.capacity.deniedByClass[StandardScenario.incident.id] ?? 0
        return VStack(alignment: .leading, spacing: 8) {
            Text("Incident requests denied")
                .font(.headline)
            HStack {
                Label("\(restrictionIncidents)", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(restrictionIncidents > 0 ? .orange : .secondary)
                Text("access restriction").foregroundStyle(.secondary)
                Spacer()
                Label("\(capacityIncidents)", systemImage: "checkmark.shield.fill")
                    .foregroundStyle(capacityIncidents > 0 ? .orange : .green)
                Text("capacity model").foregroundStyle(.secondary)
            }
            .font(.subheadline)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct LabeledSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let display: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.subheadline.weight(.medium))
                Spacer()
                Text(display).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range)
        }
    }
}

private struct TrialCard: View {
    let title: String
    let subtitle: String
    let trial: PolicyTrial
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            Row(name: "Accepted", value: "\(trial.accepted)", emphasised: true)
            Row(name: "Discarded", value: "\(trial.discarded)")
            Row(name: "Spent", value: trial.settledSpend.description)
            Row(name: "Per accepted", value: trial.costPerAcceptedOutcome?.description ?? "—")
            Row(name: "Denied", value: "\(trial.denied)")
            Row(name: "Deferred", value: "\(trial.deferred)")
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(tint.opacity(0.35)))
    }

    private struct Row: View {
        let name: String
        let value: String
        var emphasised: Bool = false

        var body: some View {
            HStack {
                Text(name).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(value)
                    .font(emphasised ? .title3.bold().monospacedDigit() : .subheadline.monospacedDigit())
            }
        }
    }
}

#Preview {
    GovernorDemoView()
}
#endif
