import Cocoa
import KernovaCore
import KernovaLogging
import Virtualization

/// The VM's screen, which takes a guest drag over when the pointer leaves it
/// holding the press.
///
/// A press that began here and is dragged outside asks the host to take the
/// guest's drag over — on every outside drag event, so an offer that lands after
/// the pointer left still takes over. From then until the take settles, no
/// physical drag or mouse-up reaches the guest: each is withheld and drives the
/// take, and the guest sees only what the take injects. A take that fails hands
/// the rest of the press back.
///
/// `VZVirtualMachineView` receives a press as ordinary `mouseDown`/
/// `mouseDragged`/`mouseUp` calls and runs no tracking loop of its own, and a
/// constructed event handed to them reaches the guest: observed on a macOS 27.2
/// host with a macOS 26.6.2 guest (2026-10-14), not documented —
/// `VZVirtualMachineView.h` says nothing about constructed events.
@MainActor
class VMDisplayMachineView: VZVirtualMachineView, GuestDragDisplay {
    /// Where the display's file transfers go, resolved at each press.
    var transferHost: () -> (any VMDisplayTransferHosting)? = { nil }

    /// Where the current left press stands.
    private enum Press {
        /// No press, or one whose take released the guest's button: what is
        /// left of it reaches the guest no more.
        case idle
        /// A press that began here, forwarded to the guest while it looks for
        /// a drag to take over.
        case tracking
        /// The guest's drag is being taken over; the press is withheld.
        case taking(any GuestDragTaking)
        /// The press is the guest's again for the rest of it.
        case forwarding
    }

    private var press: Press = .idle

    /// The physical drag event being withheld right now — what a Mac drag
    /// session begins from.
    private var withheldDrag: NSEvent?

    /// Where the last nudge put the guest pointer, which is where the release
    /// goes.
    private var lastNudgePoint: NSPoint?

    private static let logger = KernovaLogger(
        subsystem: "app.kernova", category: "VMDisplayMachineView")

    // MARK: - The press

    override func mouseDown(with event: NSEvent) {
        if case .taking(let take) = press { take.displayAbandoned() }
        press = .tracking
        lastNudgePoint = nil
        transferHost()?.displayPressBegan()
        forward(event)
    }

    override func mouseDragged(with event: NSEvent) {
        switch press {
        case .tracking:
            guard !bounds.contains(convert(event.locationInWindow, from: nil)),
                let take = transferHost()?.takeGuestDrag(display: self)
            else { return forward(event) }
            // Withheld from here: the guest's pointer stays where the last
            // forwarded event put it until the take moves it.
            press = .taking(take)
        case .taking(let take):
            withheldDrag = event
            take.withheldDrag()
            withheldDrag = nil
            if case .forwarding = press { forward(event) }
        case .forwarding:
            forward(event)
        case .idle:
            // A press whose release was injected: one more drag would move a
            // guest pointer whose button is up.
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        switch press {
        case .taking(let take):
            take.withheldMouseUp()
            // A take that failed hands this release back to the guest; one
            // that released injected its own, and a second would be a second
            // drop.
            if case .forwarding = press { forward(event) }
        case .tracking, .forwarding:
            forward(event)
        case .idle:
            break
        }
        press = .idle
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window == nil, case .taking(let take) = press else { return }
        press = .idle
        take.displayAbandoned()
    }

    // MARK: - GuestDragDisplay

    func injectNudge(_ nudge: GuestDragNudge) {
        let point = nudgePoint(nudge)
        lastNudgePoint = point
        guard let event = makeEvent(.leftMouseDragged, at: point) else { return }
        forward(event)
    }

    func injectRelease() {
        press = .idle
        guard let event = makeEvent(.leftMouseUp, at: lastNudgePoint ?? nudgePoint(.center)) else {
            return
        }
        forward(event)
    }

    func beginHostSession(carrying take: any GuestDragTaking) -> Bool {
        guard let event = withheldDrag, let vmID = transferHost()?.id else { return false }
        let source = DisplayDragOutSource(vmID: vmID, take: take)
        let location = convert(event.locationInWindow, from: nil)
        return startDraggingSession(
            with: source.draggingItems(centeredAt: location), event: event, source: source)
    }

    func resumeForwarding() {
        guard case .taking = press else { return }
        press = .forwarding
    }

    // MARK: - Reaching the guest

    /// Hands `event` to `VZVirtualMachineView`, which sends it to the guest —
    /// the one place a left-button event reaches the guest from this view.
    func forward(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown: super.mouseDown(with: event)
        case .leftMouseDragged: super.mouseDragged(with: event)
        case .leftMouseUp: super.mouseUp(with: event)
        default: break
        }
    }

    /// Begins the Mac drag session, reporting whether it began.
    ///
    /// The frame of each item may lie outside the view's visible rect, which
    /// `NSView.h` names as the session's clip rect: the pointer has left the
    /// display by the time a session begins.
    func startDraggingSession(
        with items: [NSDraggingItem], event: NSEvent, source: any NSDraggingSource
    ) -> Bool {
        guard window != nil else { return false }
        _ = beginDraggingSession(with: items, event: event, source: source)
        return true
    }

    /// Where `nudge` puts the guest pointer, in this view's coordinates.
    func nudgePoint(_ nudge: GuestDragNudge) -> NSPoint {
        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        switch nudge {
        case .center: return center
        case .offset: return NSPoint(x: center.x + 1, y: center.y)
        }
    }

    private func makeEvent(_ type: NSEvent.EventType, at point: NSPoint) -> NSEvent? {
        let event = NSEvent.mouseEvent(
            with: type, location: convert(point, to: nil), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window?.windowNumber ?? 0, context: nil, eventNumber: 0,
            clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)
        if event == nil {
            #log(Self.logger, .fault, "Could not construct a \(type.rawValue, privacy: .public) mouse event")
            assertionFailure("NSEvent.mouseEvent returned nil for a left-button event")
        }
        return event
    }
}
