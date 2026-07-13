# TESTING.md

Deep dives for test-writing: the async-wait seams, the injected-timeout rule, and test-only exposure patterns. The basic conventions (Swift Testing, mocks, factories, happy + error paths) are in [AGENTS.md](../AGENTS.md#unit-tests); read this file before writing any test that waits on async state or needs access to private production state.

## Async waits in tests

macos-26 CI runners have heavy `@MainActor` scheduling jitter. With a `waitUntil`/`pollUntil` poll loop, the timeout deadline *is* the pass/fail criterion — so a starved scheduler fails a test whose condition would have become true. **When a test waits for async state that has an underlying signal, make the wait event-driven from the start — do not reach for a poll loop.** With event-driven waits the timeout is only a stuck-condition backstop the happy path never reaches.

Pick the seam by what produces the state. `AsyncGate`/`waitUntil`/`TestFailure` live in the shared `KernovaTestSupport` SwiftPM product (`KernovaKit/Sources/KernovaTestSupport/`), imported by all three test targets; `waitForChange` is KernovaTests-only and stays in `KernovaTests/TestHelpers.swift`:

| Seam | Use when | Notes |
|------|----------|-------|
| `waitForChange(until:)` | The predicate reads a production `@Observable` property directly (e.g. `service.clipboardContent`, `service.agentStatus`) | KernovaTests only. Built on `withObservationTracking`: the predicate must be side-effect-free and read every inspected value through an `@Observable` getter on the arming pass, or only the deadline wakes it. |
| `AsyncGate` (`notify()` + `wait(until:)`) | The signal flows through a test-owned double/recorder | Call `notify()` after each relevant mutation. A single implementation serves every bundle: `wait`/`waitUntil` take the caller's isolation via `isolation: isolated (any Actor)? = #isolation`, so the same code runs isolation-free for `@MainActor` KernovaTests predicates and nonisolated GuestAgent/KernovaKit predicates alike — no per-bundle fork to keep in sync (#526). |
| `await` the production `Task` | A production `Task` does the work | Expose it via a `#if DEBUG …ForTesting` seam and `await task.value` instead of polling the flag it flips. |

If the condition is driven by a *single* event a starved scheduler can miss (e.g. one heartbeat that latches a terminal state), drive it *continuously* — a wait conversion alone won't fix that.

Polling (`waitUntil` / `pollUntil`) is acceptable **only** for a genuine no-signal predicate: a negative assertion ("prove nothing arrived"), a filesystem-appearance poll, or an exception-catch predicate. There, use a generous cadence, assert end-state not per-iteration, and add a `RATIONALE:` comment so reviews don't re-flag it.

**Injected production timeouts race the test body — never pick a small "tidy" value.** Event-driven waits fix the *observation* side, but a test that passes a shortened production timeout into the code under test (to bound a lingering background timer, or just because the default felt long) adds a *second* clock racing the test's own progress. If that timer firing mutates observable state, and it can fire before the test reaches the line that depends on the pre-timeout state, a starved CI scheduler loses the race and the test fails non-deterministically — even with perfect event-driven waits. So an injected production timeout must be **either** (a) the behavior under test — the test is *waiting for* it to fire, where a small value is correct (e.g. `connectTimeout: 0.05` in `connectTimeoutFailsPendingPullWithServerUnreachable`) — **or** (b) sized past any plausible scheduler stall: use the production default, or ≥60s. A lingering dispatch timer in a test process is a no-op that does not delay suite completion, so shrinking it to "keep the linger short" buys nothing and costs a flake. Canonical bug: `FileProviderServiceSourceTests.cancelDispatchedPullAsksOwnerToAbort` once passed `fetchReplyTimeout: 2` to bound a harmless post-`cancel()` timer; on a stalled runner that reply timer fired *before* `cancel()`, replacing the expected `NSUserCancelledError` with `serverUnreachable`.

## Test-only seams

When a test needs to observe state that is `private` in production, pick the tightest exposure that still works:

1. **`private(set) var x`** — internal getter, private setter. The idiomatic choice when production code reading the state is harmless; tests reach it via `@testable import`, no extra accessor needed.
2. **`#if DEBUG`-gated read accessor** — when the state is a test-only implementation detail that production code should *not* read. Keep the field `private` and add a `…ForTesting` computed getter wrapped in `#if DEBUG`, so the seam is physically absent from Release builds and test-only access becomes a compile-time guarantee rather than a naming convention. Place `#if DEBUG` before the doc comment and `#endif` after the accessor.

`AttachmentFileMonitor.watchedParentsForTesting` is the canonical example; the `…ForTesting` accessors in `VsockClipboardService` and `VsockGuestClipboardAgent` follow the same pattern. Because this rationale is shared, the gate itself is the documentation — don't repeat a "DEBUG-only so it can't leak" note at each site.
