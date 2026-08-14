# SpendGovernor

**A capacity model for metered coding agents.** A monthly token cap tells you
*when* to stop. It cannot tell you *what* to stop. This library is the part that
decides what to stop.

Companion code for a Medium article on capacity models for metered coding agents.

---

## The idea in one paragraph

When an AI coding agent bills by the token, spend becomes an admission-control
problem, not a procurement one. The unit worth budgeting is not the token — it is
the **accepted outcome**: the change that survived review and got merged. A
threshold policy is indifferent to that distinction, which is why it denies an
incident hotfix and an exploratory refactor with equal enthusiasm — in this
scenario, from day 15.2 onward. `SpendGovernor` admits work by reserve, pace and
observed yield instead.

## What is in it

| Type | Job |
|---|---|
| `Micros` | Integer money. Exact sums and orderings; no float drift in a number people argue about. |
| `WorkClass` / `AcceptancePrior` | The unit of policy. Pseudo-count prior so a class with one lucky outcome cannot jump the ranking. |
| `GovernorState` | The whole world as a value. Admission is a pure function of this. |
| `ClassStats` | Evidence that survives the period boundary: spend, outcomes, estimate error. |
| `AdmissionPolicy` | `AccessRestrictionPolicy` (cap, then stop) and `CapacityPolicy` (reserve · pace · yield). |
| `Governor` | Actor shell. Serialises mutation so two concurrent runs cannot both be told there is room for one more. |
| `PolicyHarness` / `StandardScenario` | Deterministic replay. Every *result* below is printed by `swift test`; the ceiling, request count and acceptance rates are constants in `StandardScenario`. |

The load-bearing structural decision: **admission is a pure function of a
snapshot, and the actor owns nothing but the snapshot.** The signature gives a
policy nothing to await and nothing to fetch — it is *handed* the time rather
than reading one. Nothing stops a rogue conformance calling `Date()`; the
convention is that it does not, and the payoff is that every decision is
reproducible from a struct you can print into a test failure. The first question
anyone asks a budget system is "why did it say no to me," and this is the design
that can answer it.

```swift
let governor = Governor(
    state: GovernorState(period: period, classes: StandardScenario.classes),
    policy: CapacityPolicy(configuration: .init(reserveFraction: 0.2))
)

switch await governor.request(request, now: .now) {
case .admit(let reservation):
    let cost = try await runAgent()
    try await governor.settle(
        reservationID: reservation.id, actual: cost, outcome: merged ? .accepted : .discarded
    )
case .deferred(let retryAfter, _):
    schedule(request, after: retryAfter)   // queued, not killed
case .deny(let reason):
    report(reason)
}
```

## The numbers

400 agent runs across 30 days, a $1,200 ceiling, one seeded request stream,
replayed under both policies. Ground truth (each class's real cost band and real
acceptance rate) is never shown to the governor — it has to infer it from
settlements.

| Policy | Accepted | Spent | Cost per accepted | Incidents denied |
|---|---|---|---|---|
| Access restriction, 85% cut-off | 98 | $1,028.13 | $10.49 | 44 |
| Access restriction, no cut-off | 116 | $1,200.48 \* | $10.34 | 36 |
| **Capacity model** | **160** | **$1,039.58** | **$6.49** | **0** |

\* Yes, that is past the $1,200 ceiling. A policy that holds the caller's
estimate and settles the real cost does not actually cap anything —
`CalibrationEffectTests` exists to pin that behaviour down.

Against the *fairest* threshold policy — no early cut-off, spend until the
ceiling is gone — the capacity model delivered **44 more accepted outcomes
(+37.9%)** and never refused an incident run. `TimelineTests` records when each
policy starts saying no: the 85% cut-off refuses its first request on day 15.2
and its first incident run on day 15.4; the capacity model never refuses an
incident run at all.

**The caveat that most affects those numbers:** `PolicyHarness` never retries a
deferral. 82 requests were deferred under the capacity model and none came
back, so its $1,039.58 is a floor, not a total. In a real system they retry,
land later, and cost money.

### Leave-one-out, including the part that loses

| Variant | Accepted | Spent | Incidents denied |
|---|---|---|---|
| Full policy | 160 | $1,039.58 | 0 |
| No reserve | **177** | $1,199.35 | 1 |
| No yield gate | 133 | $1,150.89 | 0 |
| No calibration | 160 | $1,039.58 | 0 |

Two honest results:

- **The reserve costs 17 of the 177 accepted outcomes the unreserved policy
  delivers** — 9.6% of that figure, 10.6% of the 160 the shipped design
  delivers — to prevent exactly one incident denial in this workload. Whether that is worth it depends on what one
  denied incident costs you — which is the point. Make the trade explicitly.
- **Calibration does nothing here**, because `PolicyHarness` settles every
  reservation immediately, so holds never overlap and the held amount never
  binds. It earns its place only under concurrency — `CalibrationEffectTests`
  shows an uncalibrated cap overrunning its own ceiling and calibration pulling
  it back. One third of this design is inert in its own benchmark, and saying so
  is cheaper than having a reader find it.

Reproduce all of it with `swift test`: the policy comparison and leave-one-out
are printed by `testPrintAblationForTheWriteUp`, and the day-of-month figures by
`testPrintTimelineForTheWriteUp` in `TimelineTests`.

## How to run it

```
git clone https://github.com/rajatslakhina/agent-spend-capacity-article-demo.git
cd agent-spend-capacity-article-demo
open Demo.xcodeproj      # pick any iOS Simulator, Build & Run
```

No second repo, no package resolution step — `Demo.xcodeproj` consumes the
library through a local package reference at `.`. For the library alone,
`swift build` and `swift test` work anywhere Swift 6 runs, including Linux.

## Verification status

Stated plainly, because a demo that claims more than it did is worse than no demo.

- ✅ `swift build` — clean, Swift 6.0.3 (Linux)
- ✅ `swift test` — **80 tests, 0 failures**
- ✅ `Package.swift` declares library + test targets only. No `.executableTarget`
  — that pattern reliably crashes on launch with a nil bundle identifier.
- ✅ `Demo.xcodeproj/project.pbxproj` hand-authored and structurally audited:
  balanced delimiters, 20 object ids, zero dangling references, shared
  `Demo.xcscheme` committed.
- ❌ **Not run on a Simulator. No screenshots exist.** Computer-use access cannot
  be approved inside an unattended scheduled run, so the app was never launched
  and `SpendGovernorUI` has never been compiled by anybody. On Linux it compiles
  to an empty module behind `#if canImport(SwiftUI)`. See
  `Demo/Screenshots/README.md`.

## Source

The article this accompanies argues with, not against,
[Gartner's 24 June 2026 press release on AI coding costs](https://www.gartner.com/en/newsroom/press-releases/2026-06-24-gartner-predicts-ai-coding-costs-will-surpass-average-developer-salary-by-2028-as-token-consumption-surges).
Token thresholds are the fourth of Gartner's five recommendations, and their
list actually opens by telling you to classify development work by execution
model — which is closer to this library's argument than to a cap. But item four
is the one that ships. This library is a claim about what has to sit underneath
it.

MIT licensed.
