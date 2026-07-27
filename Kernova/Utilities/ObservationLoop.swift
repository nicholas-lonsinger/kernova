import Foundation

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
