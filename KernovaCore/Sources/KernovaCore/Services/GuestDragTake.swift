import Foundation
import KernovaKit
import KernovaLogging

/// Where a nudge puts the guest pointer.
package enum GuestDragNudge: Equatable, Sendable {
    /// The display's center: the one point certain to be on the guest's
    /// framebuffer however the view letterboxes it, and under the guest's
    /// catcher, which covers the whole guest screen.
    case center
    /// One point right of the center, so a nudge after a nudge is motion the
    /// guest drag manager hit-tests again.
    case offset

    /// The variant the nudge after this one uses.
    var next: GuestDragNudge { self == .center ? .offset : .center }
}

/// The VM display a take over drives: it withholds the press while the guest
/// hands its drag over, and injects into the guest only what the take tells it
/// to.
@MainActor
package protocol GuestDragDisplay: AnyObject {
    /// Moves the guest pointer to `nudge`'s point with a constructed drag event.
    func injectNudge(_ nudge: GuestDragNudge)

    /// Releases the guest's button at the last nudge point with a constructed
    /// mouse-up, which drops the guest's drag on whatever is under its pointer.
    ///
    /// Called at most once per take, and only once the guest reported its
    /// catcher as the drag's target.
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

    /// The display withheld a physical drag event of the press.
    func withheldDrag()

    /// The display withheld the press's physical mouse-up.
    func withheldMouseUp()

    /// The display can no longer carry the press — it left its window, or a
    /// new press began without the last one ending.
    func displayAbandoned()

    /// The Mac drag session ended; `dropped` is whether a destination took it.
    func hostSessionEnded(dropped: Bool)

    /// Writes item `index` to exactly `destination`, blocking until it lands.
    ///
    /// For an `NSFilePromiseProvider` operation queue: never the main thread.
    ///
    /// - Throws: `CocoaError(.userCancelled)` when the user called the drag's
    ///   transfers off, ``GuestDragWriteError`` when the transfer failed, or
    ///   the move's own error when the item could not be put at `destination`.
    nonisolated func writeItem(at index: Int, to destination: URL) throws
}

/// Why a dragged item never reached where it was dropped.
package enum GuestDragWriteError: Error, Equatable, Sendable {
    /// The transfer failed, for the reason the drag's readout reports.
    case failed(ClipboardTransferFailure)
}

/// One guest drag the VM display took over at its edge: the hand-off that moves
/// the guest's drag onto its catcher, the Mac drag session that carries it on,
/// and the item writes a Mac destination asks for.
///
/// The hand-off is a state machine whose one irreversible step — releasing the
/// guest's button — exists only in ``Phase/ready``, which only `TARGETED`
/// enters: a release is a real drop under the guest pointer, so it may land
/// only on the guest's catcher. Every failure before the release abandons the
/// take and resumes forwarding, so the press ends as an ordinary guest gesture
/// would. `NSDraggingSession` cannot be withdrawn, so the Mac session also
/// begins only from ``Phase/ready``.
@MainActor
@Observable
package final class GuestDragTake: GuestDragTaking {
    /// How long the guest may stay silent between the take and its catcher
    /// becoming the drag's target before the take is abandoned.
    ///
    /// A bound on a peer Kernova does not own; the catcher normally reports
    /// within a frame or two of the first nudge.
    package static let handOffDeadline: TimeInterval = 3

    /// Where the hand-off stands.
    package enum Phase: Equatable, Sendable {
        /// `DragTake` is out and the press is withheld; `armed` once the guest
        /// reported its catcher up under the pointer.
        case handingOff(armed: Bool)
        /// The guest reported its catcher as the drag's target, so the next
        /// physical event may release the guest's button.
        case ready
        /// The guest's button was released, once; `hostSession` says whether a
        /// Mac drag session carries the items on.
        case released(hostSession: Bool)
        /// The take failed before the release and the press went back to the
        /// guest.
        case abandoned
    }

    /// How the take's transfers ended early.
    private enum Terminal {
        case cancelled
        case failed(ClipboardTransferFailure)
    }

    /// How one item write ended, as the main actor settles it.
    private enum WriteEnding: Sendable {
        case landed
        case failed(WriteFault)
    }

    /// Why one item write did not land.
    private enum WriteFault: Sendable {
        case pullEnded(LazyPullOutcome)
        case offerRetired
        case landingFailed
    }

    nonisolated package let generation: UInt64
    nonisolated package let items: [ClipboardDraggedItem]
    /// Where the hand-off stands now; the one observed property.
    package private(set) var phase: Phase = .handingOff(armed: false)

    nonisolated private let endpoint: ClipboardEndpoint
    @ObservationIgnored private weak var display: (any GuestDragDisplay)?
    private let reporter: ClipboardTransferReporter
    private let peerName: String
    private let progressRevealDelay: TimeInterval
    private let progressIdleGap: TimeInterval
    private let clock: any EngineClock
    private let holds: @MainActor () -> Bool
    private let onRetired: @MainActor (GuestDragTake) -> Void

    @ObservationIgnored private var nextNudge: GuestDragNudge = .center
    @ObservationIgnored private var deadline: Task<Void, Never>?
    @ObservationIgnored private var holdsWatch: ObservationLoop?

    // MARK: After the release

    /// Whether the guest's drag is over — caught, or reported failed — so a
    /// `DragComplete` can no longer reach its catcher ahead of the injected
    /// release.
    @ObservationIgnored private var guestDragEnded = false
    /// Whether the Mac session ended with no destination taking it.
    @ObservationIgnored private var hostSessionDroppedNothing = false
    @ObservationIgnored private var written: Set<Int> = []
    @ObservationIgnored private var writesInFlight = 0
    @ObservationIgnored private var isSuperseded = false
    @ObservationIgnored private var terminal: Terminal?
    /// Whether this take is done with the drag: `DragComplete` sent, or the
    /// channel gone.
    @ObservationIgnored private var isRetired = false
    @ObservationIgnored private var readout: ClipboardTransferOperation?

    nonisolated private static let logger = KernovaLogger(
        subsystem: "app.kernova", category: "GuestDragTake")

    /// Takes over `drag` on `endpoint` for `display`, which the take drives
    /// while `holds` stays true.
    ///
    /// Nothing is sent until ``begin()``.
    init(
        drag: ClipboardInboundDrag, endpoint: ClipboardEndpoint, display: any GuestDragDisplay,
        reporter: ClipboardTransferReporter, peerName: String,
        progressRevealDelay: TimeInterval, progressIdleGap: TimeInterval, clock: any EngineClock,
        holds: @escaping @MainActor () -> Bool,
        onRetired: @escaping @MainActor (GuestDragTake) -> Void
    ) {
        self.generation = drag.generation
        self.items = drag.items
        self.endpoint = endpoint
        self.display = display
        self.reporter = reporter
        self.peerName = peerName
        self.progressRevealDelay = progressRevealDelay
        self.progressIdleGap = progressIdleGap
        self.clock = clock
        self.holds = holds
        self.onRetired = onRetired
    }

    /// Asks the guest to hand the drag over, and starts the hand-off's bounds:
    /// its deadline, and the condition it holds under.
    func begin() {
        endpoint.sendDragTake(generation: generation)
        deadline = clock.schedule(after: Self.handOffDeadline) { [weak self] in
            await self?.handOffDeadlinePassed()
        }
        holdsWatch = observeRecurring(
            track: { [weak self] in _ = self?.holds() },
            apply: { [weak self] in
                guard let self, !self.holds() else { return }
                self.abandon(because: "the VM stopped running", tellingGuest: true)
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
            let began = display?.beginHostSession(carrying: self) ?? false
            release(hostSession: began)
        case .handingOff(armed: false), .released, .abandoned:
            break
        }
    }

    package func withheldMouseUp() {
        switch phase {
        case .handingOff:
            abandon(because: "the button came up before the guest's catcher was targeted", tellingGuest: true)
        case .ready:
            release(hostSession: false)
        case .released, .abandoned:
            break
        }
    }

    package func displayAbandoned() {
        abandon(because: "the display can no longer carry the press", tellingGuest: true)
    }

    package func hostSessionEnded(dropped: Bool) {
        hostSessionDroppedNothing = !dropped
        retireIfDone()
    }

    // MARK: - The guest's reports

    /// Takes one step of the guest's hand-off.
    func handOff(_ step: ClipboardDragHandOffStep) {
        switch (phase, step) {
        case (.handingOff(armed: false), .armed):
            phase = .handingOff(armed: true)
            nudge()
        case (.handingOff, .targeted):
            phase = .ready
            deadline?.cancel()
            Self.logger.log(
                .notice,
                "The guest's catcher is the target of drag gen=\(self.generation, privacy: .public)")
        case (.handingOff, .caught), (.ready, .caught):
            // Nothing here released the button, so the guest dropped on its
            // catcher by some path this side did not drive.
            abandon(because: "the guest reported a catch nothing released", tellingGuest: true)
        case (.handingOff, .failed(let code, let message)), (.ready, .failed(let code, let message)):
            abandon(
                because: "the guest failed the hand-off (\(code?.rawValue ?? "unknown")): \(message)",
                tellingGuest: true)
        case (.released, .caught):
            guestDragEnded = true
            retireIfDone()
        case (.released, .failed(let code, let message)):
            Self.logger.log(
                .warning,
                "The guest reported drag gen=\(self.generation, privacy: .public) failed after its release (\(code?.rawValue ?? "unknown", privacy: .public)): \(message, privacy: .public)"
            )
            guestDragEnded = true
            retireIfDone()
        case (.handingOff(armed: true), .armed), (.ready, .armed), (.ready, .targeted),
            (.released, .armed), (.released, .targeted), (.abandoned, _):
            break
        }
    }

    /// The guest withdrew the drag (`DragRelease`), which the endpoint has
    /// already retired.
    func guestWithdrew() {
        switch phase {
        case .handingOff, .ready:
            abandon(because: "the guest withdrew the drag", tellingGuest: true)
        case .released(let hostSession):
            guestDragEnded = true
            if hostSession, !hostSessionDroppedNothing, written.count < items.count {
                fail(.peerReported(nil))
            }
            retireIfDone()
        case .abandoned:
            break
        }
    }

    /// A newer take replaced this one: a take still handing off is abandoned,
    /// and a released one stops waiting for its guest drag, which ended with
    /// its press, but still writes what its Mac destination asks for.
    func supersede() {
        isSuperseded = true
        switch phase {
        case .handingOff, .ready:
            abandon(because: "a newer drag replaced it", tellingGuest: true)
        case .released:
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
        case .released:
            if writesInFlight > 0 { fail(.interrupted(fileCount: nil)) }
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

    private func handOffDeadlinePassed() {
        guard case .handingOff = phase else { return }
        abandon(
            because: "the guest went \(Self.handOffDeadline) s without its catcher becoming the target",
            tellingGuest: true)
    }

    /// Releases the guest's button, which only ``Phase/ready`` reaches, and so
    /// at most once.
    private func release(hostSession: Bool) {
        guard case .ready = phase else { return }
        phase = .released(hostSession: hostSession)
        stopBounds()
        display?.injectRelease()
        Self.logger.log(
            .notice,
            "Released the guest's button over its catcher for drag gen=\(self.generation, privacy: .public) (Mac session: \(hostSession, privacy: .public))"
        )
        retireIfDone()
    }

    /// Ends a take that never released, handing the press back to the guest.
    private func abandon(because reason: String, tellingGuest: Bool) {
        switch phase {
        case .handingOff, .ready: break
        case .released, .abandoned: return
        }
        phase = .abandoned
        stopBounds()
        Self.logger.log(
            .notice,
            "Abandoned the take of guest drag gen=\(self.generation, privacy: .public): \(reason, privacy: .public)"
        )
        retire(tellingGuest: tellingGuest)
        display?.resumeForwarding()
    }

    private func stopBounds() {
        deadline?.cancel()
        deadline = nil
        holdsWatch?.cancel()
        holdsWatch = nil
    }

    // MARK: - Retiring

    /// Sends the drag's `DragComplete` once nothing will pull from it again and
    /// the guest's own drag is over.
    ///
    /// The guest's catcher refuses a release that reaches it after
    /// `DragComplete`, so one that overtook the injected release would turn the
    /// catch into a refusal — hence a released take waits for the guest to
    /// report its drag over. A superseded take's guest drag ended with its
    /// press, long before the next one began, but its destination may still
    /// have writes queued, so it retires like any other released take.
    private func retireIfDone() {
        guard case .released(let hostSession) = phase, !isRetired else { return }
        let guestDone = guestDragEnded || isSuperseded
        let nothingMoreToWrite =
            !hostSession || hostSessionDroppedNothing || written.count == items.count
            || terminal != nil
        guard guestDone, nothingMoreToWrite, writesInFlight == 0 else { return }
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
        onRetired(self)
    }

    // MARK: - Writing items

    nonisolated package func writeItem(at index: Int, to destination: URL) throws {
        let repIndex: Int
        let operation: ClipboardTransferOperation
        switch MainActorBridge.sync({ self.beginWrite(index) }) {
        case .success(let start): (repIndex, operation) = start
        case .failure(let refusal): throw refusal.error
        }
        let outcome = endpoint.pull(generation: generation, repIndex: repIndex, operation: operation)
        var landingError: (any Error)?
        let ending: WriteEnding
        switch outcome {
        case .delivered(let representation):
            // Asked again before landing: a Cancel retires the drag, and an item
            // landed after it would put a file where the user called it off.
            // Staging is app-internal, so a copy that does not land is removed
            // outright.
            let discard = {
                guard let url = representation.fileURL else { return }
                _ = try? FileManager.default.removeItem(at: url)
            }
            if endpoint.hasLiveInboundOffer(generation: generation) {
                do {
                    // Staging's volume is what the pull's free-space pre-flight
                    // read, so a destination full on another volume surfaces
                    // here, as a failed copy.
                    try StagedItemLanding.land(representation, at: destination)
                    ending = .landed
                } catch {
                    landingError = error
                    ending = .failed(.landingFailed)
                    discard()
                }
            } else {
                ending = .failed(.offerRetired)
                discard()
            }
        default:
            ending = .failed(.pullEnded(outcome))
        }
        let failure = MainActorBridge.sync { self.endWrite(index, ending: ending) }
        if let landingError { throw landingError }
        if let failure { throw failure.error }
    }

    /// Accounts for one write starting, opening the take's readout if none is
    /// running, or says why it cannot run.
    private func beginWrite(
        _ index: Int
    ) -> Result<(repIndex: Int, operation: ClipboardTransferOperation), GuestDragWriteFailure> {
        guard items.indices.contains(index) else {
            return .failure(GuestDragWriteFailure(GuestDragWriteError.failed(.transferFailed)))
        }
        if let terminal { return .failure(Self.error(for: terminal)) }
        guard case .released = phase, !isRetired else {
            // The drag was already garbage-collected: every item was written,
            // or the session ended with nothing dropped.
            return .failure(GuestDragWriteFailure(GuestDragWriteError.failed(.transferFailed)))
        }
        writesInFlight += 1
        return .success((items[index].repIndex, liveReadout()))
    }

    /// Settles one write, returning the error its caller throws, if any.
    private func endWrite(_ index: Int, ending: WriteEnding) -> GuestDragWriteFailure? {
        writesInFlight -= 1
        defer { retireIfDone() }
        let fault: WriteFault
        switch ending {
        case .landed:
            written.insert(index)
            readout?.finishWhenIdle()
            return nil
        case .failed(let ended):
            fault = ended
        }
        if let terminal { return Self.error(for: terminal) }
        let failure = failure(for: fault)
        fail(failure)
        return GuestDragWriteFailure(GuestDragWriteError.failed(failure))
    }

    /// The failure a write that did not land reports, when nothing had already
    /// ended the take's transfers.
    private func failure(for fault: WriteFault) -> ClipboardTransferFailure {
        let lostOffer: ClipboardTransferFailure =
            endpoint.hasEnded ? .interrupted(fileCount: nil) : .peerReported(nil)
        switch fault {
        case .landingFailed:
            return .stagingFailed
        case .offerRetired:
            return lostOffer
        case .pullEnded(let outcome):
            switch outcome {
            case .aborted(let info):
                guard !info.isRetiring else { return lostOffer }
                return ClipboardTransferFailure.inboundPullAborted(info) ?? .transferFailed
            case .timedOut:
                return .timedOut
            case .cancelled:
                return lostOffer
            case .delivered, .mainThreadUnavailable:
                return .transferFailed
            }
        }
    }

    /// Ends the take's transfers on `failure`: the readout reports it, and no
    /// further item is pulled.
    private func fail(_ failure: ClipboardTransferFailure) {
        guard terminal == nil else { return }
        terminal = .failed(failure)
        readout?.finish(.failed(failure))
        endpoint.cancelInbound(generation: generation)
    }

    /// The readout's Cancel: every pending write fails as cancelled, and the
    /// drag is done with.
    private func cancelWrites() {
        guard terminal == nil else { return }
        terminal = .cancelled
        readout?.finish(.cancelled)
        // Wakes a parked pull; the guest hears `DragComplete` once the writes
        // have settled.
        endpoint.cancelInbound(generation: generation)
        retireIfDone()
    }

    /// The readout this take's writes report on — the one running, or a new
    /// one when the last has ended.
    private func liveReadout() -> ClipboardTransferOperation {
        if let readout, readout.isLive { return readout }
        let operation = ClipboardTransferOperation(
            gesture: .dragOut, direction: .inbound, peerName: peerName,
            expectedBytes: items.reduce(UInt64(0)) { $0 &+ $1.byteCount },
            expectedItems: items.count,
            revealDelay: progressRevealDelay, idleGap: progressIdleGap,
            onCancelRequested: { [weak self] in
                // Called outside the operation's lock on whichever thread saw
                // the click, so it hops before touching anything.
                MainActorBridge.async { self?.cancelWrites() }
            },
            reporter: reporter)
        readout = operation
        return operation
    }

    private static func error(for terminal: Terminal) -> GuestDragWriteFailure {
        switch terminal {
        case .cancelled: GuestDragWriteFailure(CocoaError(.userCancelled))
        case .failed(let failure): GuestDragWriteFailure(GuestDragWriteError.failed(failure))
        }
    }
}

/// An error a write hands back across the main-actor hop that decided it.
private struct GuestDragWriteFailure: Error, Sendable {
    let error: any Error & Sendable

    init(_ error: any Error & Sendable) { self.error = error }
}
