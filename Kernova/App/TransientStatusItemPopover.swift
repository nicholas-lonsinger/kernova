import AppKit
import KernovaKit
import os

/// The menu-bar status item's one transient-popover slot: a callout anchored to
/// the item's button, up for a bounded stretch unless something dismisses it
/// first.
///
/// The soft-quit reminder and the clipboard notice share the anchor, so they
/// share the slot — showing either replaces the other. The dropdown is detached
/// for as long as a popover is up, and reattached on every dismissal path, so a
/// click on the status item reaches the menu again immediately.
@MainActor
final class TransientStatusItemPopover: NSObject {
    private static let logger = Logger(subsystem: "app.kernova", category: "TransientStatusItemPopover")

    private let statusItem: NSStatusItem
    /// The dropdown detached while a popover is up.
    private let menu: NSMenu
    /// Whether the dropdown is on screen, which `NSMenu` doesn't expose.
    private let isDropdownOpen: () -> Bool

    private let presenter = PopoverPresenter()
    /// Auto-dismiss timer for the popover currently up; cancelled when it closes
    /// earlier or a newer callout takes the slot.
    private var dismissTask: Task<Void, Never>?

    init(statusItem: NSStatusItem, menu: NSMenu, isDropdownOpen: @escaping () -> Bool) {
        self.statusItem = statusItem
        self.menu = menu
        self.isDropdownOpen = isDropdownOpen
        super.init()
        // The backstop for a close this type didn't initiate; a close that a
        // newer callout has already replaced leaves the detachment in place.
        presenter.onClose = { [weak self] in
            guard let self, !self.presenter.isShown else { return }
            self.reattachMenu()
        }
    }

    /// Shows `content` for `duration`, replacing whatever the slot held.
    ///
    /// `false` when the status item can't carry a popover — hidden by the app,
    /// dropped from a crowded menu bar, or with its dropdown already open —
    /// which the caller logs its own outcome for; `description` names the
    /// callout in this type's own skip line.
    @discardableResult
    func show(_ content: NSViewController, for duration: Duration, describedAs description: String)
        -> Bool
    {
        let visible = statusItem.isVisible
        let onScreen = statusItem.isButtonOnScreen
        let dropdownOpen = isDropdownOpen()
        guard let button = statusItem.button, visible, onScreen, !dropdownOpen else {
            Self.logger.info(
                "\(description, privacy: .public) skipped — visible=\(visible, privacy: .public), onScreen=\(onScreen, privacy: .public), menuOpen=\(dropdownOpen, privacy: .public)"
            )
            return false
        }

        // Re-arm cleanly if a prior callout is still up.
        dismissTask?.cancel()

        // RATIONALE: detach the dropdown while a popover is anchored. With
        // `statusItem.menu` assigned, `NSPopover.show(relativeTo:)` against the
        // status-item button pops the assigned menu open by itself (macOS 26,
        // observed on every soft quit with the cursor nowhere near the item), and
        // that open dismisses the popover through the controller's
        // `menuNeedsUpdate` within a frame. Every dismissal path restores it.
        statusItem.menu = nil
        button.target = self
        button.action = #selector(statusItemTapped)

        // RATIONALE: `.applicationDefined`, not the default `.transient` — both
        // callouts have to outlive the app deactivating, and a `.transient`
        // popover auto-closes on deactivation (see `PopoverPresenter`'s `onClose`
        // doc): a soft quit deactivates the app moments after the reminder shows,
        // and acting on a clipboard refusal means switching to another app to
        // retry the paste. Lifetime is bounded instead by `duration`, a click on
        // the status item, and the content's own link.
        presenter.show(
            content: content, from: button, preferredEdge: .minY, behavior: .applicationDefined)

        dismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
        return true
    }

    /// Closes whatever the slot holds, cancels its auto-dismiss timer, and
    /// reattaches the dropdown.
    ///
    /// Idempotent.
    func dismiss() {
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
