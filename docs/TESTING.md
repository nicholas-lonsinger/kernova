# TESTING.md

Read this before writing any test that waits on async state or needs access to private production state: the async-wait seams, the injected-timeout rule, test-only exposure patterns, and the guest-agent precondition for live tests. The basic conventions (Swift Testing, mocks, factories, happy + error paths) are in [AGENTS.md](../AGENTS.md#unit-tests).

## Async waits in tests

macos-26 CI runners have heavy `@MainActor` scheduling jitter. With a `waitUntil`/`pollUntil` poll loop, the timeout deadline *is* the pass/fail criterion — so a starved scheduler fails a test whose condition would have become true. **When a test waits for async state that has an underlying signal, make the wait event-driven from the start — do not reach for a poll loop.** With event-driven waits the timeout is only a stuck-condition backstop the happy path never reaches.

**Wait timeouts default to the shared `testWaitBackstop` — don't pass a smaller explicit value.** Runner stalls defeated 5 s *and* 10 s backstops (2026-07-19: two consecutive main-branch runs timed out 12 event-driven waits whose conditions were sound). A shorter timeout is reserved for the rare case where the deadline itself is the assertion; negative assertions ("prove nothing arrived") don't qualify — they use a fixed observation window (`expectNoNewFrames`-style), not a wait timeout.

Pick the seam by what produces the state. `AsyncGate`/`waitUntil`/`TestFailure` are in the shared `KernovaTestSupport` product, imported by every test target; `waitForChange` is KernovaTests-only:

| Seam | Use when | Notes |
|------|----------|-------|
| `waitForChange(until:)` | The predicate reads a production `@Observable` property directly (e.g. `service.clipboardContent`, `service.agentStatus`) | KernovaTests only. Built on `withObservationTracking`: the predicate must be side-effect-free and read every inspected value through an `@Observable` getter on the arming pass, or only the deadline wakes it. |
| `AsyncGate` (`notify()` + `wait(until:)`) | The signal flows through a test-owned double/recorder | Call `notify()` after each relevant mutation. One implementation serves every bundle — `wait`/`waitUntil` take the caller's isolation (`isolation: isolated (any Actor)? = #isolation`), so `@MainActor` and nonisolated predicates share it. Don't fork a per-bundle copy. |
| `await` the production `Task` | A production `Task` does the work | Expose it via a `#if DEBUG …ForTesting` seam and `await task.value` instead of polling the flag it flips. |

If the condition is driven by a *single* event a starved scheduler can miss (e.g. one heartbeat that latches a terminal state), drive it *continuously* — a wait conversion alone won't fix that.

**A gate proves only what the state it reads proves.** `AsyncGate.wait`
evaluates its predicate at call time, so the wait resolves the moment the
predicate holds — whichever step made it hold, and whether or not the gate
named in the call has fired at all. A predicate over state an *earlier* step
writes therefore returns before the step the test is sequencing against.
Gate on the state the next line acts on, never on a proxy for it.

**To cross a production time window, inject `TestEngineClock` and advance it — never sleep through it.** A subject that measures elapsed time (a burst window, a backoff, a liveness deadline) takes `any EngineClock`; the manually advanced conformance in `KernovaTestSupport` moves its reading in one call, so no wall-clock wait and no shortened production window are needed.

Polling (`waitUntil` / `pollUntil`) is acceptable **only** for a genuine no-signal predicate: a negative assertion ("prove nothing arrived"), a filesystem-appearance poll, or an exception-catch predicate. There, use a generous cadence, assert end-state not per-iteration, and add a one-line `RATIONALE:` naming **which** of those three categories applies. That is the local fact a reader cannot derive; the general rule is this document, so cite it rather than restating it at the call site.

### Synchronous pull bridges

**Blocking bridge calls run on GCD via `offCooperativePool`, never `Task.detached`.** The synchronous pull bridges (`ClipboardPromiseServing`'s `serveFileURL`/`serveData`, fired from a pasteboard promise's provider) park their calling thread until the transfer resolves. `Task.detached` parks one of the cooperative pool's few threads (CI runners have 3-4); enough parked pulls exhaust the pool, the `@MainActor` responders they wait on starve, and the whole bundle freezes — the 2026-07-19 mass CI failures. `offCooperativePool` (in `KernovaTestSupport`) dispatches to an overcommitting GCD global queue instead.

**A main-thread bridge call runs a nested event loop; drive it at the coordinator level, and never let its resolution depend on main-queue work.**
On the main thread the pull services the run loop (`NestedEventLoopWait`), so a call from a main-run-loop callout (`RunLoop.main.perform`) reentrantly runs *other* queued main-actor work — in the parallel bundle, every concurrent test. If the pull resolves only once some main-queue work runs, the loop drains the whole bundle's backlog first and everything stalls.
So test the serviced wait against `LazyPullCoordinator`, where a pre-scheduled `RunLoop.main.perform` or an off-thread `deliver` resolves it in milliseconds, and prove progress-during-a-pull through the off-main `offCooperativePool` bridge.

**Never let a synchronous pull *wait* from a `@MainActor` test function.** That body is a GCD main-queue job, where the nested loop cannot drain the main queue at all, so whatever the pull needs from the main actor — under a parallel gate, every concurrent test's doubles — never runs and the pull dies at its backstop.
Reach a waiting bridge from the run loop's base with `performOnMainRunLoop`, the way pboard fires it, or off-main with `offCooperativePool`. A fire that provably refuses *before* it waits — a failed pre-flight, a stale generation — waits for nothing and belongs on the main thread, where the ordering it has to survive is real.

### Injected production timeouts

**A timeout that bounds a hostage window stays small — the one exception to the ≥60 s rule below.** When a test *synchronously blocks the main thread* for up to an injected timeout, that timeout caps how long every concurrent test's MainActor-bound waits freeze; it must sit far *below* `testWaitBackstop` so a lost fast path fails that one test instead of mass-failing the bundle. The ≥60 s sizing applies only to timers that hold no thread or actor hostage.

**Every other injected production timeout is either the behavior under test — where a small value is correct — or the production default / ≥60 s.** A shortened timeout is a second clock racing the test body: if it fires before the test reaches the line that depends on the pre-timeout state, a starved runner loses the race and the test flakes even with perfect event-driven waits. A lingering dispatch timer delays nothing, so shrinking one buys nothing.

## Test-double isolation

**A double that plays a peer gets its own isolation domain — never `@MainActor`.** It has to speak while the subject holds the main thread, so main-actor isolation makes it unanswerable exactly when the test needs an answer. Guard its state with a lock, and keep its wait seams isolation-agnostic (`AsyncGate` takes the caller's). `defer` cannot `await`, so one a test tears down there needs a `nonisolated` synchronous `cancel()`.

**A double a production contract pins stays pinned.** One conforming to a `@MainActor` protocol is main-bound by that protocol, not by convenience, and moving it would only move the violation.

## Flaky tests

A flaky test is a defect, never weather. **Fix it or delete it — do not
patch it.** Every flake gets one of three outcomes: fixed by construction
(the race is impossible, not merely rarer), rearchitected (the test asserts
what holds in every legal ordering), or deleted, with maintainer sign-off.
Widened timeouts, retries, sleeps, reduced concurrency, and
diagnostics-as-the-fix are not outcomes; they trade the failure's
visibility for its persistence.

Hunt flakes with contention rather than hiding them from it. Gating a CI
run at `TEST_RUNNER_KERNOVA_TEST_ADMISSION_WIDTH=8` amplifies
scheduling-sensitive defects (2026-08-20: one gated run reproduced, with
failure text, a family ungated CI had surfaced only piecemeal over weeks),
and the "Report failure messages" step prints each failure's `#expect`
text. `main`'s width is a herd cap sized for headroom, never a tuning knob:
lowering it to quiet a flake is a patch wearing configuration's clothes —
the suite must stay green at any width.

## Live tests against a guest

A live test — anything driven through the running app against a real VM (clipboard, drop, control channel) — runs on the agent bundled in the build under test, the only one the product supports.

Before the first scenario, read the connected agent's version off a surface the healthy state keeps up. With Clipboard Sharing on, the VM's Clipboard window's status bar reads `Connected (<version>)`, or `Update available (<installed> → <bundled>)` beside its **Update Guest Agent…** button. The unified log answers whatever the toggles say: `Guest agent connected for '<vm>' … agent=<version>`, subsystem `app.kernova`, category `VsockControlService`. It must be the bundled version; an update available is taken before anything is observed.

A stale agent discovered mid-run voids the run: update, then restart from the first scenario rather than resuming, and report both the starting and ending agent version.

## Test-only seams

When a test needs to observe state that is `private` in production, pick the tightest exposure that still works:

1. **`private(set) var x`** — internal getter, private setter. The idiomatic choice when production code reading the state is harmless; tests reach it via `@testable import`, no extra accessor needed.
2. **`#if DEBUG`-gated read accessor** — when the state is a test-only implementation detail that production code should *not* read. Keep the field `private` and add a `…ForTesting` computed getter wrapped in `#if DEBUG`, so the seam is physically absent from Release builds and test-only access becomes a compile-time guarantee rather than a naming convention. Place `#if DEBUG` before the doc comment and `#endif` after the accessor.

The `#if DEBUG` gate is itself the documentation — don't repeat a "DEBUG-only so it can't leak" note at each site.
