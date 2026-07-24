import AppKit

/// Presents a materializing paste's progress readout inside a menu-bar status
/// item's dropdown, and runs the one-shot automatic open that reveals it (#643).
///
/// The host app's `HostAgentStatusItemController` and the guest agent's
/// `AgentStatusItemController` render the same readout the same way — only the
/// surrounding menu, the icon, and (host-only) the soft-quit reminder differ.
/// This owns the shared half so there is one copy of it: the live
/// `PasteProgressMenuItemView` and its separator, their insertion into and
/// removal from an open dropdown, and the `PasteProgressMenuAutoOpener` state
/// machine that decides when the readout opens and closes the dropdown on its
/// own. Each controller keeps its own icon and menu structure and drives this
/// from its `NSMenuDelegate` callbacks, reading `snapshot` back to compose the
/// icon ring and tooltip.
@MainActor
public final class PasteProgressStatusItemPresenter {
    private let statusItem: NSStatusItem
    private let menu: NSMenu
    /// Run just before the presenter pops the dropdown open by itself.
    ///
    /// The host dismisses its soft-quit reminder here: a live reminder detaches
    /// the dropdown while it is anchored, so the automatic click would land on
    /// the reminder's dismissal handler instead of opening the menu. `nil` for
    /// the guest, which has no reminder.
    private let willAutoOpen: (() -> Void)?

    /// The paste currently materializing, or `nil` when none is.
    ///
    /// Read by the controller to compose the icon ring and the tooltip, which
    /// stay controller-specific (different glyphs, and the host's enablement
    /// badge).
    public private(set) var snapshot: PasteMaterializationSnapshot?

    /// The dropdown's live readout.
    ///
    /// Built on first use — most sessions never paste a file large enough to
    /// reveal one — and then kept, so it updates in place while the dropdown is
    /// open instead of being rebuilt under the cursor.
    private lazy var view = PasteProgressMenuItemView()
    private lazy var item: NSMenuItem = {
        let item = NSMenuItem()
        item.view = view
        item.isEnabled = false
        return item
    }()
    private let separator = NSMenuItem.separator()

    /// Decides when the readout opens and closes the dropdown by itself.
    private var autoOpener = PasteProgressMenuAutoOpener()
    /// Whether the dropdown is currently on screen, which the auto-opener needs
    /// and `NSMenu` doesn't expose.
    private var menuIsOpen = false
    /// Set between asking for an automatic open and the resulting `menuWillOpen`,
    /// so the opener can tell its own dropdown from one the user summoned.
    private var pendingAutoOpen = false

    /// Creates a presenter bound to a status item and its dropdown.
    ///
    /// `willAutoOpen` runs synchronously just before an automatic open; pass it
    /// on the host to dismiss the soft-quit reminder, omit it on the guest.
    public init(statusItem: NSStatusItem, menu: NSMenu, willAutoOpen: (() -> Void)? = nil) {
        self.statusItem = statusItem
        self.menu = menu
        self.willAutoOpen = willAutoOpen
    }

    /// Applies the readout the domain host just published — a snapshot to render,
    /// or `nil` to clear it.
    ///
    /// Updates the live view, an open dropdown, and the automatic open. The
    /// controller composes the icon and tooltip afterwards from `snapshot`.
    public func apply(_ snapshot: PasteMaterializationSnapshot?) {
        self.snapshot = snapshot
        if let snapshot { view.apply(snapshot) }
        syncItems()
        applyAutoOpen(hasReadout: snapshot != nil)
    }

    /// Inserts the readout rows at the top of a dropdown being rebuilt, when a
    /// paste is live.
    ///
    /// Called from the controller's `menuNeedsUpdate`.
    public func insertItemsIfActive() {
        guard snapshot != nil else { return }
        insertItems()
    }

    /// Records that the dropdown opened, distinguishing an automatic open from
    /// one the user summoned.
    ///
    /// Called from the controller's `menuWillOpen`.
    public func menuWillOpen() {
        menuIsOpen = true
        autoOpener.menuOpened(automatically: pendingAutoOpen)
        pendingAutoOpen = false
    }

    /// Records that the dropdown closed.
    ///
    /// Called from the controller's `menuDidClose`. A user dismissal lands here
    /// too, which is what stops a paste from re-opening the dropdown it was just
    /// told to go away from.
    public func menuDidClose() {
        menuIsOpen = false
        autoOpener.menuClosed()
    }

    // MARK: - Private

    /// Adds or removes the readout rows from a dropdown that is already on
    /// screen; a closed one is rebuilt by `menuNeedsUpdate` when it next opens.
    private func syncItems() {
        guard menuIsOpen else { return }
        if snapshot != nil {
            insertItems()
        } else {
            removeItems()
        }
    }

    private func insertItems() {
        guard menu.index(of: item) < 0 else { return }
        menu.insertItem(item, at: 0)
        menu.insertItem(separator, at: 1)
    }

    private func removeItems() {
        for menuItem in [separator, item] where menu.index(of: menuItem) >= 0 {
            menu.removeItem(menuItem)
        }
    }

    /// Runs the auto-opener's decision for the current readout.
    private func applyAutoOpen(hasReadout: Bool) {
        // macOS drops status items it can't fit in a crowded menu bar, and a
        // dropdown popped from a hidden item would appear anchored to nothing.
        let canOpen = statusItem.isVisible && statusItem.button?.window != nil
        switch autoOpener.readoutChanged(
            hasReadout: hasReadout, menuIsOpen: menuIsOpen, canOpen: canOpen)
        {
        case .none:
            break
        case .open:
            // Host-only: detach the dropdown from the soft-quit reminder so the
            // click below opens the menu rather than the reminder's dismissal.
            willAutoOpen?()
            // Deferred, and deliberately NOT via `Task { @MainActor }`:
            // `performClick` parks inside a nested menu-tracking loop until the
            // dropdown closes, and parking there from a main-queue block starves
            // every later main-queue update — which froze both the ring and the
            // readout for the whole time the auto-opened dropdown was up. See
            // `performOnMainRunLoop`.
            performOnMainRunLoop { [weak self] in
                guard let self else { return }
                // The paste can end inside that turn (a cancel lands as a pull
                // failure); opening for a readout that is already gone would
                // leave a dropdown nothing will close.
                guard self.snapshot != nil else { return }
                self.pendingAutoOpen = true
                self.statusItem.button?.performClick(nil)
                // `performClick` only returns once the dropdown closes, by which
                // point `menuWillOpen` has consumed the flag. Clearing it here
                // covers the click that opened nothing at all, which would
                // otherwise leave the flag set to mislabel the *user's* next
                // dropdown as ours and close it under them.
                self.pendingAutoOpen = false
            }
        case .close:
            menu.cancelTracking()
        }
    }
}
