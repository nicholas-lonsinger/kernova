import Foundation
import Darwin
import KernovaProtocol

// Shared timing/test primitives for the KernovaTests bundle. Mirrors the
// shape of `KernovaGuestAgentTests/TestHelpers.swift` so the two bundles
// give the same diagnostic detail (timeout vs EOF) when frame waits fail.
//
// Xcode 16 synchronized folders make each bundle's files target-private,
// so a single file can't be shared across both — the duplication here is
// deliberate. Keep these signatures aligned with the GuestAgent variant.

// MARK: - TestFailure

struct TestFailure: Error {
    let message: String
    init(_ m: String) { message = m }
}

// MARK: - Socket / channel factories

/// Returns a connected AF_UNIX socketpair as two raw file descriptors.
func makeRawSocketPair() throws -> (Int32, Int32) {
    var fds: [Int32] = [-1, -1]
    let rc = fds.withUnsafeMutableBufferPointer { buf in
        socketpair(AF_UNIX, SOCK_STREAM, 0, buf.baseAddress)
    }
    guard rc == 0 else {
        throw POSIXError(.init(rawValue: errno) ?? .EIO)
    }
    return (fds[0], fds[1])
}

// MARK: - waitUntil

/// Polls `predicate` every 50 ms until it returns `true` or `timeout` elapses.
///
/// Default deadline is generous (5 s) to absorb MainActor scheduling jitter on
/// CI runners. See memory `ci-test-timings`. Prefer the
/// event-driven `AsyncGate` below for new timing-sensitive waits — polling is
/// retained for predicates with no underlying signal to await; the 50 ms tick
/// (up from 10 ms) keeps idle pollers from adding avoidable MainActor churn.
///
/// `@MainActor`-isolated because every test in `KernovaTests` is MainActor and
/// the predicates routinely close over MainActor-isolated state (services,
/// view models). Keeping the helper on the same actor sidesteps Swift 6's
/// non-Sendable-closure errors on MainActor → nonisolated boundaries.
@MainActor
func waitUntil(
    timeout: Duration = .seconds(5),
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

// MARK: - nextFrame

/// Reads the next frame from `channel`, distinguishing timeout from EOF.
///
/// - Throws: `TestFailure("Timed out…")` when no frame arrives within `timeout`.
/// - Throws: `TestFailure("Channel finished…")` when the channel closes without
///   producing a frame (EOF), so the two failure shapes are identifiable in
///   post-mortem logs. Conflating them once masked a CI flake as a
///   peer-disconnect bug.
@MainActor
func nextFrame(
    from channel: VsockChannel,
    timeout: Duration = .seconds(5)
) async throws -> Frame {
    let receiver = Task<Frame?, Error> {
        var iterator = channel.incoming.makeAsyncIterator()
        return try await iterator.next()
    }
    // RATIONALE: `receiver` is not cancelled in `defer` because every exit path
    // already awaits `receiver.value` (success, EOF, or timeout-induced
    // CancellationError). By the time the function returns, the receiver task
    // has completed; a redundant cancel would be a no-op and obscures intent.
    // Cancelling the timeoutTask is necessary on the success path.
    let timeoutTask = Task<Void, Never> {
        try? await Task.sleep(for: timeout)
        receiver.cancel()
    }
    defer { timeoutTask.cancel() }

    do {
        guard let frame = try await receiver.value else {
            throw TestFailure("Channel finished without producing a frame (EOF)")
        }
        return frame
    } catch is CancellationError {
        throw TestFailure("Timed out waiting for a frame after \(timeout)")
    }
}

// MARK: - AsyncGate

/// Resumes its continuation at most once, regardless of how many racing paths
/// (a `notify()` and the timeout backstop) try to fire it. `CheckedContinuation`
/// traps on a second resume, so this guard makes the race safe.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    func fire(_ body: () -> Void) {
        lock.lock()
        let already = fired
        fired = true
        lock.unlock()
        if !already { body() }
    }
}

/// Event-driven replacement for `waitUntil` polling.
///
/// A producer calls `notify()` after each observable state change; the consumer
/// awaits `wait(until:)`, which suspends until the predicate holds — re-checked
/// on every `notify()` — or throws `TestFailure` after `timeout`.
///
/// Unlike the poll loop, an idle waiter adds **zero** wake-ups to the shared
/// (and, on CI, contended) MainActor, and the `timeout` is a backstop the happy
/// path never reaches rather than the success deadline — so a slow runner no
/// longer fails the wait, only a genuinely stuck condition does. This is the
/// fix for the timing-sensitive flakes documented in the flaky-CI
/// investigation; keep it aligned with the GuestAgent bundle's copy.
final class AsyncGate: @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [UUID: () -> Void] = [:]

    /// Wake every current waiter; call right after mutating observed state.
    func notify() {
        lock.lock()
        let resumes = Array(waiters.values)
        waiters.removeAll()
        lock.unlock()
        resumes.forEach { $0() }
    }

    /// Suspend until `predicate()` holds (re-checked on each `notify()`), or
    /// throw `TestFailure` after `timeout`. `@MainActor` so predicates may read
    /// MainActor-isolated test state, matching this bundle's `waitUntil`.
    @MainActor
    func wait(
        timeout: Duration = .seconds(10),
        until predicate: () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !predicate() {
            if ContinuousClock.now >= deadline {
                throw TestFailure("Condition not met within \(timeout)")
            }
            await armOnce(deadline: deadline, predicate: predicate)
        }
    }

    /// Suspends until the next `notify()`, an immediate hit (the predicate
    /// already holds at arm time, closing the arm-vs-notify race), or the
    /// `deadline` backstop — whichever comes first.
    @MainActor
    private func armOnce(
        deadline: ContinuousClock.Instant,
        predicate: () -> Bool
    ) async {
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
            Task {
                try? await Task.sleep(until: deadline, clock: ContinuousClock())
                self.lock.withLock { _ = self.waiters.removeValue(forKey: id) }
                once.fire { cont.resume() }
            }
        }
    }
}
