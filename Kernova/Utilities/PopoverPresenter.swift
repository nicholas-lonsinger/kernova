import AppKit

/// Manages a single `NSPopover` lifecycle for one anchor view.
///
/// One ``PopoverPresenter`` instance corresponds to one popover slot — typical
/// usage is a stored property on the view controller hosting the anchor. When
/// ``show(content:from:preferredEdge:behavior:)`` is called a second time
/// while the popover is already visible, the existing popover is updated in
/// place (content view controller swapped, content size adjusted) instead of
/// being dismissed and re-presented, which avoids the flicker users would
/// otherwise see if the underlying view-model state changed mid-popover.
///
/// To dismiss programmatically, call ``close()``. To be notified when the
/// user dismisses the popover (click outside, Esc), set ``onClose`` — the
/// closure fires after `popoverDidClose` and is the natural place to reset
/// the modal-flag boolean on the view model.
@MainActor
final class PopoverPresenter: NSObject, NSPopoverDelegate {
    private var popover: NSPopover?

    /// Called after the popover has been dismissed by any means
    /// (programmatic ``close()``, click outside, Escape key, app
    /// deactivation under `.transient` behavior).
    ///
    /// Typical use is to reset a `Bool` on the view model that originally
    /// drove the show, so the next `false → true` transition presents
    /// cleanly.
    var onClose: (() -> Void)?

    /// Show the popover, or update an already-shown one in place.
    ///
    /// - Parameters:
    ///   - content: View controller to install as the popover's content.
    ///     Its `preferredContentSize` is set to `contentSize` (if provided)
    ///     before the popover is shown; otherwise the controller's own
    ///     `preferredContentSize` is used unchanged.
    ///   - anchor: The view the popover attaches to. The popover anchors
    ///     to `anchor.bounds` so callers don't need to compute a rect.
    ///   - preferredEdge: Edge of `anchor` the popover prefers to point at.
    ///   - behavior: Dismissal behavior. `.transient` (default) dismisses on
    ///     any click outside or Esc; `.semitransient` survives clicks in the
    ///     parent window so the popover can host editable fields without
    ///     disappearing when the user clicks back into a related row.
    ///   - contentSize: Optional explicit size. If `nil`, the content view
    ///     controller's `preferredContentSize` is preserved.
    func show(
        content: NSViewController,
        from anchor: NSView,
        preferredEdge: NSRectEdge = .maxY,
        behavior: NSPopover.Behavior = .transient,
        contentSize: NSSize? = nil
    ) {
        if let contentSize {
            content.preferredContentSize = contentSize
        }

        // If a popover is already showing, refresh in place — swapping the
        // content view controller and re-pinning the size — to avoid a
        // dismiss/re-present flicker when state changes mid-popover.
        if let popover, popover.isShown {
            popover.contentViewController = content
            if let contentSize {
                popover.contentSize = contentSize
            }
            return
        }

        let popover = NSPopover()
        popover.behavior = behavior
        popover.delegate = self
        popover.contentViewController = content
        if let contentSize {
            popover.contentSize = contentSize
        }

        popover.show(
            relativeTo: anchor.bounds,
            of: anchor,
            preferredEdge: preferredEdge
        )
        self.popover = popover
    }

    /// Dismisses the popover if visible.
    ///
    /// Idempotent.
    func close() {
        popover?.performClose(nil)
        popover = nil
    }

    /// `true` when a popover is currently visible.
    var isShown: Bool {
        popover?.isShown == true
    }

    // MARK: - NSPopoverDelegate

    nonisolated func popoverDidClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            popover = nil
            onClose?()
        }
    }
}
