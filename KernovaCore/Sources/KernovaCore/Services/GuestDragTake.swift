import Foundation
import KernovaAgentCore
import KernovaTransferProgress
import Synchronization
import KernovaKit
import KernovaLogging
import KernovaWire
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

/// One item of a guest's drag offer as a Mac drag session carries it: the
/// FILE or FOLDER representation the guest offers it as.
package struct DraggedOutItem: Equatable, Sendable {
    /// The item's name, as the offer carries it.
    package var name: Data
    /// The type a Mac destination is promised.
    package var type: UTType
    /// Whether the item is a folder.
    package var isDirectory: Bool
    /// Whether the guest's source writes it only once called in, so its name
    /// is a stand-in until the drag is delivered.
    package var isPromised: Bool
    /// The representation a pull names.
    package var representation: UInt32
    /// The guest's estimate of its bytes; 0 when unknown.
    package var sizeEstimate: UInt64

    /// What a Mac destination is told the item is called.
    package var filename: String { String(decoding: name, as: UTF8.self) }

    /// What a take carries of `items`, which its first `TARGETED` listed and
    /// the hub checked with `DragItems.carried(_:)`.
    package static func carried(_ items: [OfferedItem]) -> [DraggedOutItem] {
        (DragItems.carried(items) ?? []).map { DraggedOutItem($0.representation, at: $0.index) }
    }

    /// The item carried out of the guest by `representation`, at `index` among
    /// its item's representations (`DragItems.carried(_:)`).
    package init(_ representation: Representation, at index: UInt32) {
        let isDirectory = representation.storage == .folder
        let declared = representation.type.appleUTI.flatMap { UTType($0) }
        self.init(
            name: representation.name, type: declared ?? (isDirectory ? .folder : .data), isDirectory: isDirectory,
            isPromised: representation.promised, representation: index, sizeEstimate: representation.sizeEstimate)
    }

    package init(
        name: Data, type: UTType, isDirectory: Bool, isPromised: Bool = false, representation: UInt32 = 0,
        sizeEstimate: UInt64 = 0
    ) {
        self.name = name
        self.type = type
        self.isDirectory = isDirectory
        self.isPromised = isPromised
        self.representation = representation
        self.sizeEstimate = sizeEstimate
    }
}

/// Why a dragged item never reached where it was dropped.
package enum GuestDragWriteError: Error, Equatable, Sendable {
    /// The transfer failed, for the reason the drag's readout reports.
    case failed(ClipboardTransferFailure)
}

/// What a take hears from the guest on its stream.
package enum GuestDragTakeEvent: Equatable, Sendable {
    /// A step of the guest's hand-off.
    case report(DragTakeReport)
    /// The take ended: the guest's END, or how the stream closed without one.
    case ended(DragTakeResult)
}

/// What a take moves its drag over: the guest peer that offered it.
@MainActor
package protocol GuestDragTransport: AnyObject {
    /// Takes the guest's drag over: `events` hears each report and then the
    /// end, once, and the transport settles `delivery` as the take ends — off
    /// the main actor, reading the offer a delivering catch names first.
    func take(delivery: GuestDragDelivery, _ events: @escaping @MainActor (GuestDragTakeEvent) -> Void)

    /// Tells the guest `control` on the take.
    func control(_ control: DragTakeControl)

    /// Calls the take off; its end follows.
    func cancel()

    /// Pulls `item`, item `index` of the taken offer, to exactly
    /// `destination`, its landing reporting to `progress`, calling `ended`
    /// once with how the pull ended, and returns what cancels it.
    func pull(
        _ item: DraggedOutItem, at index: Int, to destination: URL, progress: (any ItemLandingProgress)?,
        ended: @escaping @MainActor (Result<Void, WireError>) -> Void
    ) -> @MainActor () -> Void

    /// Releases the taken offer: this side pulls nothing more of it.
    func release()
}

/// The VM display a take drives: it withholds the press while the guest
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
    /// drag on whatever is under it; the rest of the press reaches the guest
    /// no more.
    ///
    /// Called at most once per take.
    func injectRelease()

    /// Begins the Mac drag session carrying `take`'s items from the physical
    /// drag event the display is withholding right now, reporting whether one
    /// began.
    func beginHostSession(carrying take: any GuestDragTaking) -> Bool

    /// Hands the rest of the press back to the guest, the event being withheld
    /// right now included, and looks again for a drag to take over.
    func resumeTracking()
}

/// A guest drag the VM display has taken over, as the display and the Mac
/// drag session it begins speak to it.
@MainActor
package protocol GuestDragTaking: AnyObject, Sendable {
    /// What the drag carries, in the order the guest's catcher saw it; a
    /// promised item's name is a stand-in. Empty until the catcher is the
    /// drag's target, which the Mac session begins after.
    nonisolated var items: [DraggedOutItem] { get }

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

    /// A withheld drag event came back inside the display before a Mac
    /// session began: the user means the drag for the guest after all.
    func pointerReturned()

    /// The display can no longer carry the press — it left its window, or a
    /// new press began without the last one ending.
    func displayAbandoned()

    /// The Mac drag session carrying the take is beginning, its promises just
    /// written to the drag pasteboard over whatever an earlier drag put there.
    func hostSessionWillBegin()

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

    /// What item `index` is called where a Mac destination writes it. A
    /// promised item's name comes from the drag's delivery, which this asks
    /// for and waits on, from any thread, when the guest's catcher is the
    /// drag's target; at any other moment it is a stand-in.
    nonisolated func filename(forItemAt index: Int) -> String

    /// Has the drag's delivery name its promised items before a destination
    /// in this app calls them in, holding the main thread, and reports whether
    /// they are named.
    ///
    /// An in-app destination's provider is asked for names off the main
    /// thread while the main thread waits in `receivePromisedFiles`, and the
    /// release a delivery needs runs on the main thread.
    func nameItemsForInAppDestination() -> Bool

    /// Writes item `index` to exactly `destination`, calling `completion` once,
    /// from any thread, when it lands or fails: with `CocoaError(.userCancelled)`
    /// when the user called the drag's transfers off, and otherwise with a
    /// ``GuestDragWriteError``.
    nonisolated func writeItem(
        at index: Int, to destination: URL, completion: @escaping @Sendable ((any Error)?) -> Void)

    /// Runs `body` once the take retires — it delivers nothing more, so the
    /// Mac session's promises must be withdrawn — or at once if it has.
    func whenRetired(_ body: @escaping @MainActor () -> Void)
}

/// One guest drag the VM display took over at its edge: the hand-off that moves
/// the guest's drag onto its catcher, and the Mac drag session that carries it
/// on, each item pulled from the guest to where a Mac destination writes it.
///
/// Every button release the take injects is a real drop under the guest
/// pointer, so it lands in one of two places: on a catcher that reported
/// `TARGETED` for its latest showing, or where the user's own release would
/// have landed with drag-out off — where they let go over this VM's display,
/// or, when no catcher can take the drop, where the drag left the display.
///
/// The guest's drag stays live, its button held, for as long as the Mac
/// session runs: over this VM's display the catcher stands down and the guest
/// pointer follows the session, so a drag that comes back drops inside the
/// guest, released only once the guest reports the catcher `STOOD_DOWN`.
/// `NSDraggingSession` cannot be withdrawn, so the session begins only from
/// ``Phase/ready``, which only `TARGETED` enters, and every end before it
/// hands the press back.
///
/// A drag a Mac destination takes is delivered: the take asks the guest
/// (`DragDeliver`) and releases onto its catcher once the guest answers; the
/// catcher's drop calls the promises in and names them on the take, then
/// sizes its items and ends it. Every item is pulled from the taken offer,
/// which only this side ends. The first destination to ask a promised item's
/// name starts that and waits for the names alone; one that took the drop
/// without asking yet has it started as the session ends. That wait alone has
/// a wall clock, `GuestDragDelivery.namingDeadline`, past which the take is
/// called off and its writes fail timed out; every other wait ends on the
/// guest's answer, the take's end, or the user's own release or return.
///
/// The Mac session's file promises live exactly as long as the take can keep
/// them: the take retires once it delivers nothing more, and its retirement is
/// what withdraws them (``whenRetired(_:)``), so the drag pasteboard never
/// advertises a file Kernova can no longer deliver.
@MainActor
@Observable
package final class GuestDragTake: GuestDragTaking {
    /// Where the hand-off stands.
    package enum Phase: Equatable, Sendable {
        /// `DRAG_TAKE` is out and the press is withheld; `armed` once the guest
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
        /// began: the VM stopped under it, or a newer drag replaced it.
        case unreleased
        /// The take ended before the Mac session and the press went back to
        /// the guest.
        case abandoned
    }

    /// Where the Mac session carrying the guest's drag stands.
    package enum Carriage: Equatable, Sendable {
        /// Off this VM's display; `targeted` while the guest's catcher, shown,
        /// is the drag's target.
        case outside(targeted: Bool)
        /// Over this VM's display: the catcher is asked to stand down, and the
        /// guest pointer follows the session.
        case inside
        /// Dropped on this VM's display; the release at the drop point waits
        /// for the catcher to report itself stood down.
        case dropped
        /// The session ended away from the guest; the release waits for the
        /// catcher to become the drag's target.
        case ended
        /// The guest is asked to deliver the drag; the release onto its
        /// catcher waits for its answer.
        case delivering
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

    nonisolated package var items: [DraggedOutItem] { carried.withLock { $0 } }
    /// The drag's items, set once by the take's first `TARGETED`.
    nonisolated private let carried = Mutex<[DraggedOutItem]>([])
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

    /// The drag's delivery, which a name ask on any thread waits on.
    nonisolated private let delivery: GuestDragDelivery

    @ObservationIgnored private let transport: any GuestDragTransport
    @ObservationIgnored private weak var display: (any GuestDragDisplay)?
    @ObservationIgnored private let reporter: ClipboardTransferReporter
    @ObservationIgnored private let peerName: String
    @ObservationIgnored private let progressRevealDelay: TimeInterval
    @ObservationIgnored private let progressIdleGap: TimeInterval
    @ObservationIgnored private let holds: @MainActor () -> Bool
    @ObservationIgnored private let onFinished: @MainActor (GuestDragTake) -> Void
    @ObservationIgnored private let onHostSessionBegan: @MainActor (GuestDragTake) -> Void

    @ObservationIgnored private var nextNudge: GuestDragNudge = .exitPoint
    @ObservationIgnored private var holdsWatch: ObservationLoop?

    // MARK: The catcher

    /// How many times the guest was asked to show its catcher: the take, then
    /// each `DragCatcher` that shows it again.
    @ObservationIgnored private var catcherShowings = 1
    /// How many `ARMED` reports the guest sent. The guest arms once per
    /// showing, in order on one stream, so a step that arrives while this
    /// trails ``catcherShowings`` answers a showing that was since stood down.
    @ObservationIgnored private var catcherArmings = 0
    /// How many times the guest was asked to stand its catcher down.
    @ObservationIgnored private var catcherStandDowns = 0
    /// How many `STOOD_DOWN` reports the guest sent, one per stand-down, in
    /// order on one stream.
    @ObservationIgnored private var catcherStoodDown = 0
    /// Whether the guest's catcher can no longer take the drag: the take
    /// ended without a catch.
    @ObservationIgnored private var catcherLost = false

    /// Whether the catcher's latest showing is up and can still take the drag.
    private var catcherArmed: Bool { !catcherLost && catcherArmings == catcherShowings }

    /// Whether no catcher is up to take a release: the guest reported every
    /// stand-down, or the take ended.
    private var catcherDown: Bool { catcherLost || catcherStoodDown == catcherStandDowns }

    // MARK: The take and the offers

    /// Whether the take's stream is open: the guest has not ended it, and this
    /// side has not called it off.
    @ObservationIgnored private var takeOpen = true
    /// Whether the taken offer is open: this side has not released it, and the
    /// guest has not ended it.
    @ObservationIgnored private var offerOpen = true

    // MARK: After the Mac session begins

    @ObservationIgnored private var hasHostSession = false
    /// Whether the Mac session has begun and not yet ended.
    @ObservationIgnored private var hostSessionLive = false
    /// Whether no Mac destination will ask for the items: the session ended
    /// with nothing taking it, or was dropped into the guest.
    @ObservationIgnored private var noDestinationAsks = false
    /// Whether the guest was asked to deliver the drag.
    @ObservationIgnored private var deliveryAsked = false
    /// Whether a newer drag's Mac session wrote the drag pasteboard over this
    /// one's promises: no destination then asks for an item it has not asked
    /// for.
    @ObservationIgnored private var superseded = false
    @ObservationIgnored private var isFinished = false
    /// What runs once the take retires.
    @ObservationIgnored private var retirement: [@MainActor () -> Void] = []

    // MARK: Writing items

    /// How the writes ended early, once they did.
    @ObservationIgnored private var terminal: Terminal?
    @ObservationIgnored private var written: Set<Int> = []
    /// The items a Mac destination asked for: by name, which it asks before it
    /// writes, or by a write.
    nonisolated private let asked = Mutex<Set<Int>>([])
    /// The writes pulling now, by item index, each with what cancels it.
    @ObservationIgnored private var inFlight: [Int: @MainActor () -> Void] = [:]
    /// The writes waiting for the drag's delivery to say what to pull, by item
    /// index.
    @ObservationIgnored private var owed: [Int: (destination: URL, completion: @Sendable ((any Error)?) -> Void)] = [:]
    @ObservationIgnored private var readout: ClipboardTransferOperation?

    private enum Terminal {
        case cancelled
        case failed(ClipboardTransferFailure)
    }

    nonisolated private static let logger = KernovaLogger(
        subsystem: "app.kernova", category: "GuestDragTake")

    /// Takes over a guest drag through
    /// `transport` for `display`, which the take drives while `holds` stays
    /// true.
    ///
    /// `onFinished` is called once, when the take's stream has closed, its
    /// offers are released or ended, and no write is still pulling;
    /// `onHostSessionBegan` as its Mac session begins. The delivery's naming
    /// deadline runs on `clock`. Nothing is sent until ``begin()``.
    init(
        transport: any GuestDragTransport, display: any GuestDragDisplay,
        reporter: ClipboardTransferReporter, peerName: String,
        progressRevealDelay: TimeInterval = ClipboardTransferOperation.defaultRevealDelay,
        progressIdleGap: TimeInterval = ClipboardTransferOperation.defaultIdleGap,
        clock: any EngineClock = makePlatformEngineClock(),
        holds: @escaping @MainActor () -> Bool,
        onFinished: @escaping @MainActor (GuestDragTake) -> Void,
        onHostSessionBegan: @escaping @MainActor (GuestDragTake) -> Void
    ) {
        self.transport = transport
        self.display = display
        self.reporter = reporter
        self.peerName = peerName
        self.progressRevealDelay = progressRevealDelay
        self.progressIdleGap = progressIdleGap
        self.delivery = GuestDragDelivery(clock: clock)
        self.holds = holds
        self.onFinished = onFinished
        self.onHostSessionBegan = onHostSessionBegan
    }

    /// Asks the guest to hand the drag over, and starts watching the condition
    /// the take holds under.
    ///
    /// Announced to the reporter as a gesture of its own: a write can fail
    /// before its readout publishes anything, and its refusal would otherwise
    /// collapse into the identical one the last take left standing
    /// (`ClipboardTransferReporter.gestureBegan`).
    func begin() {
        reporter.gestureBegan()
        delivery.whenSettled { [weak self] in MainActorBridge.async { self?.deliverySettled() } }
        transport.take(delivery: delivery) { [weak self] event in self?.handle(event) }
        holdsWatch = observeRecurring(
            track: { [weak self] in _ = self?.holds() },
            apply: { [weak self] in
                guard let self, !self.holds() else { return }
                self.vmStopped()
            })
        Self.logger.log(
            .notice,
            "Taking over a guest drag from '\(self.peerName, privacy: .public)'"
        )
    }

    // MARK: - The display's events

    package func withheldDrag() {
        switch phase {
        case .handingOff(armed: true):
            nudge()
        case .ready:
            guard display?.beginHostSession(carrying: self) == true else { return release(at: .catcher) }
            hasHostSession = true
            hostSessionLive = true
            phase = .carried(.outside(targeted: true))
            Self.logger.log(.notice, "A Mac drag session carries the guest's drag; its button stays held")
        case .handingOff(armed: false), .carried, .released, .unreleased, .abandoned:
            break
        }
    }

    package func withheldMouseUp() {
        switch phase {
        case .handingOff: abandon(because: "the button came up before the guest's catcher was targeted")
        case .ready: release(at: .catcher)
        case .carried, .released, .unreleased, .abandoned: break
        }
    }

    package func pointerReturned() {
        abandon(because: "the pointer came back over the display")
    }

    package func displayAbandoned() {
        switch phase {
        case .handingOff, .ready:
            abandon(because: "the display can no longer carry the press")
        case .carried(let carriage):
            // Nothing can wait for a target any more: a new press is about to
            // reach the guest, or the display is gone.
            guard carriage != .dropped else { return release(at: .dropPoint) }
            let onCatcher = carriage == .outside(targeted: true) || carriage == .delivering
            release(at: onCatcher && catcherArmed ? .catcher : .exitPoint)
        case .released, .unreleased, .abandoned:
            break
        }
    }

    package func hostSessionWillBegin() {
        onHostSessionBegan(self)
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
            catcherStandDowns += 1
            transport.control(.catcher(shown: false))
            Self.logger.log(.notice, "The Mac session came back over its display; the guest's catcher stands down")
        case .inside:
            break
        case .ended, .delivering, .dropped:
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
        // A catcher still up would take the release the user meant for what
        // is under it.
        guard catcherDown else {
            phase = .carried(.dropped)
            Self.logger.log(.notice, "Dropped on the display; waiting for the guest's catcher to stand down")
            return true
        }
        release(at: .dropPoint)
        return true
    }

    package func hostSessionEnded(dropped: Bool) {
        hostSessionLive = false
        if !dropped { noDestinationAsks = true }
        guard case .carried(let carriage) = phase else { return retireIfDone() }
        switch carriage {
        case .outside(targeted: true):
            releaseOntoCatcher()
        case .inside:
            // Ended over the display with no drop there, so nothing in the
            // guest is where the user let go: the catcher takes it.
            showCatcherAgain()
            awaitTarget()
        case .outside(targeted: false):
            awaitTarget()
        case .ended, .delivering, .dropped:
            break
        }
    }

    // MARK: - The guest's side

    private func handle(_ event: GuestDragTakeEvent) {
        switch event {
        case .report(let report): reported(report)
        case .ended(let result): takeEnded(result)
        }
    }

    /// One step of the guest's hand-off.
    func reported(_ report: DragTakeReport) {
        switch report {
        case .armed:
            catcherArmings += 1
            guard catcherArmed else { return }
            switch phase {
            case .handingOff(armed: false):
                phase = .handingOff(armed: true)
                // The catcher becomes the drag's target only through motion
                // the guest's drag manager hit-tests after it appears, and a
                // pointer stopped past the edge makes none.
                nudge()
            case .carried(.outside(targeted: false)), .carried(.ended):
                nudge()
            case .handingOff(armed: true), .ready, .carried, .released, .unreleased, .abandoned:
                break
            }
        case .targeted(let listed):
            carried.withLock { if $0.isEmpty { $0 = DraggedOutItem.carried(listed) } }
            // A target for a showing since stood down says nothing about the
            // catcher up now.
            guard catcherArmed else { return }
            switch phase {
            case .handingOff:
                phase = .ready
                Self.logger.log(.notice, "The guest's catcher is the drag's target")
            case .carried(.outside(targeted: false)):
                phase = .carried(.outside(targeted: true))
                Self.logger.log(.notice, "The guest's catcher, shown again, is the drag's target")
            case .carried(.ended):
                releaseOntoCatcher()
            case .ready, .carried, .released, .unreleased, .abandoned:
                break
            }
        case .delivering, .deliverRefused:
            deliveryAnswered(delivering: report == .delivering)
        case .stoodDown:
            catcherStoodDown += 1
            if phase == .carried(.dropped), catcherDown { release(at: .dropPoint) }
        case .named:
            // The delivery hears the names on the transport's queue.
            break
        }
    }

    /// The take ended: the guest's END, or how the stream closed without one.
    func takeEnded(_ result: DragTakeResult) {
        takeOpen = false
        let reason = Self.describe(result)
        switch phase {
        case .handingOff, .ready:
            abandon(because: "the take ended before the Mac session: \(reason)")
        case .carried(let carriage):
            catcherLost = true
            Self.logger.log(.notice, "The guest's catcher can no longer take the drag: \(reason, privacy: .public)")
            switch carriage {
            case .outside: phase = .carried(.outside(targeted: false))
            case .inside: break
            case .dropped: release(at: .dropPoint)
            case .delivering where hostSessionLive: phase = .carried(.outside(targeted: false))
            case .ended, .delivering: release(at: .exitPoint)
            }
        case .released, .unreleased, .abandoned:
            retireIfDone()
        }
    }

    /// The taken offer ended without this side releasing it.
    func offerEnded() {
        guard offerOpen else { return }
        offerOpen = false
        switch phase {
        case .handingOff, .ready: abandon(because: "the guest's offer ended")
        case .carried, .released, .unreleased, .abandoned:
            endWrites(.interrupted(fileCount: items.count - written.count))
            retireIfDone()
        }
    }

    /// A newer take began, its press ending this take's guest drag: one not
    /// yet carried by a Mac session is abandoned, and one that is stops
    /// waiting for its guest drag. Its session's promises stay on the drag
    /// pasteboard until a newer session writes it (``promisesReplaced()``).
    func newerTakeBegan() {
        switch phase {
        case .handingOff, .ready: abandon(because: "a newer drag replaced it")
        case .carried: endUnreleased(because: "a newer drag replaced it")
        case .released, .unreleased, .abandoned: break
        }
    }

    /// A newer drag's Mac session wrote the drag pasteboard over this take's
    /// promises, so it writes what its Mac destination has asked for and then
    /// retires.
    func promisesReplaced() {
        superseded = true
        retireIfDone()
    }

    /// The app is terminating: the take writes nothing more and retires now,
    /// without waiting for the guest's answers, so its promises are withdrawn
    /// before the process resolves them on its way out.
    func endForTermination() {
        switch phase {
        case .handingOff, .ready: abandon(because: "the app is terminating")
        case .carried: endUnreleased(because: "the app is terminating")
        case .released: if takeOpen { transport.cancel() }
        // Each called the take off as it ended.
        case .unreleased, .abandoned: break
        }
        takeOpen = false
        cancelWrites()
        retire()
    }

    // MARK: - Hand-off steps

    private func nudge() {
        let nudge = nextNudge
        nextNudge = nudge.next
        display?.injectNudge(nudge)
    }

    private func vmStopped() {
        switch phase {
        case .handingOff, .ready: abandon(because: "the VM stopped running")
        case .carried: endUnreleased(because: "the VM stopped running")
        case .released, .unreleased, .abandoned: break
        }
    }

    /// Asks the guest to show its catcher again, as the Mac session leaves
    /// this VM's display or ends over it.
    private func showCatcherAgain() {
        guard !catcherLost else { return }
        catcherShowings += 1
        transport.control(.catcher(shown: true))
    }

    /// Waits for the catcher to become the target of a drag whose Mac session
    /// ended — at once at the exit point when no catcher can take it.
    private func awaitTarget() {
        guard !catcherLost else { return release(at: .exitPoint) }
        phase = .carried(.ended)
        Self.logger.log(.notice, "The Mac session ended; waiting for the guest's catcher to be the target")
        // The user letting go is the last motion the session gives a nudge to
        // ride.
        if catcherArmed { nudge() }
    }

    /// Releases onto the targeted catcher, asking the guest to deliver the
    /// drag first when a Mac destination may still ask for it: the delivery
    /// names its promises and sizes everything else, none of which the guest
    /// reads before the drop.
    private func releaseOntoCatcher() {
        guard destinationMayAsk else { return release(at: .catcher) }
        askDelivery()
    }

    /// Asks the guest to deliver the drag at the drop that follows; the release
    /// waits for its answer.
    private func askDelivery() {
        deliveryAsked = true
        phase = .carried(.delivering)
        transport.control(.deliver)
        Self.logger.log(.notice, "Asked the guest to deliver the drag at its catcher's drop")
    }

    /// The guest answered the ask for a delivering drop; a refusal means the
    /// drop delivers nothing, which the delivery's settling reports.
    private func deliveryAnswered(delivering: Bool) {
        guard phase == .carried(.delivering) else { return }
        if !delivering { Self.logger.log(.notice, "The guest refused to deliver the drag; releasing it anyway") }
        release(at: .catcher)
    }

    /// Releases the guest's button at `spot`, which only ``Phase/ready`` and
    /// ``Phase/carried(_:)`` reach, and so at most once.
    private func release(at spot: ReleaseSpot) {
        switch phase {
        case .ready, .carried: break
        case .handingOff, .released, .unreleased, .abandoned: return
        }
        phase = .released(at: spot)
        stopWatching()
        if spot == .exitPoint { display?.returnToExitPoint() }
        display?.injectRelease()
        Self.logger.log(
            .notice,
            "Released the guest's button at the \(spot.logName, privacy: .public) (Mac session: \(self.hasHostSession, privacy: .public))"
        )
        retireIfDone()
    }

    /// Ends a carried take that will never release, calling it off.
    private func endUnreleased(because reason: String) {
        guard case .carried = phase else { return }
        phase = .unreleased
        stopWatching()
        if takeOpen { transport.cancel() }
        Self.logger.log(.notice, "Ended the take without a release: \(reason, privacy: .public)")
        retireIfDone()
    }

    /// Ends a take before its Mac session, calling it off, returning the guest
    /// pointer to where the drag left the display and handing the press back.
    private func abandon(because reason: String) {
        switch phase {
        case .handingOff, .ready: break
        case .carried, .released, .unreleased, .abandoned: return
        }
        phase = .abandoned
        stopWatching()
        if takeOpen { transport.cancel() }
        Self.logger.log(.notice, "Abandoned the take of a guest drag: \(reason, privacy: .public)")
        display?.returnToExitPoint()
        display?.resumeTracking()
        retireIfDone()
    }

    private func stopWatching() {
        holdsWatch?.cancel()
        holdsWatch = nil
    }

    // MARK: - Retiring

    /// Whether a Mac destination may still ask for items: a Mac session
    /// carries them, and it neither ended with nothing taking it nor was
    /// dropped into the guest.
    private var destinationMayAsk: Bool { hasHostSession && !noDestinationAsks }

    /// Retires the take once nothing will pull from its offer again and its
    /// stream has closed.
    ///
    /// A Mac destination asks for the items after its session ends, at any
    /// moment and for only some of them, and AppKit reports no end to its
    /// asking. So a session a destination took holds the offer until every
    /// item is written, the writes ended, or a newer drag's session replaced
    /// its promises — after which only an item already asked for is still
    /// written.
    private func retireIfDone() {
        switch phase {
        case .handingOff, .ready, .carried: return
        case .released, .unreleased, .abandoned: break
        }
        guard !takeOpen, inFlight.isEmpty, owed.isEmpty else { return }
        if destinationMayAsk {
            let askedWritten = superseded && asked.withLock { $0.isSubset(of: written) }
            guard written.count == items.count || terminal != nil || askedWritten else { return }
        }
        retire()
    }

    /// Releases the guest's offer, withdraws the Mac session's promises and
    /// reports the take finished, once.
    private func retire() {
        if offerOpen {
            offerOpen = false
            transport.release()
        }
        guard !isFinished else { return }
        isFinished = true
        let retired = retirement
        retirement.removeAll()
        for body in retired { body() }
        Self.logger.log(.notice, "Retired the take: its Mac session's promises are withdrawn")
        onFinished(self)
    }

    package func whenRetired(_ body: @escaping @MainActor () -> Void) {
        guard !isFinished else { return body() }
        retirement.append(body)
    }

    // MARK: - Naming promised items

    nonisolated package func filename(forItemAt index: Int) -> String {
        guard items.indices.contains(index) else { return "Untitled" }
        asked.withLock { _ = $0.insert(index) }
        let item = items[index]
        guard item.isPromised else { return item.filename }
        if let naming = delivery.naming { return Self.filename(of: index, item, naming) }
        guard MainActorBridge.sync({ self.startDeliveryForName() }) else { return item.filename }
        return Self.filename(of: index, item, waitForDelivery())
    }

    package func nameItemsForInAppDestination() -> Bool {
        guard items.contains(where: \.isPromised) else { return true }
        if delivery.naming == nil, !startDeliveryForName() {
            Self.logger.log(.warning, "A destination in this app asked for names while the drag could not deliver")
            return false
        }
        guard case .named = waitForDelivery() else { return false }
        return true
    }

    /// Starts the drag's delivery for a destination asking a name, when the
    /// catcher is the target of the Mac session carrying it, and reports
    /// whether a delivery is under way. At any other moment the catcher would
    /// have to be targeted again, which takes the take's own nudges on the
    /// main thread this ask may be holding.
    private func startDeliveryForName() -> Bool {
        if deliveryAsked { return true }
        guard phase == .carried(.outside(targeted: true)) else {
            Self.logger.log(
                .warning, "A Mac destination asked a promised item's name while the catcher was not the target")
            return false
        }
        askDelivery()
        return true
    }

    /// Waits for the drag's delivery to name its promises; a wait on the main
    /// thread injects the release itself once the guest answers, since nothing
    /// else can run there while it waits.
    nonisolated private func waitForDelivery() -> GuestDragDelivery.Naming {
        let onMain = Thread.isMainThread
        let began = ContinuousClock.now
        let outcome = delivery.waitForNames(
            releasing: onMain
                ? { MainActor.assumeIsolated { self.deliveryAnswered(delivering: true) } } : nil)
        let waited = (ContinuousClock.now - began).components
        let milliseconds = waited.seconds * 1_000 + waited.attoseconds / 1_000_000_000_000_000
        Self.logger.log(
            .notice,
            "Waited \(milliseconds, privacy: .public) ms for the guest to deliver \(self.items.count, privacy: .public) dragged item(s) (main thread: \(onMain, privacy: .public))"
        )
        return outcome
    }

    nonisolated private static func filename(
        of index: Int, _ item: DraggedOutItem, _ naming: GuestDragDelivery.Naming
    ) -> String {
        guard case .named(let named) = naming, named.indices.contains(index) else { return item.filename }
        return named[index].filename
    }

    // MARK: - Writing items

    nonisolated package func writeItem(
        at index: Int, to destination: URL, completion: @escaping @Sendable ((any Error)?) -> Void
    ) {
        Task { @MainActor in self.startWrite(index, to: destination, completion) }
    }

    private func startWrite(
        _ index: Int, to destination: URL, _ completion: @escaping @Sendable ((any Error)?) -> Void
    ) {
        if let terminal { return completion(Self.error(for: terminal)) }
        guard items.indices.contains(index), destinationMayAsk, inFlight[index] == nil, owed[index] == nil else {
            return completion(GuestDragWriteError.failed(.transferFailed))
        }
        asked.withLock { _ = $0.insert(index) }
        guard delivery.settled != nil else {
            owed[index] = (destination, completion)
            return
        }
        pull(index, to: destination, completion)
    }

    /// The drag's delivery settled: every write waiting on it pulls now, or
    /// fails when the delivery expired.
    private func deliverySettled() {
        if case .expired(let waited)? = delivery.settled { deliveryExpired(after: waited) }
        let waiting = owed
        owed.removeAll()
        for (index, write) in waiting.sorted(by: { $0.key < $1.key }) {
            if let terminal {
                write.completion(Self.error(for: terminal))
                continue
            }
            pull(index, to: write.destination, write.completion)
        }
        retireIfDone()
    }

    /// Nothing named the drag's promises by the naming deadline: the take is
    /// called off, so the guest's drop delivers nothing, and every write fails
    /// timed out.
    private func deliveryExpired(after waited: TimeInterval) {
        let promised = items.filter(\.isPromised).count
        Self.logger.log(
            .error,
            "The guest named none of the drag's \(promised, privacy: .public) promised item(s) in \(String(format: "%.1f", waited), privacy: .public) s; calling the take off"
        )
        if takeOpen { transport.cancel() }
        endWrites(.timedOut)
    }

    /// The item a pull of `index` fetches: as delivered, or as offered when
    /// nothing was.
    private func source(of index: Int) -> DraggedOutItem? {
        if case .delivered(let delivered)? = delivery.settled, delivered.indices.contains(index) {
            return delivered[index]
        }
        let item = items[index]
        // A promise nothing delivered was never called in, so the guest
        // serves nothing for it.
        guard !item.isPromised else { return nil }
        return item
    }

    private func pull(_ index: Int, to destination: URL, _ completion: @escaping @Sendable ((any Error)?) -> Void) {
        guard offerOpen, let item = source(of: index) else {
            let failure = ClipboardTransferFailure.peerReported(.dragItemUnavailable)
            readoutUnit(name: items[index].filename, expectedBytes: 0)?.failed(failure)
            endWrites(failure)
            return completion(GuestDragWriteError.failed(failure))
        }
        let unit = readoutUnit(name: item.filename, expectedBytes: item.sizeEstimate)
        var ended = false
        let cancel = transport.pull(item, at: index, to: destination, progress: unit) { [weak self] result in
            ended = true
            self?.endWrite(index, result, unit: unit, completion)
        }
        // A pull refused before it opened has already ended.
        if !ended { inFlight[index] = cancel }
    }

    private func endWrite(
        _ index: Int, _ result: Result<Void, WireError>, unit: ClipboardTransferOperation.Unit?,
        _ completion: @escaping @Sendable ((any Error)?) -> Void
    ) {
        inFlight[index] = nil
        defer { retireIfDone() }
        switch result {
        case .success:
            written.insert(index)
            unit?.ended(succeeded: true)
            if written.count == items.count { readout?.finish(.completed) } else { readout?.finishWhenIdle() }
            completion(nil)
        case .failure(let error):
            unit?.ended(succeeded: false)
            if let terminal {
                return completion(Self.error(for: terminal))
            }
            let failure = Self.failure(for: error, owed: items.count - written.count)
            Self.logger.log(
                .error,
                "Could not write dragged item \(index, privacy: .public) from '\(self.peerName, privacy: .public)': \(String(describing: error.code), privacy: .public) \(error.debugDetail, privacy: .public)"
            )
            unit?.failed(failure)
            endWrites(failure)
            completion(GuestDragWriteError.failed(failure))
        }
    }

    /// Ends every write still owed on `failure`, cancelling those in flight.
    private func endWrites(_ failure: ClipboardTransferFailure) {
        guard terminal == nil else { return }
        terminal = .failed(failure)
        // A refusal is owed an answer whether or not a readout is running.
        let operation = readout.flatMap { $0.isLive ? $0 : nil } ?? newReadout()
        operation.finish(.failed(failure))
        for cancel in inFlight.values { cancel() }
        failOwed()
    }

    /// The readout's Cancel: every write still owed fails as cancelled.
    private func cancelWrites() {
        guard terminal == nil else { return }
        terminal = .cancelled
        readout?.finish(.cancelled)
        for cancel in inFlight.values { cancel() }
        failOwed()
        retireIfDone()
    }

    /// Fails every write waiting on the delivery with the writes' end.
    private func failOwed() {
        guard let terminal else { return }
        let waiting = owed
        owed.removeAll()
        for write in waiting.values { write.completion(Self.error(for: terminal)) }
    }

    /// A write's unit on the readout the writes report on — the one running,
    /// or a new one when the last has ended.
    private func readoutUnit(name: String, expectedBytes: UInt64) -> ClipboardTransferOperation.Unit? {
        if let unit = readout?.unit(name: name, expectedBytes: expectedBytes) { return unit }
        return newReadout().unit(name: name, expectedBytes: expectedBytes)
    }

    /// A new readout for the writes, sized by the delivered items when there
    /// are any, and counting files alone unless every item has a size.
    private func newReadout() -> ClipboardTransferOperation {
        let sized: [DraggedOutItem]
        if case .delivered(let delivered)? = delivery.settled { sized = delivered } else { sized = items }
        let operation = ClipboardTransferOperation(
            gesture: .dragOut, direction: .inbound, peerName: peerName,
            expectedBytes: sized.contains { $0.sizeEstimate == 0 } ? nil : sized.reduce(0) { $0 + $1.sizeEstimate },
            expectedItems: items.count,
            revealDelay: progressRevealDelay, idleGap: progressIdleGap,
            onCancelRequested: { [weak self] in
                // Called outside the operation's lock on whichever thread saw
                // the click, so it hops before touching anything.
                Task { @MainActor in self?.cancelWrites() }
            },
            reporter: reporter)
        readout = operation
        return operation
    }

    private static func error(for terminal: Terminal) -> any Error {
        switch terminal {
        case .cancelled: CocoaError(.userCancelled)
        case .failed(let failure): GuestDragWriteError.failed(failure)
        }
    }

    /// What the readout says of a pull that ended in `error`, with `owed`
    /// items not yet written.
    static func failure(for error: WireError, owed: Int) -> ClipboardTransferFailure {
        switch error.code {
        case .itemOfferStale, .cancelled, .shuttingDown: .interrupted(fileCount: owed)
        case .itemRepresentationUnavailable: .peerReported(.dragItemUnavailable)
        case .writeFailed where error.posixErrno == ENOSPC: .diskFull(needed: nil, available: nil)
        case .writeFailed, .itemUnpackRefused, .itemDecmpfsRefused: .stagingFailed
        case .readFailed: .sourceUnreadable
        default: .transferFailed
        }
    }

    private static func describe(_ result: DragTakeResult) -> String {
        switch result {
        case .caught: "the guest caught it"
        case .returned: "the drag ended in the guest"
        case .refused(let error): "the guest refused it (\(error.code)): \(error.debugDetail)"
        case .closed(let closure): "the take closed: \(closure)"
        }
    }
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
