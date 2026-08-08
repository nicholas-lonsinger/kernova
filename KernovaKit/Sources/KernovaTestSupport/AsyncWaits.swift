import Darwin
import Foundation
import KernovaKit

// MARK: - testWaitBackstop

/// Default stuck-condition backstop for every test wait helper, in seconds.
///
/// Sized past any plausible CI scheduler stall — starved macos-26 runners have
/// defeated 5 s and 10 s backstops. Success-path waits must not pass a smaller
/// explicit timeout; explicit values are for behavior-under-test deadlines only
/// (docs/TESTING.md, "Async waits in tests").
public let testWaitBackstop: TimeInterval = 60

// MARK: - Test-session OS activity

/// OS activity held from the first wait for the rest of the process's life,
/// exempting the test host from App Nap and idle timer throttling.
///
/// On an idle, display-off machine the OS can hold a windowless process's
/// timers past the 60 s backstop, then release every armed wait at one
/// instant, mass-failing whatever cases are in flight (observed 2026-08-06,
/// #759). Test runs are user-initiated work even when the display is off.
// The token is write-once and never read — retention is its entire job.
nonisolated(unsafe) private let testSessionActivity: NSObjectProtocol =
    ProcessInfo.processInfo.beginActivity(
        options: [.userInitiated, .latencyCritical],
        reason: "Test waits measure real time and must not be throttled")

// MARK: - TestFailure

/// A test failure with a diagnostic message, thrown by the wait helpers below.
public struct TestFailure: Error, CustomStringConvertible {
    /// The diagnostic text describing what condition was not met.
    public let message: String

    /// Creates a failure carrying `message`.
    public init(_ message: String) { self.message = message }

    /// The failure's diagnostic message.
    public var description: String { message }
}

// MARK: - Backstop self-diagnosis

/// Renders the parenthetical a fired backstop appends to its `TestFailure`
/// message: how far past its deadline it fired (continuous time) and how much
/// of that the process spent suspended (continuous minus uptime elapsed), with
/// a machine-state warning once either exceeds honest-scheduling bounds.
func backstopDiagnosis(
    timeout: TimeInterval, continuousElapsed: TimeInterval, uptimeElapsed: TimeInterval
) -> String {
    let late = continuousElapsed - timeout
    let suspended = max(0, continuousElapsed - uptimeElapsed)
    var text = String(
        format: " (backstop fired %.2f s past its deadline, %.2f s of it process-suspended",
        late, suspended)
    // Scheduler noise keeps an honest backstop within a few seconds of its
    // deadline and never suspends the process; past these bounds the wait did
    // not get its full timeout of normal scheduling, so the numbers name the
    // machine, not the condition under test.
    if late >= 10 || suspended >= 1 {
        text +=
            " — the OS throttled this process's timers or suspended it;"
            + " suspect machine state (sleep, display-off idle throttling)"
            + " rather than a stuck condition"
    }
    return text + ")"
}

// MARK: - ResumeOnce

/// Resumes its continuation at most once, regardless of how many racing paths
/// (a `notify()` and the timeout backstop) try to fire it.
///
/// `CheckedContinuation` traps on a second resume.
public final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false

    /// Creates a fresh, unfired guard.
    public init() {}

    /// Runs `body` only on the first call; every later call is a no-op.
    public func fire(_ body: () -> Void) {
        lock.lock()
        let already = fired
        fired = true
        lock.unlock()
        if !already { body() }
    }
}

// MARK: - AsyncGate

/// Event-driven replacement for a `waitUntil` poll loop.
///
/// A producer calls `notify()` after each observable state change; the consumer
/// awaits `wait(until:)`, which suspends until the predicate holds — re-checked
/// on every `notify()` — or throws `TestFailure` after `timeout`, a
/// stuck-condition backstop the happy path never reaches.
public final class AsyncGate: @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [UUID: () -> Void] = [:]

    /// Creates a fresh gate with no waiters.
    public init() {}

    /// Wake every current waiter; call right after mutating observed state.
    public func notify() {
        lock.lock()
        let resumes = Array(waiters.values)
        waiters.removeAll()
        lock.unlock()
        resumes.forEach { $0() }
    }

    /// Suspend until `predicate()` holds (re-checked on each `notify()`), or
    /// throw `TestFailure` after `timeout` seconds.
    public func wait(
        timeout: TimeInterval = testWaitBackstop,
        isolation: isolated (any Actor)? = #isolation,
        until predicate: () -> Bool
    ) async throws {
        _ = testSessionActivity
        let clock = MonotonicEngineClock()
        let start = clock.now
        let uptimeStart = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        while !predicate() {
            let elapsed = clock.seconds(since: start)
            if elapsed >= timeout {
                let uptimeElapsed =
                    Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - uptimeStart) / 1_000_000_000
                throw TestFailure(
                    "Condition not met within \(timeout) s"
                        + backstopDiagnosis(
                            timeout: timeout, continuousElapsed: elapsed, uptimeElapsed: uptimeElapsed))
            }
            await armOnce(
                clock: clock, start: start, timeout: timeout,
                isolation: isolation, predicate: predicate)
        }
    }

    /// Suspends until the next `notify()`, an immediate hit (the predicate
    /// already holds at arm time, closing the arm-vs-notify race), or the
    /// deadline backstop (`start` + `timeout`) — whichever comes first.
    // `isolation` uses the Swift `isolated` keyword to pin this helper to the
    // caller's actor, so it is intentionally never referenced by name.
    // periphery:ignore:parameters isolation
    private func armOnce(
        clock: MonotonicEngineClock,
        start: EngineInstant,
        timeout: TimeInterval,
        isolation: isolated (any Actor)?,
        predicate: () -> Bool
    ) async {
        // Cancelled once the wait resolves, so a happy-path arm doesn't leak a
        // Task sleeping until `deadline`.
        var backstop: Task<Void, Never>?
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let id = UUID()
            let once = ResumeOnce()
            lock.lock()
            waiters[id] = { once.fire { cont.resume() } }
            lock.unlock()
            // Close the arm-vs-notify race: a notify may have landed before we
            // registered, so re-check now instead of blocking.
            if predicate() {
                lock.lock()
                waiters.removeValue(forKey: id)
                lock.unlock()
                once.fire { cont.resume() }
                return
            }
            // Resume at the deadline even if no notify arrives, so a stuck
            // condition fails the wait instead of hanging.
            backstop = Task {
                try? await clock.sleep(for: max(0, timeout - clock.seconds(since: start)))
                self.lock.withLock { self.waiters[id] = nil }
                once.fire { cont.resume() }
            }
        }
        backstop?.cancel()
    }
}

// MARK: - waitUntil

// `isolation` uses the Swift `isolated` keyword to inherit the caller's actor
// isolation, so it is intentionally never referenced by name.
// periphery:ignore:parameters isolation
/// Polls `predicate` every 50 ms until it returns `true` or `timeout` seconds
/// elapse.
///
/// The deadline here *is* the pass/fail criterion — prefer `AsyncGate` for a new
/// timing-sensitive wait; polling is for predicates with no signal to await.
public func waitUntil(
    timeout: TimeInterval = testWaitBackstop,
    isolation: isolated (any Actor)? = #isolation,
    _ predicate: () -> Bool
) async throws {
    _ = testSessionActivity
    let clock = MonotonicEngineClock()
    let start = clock.now
    let uptimeStart = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    while !predicate() && clock.seconds(since: start) < timeout {
        try await Task.sleep(nanoseconds: 50_000_000)
    }
    guard predicate() else {
        let uptimeElapsed =
            Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - uptimeStart) / 1_000_000_000
        throw TestFailure(
            "Predicate did not become true within \(timeout) s"
                + backstopDiagnosis(
                    timeout: timeout,
                    continuousElapsed: clock.seconds(since: start),
                    uptimeElapsed: uptimeElapsed))
    }
}

// MARK: - offCooperativePool

/// Runs a **synchronous, blocking** bridge call on a GCD global-queue thread,
/// mirroring production's callers.
///
/// RATIONALE: a blocking bridge call parks its thread until the transfer
/// resolves, so it belongs on a GCD global queue — those overcommit, and a
/// parked pull there costs a kernel thread rather than one of the cooperative
/// pool's 3-4 CI threads. Parked on the cooperative pool instead, enough pulls
/// exhaust it, the tasks the reply depends on starve, and the bundle freezes
/// until the shortest injected timeout fires — the 2026-07-19 CI mass failures
/// (#608), #618 for the guest bundle. See docs/TESTING.md "Blocking bridge calls
/// run on GCD".
public func offCooperativePool<T: Sendable>(
    _ body: @escaping @Sendable () -> T
) async -> T {
    await withCheckedContinuation { cont in
        DispatchQueue.global(qos: .userInitiated).async { cont.resume(returning: body()) }
    }
}
