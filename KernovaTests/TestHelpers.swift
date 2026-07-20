import AppKit
import Foundation
import Darwin
import Observation
import KernovaKit
import KernovaTestSupport
import Testing

@testable import Kernova

// Bundle-specific test helpers for KernovaTests. The event-driven/poll wait
// primitives (`AsyncGate`, `waitUntil`, `TestFailure`), the ephemeral-
// `UserDefaults` helpers (`makeEphemeralDefaults`, `withEphemeralDefaults`),
// and the blocking-bridge GCD hop (`offCooperativePool`) live in the shared
// `KernovaTestSupport` package product — see its doc comments for why they
// were hoisted out of this file (formerly triplicated, #526; the
// ephemeral-defaults helpers followed in #581 once a second bundle needed the
// identical ceremony for `AgentPreferences`, and `offCooperativePool` in #618
// once the guest bundle needed the identical hop).
//
// `waitForChange` below is KernovaTests-only and was never one of the
// triplicated copies: it observes `@MainActor` `@Observable` production state
// directly via `withObservationTracking`, which only this bundle's tests need
// — the GuestAgent/KernovaKit bundles' predicates read `Sendable` boxes
// (`AtomicInt`, `PolicyBox`) with no such observable type to track.

// MARK: - Ephemeral UserDefaults

/// Wraps `makeEphemeralDefaults` (`KernovaTestSupport`) in an `AppPreferences`, for suites that only
/// need the typed wrapper (e.g. to construct a `VMLibraryViewModel`) and never
/// inspect the raw `UserDefaults` store directly.
func makeEphemeralPreferences(suiteName: String) -> AppPreferences {
    AppPreferences(defaults: makeEphemeralDefaults(suiteName: suiteName))
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

// MARK: - nextFrame

/// Reads the next frame from `channel`, distinguishing timeout from EOF.
///
/// - Throws: `TestFailure("Timed out…")` when no frame arrives within the
///   `testWaitBackstop` deadline.
/// - Throws: `TestFailure("Channel finished…")` when the channel closes without
///   producing a frame (EOF), so the two failure shapes are identifiable in
///   post-mortem logs. Conflating them once masked a CI flake as a
///   peer-disconnect bug.
@MainActor
func nextFrame(from channel: VsockChannel) async throws -> Frame {
    let timeout = testWaitBackstop
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

// MARK: - expectEOF

/// Asserts `channel` reaches EOF — the peer closed its end — rather than
/// producing another frame.
///
/// Event-driven via `nextFrame`, whose stuck-stream backstop bounds the wait:
/// EOF resolves it immediately, a frame or a timeout records a test failure.
/// Used by the #145 channel-admission tests to observe a service dropping a
/// non-conformant peer.
@MainActor
func expectEOF(on channel: VsockChannel) async {
    do {
        let frame = try await nextFrame(from: channel)
        Issue.record("Expected channel EOF, got frame \(String(describing: frame.payload))")
    } catch let failure as TestFailure {
        #expect(failure.message.contains("EOF"), "Expected EOF, got: \(failure.message)")
    } catch {
        Issue.record("Expected channel EOF, got error \(error)")
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
/// flaky-CI investigation; see docs/TESTING.md "Async waits in tests".
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
    timeout: Duration = testWaitBackstop,
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
