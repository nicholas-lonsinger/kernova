import AppKit
import KernovaLogging

/// The menu-bar status item's one popover slot: a callout anchored to the
/// item's button, for whatever Kernova shows there without the user asking.
///
/// Every callout shares the anchor, so they share the slot — showing one
/// replaces whatever the slot held. A callout is non-modal, so it never takes
/// the user's next click; the status item's menu opens only from the user's own
/// click. The menu is detached for as long as a callout is up and reattached on
/// every dismissal path, and a click on the status item while a callout is up
/// dismisses it and opens the menu.
@MainActor
public final class TransientStatusItemPopover: NSObject {
    private static let logger = KernovaLogger(subsystem: "app.kernova", category: "TransientStatusItemPopover")

    /// One callout's time in the slot, handed to whoever showed it.
    public struct Showing: Hashable, Sendable {
        fileprivate let serial: UInt64
    }

    /// Which showing holds the slot.
    struct Tenancy {
        private var lastSerial: UInt64 = 0
        private(set) var current: Showing?

        /// Hands the slot to a new showing, replacing whichever held it.
        mutating func begin() -> Showing {
            lastSerial += 1
            let showing = Showing(serial: lastSerial)
            current = showing
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

    /// Shows `content`, replacing whatever the slot held, for `duration` seconds
    /// or — when `duration` is `nil` — until something dismisses it.
    ///
    /// `nil` when the status item can't carry a popover — hidden by the app,
    /// dropped from a crowded menu bar, or with its dropdown already open —
    /// which the caller logs its own outcome for; `description` names the
    /// callout in this type's own skip line.
    @discardableResult
    public func show(
        _ content: NSViewController, for duration: TimeInterval? = nil,
        describedAs description: String
    ) -> Showing? {
        let visible = statusItem.isVisible
        let onScreen = statusItem.isButtonOnScreen
        let dropdownOpen = isDropdownOpen
        guard let button = statusItem.button, visible, onScreen, !dropdownOpen else {
            Self.logger.log(
                .info,
                "\(description, privacy: .public) skipped — visible=\(visible, privacy: .public), onScreen=\(onScreen, privacy: .public), menuOpen=\(dropdownOpen, privacy: .public)"
            )
            return nil
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
        let showing = tenancy.begin()

        if let duration {
            dismissTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.dismiss(showing)
            }
        }
        return showing
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
