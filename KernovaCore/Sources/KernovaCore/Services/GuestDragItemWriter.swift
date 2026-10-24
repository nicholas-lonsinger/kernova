import Foundation
import KernovaKit
import Synchronization

/// Why a dragged item never reached where it was dropped.
package enum GuestDragWriteError: Error, Equatable, Sendable {
    /// The transfer failed, for the reason the drag's readout reports.
    case failed(ClipboardTransferFailure)
}

/// The take a ``GuestDragItemWriter`` writes for.
@MainActor
protocol GuestDragItemWriterOwner: AnyObject {
    /// Whether a Mac destination may still have items written: a Mac session
    /// carries them and the take is not yet retired.
    var acceptsWrites: Bool { get }

    /// A write settled, or the writes were cancelled.
    func writesSettled()
}

/// The item writes a Mac destination asks a guest drag's take for: each pulls
/// one item from the guest and lands it where it was dropped, on one readout
/// for the take.
@MainActor
final class GuestDragItemWriter {
    /// How the writes ended early.
    private enum Terminal {
        case cancelled
        /// `reported` once the readout has said so. A failure no write has met
        /// is reported by the first write that asks, so a destination that
        /// never asks for the rest is told nothing.
        case failed(ClipboardTransferFailure, reported: Bool)
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

    nonisolated let generation: UInt64
    let items: [ClipboardDraggedItem]
    /// The take that owns this writer; set once, as the take finishes
    /// initializing.
    weak var owner: (any GuestDragItemWriterOwner)?

    nonisolated private let endpoint: ClipboardEndpoint
    private let reporter: ClipboardTransferReporter
    private let peerName: String
    private let progressRevealDelay: TimeInterval
    private let progressIdleGap: TimeInterval

    private var written: Set<Int> = []
    private var writesInFlight = 0
    private var terminal: Terminal?
    private var readout: ClipboardTransferOperation?

    #if DEBUG
    nonisolated private let landingBeganForTesting = Mutex<(@Sendable (URL?) -> Void)?>(nil)

    /// Test seam: `body` is called on the writing thread as a delivered item
    /// starts to land, with the staged copy it moves.
    nonisolated func onLandingForTesting(_ body: (@Sendable (URL?) -> Void)?) {
        landingBeganForTesting.withLock { $0 = body }
    }
    #endif

    init(
        generation: UInt64, items: [ClipboardDraggedItem], endpoint: ClipboardEndpoint,
        reporter: ClipboardTransferReporter, peerName: String,
        progressRevealDelay: TimeInterval, progressIdleGap: TimeInterval
    ) {
        self.generation = generation
        self.items = items
        self.endpoint = endpoint
        self.reporter = reporter
        self.peerName = peerName
        self.progressRevealDelay = progressRevealDelay
        self.progressIdleGap = progressIdleGap
    }

    /// Whether no write is pulling or landing.
    var isIdle: Bool { writesInFlight == 0 }

    /// Whether nothing more will be written: every item landed, or the writes
    /// ended early.
    var isDone: Bool { written.count == items.count || terminal != nil }

    /// Ends the transfers a Mac destination is still owed as interrupted: the
    /// one in flight now, or — while `destinationMayAsk` — the next one asked
    /// for.
    func interruptOwed(destinationMayAsk: Bool) {
        let owed = items.count - written.count
        if writesInFlight > 0 {
            fail(.interrupted(fileCount: owed))
        } else if destinationMayAsk, owed > 0 {
            // Kernova's own clipboard window takes only a drop's first
            // promise, so an accepted drop can leave items no destination
            // will ever ask for.
            endTransfers(on: .interrupted(fileCount: owed), reported: false)
        }
    }

    /// The guest user's Cancel: fails what a Mac destination is still owed as
    /// cancelled, while `destinationMayAsk`.
    func cancelOwed(destinationMayAsk: Bool) {
        guard destinationMayAsk, written.count < items.count else { return }
        cancel()
    }

    // MARK: - Writing items

    /// Writes item `index` to exactly `destination`, blocking until it lands;
    /// ``GuestDragTaking/writeItem(at:to:)`` has the contract.
    nonisolated func write(at index: Int, to destination: URL) throws {
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
                #if DEBUG
                landingBeganForTesting.withLock { $0 }?(representation.fileURL)
                #endif
                do {
                    // Staging's volume is what the pull's free-space pre-flight
                    // read, so a destination full on another volume surfaces
                    // here, as a failed move.
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

    /// Accounts for one write starting, opening the readout if none is
    /// running, or says why it cannot run.
    private func beginWrite(
        _ index: Int
    ) -> Result<(repIndex: Int, operation: ClipboardTransferOperation), GuestDragWriteFailure> {
        guard items.indices.contains(index) else {
            return .failure(GuestDragWriteFailure(GuestDragWriteError.failed(.transferFailed)))
        }
        if let terminal {
            if case .failed(let failure, reported: false) = terminal {
                self.terminal = .failed(failure, reported: true)
                liveReadout().finish(.failed(failure))
            }
            return .failure(Self.error(for: terminal))
        }
        guard owner?.acceptsWrites == true else {
            // No Mac session carries the drag, or it was already
            // garbage-collected: every item was written, or the session ended
            // with nothing dropped.
            return .failure(GuestDragWriteFailure(GuestDragWriteError.failed(.transferFailed)))
        }
        writesInFlight += 1
        return .success((items[index].repIndex, liveReadout()))
    }

    /// Settles one write, returning the error its caller throws, if any.
    private func endWrite(_ index: Int, ending: WriteEnding) -> GuestDragWriteFailure? {
        writesInFlight -= 1
        defer { owner?.writesSettled() }
        let fault: WriteFault
        switch ending {
        case .landed:
            written.insert(index)
            if written.count == items.count, writesInFlight == 0 {
                // Every item landed: the take is over, so the readout ends with
                // it rather than waiting out a gap for a destination's next ask.
                readout?.finish(.completed)
            } else {
                readout?.finishWhenIdle()
            }
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
    /// ended the transfers.
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
            case .unavailable:
                return .peerReported(.dragItemUnavailable)
            case .delivered, .mainThreadUnavailable:
                return .transferFailed
            }
        }
    }

    /// Ends the transfers on `failure` and has the readout report it — one
    /// opened for the purpose when none is running.
    private func fail(_ failure: ClipboardTransferFailure) {
        endTransfers(on: failure, reported: true)
    }

    /// Ends the transfers on `failure`, so no further item is pulled,
    /// reporting it now only when `reported`.
    private func endTransfers(on failure: ClipboardTransferFailure, reported: Bool) {
        guard terminal == nil else { return }
        terminal = .failed(failure, reported: reported)
        if reported { liveReadout().finish(.failed(failure)) }
        endpoint.cancelInbound(generation: generation)
    }

    /// Either side's Cancel — the readout's here, or the guest's on its own —
    /// fails every pending write as cancelled, and the drag is done with.
    private func cancel() {
        guard terminal == nil else { return }
        terminal = .cancelled
        readout?.finish(.cancelled)
        // Wakes a parked pull; the guest hears `DragComplete` once the writes
        // have settled.
        endpoint.cancelInbound(generation: generation)
        owner?.writesSettled()
    }

    /// The readout the writes report on — the one running, or a new one when
    /// the last has ended.
    private func liveReadout() -> ClipboardTransferOperation {
        if let readout, readout.isLive { return readout }
        let operation = ClipboardTransferOperation(
            gesture: .dragOut, direction: .inbound, peerName: peerName,
            expectedBytes: endpoint.inboundByteCount(generation: generation),
            expectedItems: items.count,
            revealDelay: progressRevealDelay, idleGap: progressIdleGap,
            onCancelRequested: { [weak self] in
                // Called outside the operation's lock on whichever thread saw
                // the click, so it hops before touching anything.
                MainActorBridge.async { self?.cancel() }
            },
            reporter: reporter)
        readout = operation
        return operation
    }

    private static func error(for terminal: Terminal) -> GuestDragWriteFailure {
        switch terminal {
        case .cancelled: GuestDragWriteFailure(CocoaError(.userCancelled))
        case .failed(let failure, _): GuestDragWriteFailure(GuestDragWriteError.failed(failure))
        }
    }
}

/// An error a write hands back across the main-actor hop that decided it.
private struct GuestDragWriteFailure: Error, Sendable {
    let error: any Error & Sendable

    init(_ error: any Error & Sendable) { self.error = error }
}
