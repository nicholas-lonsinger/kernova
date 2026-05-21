import Foundation

/// Observes a `Bool` property and invokes `present` only on rising-edge
/// transitions (`false → true`).
///
/// Sugar over ``observeRecurring(track:apply:)`` for the common AppKit
/// pattern of "view model flips a Bool to request a modal; view controller
/// observes it, presents the modal once, and resets the flag on dismiss."
/// Without rising-edge filtering, ``observeRecurring`` re-fires on every
/// tracked property change — including the reset back to `false` after
/// dismiss — and would re-present the modal.
///
/// Example:
/// ```swift
/// private var deleteAlertObserver: ObservationLoop?
///
/// override func viewDidAppear() {
///     super.viewDidAppear()
///     deleteAlertObserver = observeModalFlag(
///         { [weak viewModel] in viewModel?.showDeleteConfirmation ?? false }
///     ) { [weak self] in
///         self?.presentDeleteAlert()
///     }
/// }
/// ```
///
/// The returned ``ObservationLoop`` must be retained by the caller.
@MainActor
func observeModalFlag(
    _ read: @escaping () -> Bool,
    present: @escaping () -> Void
) -> ObservationLoop {
    var previous = read()
    return observeRecurring(
        track: { _ = read() },
        apply: {
            let current = read()
            // Only fire on `false → true`. `true → false` is the reset path
            // (user dismissed, view model cleared the flag); `true → true` is
            // a spurious re-fire caused by something else inside `track`.
            if !previous, current {
                present()
            }
            previous = current
        }
    )
}
