import AppKit

/// Presents a materializing paste's progress readout inside a menu-bar status
/// item's dropdown, and runs the one-shot automatic open that reveals it.
///
/// A status-item controller keeps its own icon and menu structure, drives this
/// from its `NSMenuDelegate` callbacks, and reads `snapshot` back to compose the
/// icon ring and tooltip.
@MainActor
public final class ClipboardProgressStatusItemPresenter {
    private static let logger = KernovaLogger(
        subsystem: "app.kernova", category: "ClipboardProgressStatusItem")

    private let statusItem: NSStatusItem
    private let menu: NSMenu
    /// Run just before the presenter pops the dropdown open by itself.
    ///
    /// The host dismisses its soft-quit reminder here: a live reminder detaches
    /// the dropdown while it is anchored, so the automatic click would land on
    /// the reminder's dismissal handler instead of opening the menu.
    private let willAutoOpen: (() -> Void)?

    /// The paste currently materializing, or `nil` when none is.
    public private(set) var snapshot: ClipboardProgressSnapshot?

    /// The dropdown's live readout, built on first use and then kept so it
    /// updates in place rather than being rebuilt under the cursor.
    private lazy var view = ClipboardProgressMenuItemView()
    private lazy var item: NSMenuItem = {
        let item = NSMenuItem()
        item.view = view
        item.isEnabled = false
        return item
    }()
    private let separator = NSMenuItem.separator()

    private var autoOpener = ClipboardProgressMenuAutoOpener()
    /// Whether the dropdown is currently on screen, which the auto-opener needs
    /// and `NSMenu` doesn't expose.
    private var menuIsOpen = false
    /// Set between asking for an automatic open and the resulting `menuWillOpen`,
    /// so the opener can tell its own dropdown from one the user summoned.
    private var pendingAutoOpen = false

    /// Creates a presenter bound to a status item and its dropdown.
    public init(statusItem: NSStatusItem, menu: NSMenu, willAutoOpen: (() -> Void)? = nil) {
        self.statusItem = statusItem
        self.menu = menu
        self.willAutoOpen = willAutoOpen
    }

    /// Applies the readout the domain host just published — a snapshot to render,
    /// or `nil` to clear it.
    public func apply(_ snapshot: ClipboardProgressSnapshot?) {
        self.snapshot = snapshot
        if let snapshot { view.apply(snapshot) }
        syncItems()
        applyAutoOpen(snapshot)
    }

    /// Inserts the readout rows at the top of a dropdown being rebuilt, when a
    /// paste is live.
    ///
    /// Call from the controller's `menuNeedsUpdate`.
    public func insertItemsIfActive() {
        guard snapshot != nil else { return }
        insertItems()
    }

    /// Records that the dropdown opened, distinguishing an automatic open from
    /// one the user summoned.
    ///
    /// Call from the controller's `menuWillOpen`.
    public func menuWillOpen() {
        menuIsOpen = true
        autoOpener.menuOpened(automatically: pendingAutoOpen)
        pendingAutoOpen = false
    }

    /// Records that the dropdown closed, including a user dismissal.
    ///
    /// Call from the controller's `menuDidClose`.
    public func menuDidClose() {
        menuIsOpen = false
        autoOpener.menuClosed()
    }

    /// Whether an automatic open may click the status-item button right now.
    ///
    /// An already-open dropdown blocks it because `performClick` **toggles**: the
    /// click would dismiss the menu instead of revealing anything, and a menu
    /// opened before the line was staged does not contain that line anyway.
    public nonisolated static func allowsAutomaticOpen(
        isVisible: Bool, isOnScreen: Bool, menuIsOpen: Bool
    ) -> Bool {
        isVisible && isOnScreen && !menuIsOpen
    }

    /// Pops the dropdown open so a line the controller has just staged is seen
    /// without a click, through the same guarded path the readout's own automatic
    /// open uses.
    ///
    /// The caller writes the state the dropdown renders **before** calling this,
    /// so `menuNeedsUpdate` builds the line into the menu this opens.
    /// `stillStaged` is re-checked inside the run-loop turn, where the reason to
    /// open may already be gone.
    public func revealDropdown(while stillStaged: @escaping @MainActor () -> Bool) {
        let visible = statusItem.isVisible
        let onScreen = statusItem.isButtonOnScreen
        guard
            Self.allowsAutomaticOpen(
                isVisible: visible, isOnScreen: onScreen, menuIsOpen: menuIsOpen)
        else {
            Self.logger.info(
                "Staged-line reveal skipped — visible=\(visible, privacy: .public), onScreen=\(onScreen, privacy: .public), menuOpen=\(self.menuIsOpen, privacy: .public)"
            )
            return
        }
        Self.logger.info("Opening the dropdown to reveal a staged line")
        openDropdown(while: stillStaged)
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
    private func applyAutoOpen(_ readout: ClipboardProgressSnapshot?) {
        let visible = statusItem.isVisible
        let onScreen = statusItem.isButtonOnScreen
        let canOpen = visible && onScreen
        let action = autoOpener.readoutChanged(readout, menuIsOpen: menuIsOpen, canOpen: canOpen)
        log(action, readout: readout, visible: visible, onScreen: onScreen)
        switch action {
        case .none:
            break
        case .open:
            // The paste can end inside that turn (a cancel lands as a pull
            // failure); opening for a readout that is already gone would leave a
            // dropdown nothing will close.
            openDropdown(while: { [weak self] in self?.snapshot != nil })
        case .close:
            menu.cancelTracking()
        }
    }

    /// Clicks the status-item button on the next run-loop turn, unless
    /// `stillWanted` reports the reason for opening has passed.
    private func openDropdown(while stillWanted: @escaping @MainActor () -> Bool) {
        // Host-only: detach the dropdown from the soft-quit reminder so the click
        // below opens the menu rather than the reminder's dismissal.
        willAutoOpen?()
        // Never defer this with `Task { @MainActor }`: `performClick` parks inside
        // a nested menu-tracking loop until the dropdown closes, and parking there
        // from a main-queue block starves every later main-queue update, freezing
        // the ring and readout.
        performOnMainRunLoop { [weak self] in
            guard let self, stillWanted() else { return }
            self.pendingAutoOpen = true
            self.statusItem.button?.performClick(nil)
            // Covers a click that opened nothing: a flag left set would mislabel
            // the *user's* next dropdown as ours and close it under them. An open
            // already consumed it in `menuWillOpen`.
            self.pendingAutoOpen = false
        }
    }

    /// Records the decision with the inputs that made it — one line per delivered
    /// readout, a rate the tracker's throttle already bounds.
    private func log(
        _ action: ClipboardProgressMenuAction, readout: ClipboardProgressSnapshot?, visible: Bool,
        onScreen: Bool
    ) {
        guard let readout else {
            Self.logger.info(
                "Readout cleared — dropdown \(action == .close ? "closed" : "left alone", privacy: .public)"
            )
            return
        }
        let record: KernovaLogMessage = """
            Auto-open \(action, privacy: .public) — isPaste=\(readout.isPasteSession, privacy: .public), \
            elapsed=\(ClipboardProgressFormat.logSeconds(readout.elapsedSeconds), privacy: .public), \
            remaining=\(ClipboardProgressFormat.logSeconds(readout.secondsRemaining), privacy: .public), \
            \(readout.bytesTransferred, privacy: .public)/\(readout.totalBytes, privacy: .public) bytes, \
            menuOpen=\(menuIsOpen, privacy: .public), canOpen=\(visible && onScreen, privacy: .public) \
            (visible=\(visible, privacy: .public), onScreen=\(onScreen, privacy: .public))
            """
        switch action {
        case .none: Self.logger.debug(record)
        case .open, .close: Self.logger.info(record)
        }
    }
}
