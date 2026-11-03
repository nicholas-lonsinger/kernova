import AppKit

/// Manages a single `NSPopover` lifecycle for one anchor view.
///
/// One instance corresponds to one popover slot. Calling
/// ``show(content:from:preferredEdge:behavior:contentSize:)`` a second time
/// while the popover is already visible updates it in place instead of
/// dismissing and re-presenting, which avoids the flicker users would otherwise
/// see when the underlying view-model state changed mid-popover.
@MainActor
public final class PopoverPresenter: NSObject, NSPopoverDelegate {
    private var popover: NSPopover?
    /// Holds first responder for content with nothing of its own that takes it.
    private let keyboardHolder = KeyboardHolderView()

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
    ///
    /// A `.transient` or `.semitransient` popover has the keyboard while it is
    /// up, unless text is being edited, and AppKit returns it to the parent
    /// window's first responder as the popover closes. An `.applicationDefined`
    /// one leaves the keyboard alone.
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
            takeKeyboard(for: content, behavior: popover.behavior)
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
        takeKeyboard(for: content, behavior: behavior)
    }

    /// Gives `content`'s popover the keyboard, unless `behavior` is
    /// `.applicationDefined`, a view in `content` already took it, or text is
    /// being edited.
    func takeKeyboard(for content: NSViewController, behavior: NSPopover.Behavior) {
        guard behavior != .applicationDefined, let window = content.view.window else { return }
        // Taking the keyboard from text being edited would commit it half-typed,
        // and a sidebar rename ended that way leaves the keyboard reaching nothing
        // once the popover closes (observed on macOS 27.2).
        if let focused = window.firstResponder as? NSView,
            focused.isDescendant(of: content.view) || focused is NSText
        {
            return
        }
        // With nothing in the popover accepting first responder, keys go to the
        // parent window's first responder (observed on macOS 26.7 and 27.2 with
        // Full Keyboard Access off). A popover then closes on Escape only if that
        // responder passes the key on, which a guest's display never does.
        content.view.addSubview(keyboardHolder)
        window.makeFirstResponder(keyboardHolder)
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

/// First responder for a popover whose content offers nothing else: it has no
/// size, and stays out of the key-view loop so Tab and AppKit's own choice of
/// first responder both pass over it.
private final class KeyboardHolderView: NSView {
    nonisolated override var acceptsFirstResponder: Bool { true }
    nonisolated override var canBecomeKeyView: Bool { false }
}
