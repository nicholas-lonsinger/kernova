import AppKit
import Foundation
import Darwin
import Observation
import KernovaKit

// Shared timing/test primitives for the KernovaTests bundle. Mirrors the
// shape of `KernovaMacOSAgentTests/TestHelpers.swift` so the two bundles
// give the same diagnostic detail (timeout vs EOF) when frame waits fail.
//
// Xcode 16 synchronized folders make each bundle's files target-private,
// so a single file can't be shared across both — the duplication here is
// deliberate. Keep these signatures aligned with the GuestAgent variant.
//
// Exception: `waitForChange` is KernovaTests-only. It observes `@MainActor`
// `@Observable` production state directly; the GuestAgent bundle's helpers are
// `nonisolated`/`@Sendable` over `Sendable` boxes and have no such type to
// track, so there is nothing to mirror there.

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
/// CI runners. See CLAUDE.md "Async waits in tests". Prefer the
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
                self.lock.withLock { _ = self.waiters.removeValue(forKey: id) }
                once.fire { cont.resume() }
            }
        }
        // Resolved via notify() or the immediate hit; cancel the backstop so it
        // doesn't linger asleep until `deadline`.
        backstop?.cancel()
    }
}

// MARK: - waitForChange

/// Event-driven replacement for `waitUntil` when the predicate reads
/// `@Observable` state on a production object directly — i.e. there is no test
/// double in the loop to call `AsyncGate.notify()`.
///
/// `withObservationTracking` suspends the waiter until a property the predicate
/// actually reads changes, then the loop re-checks — so the wait resolves on the
/// mutation itself, not on a 50 ms poll tick. Like `AsyncGate`, an idle waiter
/// adds **zero** wake-ups to the shared (and, on CI, contended) MainActor, and
/// `timeout` is a stuck-condition backstop the happy path never reaches rather
/// than the success deadline. This is the fix for the poll-budget flakes in the
/// flaky-CI investigation; see CLAUDE.md "Async waits in tests".
///
/// The predicate must read every value it inspects through an `@Observable`
/// getter so tracking registers a dependency, and it must be **side-effect-free**
/// — it is evaluated several times per wait (the arming pass, the immediate-hit
/// re-check, and each outer-loop iteration). Computed properties that read
/// observed stored properties qualify (e.g. `agentStatus` reads `isUnresponsive`),
/// but tracking only registers the properties actually read on the arming pass:
/// a getter that short-circuits *before* reaching the property that will change
/// won't wake the waiter, which then resolves only via the deadline backstop. A
/// predicate over plain non-observed state would never be re-evaluated and must
/// keep `waitUntil`.
@MainActor
func waitForChange(
    timeout: Duration = .seconds(10),
    until predicate: @escaping @MainActor () -> Bool
) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while !predicate() {
        if ContinuousClock.now >= deadline {
            throw TestFailure("Observed condition not met within \(timeout)")
        }
        await armObservationOnce(deadline: deadline, predicate: predicate)
    }
}

/// Suspends until the next change to any `@Observable` property read by
/// `predicate`, an immediate hit (the predicate already holds at arm time,
/// closing the arm-vs-change race), or the `deadline` backstop — whichever
/// comes first.
///
/// Mirrors `AsyncGate.armOnce`, but the wake source is observation tracking
/// instead of an explicit `notify()`.
@MainActor
private func armObservationOnce(
    deadline: ContinuousClock.Instant,
    predicate: @escaping @MainActor () -> Bool
) async {
    // Captured so it can be cancelled once the wait resolves via observation (or
    // the immediate-hit re-check); otherwise every happy-path arm would leak a
    // Task sleeping until `deadline`, the opposite of the "zero wake-ups" goal.
    var backstop: Task<Void, Never>?
    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
        let once = ResumeOnce()
        // Arm tracking over whatever observable state the predicate reads. The
        // `onChange` fires once, during the willSet of the first such property
        // to change; the awaiting task then resumes and the outer loop
        // re-checks (by which point the setter has completed).
        withObservationTracking {
            _ = predicate()
        } onChange: {
            once.fire { cont.resume() }
        }
        // Close the arm-vs-change race: a change may have landed between the
        // outer while-check and arming. If the predicate already holds, resume
        // now so the loop re-checks instead of waiting for a change that may
        // never come.
        if predicate() {
            once.fire { cont.resume() }
            return
        }
        // Backstop: resume at the deadline so a genuinely stuck condition fails
        // the wait instead of hanging.
        backstop = Task { @MainActor in
            try? await Task.sleep(until: deadline, clock: ContinuousClock())
            once.fire { cont.resume() }
        }
    }
    // Resolved (observation, immediate hit, or the backstop itself) — cancel the
    // backstop so it doesn't linger asleep until `deadline`.
    backstop?.cancel()
}

// MARK: - AppKit window factory

/// Builds a plain window with `isReleasedWhenClosed` disarmed.
///
/// The default `true` double-releases an ARC-owned `NSWindow` on `close()`
/// (see `SettingsWindowController`'s own `isReleasedWhenClosed = false` for the
/// same reason) — fatal under ARC.
@MainActor
func makeTestWindow(styleMask: NSWindow.StyleMask) -> NSWindow {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
        styleMask: styleMask,
        backing: .buffered,
        defer: false
    )
    window.isReleasedWhenClosed = false
    return window
}
