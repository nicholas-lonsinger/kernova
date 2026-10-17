import AppKit

/// Manages a single `NSPopover` lifecycle for one anchor view.
///
/// One instance corresponds to one popover slot. Calling
/// ``show(content:from:preferredEdge:behavior:)`` a second time while the
/// popover is already visible updates it in place instead of dismissing and
/// re-presenting, which avoids the flicker users would otherwise see when the
/// underlying view-model state changed mid-popover.
@MainActor
final class PopoverPresenter: NSObject, NSPopoverDelegate {
    private var popover: NSPopover?

    /// Called after the popover has been dismissed by any means (programmatic
    /// ``close()``, click outside, Escape key, app deactivation under
    /// `.transient` behavior).
    var onClose: (() -> Void)?

    /// Show the popover, or update an already-shown one in place.
    ///
    /// The popover anchors to `anchor.bounds`. `behavior` defaults to
    /// `.transient` (dismisses on any click outside or Esc); `.semitransient`
    /// survives clicks in the parent window, so the popover can host editable
    /// fields. A `nil` `contentSize` preserves the content controller's own
    /// `preferredContentSize`.
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

    /// Dismisses the popover if visible; idempotent.
    func close() {
        popover?.performClose(nil)
        popover = nil
    }

    /// `true` when a popover is currently visible.
    var isShown: Bool {
        popover?.isShown == true
    }

    // MARK: - NSPopoverDelegate

    // `NSPopoverDelegate` is not declared `@MainActor` by the framework, so this
    // callback enters from any actor context; AppKit only ever delivers it on the
    // main thread, so `assumeIsolated` bridges back safely.
    nonisolated func popoverDidClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            popover = nil
            onClose?()
        }
    }
}
