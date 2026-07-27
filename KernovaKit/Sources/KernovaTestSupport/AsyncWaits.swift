import Foundation

// MARK: - testWaitBackstop

/// Default stuck-condition backstop for every test wait helper.
///
/// Sized past any plausible CI scheduler stall — starved macos-26 runners have
/// defeated 5 s and 10 s backstops. Success-path waits must not pass a smaller
/// explicit timeout; explicit values are for behavior-under-test deadlines only
/// (docs/TESTING.md, "Async waits in tests").
public let testWaitBackstop: Duration = .seconds(60)

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
    // `isolation` uses the Swift `isolated` keyword to pin this helper to the
    // caller's actor, so it is intentionally never referenced by name.
    // periphery:ignore:parameters isolation
    private func armOnce(
        deadline: ContinuousClock.Instant,
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
                try? await Task.sleep(until: deadline, clock: ContinuousClock())
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
/// Polls `predicate` every 50 ms until it returns `true` or `timeout` elapses.
///
/// The deadline here *is* the pass/fail criterion — prefer `AsyncGate` for a new
/// timing-sensitive wait; polling is for predicates with no signal to await.
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
