import AppKit
import KernovaKit
import KernovaLogging

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

    /// Whether `showing`'s callout still holds the slot.
    func holds(_ showing: TransientStatusItemPopover.Showing) -> Bool

    /// Shows the transfer readout in the callout for a click on the status item
    /// while a wait holds the main thread, and says whether it went up.
    var readoutForClick: (() -> TransientStatusItemPopover.ShowResult)? { get set }
}

/// What a ``TransientStatusItemPopover`` drives of the status item: its button, its dropdown, and the one
/// popover anchored to the button.
@MainActor
protocol StatusItemSurface: AnyObject {
    /// Whether the app shows the item.
    var isVisible: Bool { get }
    /// Whether the item's button is on a screen.
    var isButtonOnScreen: Bool { get }
    /// Whether a click opens the dropdown; when it doesn't, a click calls ``onClick``.
    var isMenuAttached: Bool { get set }
    /// The click on the item while the dropdown is detached.
    var onClick: (() -> Void)? { get set }
    /// Opens the dropdown for a click the detachment routed to ``onClick``.
    func openMenu()
    /// Shows `content` in the popover, or puts it in the one already up.
    func showCallout(_ content: NSViewController)
    /// Closes the popover; idempotent.
    func closeCallout()
    /// Whether a popover is up.
    var isCalloutShown: Bool { get }
    /// Called after a popover closed by any means.
    var onCalloutClose: (() -> Void)? { get set }
}

/// The menu-bar status item's one popover slot: a callout anchored to the
/// item's button, for whatever Kernova shows there without the user asking.
///
/// Every callout shares the anchor, so they share the slot. A callout with a
/// duration replaces whatever the slot held; one without — up until its owner
/// dismisses it — never displaces a timed one before its time is up, and is
/// skipped instead. A callout is non-modal, so it never takes the user's next
/// click; the status item's menu opens only from the user's own click.
///
/// The menu is attached exactly while no callout is up and no wait holds the
/// main thread (``NestedEventLoopWait/holdsMainThread``), decided afresh each
/// time one of those changes and each time the dropdown closes, so nothing a
/// click did decides the next click. Menu tracking entered under a wait holds
/// the callback's return — a paste's file — until the menu closes, where a
/// callout lets the wait keep dispatching. Otherwise a click reaches
/// ``route(calloutUp:mainThreadHeld:)``, which ``ClickRoute`` describes.
@MainActor
public final class TransientStatusItemPopover: NSObject, StatusItemCalloutSlot {
    private static let logger = KernovaLogger(subsystem: "app.kernova", category: "TransientStatusItemPopover")

    /// What a click on the status item does.
    enum ClickRoute: Equatable {
        /// The dropdown is attached, so AppKit opens it.
        case menu
        /// Closes the callout that is up, then opens the dropdown.
        case dismissThenMenu
        /// Closes the callout that is up, and nothing more.
        case dismiss
        /// Shows the transfer readout in the callout, the dropdown left
        /// detached; the dropdown when the readout can't go up.
        case readoutCallout
    }

    /// What a click does with a callout up or not, while a wait holds the main
    /// thread or not.
    static func route(calloutUp: Bool, mainThreadHeld: Bool) -> ClickRoute {
        switch (calloutUp, mainThreadHeld) {
        case (true, true): .dismiss
        case (false, true): .readoutCallout
        case (true, false): .dismissThenMenu
        case (false, false): .menu
        }
    }

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
        /// No transfer readout to show.
        case noReadout

        /// The reason as a log line names it.
        public var description: String {
            switch self {
            case .unreachable(let visible, let onScreen, let menuOpen):
                "visible=\(visible), onScreen=\(onScreen), menuOpen=\(menuOpen)"
            case .timedCalloutUp:
                "a timed callout is up"
            case .noReadout:
                "no transfer readout"
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

    private var surface: any StatusItemSurface
    private let isDropdownOpenProvider: () -> Bool
    private let mainThreadHeld: () -> Bool

    private var tenancy = Tenancy()
    /// Auto-dismiss timer for the popover currently up; cancelled when it closes
    /// earlier or a newer callout takes the slot.
    private var dismissTask: Task<Void, Never>?

    /// Creates the slot for `statusItem`, whose dropdown is `menu`.
    ///
    /// `isDropdownOpen` reports whether that dropdown is on screen, which
    /// `NSMenu` doesn't expose.
    public convenience init(statusItem: NSStatusItem, menu: NSMenu, isDropdownOpen: @escaping () -> Bool) {
        self.init(
            surface: AppKitStatusItemSurface(statusItem: statusItem, menu: menu),
            isDropdownOpen: isDropdownOpen, mainThreadHeld: { NestedEventLoopWait.holdsMainThread })
    }

    /// Creates the slot on `surface`, reading whether a wait holds the main
    /// thread from `mainThreadHeld`.
    init(
        surface: any StatusItemSurface, isDropdownOpen: @escaping () -> Bool,
        mainThreadHeld: @escaping () -> Bool
    ) {
        self.surface = surface
        self.isDropdownOpenProvider = isDropdownOpen
        self.mainThreadHeld = mainThreadHeld
        super.init()
        // The backstop for a close this type didn't initiate; a close that a
        // newer callout has already replaced leaves the slot as it is.
        self.surface.onCalloutClose = { [weak self] in
            guard let self, !self.surface.isCalloutShown else { return }
            self.tenancy.endAny()
            self.syncMenuAttachment()
        }
        self.surface.onClick = { [weak self] in self?.statusItemTapped() }
        NotificationCenter.default.addObserver(
            self, selector: #selector(syncMenuAttachment), name: NestedEventLoopWait.holdChangedNotification,
            object: nil)
        // Whichever menu AppKit names as the one that ended, the dropdown may be
        // among those that closed.
        NotificationCenter.default.addObserver(
            self, selector: #selector(syncMenuAttachment), name: NSMenu.didEndTrackingNotification, object: nil)
        syncMenuAttachment()
    }

    /// Shows the transfer readout for a click made while a wait holds the main
    /// thread; the readout's presenter sets it.
    public var readoutForClick: (() -> ShowResult)?

    /// Whether the status item's dropdown is on screen.
    public var isDropdownOpen: Bool { isDropdownOpenProvider() }

    /// Shows `content` for `duration` seconds or — when `duration` is `nil` —
    /// until something dismisses it.
    ///
    /// Logs nothing: the caller logs the outcome at the level its own rate
    /// calls for.
    public func show(_ content: NSViewController, for duration: TimeInterval? = nil) -> ShowResult {
        let visible = surface.isVisible
        let onScreen = surface.isButtonOnScreen
        let dropdownOpen = isDropdownOpen
        guard visible, onScreen, !dropdownOpen else {
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
        // a frame.
        syncMenuAttachment()

        // A `.transient` popover closes when the app deactivates (see
        // `PopoverPresenter`'s `onClose` doc), and a callout outlives that: a
        // soft quit deactivates the app moments after the reminder shows, acting
        // on a clipboard refusal means switching to another app to retry the
        // paste, and a transfer's readout runs while the user works elsewhere.
        // `duration`, its owner, a click on the status item, and the content's
        // own controls bound the lifetime instead.
        surface.showCallout(content)

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
        surface.closeCallout()
        syncMenuAttachment()
    }

    /// Attaches the dropdown exactly while no callout holds the slot and no
    /// wait holds the main thread, routing the status item's click here
    /// otherwise.
    @objc private func syncMenuAttachment() {
        surface.isMenuAttached = tenancy.current == nil && !mainThreadHeld()
    }

    /// Handles a click on the status item while its dropdown is detached.
    private func statusItemTapped() {
        switch Self.route(calloutUp: tenancy.current != nil, mainThreadHeld: mainThreadHeld()) {
        case .menu, .dismissThenMenu:
            dismiss()
            surface.openMenu()
        case .dismiss:
            dismiss()
            Self.logger.log(.notice, "A click while a paste holds the main thread closed the callout")
        case .readoutCallout:
            let result = readoutForClick?() ?? .skipped(.noReadout)
            guard case .skipped(let reason) = result else { return }
            Self.logger.log(
                .notice,
                "A click while a paste holds the main thread opened the menu, which holds the paste until it closes — readout skipped: \(String(describing: reason), privacy: .public)"
            )
            surface.openMenu()
        }
    }
}

/// The status item itself, as a ``TransientStatusItemPopover`` drives it.
@MainActor
private final class AppKitStatusItemSurface: NSObject, StatusItemSurface {
    private let statusItem: NSStatusItem
    private let menu: NSMenu
    private let presenter = PopoverPresenter()

    init(statusItem: NSStatusItem, menu: NSMenu) {
        self.statusItem = statusItem
        self.menu = menu
    }

    var isVisible: Bool { statusItem.isVisible }
    var isButtonOnScreen: Bool { statusItem.isButtonOnScreen }

    var isMenuAttached: Bool {
        get { statusItem.menu != nil }
        set {
            guard newValue != isMenuAttached else { return }
            statusItem.menu = newValue ? menu : nil
            statusItem.button?.target = newValue ? nil : self
            statusItem.button?.action = newValue ? nil : #selector(clicked)
        }
    }

    var onClick: (() -> Void)?

    @objc private func clicked() {
        onClick?()
    }

    /// Opens the dropdown as the status item's own, attached for the click;
    /// whoever routed the click here decides the attachment again once the
    /// dropdown closes.
    func openMenu() {
        // Deferred a tick: popping the menu from inside the button-action
        // callback the same click is still delivering re-enters menu tracking
        // mid-event.
        performOnMainRunLoop { [weak self] in
            guard let self else { return }
            self.isMenuAttached = true
            self.statusItem.button?.performClick(nil)
        }
    }

    func showCallout(_ content: NSViewController) {
        guard let button = statusItem.button else { return }
        presenter.show(content: content, from: button, preferredEdge: .minY, behavior: .applicationDefined)
    }

    func closeCallout() {
        presenter.close()
    }

    var isCalloutShown: Bool { presenter.isShown }

    var onCalloutClose: (() -> Void)? {
        get { presenter.onClose }
        set { presenter.onClose = newValue }
    }
}
