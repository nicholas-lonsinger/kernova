import Foundation
import KernovaKit

/// Handle to a recurring observation started by ``observeRecurring(track:apply:)``.
///
/// The observation runs until this handle is deallocated OR ``cancel()`` is
/// called, whichever comes first.
@MainActor
final class ObservationLoop {
    fileprivate var isCancelled = false
    private let track: () -> Void
    private let apply: () -> Void

    fileprivate init(track: @escaping () -> Void, apply: @escaping () -> Void) {
        self.track = track
        self.apply = apply
        register()
    }

    /// Stops the observation loop; idempotent.
    func cancel() {
        isCancelled = true
    }

    private func register() {
        guard !isCancelled else { return }
        withObservationTracking {
            track()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.isCancelled else { return }
                // Re-arm BEFORE applying: `apply()` can synchronously mutate
                // tracked state (e.g. a `makeFirstResponder` inside it forces
                // another field's edit session to commit, writing the model), and
                // re-arming afterwards would leave that mutation unobserved — a
                // lost wakeup. Registering first turns it into one coalesced
                // follow-up pass; `apply` closures are idempotent refreshes, so
                // the loop quiesces.
                self.register()
                self.apply()
            }
        }
    }
}

/// Observes any `@Observable` properties read inside `track`, invoking `apply`
/// each time one of them changes, and automatically re-registering after each
/// fire so the loop continues indefinitely.
///
/// Both closures run on the main actor; use `[weak self]` captures inside them
/// to avoid retain cycles. The returned ``ObservationLoop`` must be retained by
/// the caller — dropping it or calling ``ObservationLoop/cancel()`` stops the
/// loop at (or before) the next scheduled fire.
@MainActor
func observeRecurring(
    track: @escaping () -> Void,
    apply: @escaping () -> Void
) -> ObservationLoop {
    ObservationLoop(track: track, apply: apply)
}

/// How long an observed-change wait may last, and the clock that measures it.
///
/// The clock is a parameter so a test crosses the window in one call instead of
/// sleeping through it, as `docs/TESTING.md` requires.
struct ObservedChangeDeadline: Sendable {
    /// Seconds from the start of the wait.
    let seconds: TimeInterval
    /// What measures them.
    let clock: any EngineClock

    /// Bounds a wait at `seconds` on `clock`.
    init(seconds: TimeInterval, clock: any EngineClock) {
        self.seconds = seconds
        self.clock = clock
    }
}

/// Holds the loop, the deadline's timer, and the continuation the two race to
/// resume, so either can end the wait and neither can end it twice.
@MainActor
private final class ObservationLoopBox {
    var loop: ObservationLoop?
    private var timer: Task<Void, Never>?
    private var continuation: CheckedContinuation<Bool, Never>?

    /// Adopts the continuation the wait suspends on.
    func arm(_ continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    /// Adopts the timer that ends the wait at its deadline.
    func arm(_ timer: Task<Void, Never>) {
        self.timer = timer
    }

    /// Ends the wait, reporting whether the predicate held; later calls do
    /// nothing.
    func settle(_ satisfied: Bool) {
        guard let continuation else { return }
        self.continuation = nil
        loop?.cancel()
        loop = nil
        timer?.cancel()
        timer = nil
        continuation.resume(returning: satisfied)
    }
}

/// Suspends until `predicate` holds, waking on each change to an `@Observable`
/// property the predicate reads.
///
/// Resumes only when `predicate` holds — including for a cancelled caller — so
/// use it to wait out an operation that completes or fails on its own.
/// `predicate` must be side-effect-free and must read every value it inspects
/// through an `@Observable` getter, or nothing wakes the wait.
@MainActor
func waitForObservedChange(until predicate: @escaping @MainActor () -> Bool) async {
    _ = await waitForObservedChange(until: predicate, before: nil)
}

/// Suspends until `predicate` holds or `deadline` passes, answering whether the
/// predicate held.
///
/// A `nil` deadline is the unbounded wait above. Contract on `predicate` is the
/// same; the deadline re-reads it before answering, so a change landing in the
/// same instant is a satisfied wait rather than an expiry.
@MainActor
func waitForObservedChange(
    until predicate: @escaping @MainActor () -> Bool, before deadline: ObservedChangeDeadline?
) async -> Bool {
    guard !predicate() else { return true }
    let box = ObservationLoopBox()
    // The pre-arm check above, `observeRecurring`, and the timer all run without
    // suspending, so no change can slip between them; `settle` resumes once and
    // tears down whichever of the two lost the race.
    return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
        box.arm(continuation)
        box.loop = observeRecurring(
            track: { _ = predicate() },
            apply: {
                guard predicate() else { return }
                box.settle(true)
            }
        )
        guard let deadline else { return }
        box.arm(
            Task { @MainActor in
                try? await deadline.clock.sleep(for: deadline.seconds)
                guard !Task.isCancelled else { return }
                box.settle(predicate())
            })
    }
}
