import AppKit
import KernovaLogging

/// Presents a transfer's progress readout inside a menu-bar status item's
/// dropdown, and reveals it once in the status item's callout so it is seen
/// without a click.
///
/// A status-item controller keeps its own icon and menu structure, drives this
/// from its `menuNeedsUpdate`, and reads `snapshot` back to compose the icon
/// ring and tooltip.
@MainActor
public final class ClipboardProgressStatusItemPresenter {
    private static let logger = KernovaLogger(
        subsystem: "app.kernova", category: "ClipboardProgressStatusItem")

    private let menu: NSMenu
    /// The status item's popover slot, which the reveal shows its callout in.
    private let slot: any StatusItemCalloutSlot

    /// Stops the operation the readout is showing, named by the identity that
    /// readout carried. `nil` leaves every readout without a Cancel button.
    private let onCancel: ((ClipboardTransferOperationID) -> Void)?

    /// The readout on screen, or `nil` when there is none.
    public private(set) var snapshot: ClipboardProgressSnapshot?

    /// The dropdown's live readout, built on first use and then kept so it
    /// updates in place rather than being rebuilt under the cursor.
    private lazy var dropdownReadout = ClipboardProgressReadoutView(surface: .dropdownItem)
    private lazy var item: NSMenuItem = {
        let item = NSMenuItem()
        item.view = dropdownReadout
        item.isEnabled = false
        return item
    }()
    private let separator = NSMenuItem.separator()

    /// The callout's live readout, kept the same way.
    private lazy var calloutReadout = ClipboardProgressReadoutView(surface: .callout)
    private lazy var calloutContent: NSViewController = {
        let content = NSViewController()
        content.view = calloutReadout
        content.preferredContentSize = calloutReadout.frame.size
        return content
    }()
    /// The callout's showing, kept after it ends so the readout clearing can
    /// close it without closing whatever replaced it.
    private var calloutShowing: TransientStatusItemPopover.Showing?

    private var autoReveal = ClipboardProgressAutoReveal()

    /// Creates a presenter bound to a status item's dropdown and its popover
    /// slot.
    ///
    /// `onCancel` stops the operation whose identity it is handed — the one the
    /// readout on screen was rendered for; the button appears only while that
    /// readout reports itself cancellable.
    public init(
        menu: NSMenu, slot: any StatusItemCalloutSlot,
        onCancel: ((ClipboardTransferOperationID) -> Void)? = nil
    ) {
        self.menu = menu
        self.slot = slot
        self.onCancel = onCancel
    }

    /// Applies the transfer report the domain host just published.
    ///
    /// A running operation renders its live readout; one that completed or was
    /// cancelled keeps its bar where it stopped, with no Cancel button — there is
    /// nothing left to stop. A refusal has no bar at all: its surface is the
    /// notice and the dropdown's per-VM line.
    public func apply(_ report: ClipboardTransferReport) {
        let rendered: ClipboardProgressSnapshot?
        let allowsCancel: Bool
        switch report {
        case .running(let snapshot, _):
            rendered = snapshot
            allowsCancel = snapshot.isCancellable
        case .finished(let finish):
            rendered = finish.finalSnapshot
            allowsCancel = false
        case .idle:
            rendered = nil
            allowsCancel = false
        }
        self.snapshot = rendered
        if let rendered {
            let id = rendered.operationID
            dropdownReadout.apply(rendered)
            dropdownReadout.onCancel =
                allowsCancel
                ? cancelHandler(for: id, closingSurface: { [weak self] in self?.menu.cancelTracking() })
                : nil
            calloutReadout.apply(rendered)
            calloutReadout.onCancel =
                allowsCancel
                ? cancelHandler(for: id, closingSurface: { [weak self] in self?.dismissCallout() })
                : nil
        }
        syncItems()
        if rendered == nil {
            let closed = dismissCallout()
            Self.logger.log(
                .info,
                "Readout cleared — callout \(closed ? "dismissed" : "not up", privacy: .public)")
        }
        revealIfEarned(rendered)
    }

    /// The click handler installed on a readout: close the surface the user
    /// clicked in, then cancel the operation that readout was rendered for.
    ///
    /// `id` is bound here rather than resolved at click time, so the click stops
    /// what the user was looking at even if a newer transfer has published since.
    ///
    /// The surface goes first because the cancel's own effect on the readout
    /// arrives asynchronously — the transfers abort, the session ends below
    /// 100 %, and the linger clears it — so leaving it up would strand the user
    /// in front of a readout that keeps ticking for a moment after they stopped
    /// it.
    private func cancelHandler(
        for id: ClipboardTransferOperationID, closingSurface: @escaping () -> Void
    ) -> (() -> Void)? {
        guard let onCancel else { return nil }
        return {
            closingSurface()
            onCancel(id)
        }
    }

    /// Inserts the readout rows at the top of a dropdown being rebuilt, when a
    /// transfer is live.
    ///
    /// Call from the controller's `menuNeedsUpdate`.
    public func insertItemsIfActive() {
        guard snapshot != nil else { return }
        insertItems()
    }

    // MARK: - Private

    /// Adds or removes the readout rows from a dropdown that is already on
    /// screen; a closed one is rebuilt by `menuNeedsUpdate` when it next opens.
    private func syncItems() {
        guard slot.isDropdownOpen else { return }
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

    /// Closes the readout's callout if it still holds the slot; `false` when it
    /// was not up.
    @discardableResult
    private func dismissCallout() -> Bool {
        guard let showing = calloutShowing else { return false }
        calloutShowing = nil
        return slot.dismiss(showing)
    }

    /// Runs the reveal decision for the current readout, showing the callout
    /// when the readout earns it.
    private func revealIfEarned(_ readout: ClipboardProgressSnapshot?) {
        let dropdownOpen = slot.isDropdownOpen
        var skip: TransientStatusItemPopover.SkipReason?
        let decision = autoReveal.readoutChanged(readout, dropdownIsOpen: dropdownOpen) {
            switch slot.show(calloutContent, for: nil) {
            case .shown(let showing):
                calloutShowing = showing
                return true
            case .skipped(let reason):
                skip = reason
                return false
            }
        }
        // A clear has logged its own line.
        guard let readout else { return }
        log(decision, skip: skip, readout: readout, dropdownOpen: dropdownOpen)
    }

    /// Records the decision with the inputs that made it — one line per delivered
    /// readout, a rate the tracker's throttle already bounds.
    ///
    /// Only `.shown` is `.info`: a reveal the slot skipped is retried on every
    /// update until it goes up, so it repeats at the throttle rate as `.none`
    /// does.
    private func log(
        _ decision: ClipboardProgressRevealDecision, skip: TransientStatusItemPopover.SkipReason?,
        readout: ClipboardProgressSnapshot, dropdownOpen: Bool
    ) {
        let level: KernovaLogLevel =
            switch decision {
            case .none, .notShown: .debug
            case .shown: .info
            }
        let skipped = skip.map { " — skipped: \($0)" } ?? ""
        Self.logger.log(
            level,
            """
            Readout callout \(String(describing: decision), privacy: .public)\(skipped, privacy: .public) — \
            gesture=\(String(describing: readout.gesture), privacy: .public), \
            elapsed=\(ClipboardProgressFormat.logSeconds(readout.elapsedSeconds), privacy: .public), \
            remaining=\(ClipboardProgressFormat.logSeconds(readout.secondsRemaining), privacy: .public), \
            \(readout.bytesTransferred, privacy: .public)/\(readout.totalBytes, privacy: .public) bytes, \
            menuOpen=\(dropdownOpen, privacy: .public)
            """
        )
    }
}
