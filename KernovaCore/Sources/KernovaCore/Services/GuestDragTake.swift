import Foundation
import KernovaAgentCore
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
    /// The representation a pull names.
    package var representation: UInt32
    /// The guest's estimate of its bytes; 0 when unknown.
    package var sizeEstimate: UInt64

    /// What a Mac destination is told the item is called.
    package var filename: String { String(decoding: name, as: UTF8.self) }

    /// The item `item` carries out of the guest: its first FILE or FOLDER
    /// representation, or nil when it has none.
    package init?(_ item: OfferedItem) {
        guard
            let index = item.representations.firstIndex(where: { $0.storage == .file || $0.storage == .folder })
        else { return nil }
        let representation = item.representations[index]
        let isDirectory = representation.storage == .folder
        let declared = representation.type.appleUTI.flatMap { UTType($0) }
        self.init(
            name: representation.name, type: declared ?? (isDirectory ? .folder : .data), isDirectory: isDirectory,
            representation: UInt32(index), sizeEstimate: representation.sizeEstimate)
    }

    package init(
        name: Data, type: UTType, isDirectory: Bool, representation: UInt32 = 0, sizeEstimate: UInt64 = 0
    ) {
        self.name = name
        self.type = type
        self.isDirectory = isDirectory
        self.representation = representation
        self.sizeEstimate = sizeEstimate
    }
}

/// Why a dragged item never reached where it was dropped.
package enum GuestDragWriteError: Error, Equatable, Sendable {
    /// The transfer failed, for the reason the drag's readout reports.
    case failed(ClipboardTransferFailure)
}

/// What a take moves its drag over: the guest peer that offered it.
@MainActor
package protocol GuestDragTransport: AnyObject {
    /// Takes the guest's drag over; `ended` is called once, with the peer's
    /// answer or how the take closed without one.
    func take(ended: @escaping @MainActor (DragTakeResult) -> Void)

    /// Pulls `item`, item `index` of the offer, into `directory` under exactly
    /// `name`, calling `ended` once with how the pull ended, and returns what
    /// cancels it.
    func pull(
        _ item: DraggedOutItem, at index: Int, into directory: URL, named name: String,
        ended: @escaping @MainActor (Result<Void, WireError>) -> Void
    ) -> @MainActor () -> Void

    /// Releases the offer: this side pulls nothing more of it, which completes
    /// the drag in the guest.
    func release()
}

/// The VM display a take drives: it withholds the press while the guest
/// hands its drag over, and injects into the guest only what the take tells it
/// to.
@MainActor
package protocol GuestDragDisplay: AnyObject {
    /// Moves the guest pointer to `nudge`'s point with a constructed drag event.
    func injectNudge(_ nudge: GuestDragNudge)

    /// Moves the guest pointer back to where the drag left the display — where
    /// the last physical event the display forwarded put it — when it is
    /// anywhere else.
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
    /// What the drag carries, in the offer's order.
    nonisolated var items: [DraggedOutItem] { get }

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

    /// The Mac drag session ended; `dropped` is whether a destination took it.
    func hostSessionEnded(dropped: Bool)

    /// What item `index` is called where a Mac destination writes it: the name
    /// the guest offered it under.
    nonisolated func filename(forItemAt index: Int) -> String

    /// Writes item `index` to exactly `destination`, calling `completion` once,
    /// from any thread, when it lands or fails: with `CocoaError(.userCancelled)`
    /// when the user called the drag's transfers off, and otherwise with a
    /// ``GuestDragWriteError``.
    nonisolated func writeItem(
        at index: Int, to destination: URL, completion: @escaping @Sendable ((any Error)?) -> Void)
}

/// One guest drag the VM display took over at its edge: the hand-off that ends
/// the guest's drag on its catcher, and the Mac drag session that carries the
/// offer's items on, each pulled from the guest to where a Mac destination
/// writes it.
///
/// Every button release the take injects is a real drop under the guest
/// pointer, so it injects one only once the guest answered the take `TAKEN`:
/// its catcher, covering the screen, is then the drag's target. Every end
/// before that hands the press back to the guest, where the user's own release
/// lands as it would with drag-out off.
///
/// The release goes in as the Mac session begins, ending the guest's drag on
/// its catcher while the Mac session carries the items on; their bytes come
/// from the guest's offer, which stays open until this side releases it.
/// `NSDraggingSession` cannot be withdrawn, so the session begins only from
/// ``Phase/ready``.
@MainActor
@Observable
package final class GuestDragTake: GuestDragTaking {
    /// Where the hand-off stands.
    package enum Phase: Equatable, Sendable {
        /// `DRAG_TAKE` is out and the press is withheld.
        case handingOff
        /// The guest took the drag: its catcher is the drag's target, so the
        /// next physical event begins the Mac session or releases onto it.
        case ready
        /// A Mac drag session carries the items, and the guest's button was
        /// released onto the catcher.
        case carried
        /// The guest's button was released onto the catcher, and no Mac
        /// session carries the items.
        case released
        /// The press went back to the guest.
        case abandoned
    }

    nonisolated package let items: [DraggedOutItem]
    /// Where the hand-off stands now; the one observed property.
    package private(set) var phase: Phase = .handingOff

    @ObservationIgnored private let transport: any GuestDragTransport
    @ObservationIgnored private weak var display: (any GuestDragDisplay)?
    @ObservationIgnored private let reporter: ClipboardTransferReporter
    @ObservationIgnored private let peerName: String
    @ObservationIgnored private let progressRevealDelay: TimeInterval
    @ObservationIgnored private let progressIdleGap: TimeInterval
    @ObservationIgnored private let holds: @MainActor () -> Bool
    @ObservationIgnored private let onFinished: @MainActor (GuestDragTake) -> Void

    @ObservationIgnored private var nextNudge: GuestDragNudge = .exitPoint
    @ObservationIgnored private var holdsWatch: ObservationLoop?

    /// Whether the guest's offer is still open: this side has not released
    /// it, and the guest's side has not ended it.
    @ObservationIgnored private var offerOpen = true
    /// Whether a destination took the Mac session, once it ended.
    @ObservationIgnored private var sessionDropped: Bool?
    /// How the writes ended early, once they did.
    @ObservationIgnored private var terminal: Terminal?
    @ObservationIgnored private var written: Set<Int> = []
    /// The writes pulling now, by item index, each with what cancels it.
    @ObservationIgnored private var inFlight: [Int: @MainActor () -> Void] = [:]
    @ObservationIgnored private var readout: ClipboardTransferOperation?
    @ObservationIgnored private var isFinished = false

    private enum Terminal {
        case cancelled
        case failed(ClipboardTransferFailure)
    }

    nonisolated private static let logger = KernovaLogger(
        subsystem: "app.kernova", category: "GuestDragTake")

    /// Takes over the drag of `items` through `transport` for `display`, which
    /// the take drives while `holds` stays true.
    ///
    /// `onFinished` is called once, when the guest's offer is released or
    /// ended and no write is still pulling. Nothing is sent until ``begin()``.
    init(
        items: [DraggedOutItem], transport: any GuestDragTransport, display: any GuestDragDisplay,
        reporter: ClipboardTransferReporter, peerName: String,
        progressRevealDelay: TimeInterval = ClipboardTransferOperation.defaultRevealDelay,
        progressIdleGap: TimeInterval = ClipboardTransferOperation.defaultIdleGap,
        holds: @escaping @MainActor () -> Bool,
        onFinished: @escaping @MainActor (GuestDragTake) -> Void
    ) {
        self.items = items
        self.transport = transport
        self.display = display
        self.reporter = reporter
        self.peerName = peerName
        self.progressRevealDelay = progressRevealDelay
        self.progressIdleGap = progressIdleGap
        self.holds = holds
        self.onFinished = onFinished
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
        transport.take { [weak self] result in self?.takeEnded(result) }
        holdsWatch = observeRecurring(
            track: { [weak self] in _ = self?.holds() },
            apply: { [weak self] in
                guard let self, !self.holds() else { return }
                self.vmStopped()
            })
        Self.logger.log(
            .notice,
            "Taking over a guest drag of \(self.items.count, privacy: .public) item(s) from '\(self.peerName, privacy: .public)'"
        )
    }

    // MARK: - The display's events

    package func withheldDrag() {
        switch phase {
        case .handingOff:
            // The catcher becomes the drag's target only through motion the
            // guest's drag manager hit-tests after it appears.
            nudge()
        case .ready:
            guard display?.beginHostSession(carrying: self) == true else {
                return release(because: "the Mac drag session did not begin")
            }
            phase = .carried
            stopWatching()
            display?.injectRelease()
            Self.logger.log(
                .notice, "A Mac drag session carries the guest's drag; its button is released onto the catcher")
        case .carried, .released, .abandoned:
            break
        }
    }

    package func withheldMouseUp() {
        switch phase {
        case .handingOff: abandon(because: "the button came up before the guest took the drag")
        case .ready: release(because: "the button came up before a Mac drag session began")
        case .carried, .released, .abandoned: break
        }
    }

    package func pointerReturned() {
        switch phase {
        case .handingOff: abandon(because: "the pointer came back over the display")
        case .ready: release(because: "the pointer came back over the display")
        case .carried, .released, .abandoned: break
        }
    }

    package func displayAbandoned() {
        switch phase {
        case .handingOff: abandon(because: "the display can no longer carry the press")
        case .ready: release(because: "the display can no longer carry the press")
        case .carried, .released, .abandoned: break
        }
    }

    package func hostSessionEnded(dropped: Bool) {
        sessionDropped = dropped
        retireIfDone()
    }

    // MARK: - The guest's side

    /// The take ended: the guest's answer, or the stream's close.
    func takeEnded(_ result: DragTakeResult) {
        guard phase == .handingOff else { return }
        switch result {
        case .taken:
            phase = .ready
            Self.logger.log(.notice, "The guest handed its drag over; its catcher is the drag's target")
        case .refused(let error):
            abandon(because: "the guest refused the take (\(error.code)): \(error.debugDetail)")
        case .closed(let closure):
            abandon(because: "the take closed unanswered: \(closure)")
        }
    }

    /// The guest's offer ended without this side releasing it: the guest
    /// withdrew it, or the hub ended it with its connection or its console.
    func offerEnded() {
        guard offerOpen else { return }
        offerOpen = false
        switch phase {
        case .handingOff: abandon(because: "the guest's offer ended")
        case .ready: release(because: "the guest's offer ended")
        case .carried:
            endWrites(.interrupted(fileCount: items.count - written.count))
            retireIfDone()
        case .released, .abandoned: retireIfDone()
        }
    }

    /// A newer take replaced this one: one before its Mac session ends, and
    /// one a Mac session carries still writes what its destination asks for.
    func supersede() {
        switch phase {
        case .handingOff: abandon(because: "a newer drag replaced it")
        case .ready: release(because: "a newer drag replaced it")
        case .carried, .released, .abandoned: break
        }
    }

    // MARK: - Hand-off steps

    private func nudge() {
        let nudge = nextNudge
        nextNudge = nudge.next
        display?.injectNudge(nudge)
    }

    private func vmStopped() {
        // A guest that is not running takes no injected release.
        abandon(because: "the VM stopped running")
    }

    /// Releases the guest's button onto its catcher with no Mac session, which
    /// only ``Phase/ready`` reaches.
    private func release(because reason: String) {
        guard phase == .ready else { return }
        phase = .released
        stopWatching()
        display?.injectRelease()
        Self.logger.log(
            .notice, "Released the guest's drag onto its catcher with no Mac session: \(reason, privacy: .public)")
        retireIfDone()
    }

    /// Ends a take before its Mac session, returning the guest pointer to
    /// where the drag left the display and handing the press back.
    private func abandon(because reason: String) {
        guard phase == .handingOff || phase == .ready else { return }
        phase = .abandoned
        stopWatching()
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
    /// carries them, and it has not ended with nothing taking it.
    private var destinationMayAsk: Bool {
        phase == .carried && sessionDropped != false
    }

    /// Releases the offer, and reports the take finished, once nothing will
    /// pull from it again.
    ///
    /// A Mac destination asks for the items after its session ends, and may
    /// ask for only some of them, so a session a destination took holds the
    /// offer until every item is written or the writes ended.
    private func retireIfDone() {
        switch phase {
        case .handingOff, .ready: return
        case .carried, .released, .abandoned: break
        }
        guard inFlight.isEmpty else { return }
        if phase == .carried {
            guard let dropped = sessionDropped else { return }
            guard !dropped || written.count == items.count || terminal != nil else { return }
        }
        if offerOpen {
            offerOpen = false
            transport.release()
        }
        guard !isFinished else { return }
        isFinished = true
        onFinished(self)
    }

    // MARK: - Writing items

    nonisolated package func filename(forItemAt index: Int) -> String {
        guard items.indices.contains(index) else { return "Untitled" }
        return items[index].filename
    }

    nonisolated package func writeItem(
        at index: Int, to destination: URL, completion: @escaping @Sendable ((any Error)?) -> Void
    ) {
        Task { @MainActor in self.startWrite(index, to: destination, completion) }
    }

    private func startWrite(
        _ index: Int, to destination: URL, _ completion: @escaping @Sendable ((any Error)?) -> Void
    ) {
        if let terminal { return completion(Self.error(for: terminal)) }
        guard items.indices.contains(index), destinationMayAsk, offerOpen, inFlight[index] == nil else {
            return completion(GuestDragWriteError.failed(.transferFailed))
        }
        let operation = liveReadout()
        let item = items[index]
        operation.unitBegan(id: UInt64(index), expectedBytes: item.sizeEstimate, name: item.filename)
        var ended = false
        let cancel = transport.pull(
            item, at: index, into: destination.deletingLastPathComponent(), named: destination.lastPathComponent
        ) { [weak self] result in
            ended = true
            self?.endWrite(index, result, operation: operation, completion)
        }
        // A pull refused before it opened has already ended.
        if !ended { inFlight[index] = cancel }
    }

    private func endWrite(
        _ index: Int, _ result: Result<Void, WireError>, operation: ClipboardTransferOperation,
        _ completion: @escaping @Sendable ((any Error)?) -> Void
    ) {
        inFlight[index] = nil
        defer { retireIfDone() }
        switch result {
        case .success:
            written.insert(index)
            operation.unitEnded(id: UInt64(index), succeeded: true)
            if written.count == items.count { operation.finish(.completed) } else { operation.finishWhenIdle() }
            completion(nil)
        case .failure(let error):
            if let terminal {
                operation.unitEnded(id: UInt64(index), succeeded: false)
                return completion(Self.error(for: terminal))
            }
            let failure = Self.failure(for: error, owed: items.count - written.count)
            Self.logger.log(
                .error,
                "Could not write dragged item \(index, privacy: .public) from '\(self.peerName, privacy: .public)': \(String(describing: error.code), privacy: .public) \(error.debugDetail, privacy: .public)"
            )
            operation.unitFailed(id: UInt64(index), failure)
            endWrites(failure)
            completion(GuestDragWriteError.failed(failure))
        }
    }

    /// Ends every write still owed on `failure`, cancelling those in flight.
    private func endWrites(_ failure: ClipboardTransferFailure) {
        guard terminal == nil else { return }
        terminal = .failed(failure)
        liveReadout().finish(.failed(failure))
        for cancel in inFlight.values { cancel() }
    }

    /// The readout's Cancel: every write still owed fails as cancelled.
    private func cancelWrites() {
        guard terminal == nil else { return }
        terminal = .cancelled
        readout?.finish(.cancelled)
        for cancel in inFlight.values { cancel() }
        retireIfDone()
    }

    /// The readout the writes report on — the one running, or a new one when
    /// the last has ended.
    private func liveReadout() -> ClipboardTransferOperation {
        if let readout, readout.isLive { return readout }
        let operation = ClipboardTransferOperation(
            gesture: .dragOut, direction: .inbound, peerName: peerName,
            expectedBytes: items.reduce(0) { $0 + $1.sizeEstimate }, expectedItems: items.count,
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
        case .readFailed: .sourceUnreadable(nil)
        default: .transferFailed
        }
    }
}
