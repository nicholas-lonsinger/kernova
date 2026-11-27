import AppKit
import KernovaKit
import KernovaLogging

/// How long a callout stays in the status item's slot, which follows from the
/// kind of thing it says.
public enum CalloutLifetime: Sendable {
    /// Up until its owner dismisses it: a transfer's live readout.
    case heldByOwner
    /// Information, which goes away by itself after `seconds`.
    case informational(seconds: TimeInterval)
    /// An error, which stays until the user clicks it or the status item, or
    /// until the failure it reports stops standing, which `stands` reads from
    /// wherever that failure is held. `announcement` is what VoiceOver speaks
    /// as it goes up.
    case error(announcement: String, stands: @MainActor @Sendable () -> Bool)

    /// Where the kind stands when callouts compete for the slot: a callout
    /// takes the slot from one of the same or a lower standing, and is skipped
    /// while one of a higher standing is up. An error outranks information,
    /// so nothing but a newer error takes an unread one down.
    fileprivate var standing: Int {
        switch self {
        case .heldByOwner: 0
        case .informational: 1
        case .error: 2
        }
    }
}

/// A status item's one callout slot, as the readout presenter uses it.
///
/// It has no unscoped dismissal: a holder ends only its own showing.
@MainActor
public protocol StatusItemCalloutSlot: AnyObject {
    /// Whether the status item's dropdown is on screen.
    var isDropdownOpen: Bool { get }

    /// Shows `content` for `lifetime`, and says whether it went up; the caller
    /// logs the outcome.
    func show(_ content: NSViewController, as lifetime: CalloutLifetime)
        -> TransientStatusItemPopover.ShowResult

    /// Closes `showing`'s callout if it still holds the slot; `false` otherwise.
    @discardableResult
    func dismiss(_ showing: TransientStatusItemPopover.Showing) -> Bool

    /// Whether `showing`'s callout still holds the slot.
    func holds(_ showing: TransientStatusItemPopover.Showing) -> Bool

    /// Shows the transfer readout in the callout for a click on the status item made while a wait holds the main
    /// thread, and says whether it went up; nil when there is no readout. The readout's presenter sets it.
    var readoutForClick: (() -> TransientStatusItemPopover.ShowResult?)? { get set }
}

/// What a callout slot anchors to: a menu-bar status item.
@MainActor
protocol CalloutAnchor: AnyObject {
    /// Whether the app shows the item.
    var isVisible: Bool { get }
    /// Whether the item's button is on a screen right now.
    var isButtonOnScreen: Bool { get }
    var button: NSStatusBarButton? { get }
    var menu: NSMenu? { get set }
}

extension NSStatusItem: CalloutAnchor {}

/// What puts a callout's popover up and takes it down.
@MainActor
protocol CalloutPresenting: AnyObject {
    /// Called after a popover this presenter showed closed by any means.
    var onClose: (() -> Void)? { get set }
    /// Whether a popover is up.
    var isShown: Bool { get }
    func show(
        content: NSViewController, from anchor: NSView, preferredEdge: NSRectEdge, behavior: NSPopover.Behavior,
        contentSize: NSSize?)
    func close()
}

extension PopoverPresenter: CalloutPresenting {}

/// The menu-bar status item's one popover slot: a callout anchored to the
/// item's button, for whatever Kernova shows there without the user asking.
///
/// Every callout shares the anchor, so they share the slot, and which callout
/// holds it follows ``CalloutLifetime``'s standing. A callout is non-modal and
/// stays up through clicks elsewhere, which go to whatever was clicked, and
/// through Kernova re-hosting the status item (``rehost(_:)``); the status
/// item's menu opens only from the user's own click.
///
/// Once its owner hands it the dropdown (``attachDropdown()``), the menu is
/// attached exactly while no callout is up and no wait holds the main thread
/// (`NestedEventLoopWait`), decided afresh whenever either changes: menu
/// tracking entered under a wait holds the callback's return — a paste's file —
/// until the menu closes. A click on the status item with the menu detached
/// closes the callout that is up, then opens the menu unless a wait holds the
/// main thread; with no callout up during a wait, it shows the transfer
/// readout in the callout (``StatusItemCalloutSlot/readoutForClick``), and
/// opens nothing when there is none.
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
        /// A callout of a higher standing is up.
        case outranked

        /// The reason as a log line names it.
        public var description: String {
            switch self {
            case .unreachable(let visible, let onScreen, let menuOpen):
                "visible=\(visible), onScreen=\(onScreen), menuOpen=\(menuOpen)"
            case .outranked:
                "a callout that outranks it is up"
            }
        }
    }

    /// What became of a ``show(_:as:)``.
    public enum ShowResult: Equatable, Sendable {
        /// The callout went up, for this showing.
        case shown(Showing)
        /// The callout did not go up.
        case skipped(SkipReason)
    }

    /// Which showing holds the slot, and its lifetime.
    struct Tenancy {
        private var lastSerial: UInt64 = 0
        private(set) var current: Showing?
        /// The standing of `current`'s lifetime.
        private var currentStanding = 0
        /// What `current`'s failure stands by, when it reports one.
        private var currentStands: (@MainActor @Sendable () -> Bool)?

        /// Hands the slot to a new showing of `lifetime`, replacing whichever
        /// held it — or `nil`, leaving the slot as it was, when one of a higher
        /// standing holds it.
        mutating func begin(_ lifetime: CalloutLifetime) -> Showing? {
            guard current == nil || lifetime.standing >= currentStanding else { return nil }
            lastSerial += 1
            let showing = Showing(serial: lastSerial)
            current = showing
            currentStanding = lifetime.standing
            if case .error(_, let stands) = lifetime { currentStands = stands } else { currentStands = nil }
            return showing
        }

        /// The showing up whose failure no longer stands, or `nil`.
        @MainActor func retired() -> Showing? {
            guard let current, let currentStands, !currentStands() else { return nil }
            return current
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

    private static let logger = KernovaLogger(subsystem: "app.kernova", category: "TransientStatusItemPopover")

    private let anchor: any CalloutAnchor
    /// The dropdown, detached while a popover is up or a wait holds the main thread.
    private let menu: NSMenu
    private let isDropdownOpenProvider: () -> Bool
    private let mainThreadHeld: () -> Bool

    private let presenter: any CalloutPresenting
    private var tenancy = Tenancy()
    /// What the popover up shows, so a re-host can put it back up.
    private var presented: NSViewController?
    /// Whether the status item is being re-hosted, whose close of the popover
    /// up ends nothing.
    private var rehosting = false
    /// Auto-dismiss timer for the popover currently up; cancelled when it closes
    /// earlier or a newer callout takes the slot.
    private var dismissTask: Task<Void, Never>?

    /// Creates the slot for `statusItem`, whose dropdown is `menu`.
    ///
    /// `isDropdownOpen` reports whether that dropdown is on screen, which
    /// `NSMenu` doesn't expose.
    public convenience init(statusItem: NSStatusItem, menu: NSMenu, isDropdownOpen: @escaping () -> Bool) {
        self.init(
            anchor: statusItem, menu: menu, presenter: PopoverPresenter(), isDropdownOpen: isDropdownOpen,
            mainThreadHeld: { NestedEventLoopWait.holdsMainThread })
    }

    init(
        anchor: any CalloutAnchor, menu: NSMenu, presenter: any CalloutPresenting,
        isDropdownOpen: @escaping () -> Bool, mainThreadHeld: @escaping () -> Bool
    ) {
        self.anchor = anchor
        self.menu = menu
        self.presenter = presenter
        self.isDropdownOpenProvider = isDropdownOpen
        self.mainThreadHeld = mainThreadHeld
        super.init()
        // The backstop for a close this type didn't initiate; a close that a
        // newer callout has already replaced leaves the detachment in place.
        presenter.onClose = { [weak self] in
            guard let self, !self.rehosting, !self.presenter.isShown else { return }
            self.tenancy.endAny()
            self.presented = nil
            self.syncMenuAttachment()
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(syncMenuAttachment), name: NestedEventLoopWait.holdChanged, object: nil)
    }

    /// Takes over the status item's dropdown, which its owner sets nowhere
    /// else: attached from now on exactly while no callout is up and no wait
    /// holds the main thread.
    public func attachDropdown() {
        syncMenuAttachment()
    }

    public var readoutForClick: (() -> ShowResult?)?

    /// Whether the status item's dropdown is on screen.
    public var isDropdownOpen: Bool { isDropdownOpenProvider() }

    /// Shows `content` for `lifetime`.
    ///
    /// An error's content is wrapped so a click anywhere on it dismisses it,
    /// and VoiceOver announces it, reaches it as one button and dismisses it
    /// by pressing that button.
    ///
    /// Logs nothing: the caller logs the outcome at the level its own rate
    /// calls for.
    public func show(_ content: NSViewController, as lifetime: CalloutLifetime) -> ShowResult {
        let visible = anchor.isVisible
        let onScreen = anchor.isButtonOnScreen
        let dropdownOpen = isDropdownOpen
        guard let button = anchor.button, visible, onScreen, !dropdownOpen else {
            return .skipped(.unreachable(visible: visible, onScreen: onScreen, menuOpen: dropdownOpen))
        }
        guard let showing = tenancy.begin(lifetime) else {
            return .skipped(.outranked)
        }

        // Re-arm cleanly if a prior callout is still up.
        dismissTask?.cancel()
        dismissTask = nil

        // With `statusItem.menu` assigned, `NSPopover.show(relativeTo:)` against
        // the status-item button pops the menu open by itself (observed on macOS 26
        // on every soft quit, the cursor nowhere near the item), and that open
        // dismisses the popover through the controller's `menuNeedsUpdate` within
        // a frame.
        syncMenuAttachment()

        let shown: NSViewController
        switch lifetime {
        case .heldByOwner:
            shown = content
        case .informational(let seconds):
            shown = content
            dismissTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.dismiss(showing)
            }
        case .error(let announcement, _):
            shown = ClickToDismissCalloutController(
                content: content, label: announcement, onDismiss: { [weak self] in self?.dismiss(showing) })
        }
        present(shown, from: button)
        if case .error(let announcement, _) = lifetime {
            NSAccessibility.post(
                element: shown.view, notification: .announcementRequested,
                userInfo: [
                    .announcement: announcement,
                    .priority: NSAccessibilityPriorityLevel.high.rawValue,
                ])
        }
        return .shown(showing)
    }

    /// Puts `content`'s popover up from `button`.
    private func present(_ content: NSViewController, from button: NSView) {
        // A `.transient` popover closes when the app deactivates (see
        // `PopoverPresenter`'s `onClose` doc), and a callout outlives that: a
        // soft quit deactivates the app moments after the reminder shows, acting
        // on a clipboard refusal means switching to another app to retry the
        // paste, and a transfer's readout runs while the user works elsewhere.
        // The lifetime, a click on the status item, and the content's own
        // controls bound the lifetime instead.
        presenter.show(
            content: content, from: button, preferredEdge: .minY, behavior: .applicationDefined, contentSize: nil)
        presented = content
    }

    /// Runs `change`, which re-hosts the status item's button — an activation
    /// policy change does — and puts whatever holds the slot back up after it.
    ///
    /// A popover closes once its anchor moves to another window, and the close
    /// a re-host brings ends nothing: the callout goes back up from the
    /// re-hosted button, its showing and its timer unchanged.
    public func rehost(_ change: () -> Void) {
        rehosting = true
        defer { rehosting = false }
        change()
        guard tenancy.current != nil, let presented else { return }
        guard let button = anchor.button else { return dismiss() }
        presenter.close()
        present(presented, from: button)
    }

    /// Dismisses the error up when the failure it reports no longer stands.
    ///
    /// Call whenever what an error's `stands` reads may have changed.
    public func failuresChanged() {
        guard let retired = tenancy.retired() else { return }
        dismiss(retired)
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

    public func holds(_ showing: Showing) -> Bool {
        tenancy.current == showing
    }

    /// Closes whatever the slot holds, cancels its auto-dismiss timer, and
    /// reattaches the dropdown unless a wait holds the main thread.
    ///
    /// Idempotent.
    public func dismiss() {
        tenancy.endAny()
        close()
    }

    private func close() {
        dismissTask?.cancel()
        dismissTask = nil
        presented = nil
        presenter.close()
        syncMenuAttachment()
    }

    /// Attaches the dropdown exactly while no callout holds the slot and no
    /// wait holds the main thread, routing a click on the status item to
    /// ``statusItemTapped()`` otherwise.
    @objc private func syncMenuAttachment() {
        let attached = tenancy.current == nil && !mainThreadHeld()
        guard attached != (anchor.menu != nil) else { return }
        anchor.menu = attached ? menu : nil
        anchor.button?.target = attached ? nil : self
        anchor.button?.action = attached ? nil : #selector(statusItemTapped)
    }

    /// Handles a click on the status item while the dropdown is detached: by a
    /// callout up, or by a wait holding the main thread.
    @objc private func statusItemTapped() {
        guard tenancy.current == nil else {
            dismiss()
            guard anchor.menu != nil else {
                return Self.logger.log(.notice, "A click while a wait holds the main thread closed the callout")
            }
            // Deferred a tick: popping the menu from inside the button-action
            // callback the same click is still delivering re-enters menu
            // tracking mid-event. By then a wait may hold the main thread.
            return performOnMainRunLoop { [weak self] in
                guard let self, self.anchor.menu != nil else { return }
                self.anchor.button?.performClick(nil)
            }
        }
        switch readoutForClick?() {
        case .shown?:
            Self.logger.log(.notice, "A click while a wait holds the main thread showed the transfer readout")
        case .skipped(let reason)?:
            Self.logger.log(
                .notice,
                "A click while a wait holds the main thread opened nothing: the transfer readout was skipped — \(String(describing: reason), privacy: .public)"
            )
        case nil:
            Self.logger.log(.notice, "A click while a wait holds the main thread opened nothing: no transfer readout")
        }
    }
}
