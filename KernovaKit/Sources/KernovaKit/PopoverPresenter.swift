import AppKit

/// Manages a single `NSPopover` lifecycle for one anchor view.
///
/// One instance corresponds to one popover slot. Calling
/// ``show(content:from:preferredEdge:behavior:)`` a second time while the
/// popover is already visible updates it in place instead of dismissing and
/// re-presenting, which avoids the flicker users would otherwise see when the
/// underlying view-model state changed mid-popover.
@MainActor
public final class PopoverPresenter: NSObject, NSPopoverDelegate {
    private var popover: NSPopover?

    /// Creates a presenter with no popover up.
    public override init() {
        super.init()
    }

    /// Called after a popover this presenter showed has been dismissed by any
    /// means (programmatic ``close()``, click outside, Escape key, app
    /// deactivation under `.transient` behavior).
    ///
    /// A popover ``close()`` dismissed reports here once its close completes,
    /// by which time a newer one may be up, so check ``isShown``.
    public var onClose: (() -> Void)?

    /// Show the popover, or update an already-shown one in place.
    ///
    /// The popover anchors to `anchor.bounds`. `behavior` defaults to
    /// `.transient` (dismisses on any click outside or Esc); `.semitransient`
    /// survives clicks in the parent window, so the popover can host editable
    /// fields. A `nil` `contentSize` preserves the content controller's own
    /// `preferredContentSize`.
    public func show(
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
    public func close() {
        popover?.performClose(nil)
        popover = nil
    }

    /// `true` when a popover is currently visible.
    public var isShown: Bool {
        popover?.isShown == true
    }

    // MARK: - NSPopoverDelegate

    /// Forgets the popover that closed, if it is the one up, and reports the
    /// close through ``onClose``.
    ///
    /// `NSPopoverDelegate` is not declared `@MainActor` by the framework, so this
    /// enters from any actor context; AppKit only ever delivers it on the main
    /// thread, so `assumeIsolated` bridges back safely.
    public nonisolated func popoverDidClose(_ notification: Notification) {
        let closed = (notification.object as AnyObject?).map(ObjectIdentifier.init)
        MainActor.assumeIsolated {
            // A popover `close()` already let go of finishes closing after a
            // newer `show` may have put another one up; that one stays tracked.
            if let popover, closed == ObjectIdentifier(popover) {
                self.popover = nil
            }
            onClose?()
        }
    }
}
