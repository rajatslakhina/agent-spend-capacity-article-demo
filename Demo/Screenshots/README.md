# Screenshots — none, and here is why

This folder is empty on purpose.

The demo app was **not run on a Simulator** during the automated run that produced
this repository. Computer-use access (which is what would drive Xcode and the
Simulator) cannot be approved inside an unattended scheduled run — the request
returns *"can't be approved during a scheduled run"*, so not even a screenshot of
the screen was possible, let alone a build.

Rather than ship a mock-up and call it evidence, the folder stays empty and the
gap is stated in the top-level `README.md` under **Verification status**.

What *was* verified, on Linux with Swift 6.0.3:

- `swift build` — clean
- `swift test` — 76 tests, 0 failures

`SpendGovernorUI` is guarded by `#if canImport(SwiftUI)`, so on Linux it compiles
to an empty module. **It has never been compiled by anyone.** If you clone this
and run it, you are the first — and if it does not build, that is a real bug and
an issue is welcome.
