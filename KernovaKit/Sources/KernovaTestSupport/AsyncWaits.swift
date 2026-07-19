import Foundation

// Shared event-driven/poll wait primitives for the three test bundles
// (KernovaTests, KernovaMacOSAgentTests, KernovaKitTests). Formerly
// triplicated — each bundle carried its own copy because Xcode 16
// synchronized folders make each bundle's own files target-private — and had
// already drifted once (#526). `KernovaTestSupport` is a plain Foundation
// SwiftPM product all three test targets depend on, so there is now exactly
// one copy.
//
// `AsyncGate.wait`/`waitUntil` take the caller's isolation via `#isolation`,
// so the same implementation serves both `@MainActor` callers (predicates
// reading MainActor-isolated state, e.g. KernovaTests) and nonisolated
// callers (predicates reading `Sendable` boxes, e.g. the GuestAgent/
// KernovaKit bundles) without forking the type. `waitForChange` — the one
// genuinely KernovaTests-only helper, built on `withObservationTracking`
// over `@MainActor` `@Observable` production state — stays local to
// `KernovaTests/TestHelpers.swift`; it was never one of the triplicated
// copies.

// MARK: - testWaitBackstop

/// Default stuck-condition backstop for every test wait helper.
///
/// Sized past any plausible CI scheduler stall (starved macos-26 runners have
/// defeated 5 s and 10 s backstops). The happy path resolves via
/// `notify()`/observation and never reaches this deadline, so the generous
/// value costs nothing on a green run — it only delays the failure report for
/// a genuinely stuck condition. Success-path waits should not pass a smaller
/// explicit timeout; explicit values are for behavior-under-test deadlines
/// only. See docs/TESTING.md "Async waits in tests".
public let testWaitBackstop: Duration = .seconds(60)

// MARK: - TestFailure

/// A test failure with a diagnostic message, thrown by the wait helpers below.
///
/// Shared by all three test bundles. `KernovaKitTests`'s `pollUntil` and
/// stream helpers keep their own `StreamTestFailure` (see
/// `StreamTestSupport.swift`) — that type is package-specific and was never
/// one of the triplicated copies this module consolidates.
public struct TestFailure: Error, CustomStringConvertible {
    /// The diagnostic text describing what condition was not met.
    public let message: String

    /// Creates a failure carrying `message`.
    public init(_ message: String) { self.message = message }

    /// The failure's diagnostic message.
    public var description: String { message }
}

// MARK: - ResumeOnce

/// Resumes its continuation at most once, regardless of how many racing paths
/// (a `notify()` and the timeout backstop) try to fire it. `CheckedContinuation`
/// traps on a second resume, so this guard makes the race safe.
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
/// on every `notify()` — or throws `TestFailure` after `timeout`.
///
/// Unlike a poll loop, an idle waiter adds **zero** wake-ups to the shared (and,
/// on CI, contended) executor, and `timeout` is a stuck-condition backstop the
/// happy path never reaches rather than the success deadline — so a slow runner
/// no longer fails the wait, only a genuinely stuck condition does. This is the
/// fix for the timing-sensitive flakes documented in the flaky-CI investigation
/// (see docs/TESTING.md's "Async waits in tests").
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
    /// throw `TestFailure` after `timeout`.
    public func wait(
        timeout: Duration = testWaitBackstop,
        isolation: isolated (any Actor)? = #isolation,
        until predicate: () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !predicate() {
            if ContinuousClock.now >= deadline {
                throw TestFailure("Condition not met within \(timeout)")
            }
            await armOnce(deadline: deadline, isolation: isolation, predicate: predicate)
        }
    }

    /// Suspends until the next `notify()`, an immediate hit (the predicate
    /// already holds at arm time, closing the arm-vs-notify race), or the
    /// `deadline` backstop — whichever comes first.
    ///
    /// `isolation` is forwarded from `wait` rather than re-derived via
    /// `#isolation`, so the synchronous body below — which calls `predicate()`
    /// — runs on the same actor as the original caller with no hop. The
    /// backstop `Task` touches only `Sendable` state (never `predicate`), so
    /// it needs no isolation of its own.
    // `isolation` uses the Swift `isolated` keyword to pin this helper to the
    // caller's actor (forwarded from `wait`, see above), so it is intentionally
    // never referenced by name. Periphery reports it as an unused parameter.
    // periphery:ignore:parameters isolation
    private func armOnce(
        deadline: ContinuousClock.Instant,
        isolation: isolated (any Actor)?,
        predicate: () -> Bool
    ) async {
        // Captured so it can be cancelled once `notify()` (or the immediate-hit
        // re-check) resolves the wait; otherwise every happy-path arm would leak
        // a Task sleeping until `deadline`.
        var backstop: Task<Void, Never>?
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let id = UUID()
            let once = ResumeOnce()
            lock.lock()
            waiters[id] = { once.fire { cont.resume() } }
            lock.unlock()
            // Close the arm-vs-notify race: if the state already satisfies the
            // predicate (a notify may have landed before we registered), resume
            // now so the outer loop re-checks promptly instead of blocking.
            if predicate() {
                lock.lock()
                waiters.removeValue(forKey: id)
                lock.unlock()
                once.fire { cont.resume() }
                return
            }
            // Backstop: resume at the deadline even if no notify arrives, so a
            // genuinely stuck condition fails the wait instead of hanging.
            backstop = Task {
                try? await Task.sleep(until: deadline, clock: ContinuousClock())
                self.lock.withLock { self.waiters[id] = nil }
                once.fire { cont.resume() }
            }
        }
        // Resolved via notify() or the immediate hit; cancel the backstop so it
        // doesn't linger asleep until `deadline`.
        backstop?.cancel()
    }
}

// MARK: - waitUntil

// `isolation` uses the Swift `isolated` keyword to inherit the caller's actor
// isolation so the synchronous `predicate()` calls need no hop; it is
// intentionally never referenced by name. Periphery reports it as unused.
// periphery:ignore:parameters isolation
/// Polls `predicate` every 50 ms until it returns `true` or `timeout` elapses.
///
/// Unlike the event-driven helpers, the deadline here *is* the pass/fail
/// criterion, so the generous `testWaitBackstop` default matters even more.
/// See docs/TESTING.md's "Async waits in tests" — prefer the event-driven
/// `AsyncGate` above for new timing-sensitive waits; polling is retained for
/// predicates with no underlying signal to await.
public func waitUntil(
    timeout: Duration = testWaitBackstop,
    isolation: isolated (any Actor)? = #isolation,
    _ predicate: () -> Bool
) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while !predicate() && ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(50))
    }
    guard predicate() else {
        throw TestFailure("Predicate did not become true within \(timeout)")
    }
}
