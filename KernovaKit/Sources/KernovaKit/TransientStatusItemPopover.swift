import AppKit

/// A status item's one callout slot, as the readout presenter uses it.
///
/// It has no unscoped dismissal: a holder ends only its own showing.
@MainActor
public protocol StatusItemCalloutSlot: AnyObject {
    /// Whether the status item's dropdown is on screen.
    var isDropdownOpen: Bool { get }

    /// Shows `content` for `duration` seconds, or until dismissed when `nil`,
    /// and says whether it went up; the caller logs the outcome.
    func show(_ content: NSViewController, for duration: TimeInterval?)
        -> TransientStatusItemPopover.ShowResult

    /// Closes `showing`'s callout if it still holds the slot; `false` otherwise.
    @discardableResult
    func dismiss(_ showing: TransientStatusItemPopover.Showing) -> Bool
}

/// The menu-bar status item's one popover slot: a callout anchored to the
/// item's button, for whatever Kernova shows there without the user asking.
///
/// Every callout shares the anchor, so they share the slot. A callout with a
/// duration replaces whatever the slot held; one without — up until its owner
/// dismisses it — never displaces a timed one before its time is up, and is
/// skipped instead. A callout is non-modal, so it never takes the user's next
/// click; the status item's menu opens only from the user's own click. The menu
/// is detached for as long as a callout is up and reattached on every dismissal
/// path, and a click on the status item while a callout is up dismisses it and
/// opens the menu.
@MainActor
public final class TransientStatusItemPopover: NSObject, StatusItemCalloutSlot {
    /// One callout's time in the slot, handed to whoever showed it.
    public struct Showing: Hashable, Sendable {
        fileprivate let serial: UInt64
    }

    /// Why the slot skipped a callout.
    public enum SkipReason: Equatable, Sendable, CustomStringConvertible {
        /// The status item can't carry a popover: hidden by the app, dropped
        /// from a crowded menu bar, or with its dropdown already open.
        case unreachable(visible: Bool, onScreen: Bool, menuOpen: Bool)
        /// An untimed callout would displace a timed one still up.
        case timedCalloutUp

        /// The reason as a log line names it.
        public var description: String {
            switch self {
            case .unreachable(let visible, let onScreen, let menuOpen):
                "visible=\(visible), onScreen=\(onScreen), menuOpen=\(menuOpen)"
            case .timedCalloutUp:
                "a timed callout is up"
            }
        }
    }

    /// What became of a ``show(_:for:)``.
    public enum ShowResult: Equatable, Sendable {
        /// The callout went up, for this showing.
        case shown(Showing)
        /// The callout did not go up.
        case skipped(SkipReason)
    }

    /// Which showing holds the slot, and whether it is timed.
    struct Tenancy {
        private var lastSerial: UInt64 = 0
        private(set) var current: Showing?
        /// Whether `current` ends on its own timer.
        private var currentIsTimed = false

        /// Hands the slot to a new showing, replacing whichever held it — or
        /// `nil`, leaving the slot as it was, when an untimed showing would
        /// displace a timed one still up.
        mutating func begin(timed: Bool) -> Showing? {
            guard timed || current == nil || !currentIsTimed else { return nil }
            lastSerial += 1
            let showing = Showing(serial: lastSerial)
            current = showing
            currentIsTimed = timed
            return showing
        }

        /// Ends `showing`'s tenancy; `false` when it no longer holds the slot,
        /// because a newer showing replaced it or the slot was emptied.
        mutating func end(_ showing: Showing) -> Bool {
            guard current == showing else { return false }
            current = nil
            return true
        }

        /// Empties the slot, whoever held it.
        mutating func endAny() {
            current = nil
        }
    }

    private let statusItem: NSStatusItem
    /// The dropdown detached while a popover is up.
    private let menu: NSMenu
    private let isDropdownOpenProvider: () -> Bool

    private let presenter = PopoverPresenter()
    private var tenancy = Tenancy()
    /// Auto-dismiss timer for the popover currently up; cancelled when it closes
    /// earlier or a newer callout takes the slot.
    private var dismissTask: Task<Void, Never>?

    /// Creates the slot for `statusItem`, whose dropdown is `menu`.
    ///
    /// `isDropdownOpen` reports whether that dropdown is on screen, which
    /// `NSMenu` doesn't expose.
    public init(statusItem: NSStatusItem, menu: NSMenu, isDropdownOpen: @escaping () -> Bool) {
        self.statusItem = statusItem
        self.menu = menu
        self.isDropdownOpenProvider = isDropdownOpen
        super.init()
        // The backstop for a close this type didn't initiate; a close that a
        // newer callout has already replaced leaves the detachment in place.
        presenter.onClose = { [weak self] in
            guard let self, !self.presenter.isShown else { return }
            self.tenancy.endAny()
            self.reattachMenu()
        }
    }

    /// Whether the status item's dropdown is on screen.
    public var isDropdownOpen: Bool { isDropdownOpenProvider() }

    /// Shows `content` for `duration` seconds or — when `duration` is `nil` —
    /// until something dismisses it.
    ///
    /// Logs nothing: the caller logs the outcome at the level its own rate
    /// calls for.
    public func show(_ content: NSViewController, for duration: TimeInterval? = nil) -> ShowResult {
        let visible = statusItem.isVisible
        let onScreen = statusItem.isButtonOnScreen
        let dropdownOpen = isDropdownOpen
        guard let button = statusItem.button, visible, onScreen, !dropdownOpen else {
            return .skipped(.unreachable(visible: visible, onScreen: onScreen, menuOpen: dropdownOpen))
        }
        guard let showing = tenancy.begin(timed: duration != nil) else {
            return .skipped(.timedCalloutUp)
        }

        // Re-arm cleanly if a prior callout is still up.
        dismissTask?.cancel()
        dismissTask = nil

        // With `statusItem.menu` assigned, `NSPopover.show(relativeTo:)` against
        // the status-item button pops the menu open by itself (observed on macOS 26
        // on every soft quit, the cursor nowhere near the item), and that open
        // dismisses the popover through the controller's `menuNeedsUpdate` within
        // a frame. Every dismissal path restores the menu.
        statusItem.menu = nil
        button.target = self
        button.action = #selector(statusItemTapped)

        // A `.transient` popover closes when the app deactivates (see
        // `PopoverPresenter`'s `onClose` doc), and a callout outlives that: a
        // soft quit deactivates the app moments after the reminder shows, acting
        // on a clipboard refusal means switching to another app to retry the
        // paste, and a transfer's readout runs while the user works elsewhere.
        // `duration`, its owner, a click on the status item, and the content's
        // own controls bound the lifetime instead.
        presenter.show(
            content: content, from: button, preferredEdge: .minY, behavior: .applicationDefined)

        if let duration {
            dismissTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.dismiss(showing)
            }
        }
        return .shown(showing)
    }

    /// Closes `showing`'s callout if it still holds the slot, so an owner never
    /// closes a newer callout that replaced its own.
    ///
    /// `false` when `showing` no longer held the slot and nothing closed.
    @discardableResult
    public func dismiss(_ showing: Showing) -> Bool {
        guard tenancy.end(showing) else { return false }
        close()
        return true
    }

    /// Closes whatever the slot holds, cancels its auto-dismiss timer, and
    /// reattaches the dropdown.
    ///
    /// Idempotent.
    public func dismiss() {
        tenancy.endAny()
        close()
    }

    private func close() {
        dismissTask?.cancel()
        dismissTask = nil
        presenter.close()
        reattachMenu()
    }

    /// Restores the dropdown, clearing the temporary button action.
    private func reattachMenu() {
        guard statusItem.menu == nil else { return }
        statusItem.button?.target = nil
        statusItem.button?.action = nil
        statusItem.menu = menu
    }

    /// Handles a click on the status item while a popover is up and the dropdown
    /// is therefore detached.
    @objc private func statusItemTapped() {
        dismiss()
        // Deferred a tick: the menu is reattached above, but popping it from
        // inside the button-action callback the same click is still delivering
        // re-enters menu tracking mid-event.
        performOnMainRunLoop { [weak self] in
            self?.statusItem.button?.performClick(nil)
        }
    }
}
