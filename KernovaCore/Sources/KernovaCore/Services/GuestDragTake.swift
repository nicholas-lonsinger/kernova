import Foundation
import KernovaKit
import KernovaLogging
import UniformTypeIdentifiers

/// Where a nudge puts the guest pointer.
package enum GuestDragNudge: Equatable, Sendable {
    /// Where the drag left the display, held 8 points in from every edge of
    /// the view. Past the guest screen, in a letterbox area, Virtualization
    /// puts the guest pointer at the nearest point of the screen's edge
    /// (docs/research/2026-10-23-vz-letterbox-pointer-mapping.md), so it is on
    /// the guest screen either way, under the guest's catcher, which covers
    /// the whole screen.
    case exitPoint
    /// One point from ``exitPoint`` toward the view's center on each axis, so
    /// a nudge after a nudge is motion the guest drag manager hit-tests again;
    /// where ``exitPoint`` maps to the screen's edge, that motion runs along it.
    case offset

    /// The variant the nudge after this one uses.
    var next: GuestDragNudge { self == .exitPoint ? .offset : .exitPoint }
}

/// The VM display a take over drives: it withholds the press while the guest
/// hands its drag over, and injects into the guest only what the take tells it
/// to.
@MainActor
package protocol GuestDragDisplay: AnyObject {
    /// Moves the guest pointer to `nudge`'s point with a constructed drag event.
    func injectNudge(_ nudge: GuestDragNudge)

    /// Moves the guest pointer to `point`, in the display's coordinates, with a
    /// constructed drag event: where the Mac session is over the display, and
    /// so where the drag leaves it if it leaves again.
    func injectDrag(at point: CGPoint)

    /// Moves the guest pointer back to where the drag left the display — where
    /// the last physical event the display forwarded put it, or the last
    /// ``injectDrag(at:)`` — when it is anywhere else.
    func returnToExitPoint()

    /// Releases the guest's button where the last event the display sent put
    /// the guest pointer, with a constructed mouse-up, which drops the guest's
    /// drag on whatever is under it.
    ///
    /// Called at most once per take.
    func injectRelease()

    /// Begins the Mac drag session carrying `take`'s items from the physical
    /// drag event the display is withholding right now, reporting whether one
    /// began.
    func beginHostSession(carrying take: any GuestDragTaking) -> Bool

    /// Hands the rest of the press back to the guest, the event being withheld
    /// right now included.
    func resumeForwarding()
}

/// A guest drag the VM display has taken over, as the display and the Mac
/// drag session it begins speak to it.
@MainActor
package protocol GuestDragTaking: AnyObject, Sendable {
    /// The generation the guest offered the drag under.
    var generation: UInt64 { get }

    /// What the drag carries.
    var items: [ClipboardDraggedItem] { get }

    /// Whether the Mac session is over the display the take began on,
    /// carrying the guest's drag there.
    var sessionOverDisplay: Bool { get }

    /// Called with ``sessionOverDisplay``'s new value in the same call that
    /// changes it.
    var sessionOverDisplayChanged: (@MainActor (Bool) -> Void)? { get set }

    /// The display withheld a physical drag event of the press.
    func withheldDrag()

    /// The display withheld the press's physical mouse-up.
    func withheldMouseUp()

    /// A withheld drag event came back inside the display: the user means the
    /// drag for the guest after all.
    func pointerReturned()

    /// The display can no longer carry the press — it left its window, or a
    /// new press began without the last one ending.
    func displayAbandoned()

    /// The Mac drag session moved, wherever it is.
    func hostSessionMoved()

    /// The Mac drag session is over `display` at `point`, in its coordinates,
    /// returning whether a drop there goes to the guest: only over the display
    /// the take began on, while the session still carries the guest's drag.
    func hostSession(over display: any GuestDragDisplay, at point: CGPoint) -> Bool

    /// The Mac drag session left `display`.
    func hostSessionLeft(_ display: any GuestDragDisplay)

    /// The Mac drag session was dropped on `display` at `point`, returning
    /// whether the guest took the drop there.
    func hostSessionDropped(on display: any GuestDragDisplay, at point: CGPoint) -> Bool

    /// The Mac drag session ended; `dropped` is whether a destination took it.
    func hostSessionEnded(dropped: Bool)

    /// What item `index` is called where a Mac destination writes it, asking
    /// the guest for a promised item's name when nothing has yet — from any
    /// thread, holding it for a bounded time.
    ///
    /// A promised item the guest could not name gets a stand-in name, and its
    /// write then fails.
    nonisolated func filename(forItemAt index: Int) -> String

    /// Has the guest name the drag's promised items before a destination in
    /// this app calls them in, holding the main thread for a bounded time,
    /// and reports whether they are named; a failure is reported as the drag's.
    ///
    /// An in-app destination's provider can be asked for names off the main
    /// thread while the main thread waits in `receivePromisedFiles`, and the
    /// release naming needs runs on the main thread.
    func nameItemsForInAppDestination() -> Bool

    /// Writes item `index` to exactly `destination`, blocking until it lands.
    ///
    /// For an `NSFilePromiseProvider` operation queue: never the main thread.
    ///
    /// - Throws: `CocoaError(.userCancelled)` when the user called the drag's
    ///   transfers off, ``GuestDragWriteError`` when the transfer failed, or
    ///   the move's own error when the item could not be put at `destination`.
    nonisolated func writeItem(at index: Int, to destination: URL) throws
}

/// One guest drag the VM display took over at its edge: the hand-off that moves
/// the guest's drag onto its catcher, and the Mac drag session that carries it
/// on. Its ``GuestDragItemWriter`` writes the items a Mac destination asks for.
///
/// Every button release the take injects is a real drop under the guest
/// pointer, so it lands in one of two places: on a catcher that has reported
/// `TARGETED`, or where the user's own release would have landed with drag-out
/// off — where they let go over this VM's display, or, when no catcher can
/// take the drop, where the drag left the display. Before the press goes back
/// to the guest, the guest pointer returns to that exit point.
///
/// The guest's drag stays live, its button held, for as long as the Mac
/// session runs: over this VM's display the catcher stands down and the guest
/// pointer follows the session, so a drag that comes back drops inside the
/// guest. `NSDraggingSession` cannot be withdrawn, so the session begins only
/// from ``Phase/ready``, which only `TARGETED` enters, and every failure before
/// it hands the press back.
///
/// A promised item has no name until the guest's catcher calls it in, so the
/// first Mac destination to ask for one has the guest name them all: the take
/// asks (`DragResolve`), and releases the guest's button onto its catcher once
/// the guest answers that the catcher calls them in on that drop. A
/// destination that took the drop without asking yet has them named as the
/// session ends, so its later ask is answered at once.
@MainActor
@Observable
package final class GuestDragTake: GuestDragTaking, GuestDragItemWriterOwner {
    /// How long the guest may go without its catcher becoming the drag's
    /// target: from the take to the Mac session, and from the session's end to
    /// the release onto a catcher shown again.
    ///
    /// A bound on a peer Kernova does not own; the catcher normally reports
    /// within a frame or two of the first nudge.
    package static let handOffDeadline: TimeInterval = 3

    /// How long a Mac destination asking for a promised item's name waits for
    /// the guest to name it.
    ///
    /// A bound on a peer Kernova does not own; Photos and Safari promises in a
    /// macOS 26.6.2 guest were named 4–16 ms after the catcher called them in.
    package static let namingDeadline: TimeInterval = 2

    /// Where the hand-off stands.
    package enum Phase: Equatable, Sendable {
        /// `DragTake` is out and the press is withheld; `armed` once the guest
        /// reported its catcher up under the pointer.
        case handingOff(armed: Bool)
        /// The guest reported its catcher as the drag's target, so the next
        /// physical event may begin the Mac session or release onto it.
        case ready
        /// A Mac drag session carries the items, and the guest's button is
        /// still held.
        case carried(Carriage)
        /// The guest's button was released, once, at `spot`.
        case released(at: ReleaseSpot)
        /// The take ended with no release of its own after the Mac session
        /// began: the VM stopped under it, or the guest's press is already
        /// over.
        case unreleased
        /// The take failed before the Mac session and the press went back to
        /// the guest.
        case abandoned
    }

    /// Where the Mac session carrying the guest's drag stands.
    package enum Carriage: Equatable, Sendable {
        /// Off this VM's display; `targeted` while the guest's catcher, shown,
        /// is the drag's target.
        case outside(targeted: Bool)
        /// Over this VM's display: the catcher is stood down, and the guest
        /// pointer follows the session.
        case inside
        /// The session ended away from the guest; the release waits for the
        /// catcher to become the drag's target.
        case ended
    }

    /// Where the take released the guest's button.
    package enum ReleaseSpot: Equatable, Sendable {
        /// On the catcher, once it reported `TARGETED`.
        case catcher
        /// Where the Mac session was dropped on this VM's display.
        case dropPoint
        /// Where the drag left the display, when no catcher could take it.
        case exitPoint
    }

    nonisolated package let generation: UInt64
    nonisolated package let items: [ClipboardDraggedItem]
    /// Where the hand-off stands now; the one observed property.
    package private(set) var phase: Phase = .handingOff(armed: false) {
        didSet {
            if (oldValue == .carried(.inside)) != sessionOverDisplay {
                sessionOverDisplayChanged?(sessionOverDisplay)
            }
        }
    }

    package var sessionOverDisplay: Bool { phase == .carried(.inside) }

    @ObservationIgnored package var sessionOverDisplayChanged: (@MainActor (Bool) -> Void)?

    nonisolated private let endpoint: ClipboardEndpoint
    nonisolated private let writer: GuestDragItemWriter
    nonisolated private let namingDeadline: TimeInterval
    @ObservationIgnored private weak var display: (any GuestDragDisplay)?
    private let reporter: ClipboardTransferReporter
    private let peerName: String
    private let clock: any EngineClock
    private let holds: @MainActor () -> Bool
    private let onFinished: @MainActor (GuestDragTake) -> Void

    @ObservationIgnored private var nextNudge: GuestDragNudge = .exitPoint
    @ObservationIgnored private var deadline: Task<Void, Never>?
    @ObservationIgnored private var holdsWatch: ObservationLoop?

    // MARK: The catcher

    /// How many times the guest was asked to show its catcher: `DragTake`,
    /// then each `DragCatcher` that shows it again.
    @ObservationIgnored private var catcherShowings = 1
    /// How many `ARMED` reports the guest sent. The guest arms once per
    /// showing, in order on one channel, so a step that arrives while this
    /// trails ``catcherShowings`` answers a showing that was since stood down.
    @ObservationIgnored private var catcherArmings = 0
    /// Whether the guest's catcher can no longer take the drag: the guest
    /// reported a failure, or the channel ended.
    @ObservationIgnored private var catcherLost = false

    /// Whether the catcher's latest showing is up and can still take the drag.
    private var catcherArmed: Bool { !catcherLost && catcherArmings == catcherShowings }

    // MARK: After the Mac session begins

    /// Whether a Mac drag session carries the items, so a destination may ask
    /// for them.
    @ObservationIgnored private var hasHostSession = false
    /// Whether no Mac destination will ask for the items: the session ended
    /// with nothing taking it, or was dropped into the guest.
    @ObservationIgnored private var noDestinationAsks = false
    /// Whether the guest's drag is over — caught, or reported failed — so a
    /// `DragComplete` can no longer reach its catcher ahead of the injected
    /// release.
    @ObservationIgnored private var guestDragEnded = false
    @ObservationIgnored private var isSuperseded = false
    /// Whether this take is done with the drag: `DragComplete` sent, or the
    /// channel gone.
    @ObservationIgnored private var isRetired = false
    @ObservationIgnored private var isFinished = false

    // MARK: Naming promised items

    /// What the take decided about asking the guest to name the drag's
    /// promised items; `nil` until something needs them.
    private enum Naming {
        /// The guest was asked; every later ask joins that one.
        case asked
        /// A destination asked while the catcher was not the drag's target and
        /// holds a stand-in name, so nothing asks the guest any more.
        case forgone
    }

    @ObservationIgnored private var naming: Naming?

    nonisolated private static let logger = KernovaLogger(
        subsystem: "app.kernova", category: "GuestDragTake")

    /// Takes over `drag` on `endpoint` for `display`, which the take drives
    /// while `holds` stays true.
    ///
    /// `onFinished` is called once, when the take is retired and no write is
    /// still pulling or landing — from then on nothing reads what the drag's
    /// pulls staged. Nothing is sent until ``begin()``.
    init(
        drag: ClipboardInboundDrag, endpoint: ClipboardEndpoint, display: any GuestDragDisplay,
        reporter: ClipboardTransferReporter, peerName: String,
        progressRevealDelay: TimeInterval, progressIdleGap: TimeInterval,
        namingDeadline: TimeInterval = GuestDragTake.namingDeadline, clock: any EngineClock,
        holds: @escaping @MainActor () -> Bool,
        onFinished: @escaping @MainActor (GuestDragTake) -> Void
    ) {
        self.generation = drag.generation
        self.items = drag.items
        self.endpoint = endpoint
        self.writer = GuestDragItemWriter(
            generation: drag.generation, items: drag.items, endpoint: endpoint, reporter: reporter,
            peerName: peerName, progressRevealDelay: progressRevealDelay,
            progressIdleGap: progressIdleGap)
        self.namingDeadline = namingDeadline
        self.display = display
        self.reporter = reporter
        self.peerName = peerName
        self.clock = clock
        self.holds = holds
        self.onFinished = onFinished
        writer.owner = self
    }

    /// Asks the guest to hand the drag over, and starts the hand-off's bounds:
    /// its deadline, and the condition it holds under.
    ///
    /// Announced to the reporter as a gesture of its own: a write can fail
    /// before its readout publishes anything, and its refusal would otherwise
    /// collapse into the identical one the last take left standing
    /// (`ClipboardTransferReporter.gestureBegan`).
    func begin() {
        reporter.gestureBegan()
        endpoint.sendDragTake(generation: generation)
        startDeadline()
        holdsWatch = observeRecurring(
            track: { [weak self] in _ = self?.holds() },
            apply: { [weak self] in
                guard let self, !self.holds() else { return }
                self.vmStopped()
            })
        Self.logger.log(
            .notice,
            "Taking over the guest drag gen=\(self.generation, privacy: .public) of \(self.items.count, privacy: .public) item(s) from '\(self.peerName, privacy: .public)'"
        )
    }

    // MARK: - The display's events

    package func withheldDrag() {
        switch phase {
        case .handingOff(armed: true):
            nudge()
        case .ready:
            guard display?.beginHostSession(carrying: self) == true else {
                return release(at: .catcher)
            }
            hasHostSession = true
            phase = .carried(.outside(targeted: true))
            Self.logger.log(
                .notice,
                "A Mac drag session carries guest drag gen=\(self.generation, privacy: .public); the guest's button stays held"
            )
        case .handingOff(armed: false), .carried, .released, .unreleased, .abandoned:
            break
        }
    }

    package func withheldMouseUp() {
        switch phase {
        case .handingOff:
            abandon(because: "the button came up before the guest's catcher was targeted", tellingGuest: true)
        case .ready:
            release(at: .catcher)
        case .carried, .released, .unreleased, .abandoned:
            break
        }
    }

    package func pointerReturned() {
        abandon(because: "the pointer came back over the display", tellingGuest: true)
    }

    package func displayAbandoned() {
        switch phase {
        case .handingOff, .ready:
            abandon(because: "the display can no longer carry the press", tellingGuest: true)
        case .carried(let carriage):
            // Nothing can wait for a target any more: a new press is about to
            // reach the guest, or the display is gone.
            release(at: carriage == .outside(targeted: true) ? .catcher : .exitPoint)
        case .released, .unreleased, .abandoned:
            break
        }
    }

    package func hostSessionMoved() {
        // The user's own motion re-nudges a catcher shown again, as withheld
        // drags do before the session.
        guard phase == .carried(.outside(targeted: false)), catcherArmed else { return }
        nudge()
    }

    package func hostSession(over display: any GuestDragDisplay, at point: CGPoint) -> Bool {
        guard display === self.display, case .carried(let carriage) = phase else { return false }
        switch carriage {
        case .outside:
            phase = .carried(.inside)
            endpoint.sendDragCatcher(generation: generation, shown: false)
            Self.logger.log(
                .notice,
                "The Mac session carrying drag gen=\(self.generation, privacy: .public) came back over its display; the guest's catcher stands down"
            )
        case .inside:
            break
        case .ended:
            return false
        }
        display.injectDrag(at: point)
        return true
    }

    package func hostSessionLeft(_ display: any GuestDragDisplay) {
        guard display === self.display, phase == .carried(.inside) else { return }
        showCatcherAgain()
        phase = .carried(.outside(targeted: false))
    }

    package func hostSessionDropped(on display: any GuestDragDisplay, at point: CGPoint) -> Bool {
        guard display === self.display, phase == .carried(.inside) else { return false }
        noDestinationAsks = true
        display.injectDrag(at: point)
        release(at: .dropPoint)
        return true
    }

    package func hostSessionEnded(dropped: Bool) {
        if !dropped { noDestinationAsks = true }
        if phase == .carried(.outside(targeted: true)), namingOwed {
            // The destination may ask for the names only once the session is
            // over, so the guest names them now, on the release that ends its
            // drag.
            naming = .asked
            _ = resolveNames(releasingFrom: phase)
        }
        guard case .carried(let carriage) = phase else { return retireIfDone() }
        switch carriage {
        case .outside(targeted: true):
            release(at: .catcher)
        case .inside:
            // Ended over the display with no drop there, so nothing in the
            // guest is where the user let go: the catcher takes it.
            showCatcherAgain()
            awaitTarget()
        case .outside(targeted: false):
            awaitTarget()
        case .ended:
            break
        }
    }

    // MARK: - The guest's reports

    /// Takes one step of the guest's hand-off.
    func handOff(_ step: ClipboardDragHandOffStep) {
        switch step {
        case .armed:
            catcherArmings += 1
            guard catcherArmed else { return }
            switch phase {
            case .handingOff(armed: false):
                phase = .handingOff(armed: true)
                nudge()
            case .carried(.outside(targeted: false)), .carried(.ended):
                nudge()
            case .handingOff(armed: true), .ready, .carried, .released, .unreleased, .abandoned:
                break
            }
        case .targeted:
            // A target for a showing since stood down says nothing about the
            // catcher up now.
            guard catcherArmed else { return }
            switch phase {
            case .handingOff:
                phase = .ready
                stopDeadline()
                Self.logger.log(
                    .notice,
                    "The guest's catcher is the target of drag gen=\(self.generation, privacy: .public)")
            case .carried(.outside(targeted: false)):
                phase = .carried(.outside(targeted: true))
                Self.logger.log(
                    .notice,
                    "The guest's catcher, shown again, is the target of drag gen=\(self.generation, privacy: .public)"
                )
            case .carried(.ended):
                if namingOwed {
                    stopDeadline()
                    naming = .asked
                    _ = resolveNames(releasingFrom: phase)
                }
                release(at: .catcher)
            case .ready, .carried, .released, .unreleased, .abandoned:
                break
            }
        case .caught:
            switch phase {
            case .handingOff, .ready:
                // Nothing here released the button, so the guest dropped on
                // its catcher by some path this side did not drive.
                abandon(because: "the guest reported a catch nothing released", tellingGuest: true)
            case .carried:
                guestDragEnded = true
                endUnreleased(because: "the guest reported a catch nothing released")
            case .released, .unreleased:
                guestDragEnded = true
                retireIfDone()
            case .abandoned:
                break
            }
        case .resolving:
            // Answers the `DragResolve` a naming of promised items sends, which
            // the endpoint consumes itself
            // (`ClipboardEndpoint.resolveDragNames(generation:deadline:releasingGuestButton:)`).
            break
        case .failed(let code, let message):
            let reason = "the guest failed the hand-off (\(code?.rawValue ?? "unknown")): \(message)"
            switch phase {
            case .handingOff, .ready:
                abandon(because: reason, tellingGuest: true)
            case .carried(let carriage):
                // A failed take's catcher is down, or up only to refuse the
                // drop, so a `DragComplete` can no longer overtake anything. A
                // later `FAILED` — the stale refusal of a re-show after the
                // guest ended the take — lands here again and changes nothing.
                guestDragEnded = true
                loseCatcher(because: reason, carriage: carriage)
            case .released, .unreleased:
                Self.logger.log(
                    .warning,
                    "The guest reported drag gen=\(self.generation, privacy: .public) failed after its release (\(code?.rawValue ?? "unknown", privacy: .public)): \(message, privacy: .public)"
                )
                guestDragEnded = true
                retireIfDone()
            case .abandoned:
                break
            }
        }
    }

    /// The guest withdrew the drag (`DragRelease`), which the endpoint has
    /// already retired.
    ///
    /// Once the Mac session begins the guest's watcher never withdraws a taken
    /// drag, so a withdrawal then is the guest user's Cancel on the readout
    /// serving it, and ends the take's transfers as cancelled.
    func guestWithdrew() {
        switch phase {
        case .handingOff, .ready:
            abandon(because: "the guest withdrew the drag", tellingGuest: true)
        case .carried:
            writer.cancelOwed(destinationMayAsk: destinationMayAsk)
        case .released, .unreleased:
            guestDragEnded = true
            writer.cancelOwed(destinationMayAsk: destinationMayAsk)
            retireIfDone()
        case .abandoned:
            break
        }
    }

    /// A newer take replaced this one: a take not yet carried by a Mac session
    /// is abandoned, and one that is stops waiting for its guest drag, which
    /// ended with its press, but still writes what its Mac destination asks
    /// for.
    func supersede() {
        isSuperseded = true
        switch phase {
        case .handingOff, .ready:
            abandon(because: "a newer drag replaced it", tellingGuest: true)
        case .carried:
            endUnreleased(because: "a newer drag replaced it")
        case .released, .unreleased:
            retireIfDone()
        case .abandoned:
            break
        }
    }

    /// The drop channel is gone, and the drag with it; nothing is sent.
    func channelEnded() {
        switch phase {
        case .handingOff, .ready:
            abandon(because: "the drop channel closed", tellingGuest: false)
        case .carried(let carriage):
            writer.interruptOwed(destinationMayAsk: destinationMayAsk)
            retire(tellingGuest: false)
            loseCatcher(because: "the drop channel closed", carriage: carriage)
        case .released, .unreleased:
            writer.interruptOwed(destinationMayAsk: destinationMayAsk)
            retire(tellingGuest: false)
        case .abandoned:
            break
        }
    }

    // MARK: - Hand-off steps

    private func nudge() {
        let nudge = nextNudge
        nextNudge = nudge.next
        display?.injectNudge(nudge)
    }

    private func startDeadline() {
        deadline?.cancel()
        deadline = clock.schedule(after: Self.handOffDeadline) { [weak self] in
            await self?.handOffDeadlinePassed()
        }
    }

    private func stopDeadline() {
        deadline?.cancel()
        deadline = nil
    }

    private func handOffDeadlinePassed() {
        let reason = "the guest went \(Self.handOffDeadline) s without its catcher becoming the target"
        switch phase {
        case .handingOff:
            abandon(because: reason, tellingGuest: true)
        case .carried(.ended):
            Self.logger.log(
                .notice,
                "Releasing drag gen=\(self.generation, privacy: .public) where it left the display: \(reason, privacy: .public)"
            )
            release(at: .exitPoint)
        case .ready, .carried, .released, .unreleased, .abandoned:
            break
        }
    }

    private func vmStopped() {
        switch phase {
        case .handingOff, .ready:
            abandon(because: "the VM stopped running", tellingGuest: true)
        case .carried:
            endUnreleased(because: "the VM stopped running")
        case .released, .unreleased, .abandoned:
            break
        }
    }

    /// Asks the guest to show its catcher again, as the Mac session leaves
    /// this VM's display or ends over it.
    private func showCatcherAgain() {
        guard !catcherLost else { return }
        catcherShowings += 1
        endpoint.sendDragCatcher(generation: generation, shown: true)
    }

    /// Waits, within the hand-off deadline, for the catcher to become the
    /// target of a drag whose Mac session ended — at once at the exit point
    /// when no catcher can take it.
    private func awaitTarget() {
        guard !catcherLost else { return release(at: .exitPoint) }
        phase = .carried(.ended)
        startDeadline()
        Self.logger.log(
            .notice,
            "The Mac session carrying drag gen=\(self.generation, privacy: .public) ended; waiting for the guest's catcher to be the target"
        )
        // The user letting go is the last motion the session gives a nudge to
        // ride.
        if catcherArmed { nudge() }
    }

    /// The guest's catcher can no longer take the drag, so the release goes
    /// where it left the display — now, when the session has already ended.
    private func loseCatcher(because reason: String, carriage: Carriage) {
        catcherLost = true
        Self.logger.log(
            .notice,
            "The guest's catcher can no longer take drag gen=\(self.generation, privacy: .public): \(reason, privacy: .public)"
        )
        switch carriage {
        case .outside:
            phase = .carried(.outside(targeted: false))
        case .inside:
            break
        case .ended:
            release(at: .exitPoint)
        }
    }

    /// Releases the guest's button at `spot`, which only ``Phase/ready`` and
    /// ``Phase/carried(_:)`` reach, and so at most once.
    private func release(at spot: ReleaseSpot) {
        switch phase {
        case .ready, .carried: break
        case .handingOff, .released, .unreleased, .abandoned: return
        }
        phase = .released(at: spot)
        stopBounds()
        if spot == .exitPoint { display?.returnToExitPoint() }
        display?.injectRelease()
        Self.logger.log(
            .notice,
            "Released the guest's button for drag gen=\(self.generation, privacy: .public) at the \(spot.logName, privacy: .public) (Mac session: \(self.hasHostSession, privacy: .public))"
        )
        retireIfDone()
    }

    /// Ends a carried take that will never release: the guest's press is
    /// over, or the VM stopped under it.
    private func endUnreleased(because reason: String) {
        guard case .carried = phase else { return }
        phase = .unreleased
        stopBounds()
        Self.logger.log(
            .notice,
            "Ended the take of guest drag gen=\(self.generation, privacy: .public) without a release: \(reason, privacy: .public)"
        )
        retireIfDone()
    }

    /// Ends a take before its Mac session, returning the guest pointer to
    /// where the drag left the display and handing the press back.
    private func abandon(because reason: String, tellingGuest: Bool) {
        switch phase {
        case .handingOff, .ready: break
        case .carried, .released, .unreleased, .abandoned: return
        }
        phase = .abandoned
        stopBounds()
        Self.logger.log(
            .notice,
            "Abandoned the take of guest drag gen=\(self.generation, privacy: .public): \(reason, privacy: .public)"
        )
        retire(tellingGuest: tellingGuest)
        display?.returnToExitPoint()
        display?.resumeForwarding()
    }

    private func stopBounds() {
        stopDeadline()
        holdsWatch?.cancel()
        holdsWatch = nil
    }

    // MARK: - Retiring

    /// Sends the drag's `DragComplete` once nothing will pull from it again and
    /// the guest's own drag is over.
    ///
    /// The guest's catcher comes down on `DragComplete` for a take it did not
    /// refuse, so one that overtook the injected release would let that
    /// release drop on whatever lies under the guest pointer — hence a take
    /// released onto its catcher or at the exit point waits for the guest to
    /// report `CAUGHT` or `FAILED`, and none goes out before the release. A
    /// drop into the guest happens with the catcher stood down. A superseded
    /// take's guest drag ended with its press, before the newer guest press
    /// the supersession needs, but its destination may still have writes
    /// queued, so it retires like any other released take.
    private func retireIfDone() {
        let guestDone: Bool
        switch phase {
        case .released(let spot): guestDone = spot == .dropPoint || guestDragEnded || isSuperseded
        case .unreleased: guestDone = true
        case .handingOff, .ready, .carried, .abandoned: return
        }
        guard !isRetired else { return }
        let nothingMoreToWrite = !destinationMayAsk || writer.isDone
        guard guestDone, nothingMoreToWrite, writer.isIdle else { return }
        retire(tellingGuest: true)
    }

    private func retire(tellingGuest: Bool) {
        guard !isRetired else { return }
        isRetired = true
        if tellingGuest {
            endpoint.completeDrag(generation: generation)
        } else {
            endpoint.retireInbound(generation: generation)
        }
        finishIfIdle()
    }

    /// Reports the take finished once it is retired and its last write has
    /// settled: a channel's end retires a take with writes still in flight.
    private func finishIfIdle() {
        guard isRetired, writer.isIdle, !isFinished else { return }
        isFinished = true
        onFinished(self)
    }

    /// Whether a Mac destination may still ask for items: a Mac session
    /// carries them, and it neither ended with nothing taking it nor was
    /// dropped into the guest.
    private var destinationMayAsk: Bool { hasHostSession && !noDestinationAsks }

    // MARK: - Naming promised items

    /// A promised item's name comes from the guest only while the catcher is
    /// the drag's target. A destination asking at any other moment gets a
    /// stand-in at once rather than having the catcher re-targeted, which
    /// takes the take's own nudges on the main actor this wait may be holding:
    /// a Mac drop within a frame or two of the session leaving the display
    /// again is that case.
    nonisolated package func filename(forItemAt index: Int) -> String {
        guard items.indices.contains(index) else { return Self.genericStem(isDirectory: false) }
        let item = items[index]
        if let filename = item.filename { return filename }
        return promisedNames()?[item.repIndex] ?? Self.standInName(for: item)
    }

    package func nameItemsForInAppDestination() -> Bool {
        guard items.contains(where: \.isPromised) else { return true }
        guard promisedNames() != nil else {
            writer.failNaming()
            return false
        }
        return true
    }

    /// Whether a destination that took the drop may yet ask for promised items
    /// nothing has asked the guest to name.
    private var namingOwed: Bool {
        destinationMayAsk && naming == nil && items.contains(where: \.isPromised)
    }

    /// The names the guest gave the promised items — asking for them while the
    /// catcher is the drag's target, when nothing has yet — or `nil` when they
    /// cannot be had.
    nonisolated private func promisedNames() -> [Int: String]? {
        if let names = endpoint.resolvedDragNames(generation: generation) { return names }
        let targeted = Phase.carried(.outside(targeted: true))
        guard MainActorBridge.sync({ self.admitNaming(from: targeted) }) else { return nil }
        return resolveNames(releasingFrom: targeted)
    }

    /// Whether the guest is asked for names now: a first ask decides, by
    /// whether the take is in `expected`, and every later one follows it.
    private func admitNaming(from expected: Phase) -> Bool {
        if let naming { return naming == .asked }
        guard phase == expected else {
            naming = .forgone
            Self.logger.log(
                .warning,
                "A Mac destination asked for the names of drag gen=\(self.generation, privacy: .public)'s promised items while the guest's catcher was not its target; they get stand-in names"
            )
            return false
        }
        naming = .asked
        return true
    }

    /// Has the guest name the promised items, its button released from
    /// `expected` once the catcher will call them in, returning the names or
    /// `nil` when they could not be had.
    nonisolated private func resolveNames(releasingFrom expected: Phase) -> [Int: String]? {
        let result = endpoint.resolveDragNames(
            generation: generation, deadline: .now() + namingDeadline
        ) {
            MainActorBridge.sync { self.releaseForNaming(from: expected) }
        }
        switch result {
        case .success(let names):
            return names
        case .failure(let failure):
            Self.logger.log(
                .warning,
                "The guest did not name drag gen=\(self.generation, privacy: .public)'s promised items: \(String(describing: failure), privacy: .public)"
            )
            return nil
        }
    }

    /// Releases the guest's button onto its catcher, which answered that it
    /// calls the promises in on this drop — unless the take has moved on from
    /// `expected`, where its own paths release.
    private func releaseForNaming(from expected: Phase) {
        guard phase == expected else {
            Self.logger.log(
                .notice,
                "Drag gen=\(self.generation, privacy: .public) moved on before the guest's catcher was ready to call its promises in; no release for them"
            )
            return
        }
        release(at: .catcher)
    }

    /// What a promised item the guest did not name is called: a generic stem
    /// with its declared type's extension.
    nonisolated static func standInName(for item: ClipboardDraggedItem) -> String {
        let stem = genericStem(isDirectory: item.isDirectory)
        guard let pathExtension = item.type.preferredFilenameExtension else { return stem }
        return "\(stem).\(pathExtension)"
    }

    nonisolated private static func genericStem(isDirectory: Bool) -> String {
        ClipboardDraggedItem.safeFilename("", isDirectory: isDirectory)
    }

    // MARK: - Writing items

    nonisolated package func writeItem(at index: Int, to destination: URL) throws {
        try writer.write(at: index, to: destination)
    }

    var acceptsWrites: Bool { hasHostSession && !isRetired }

    func writesSettled() {
        retireIfDone()
        finishIfIdle()
    }

    #if DEBUG
    /// Test seam: ``GuestDragItemWriter/onLandingForTesting(_:)``.
    func onLandingForTesting(_ body: (@Sendable (URL?) -> Void)?) {
        writer.onLandingForTesting(body)
    }
    #endif
}

extension GuestDragTake.ReleaseSpot {
    /// How a log line names the spot.
    fileprivate var logName: String {
        switch self {
        case .catcher: "catcher"
        case .dropPoint: "drop point"
        case .exitPoint: "exit point"
        }
    }
}
