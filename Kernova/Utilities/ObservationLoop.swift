import Foundation

/// Handle to a recurring observation started by ``observeRecurring(track:apply:)``.
///
/// The observation runs until this handle is deallocated OR ``cancel()`` is
/// called, whichever comes first. Callers typically store the handle as a
/// stored property on the object whose state is being observed and drop it or
/// cancel it during teardown.
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

    /// Stops the observation loop. Idempotent; safe to call multiple times.
    func cancel() {
        isCancelled = true
    }

    private func register() {
        guard !isCancelled else { return }
        withObservationTracking {
            track()
        } onChange: {
            Task { @MainActor [weak self] in
                guard let self, !self.isCancelled else { return }
                self.apply()
                self.register()
            }
        }
    }
}

/// Observes any `@Observable` properties read inside `track`, invoking `apply`
/// each time one of them changes, and automatically re-registering after each
/// fire so the loop continues indefinitely.
///
/// Prefer this helper over hand-rolling the `withObservationTracking` +
/// `Task { @MainActor }` + recursive re-register dance at each call site. Both
/// closures run on the main actor. Callers should use `[weak self]` captures
/// inside both closures to avoid retain cycles and to short-circuit gracefully
/// after the observing object is deallocated.
///
/// The returned ``ObservationLoop`` must be retained by the caller — typically
/// as a stored property. When the caller drops the reference or calls
/// ``ObservationLoop/cancel()``, the loop stops at (or before) the next
/// scheduled fire.
///
/// Example:
/// ```swift
/// private var toolbarObservation: ObservationLoop?
///
/// private func startToolbarObservation() {
///     toolbarObservation = observeRecurring(
///         track: { [weak self] in
///             guard let self else { return }
///             _ = self.viewModel.selectedInstance?.status
///         },
///         apply: { [weak self] in
///             self?.updateToolbarItems()
///         }
///     )
/// }
/// ```
@MainActor
@discardableResult
func observeRecurring(
    track: @escaping () -> Void,
    apply: @escaping () -> Void
) -> ObservationLoop {
    ObservationLoop(track: track, apply: apply)
}
