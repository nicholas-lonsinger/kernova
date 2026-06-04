# Testing

How tests are organized, written, and kept stable. The build/test commands themselves are in [CLAUDE.md](../CLAUDE.md#build--test).

## Test targets and the test plan

A single `xcodebuild test -scheme Kernova` (what `make test` runs) covers all three test targets — `KernovaTests`, `KernovaGuestAgentTests`, and `KernovaProtocolTests` — via `Kernova.xctestplan`. This works because `KernovaProtocol` is referenced as a top-level peer in the project (a `PBXFileReference` in `Kernova.xcodeproj`'s main group) rather than as an `XCLocalSwiftPackageReference` under Package Dependencies. In the dependency form, Xcode treats the package as upstream and hides its `.testTarget`s from the test-plan picker; in the peer form, the package's tests appear in `Edit Scheme → Test → +` as first-class targets and can be added to the test plan. If `KernovaProtocol` ever needs to be re-added, drag the folder into the Project Navigator from Finder rather than using `Add Package Dependencies → Add Local`. `make test-package` exists as a focused shortcut for iterating on the package tests in isolation.

`KernovaGuestAgentTests` is a standalone xctest bundle (no `TEST_HOST`) that compiles the agent's sources directly — see [Helper Targets in ARCHITECTURE.md](../ARCHITECTURE.md#helper-targets) for the rationale. It runs non-parallelized in the scheme because the agent sources include global state (`VsockLogBridge.connection`).

## Writing tests

Follow the existing patterns in `KernovaTests/`:

- **Framework:** Swift Testing (`@Suite`, `@Test`, `#expect`) — not XCTest.
- **Mocks:** protocol-based mock implementations in `KernovaTests/Mocks/`, supporting call counting and error injection via `throwError` properties. `SuspendingMockVirtualizationService` and `SuspendingMockUSBDeviceService` suspend mid-operation to test operation serialization and the installer-mount mutex; both rely on `@MainActor` cooperative scheduling (documented in the mocks) and enforce single-suspension via `precondition`.
- **Factories:** reuse shared helpers (`makeInstance()`, `makeViewModel()`, `makeCoordinator()`) rather than duplicating setup logic across test files.
- **Scope:** test models, services, and view models. UI views don't need unit tests beyond extracted pure helpers (e.g. `DetailRoute.resolve`, `MicPermissionPresentation`) and the VC-level suites that exercise layout-independent behavior.
- **Error paths:** test both happy and error paths; inject failures by setting a mock's `throwError`.
- Run the full test suite before committing.

## Test-only seams

When a test needs to observe state that is `private` in production, pick the tightest exposure that still works:

1. **`private(set) var x`** — internal getter, private setter. The idiomatic choice when production code reading the state is harmless; tests reach it via `@testable import`, no extra accessor needed.
2. **`#if DEBUG`-gated read accessor** — when the state is a test-only implementation detail that production code should *not* read. Keep the field `private` and add a `…ForTesting` computed getter wrapped in `#if DEBUG`, so the seam is physically absent from Release builds and test-only access becomes a compile-time guarantee rather than a naming convention. Place `#if DEBUG` before the doc comment and `#endif` after the accessor.

`AttachmentFileMonitor.watchedParentsForTesting` is the canonical example; the `…ForTesting` accessors in `VsockClipboardService`, `VsockGuestClipboardAgent`, and `VsockHostConnection` follow the same pattern. Because this rationale is shared, the gate itself is the documentation — don't repeat a "DEBUG-only so it can't leak" note at each site.

## Timing-sensitive waits: event-driven, not polling

When a test needs to wait for async state, reach for an **event-driven** wait, not a `waitUntil { predicate }` poll loop. `KernovaTests` and `KernovaGuestAgentTests` each have an `AsyncGate` in their `TestHelpers.swift`: the producer (usually a test double) calls `gate.notify()` after each observable mutation, and the consumer does `await gate.wait(until:)`. For waits on a production `Task` (e.g. the agent post-start watchdog), `await` the task itself via a `#if DEBUG …ForTesting` seam instead of polling the flag it flips.

**Why:** with polling, the timeout IS the success criterion — a load-bearing deadline that fails when the runner is slow, not just when the code is wrong. With an event-driven wait, the timeout is a backstop the happy path never reaches, so a slow runner can't fail the wait; only a genuinely stuck condition can. This was learned the hard way: PR #285's merge turned `main` red purely from poll-based waits (10 ms tick / 5 s deadline) starving under MainActor contention — the merge tree was byte-identical to the branch that had passed CI minutes earlier. The poll budget had already been bumped once (2 s → 5 s) and regressed anyway; PR #286 converted the failing waits to event-driven and `main` went green.

Guidelines:

- New timing-sensitive wait → give the test double an `AsyncGate`, `notify()` on each mutation, `await gate.wait(until:)`. Watchdog/`Task`-style waits → expose the `Task` via a `#if DEBUG` seam and `await task.value`.
- **Never "fix" a CI timing flake by raising the timeout or poll cadence** — that's a treadmill, not a fix. Make the wait event-driven so the wall-clock budget stops being the pass/fail line.
- `AsyncGate.wait` is `@MainActor` in `KernovaTests` (predicates touch MainActor state) and `nonisolated` with a `@Sendable` predicate in `KernovaGuestAgentTests` (predicates read `Sendable` boxes). Keep the two copies aligned. `NSLock.lock()/unlock()` are `noasync` — use `withLock` inside async closures.
- ~40 `waitUntil` poll sites remain (connection/channel/pasteboard/file-monitor waits). Each needs a production event seam, and none were flaking, so they stay on the calmer 50 ms tick. Migrate a site to `AsyncGate` only if and when it actually flakes — no speculative sweeps (the "genuinely better today" bar, [SPEC.md](../SPEC.md#code-approach)).
- If a wait genuinely *can't* be event-driven (a generic predicate with no underlying signal to await, or a "settle, then assert *absence*" negative check), keep polling but use a generous cadence (the shared `waitUntil` tick is 50 ms) and a generous deadline, and assert **end-state**, not per-iteration.

## CI timing characteristics (macos-26 runners)

macos-26 GitHub Actions runners exhibit heavy `@MainActor` scheduling jitter compared to local Apple Silicon — `Task.sleep` durations are a *minimum*, and under parallel test execution on a contended runner, continuations can be delayed by seconds. Tests that depend on wall-clock timing flake there even when the code under test is correct.

- **Don't diagnose a green-PR/red-`main` failure as a code regression without checking the merge tree first.** If the merged tree is identical to the branch that passed CI, the failure is a runner-load flake, not a regression. These flakes can look like crashes — xcbeautify swallows the failure (exit 65 with no `✘` line); the truth is in the `TestResults.xcresult` artifact.
- The `build-and-test` required check is occasionally flaky on timing-sensitive vsock tests; a re-run is reasonable once the failure is confirmed to be a known flake rather than a regression.
- For unavoidable timing-dependent tests, use cadences ≥100 ms, deadlines ≥10× the cadence, and end-state assertions — but prefer converting the wait to event-driven (see above) over tuning budgets.

## Coverage

Most models, services, and view models have a dedicated suite — the per-suite scope is annotated in [ARCHITECTURE.md's directory tree](../ARCHITECTURE.md#directory-structure). The known gaps:

**Mocked but not directly tested** (fully mocked in other suites; no suite exercises the real implementation):

- `DiskImageService` — decompresses bundled templates (no subprocess; direct testing feasible but requires bundled resources in the test target)
- `MacOSInstallService` — requires a real `VZVirtualMachine` and restore image

**Not tested:**

- `VMDirectoryWatcher` — relies on `DispatchSource` file-system monitoring
- `SystemSleepWatcher` — relies on `NSWorkspace` sleep/wake notifications (the sleep/wake *logic* is tested via `VMLibraryViewModel`)
- `KernovaUTType` — static UTType declaration
- The window controllers (`MainWindowController`, `VMDisplayWindowController`, `ClipboardWindowController`) and `AppDelegate` — app lifecycle and window management
- Pure AppKit view rendering beyond the extracted testable helpers and the VC-level suites (`SheetPresenter.show()` is also untested — it needs a key window and a run loop)
