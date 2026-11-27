import Foundation
import KernovaKit
import KernovaTransferProgress

/// Handle to a recurring observation started by ``observeRecurring(track:apply:)``.
///
/// The observation runs until this handle is deallocated OR ``cancel()`` is
/// called, whichever comes first.
@MainActor
package final class ObservationLoop {
    fileprivate var isCancelled = false
    private let track: () -> Void
    private let apply: () -> Void

    fileprivate init(track: @escaping () -> Void, apply: @escaping () -> Void) {
        self.track = track
        self.apply = apply
        register()
    }

    /// Stops the observation loop; idempotent.
    package func cancel() {
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
/// `apply` runs in a main-actor task the change itself enqueues, so main-actor
/// work enqueued after the change runs after it.
///
/// Both closures run on the main actor; use `[weak self]` captures inside them
/// to avoid retain cycles. The returned ``ObservationLoop`` must be retained by
/// the caller — dropping it or calling ``ObservationLoop/cancel()`` stops the
/// loop at (or before) the next scheduled fire.
@MainActor
package func observeRecurring(
    track: @escaping () -> Void,
    apply: @escaping () -> Void
) -> ObservationLoop {
    ObservationLoop(track: track, apply: apply)
}

/// How long an observed-change wait may last, and the clock that measures it.
package struct ObservedChangeDeadline: Sendable {
    /// Seconds from the start of the wait.
    let seconds: TimeInterval
    /// What measures them.
    let clock: any EngineClock
}

/// How an observed wait ended.
private enum ObservedWaitEnd<Value: Sendable>: Sendable {
    /// The reading answered `Value`.
    case read(Value)
    /// The deadline passed first.
    case expired
    /// The caller was cancelled first.
    case cancelled
}

/// Holds the loop, the deadline's timer, and the continuation they race to
/// resume, so any of them can end the wait and none can end it twice.
@MainActor
private final class ObservedWait<Value: Sendable> {
    var loop: ObservationLoop?
    private var timer: Task<Void, Never>?
    private var continuation: CheckedContinuation<ObservedWaitEnd<Value>, Never>?

    /// Adopts the continuation the wait suspends on.
    func arm(_ continuation: CheckedContinuation<ObservedWaitEnd<Value>, Never>) {
        self.continuation = continuation
    }

    /// Adopts the timer that ends the wait at its deadline.
    func arm(_ timer: Task<Void, Never>) {
        self.timer = timer
    }

    /// Ends the wait as `end` says; later calls do nothing.
    func settle(_ end: ObservedWaitEnd<Value>) {
        guard let continuation else { return }
        self.continuation = nil
        loop?.cancel()
        loop = nil
        timer?.cancel()
        timer = nil
        continuation.resume(returning: end)
    }
}

/// The wait behind every observed-change wait: until `reading` answers a
/// value, `deadline` passes, or — where `endsOnCancellation` — the caller is
/// cancelled.
@MainActor
private func observe<Value: Sendable>(
    _ reading: @escaping @MainActor () -> Value?, before deadline: ObservedChangeDeadline?,
    endsOnCancellation: Bool
) async -> ObservedWaitEnd<Value> {
    if let value = reading() { return .read(value) }
    let wait = ObservedWait<Value>()
    // The read above, `observeRecurring`, and the timer all run without
    // suspending, so no change can slip between them; `settle` resumes once
    // and tears down whatever lost the race. A cancellation hops onto the main
    // actor, so it lands after the continuation is armed even when the
    // caller was cancelled before this began.
    return await withTaskCancellationHandler {
        await withCheckedContinuation { (continuation: CheckedContinuation<ObservedWaitEnd<Value>, Never>) in
            wait.arm(continuation)
            wait.loop = observeRecurring(
                track: { _ = reading() },
                apply: {
                    guard let value = reading() else { return }
                    wait.settle(.read(value))
                }
            )
            guard let deadline else { return }
            wait.arm(
                deadline.clock.schedule(after: deadline.seconds) { @MainActor in
                    guard !Task.isCancelled else { return }
                    wait.settle(reading().map { .read($0) } ?? .expired)
                })
        }
    } onCancel: {
        guard endsOnCancellation else { return }
        Task { @MainActor in wait.settle(.cancelled) }
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
package func waitForObservedChange(until predicate: @escaping @MainActor () -> Bool) async {
    _ = await waitForObservedChange(until: predicate, before: nil)
}

/// Suspends until `predicate` holds or `deadline` passes, answering whether the
/// predicate held.
///
/// A `nil` deadline is the unbounded wait above. Contract on `predicate` is the
/// same; the deadline re-reads it before answering, so a change landing in the
/// same instant is a satisfied wait rather than an expiry.
@MainActor
package func waitForObservedChange(
    until predicate: @escaping @MainActor () -> Bool, before deadline: ObservedChangeDeadline?
) async -> Bool {
    let end = await observe({ predicate() ? () : nil }, before: deadline, endsOnCancellation: false)
    if case .read = end { return true }
    return false
}

/// Suspends until `reading` answers a value, answering it.
///
/// `reading`'s contract is ``waitForObservedChange(until:)``'s on its
/// predicate. Unlike that wait, a cancelled caller ends this one.
///
/// - Throws: `CancellationError` when the caller is cancelled first.
@MainActor
package func waitForObservedValue<Value: Sendable>(
    _ reading: @escaping @MainActor () -> Value?
) async throws -> Value {
    // With no deadline, a cancellation is the one other end.
    guard case .read(let value) = await observe(reading, before: nil, endsOnCancellation: true) else {
        throw CancellationError()
    }
    return value
}

/// ``waitForObservedValue(_:)`` bounded by `deadline` as
/// ``waitForObservedChange(until:before:)`` is, answering `nil` once it passes
/// first.
///
/// - Throws: `CancellationError` when the caller is cancelled first.
@MainActor
package func waitForObservedValue<Value: Sendable>(
    _ reading: @escaping @MainActor () -> Value?, before deadline: ObservedChangeDeadline
) async throws -> Value? {
    switch await observe(reading, before: deadline, endsOnCancellation: true) {
    case .read(let value): return value
    case .expired: return nil
    case .cancelled: throw CancellationError()
    }
}
