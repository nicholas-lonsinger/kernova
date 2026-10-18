import Foundation
import KernovaLogging
import KernovaSynchronization

/// One peer's pull of a single representation, however it reached this side.
///
/// A guest's pull arrives as the first frame on the data connection it dialled;
/// a host's arrives as a `ClipboardRequest` on the control channel, and the
/// connection follows. The fields are the same either way, so the owner logic
/// that answers one is written once.
struct ClipboardPullRequest: Sendable {
    /// The offer generation being pulled from.
    let generation: UInt64
    /// Names the transfer answering this pull.
    let transferID: UInt64
    /// The single representation being consumed.
    let uti: String
    /// The requester's payload ceiling, in the unit the offer advertised.
    let maxAcceptByteCount: UInt64

    /// Describes one pull.
    init(generation: UInt64, transferID: UInt64, uti: String, maxAcceptByteCount: UInt64) {
        self.generation = generation
        self.transferID = transferID
        self.uti = uti
        self.maxAcceptByteCount = maxAcceptByteCount
    }

    /// The pull a control-channel `ClipboardRequest` names.
    init(_ request: Kernova_V1_ClipboardRequest) {
        self.init(
            generation: request.generation, transferID: request.transferID, uti: request.uti,
            maxAcceptByteCount: request.maxAcceptByteCount)
    }

    /// The pull a data connection's opening frame names.
    init(_ request: Kernova_V1_ClipboardTransferRequest) {
        self.init(
            generation: request.generation, transferID: request.transferID, uti: request.uti,
            maxAcceptByteCount: request.maxAcceptByteCount)
    }
}

/// How many of one gesture's items this side had nothing to send the peer,
/// recorded from whichever transfer queue found out.
///
/// The two stages an item can be lost at count into one number, so the batch's
/// verdict names the whole of what the user is missing rather than whichever
/// stage spoke last: `skippedBeforeOffer` never reached the peer, and the
/// indices failed once it asked for them. Keyed by index rather than counted,
/// so a representation the peer asks for twice is one item however often it
/// fails.
private final class UnreadableReps: Sendable {
    /// Items left out of the offer, which have no rep index of their own —
    /// the peer was never told they existed.
    let skippedBeforeOffer: Int
    private let indices = Locked<Set<Int>>([])

    init(skippedBeforeOffer: Int) {
        self.skippedBeforeOffer = skippedBeforeOffer
    }

    func record(repIndex: Int) {
        indices.withLock { _ = $0.insert(repIndex) }
    }

    /// How many of the gesture's items this side had nothing to send for.
    var count: Int { skippedBeforeOffer + indices.withLock { $0.count } }
}

/// What this side has offered the peer, and the transfers it serves in answer.
///
/// The peer decides what it pulls and when — a paste can take two waves minutes
/// apart — so transfers are declared as they are asked for, never up front.
///
/// What differs between a clipboard offer, a host's drop, and a guest's drag
/// out — whether an offer supersedes the last, when its readout opens, whether
/// it has a claim deadline, what a Cancel or the session's end does to it — is
/// read off the session's ``ClipboardOfferDiscipline`` rather than branched on
/// here.
@MainActor
final class ClipboardOutboundOffers {
    /// One offer this side has made and can still serve.
    private final class Entry {
        let generation: UInt64
        let content: ClipboardContent
        /// The generation the offer is still wanted at, read from each
        /// transfer's own queue; zeroed once it is not, which aborts its
        /// transfers.
        let live: Locked<UInt64>
        /// The readout measuring this offer — opened with it under an
        /// up-front readout, on the peer's first request under a per-entry one,
        /// and never under the shared paste readout, which is held apart.
        var operation: ClipboardTransferOperation?
        /// Whether the user called the offer off, so later requests are refused
        /// rather than answered.
        var isCancelled = false
        /// Whether the peer has asked for at least one of this offer's items.
        var isClaimed = false
        /// The deadline armed for this offer, which is armed in every state but
        /// "something else is streaming"; a stand-down cancels it.
        var claimDeadline: Task<Void, Never>?
        /// How many times this offer's bytes have moved, counted from whichever
        /// queue is serving it, so its deadline can tell a peer that has gone
        /// quiet from one still moving them. A count rather than a timestamp:
        /// the deadline samples it when it arms and again when it fires, so
        /// "moved since" needs no clock of its own.
        let activity = Locked<UInt64>(0)
        /// The items of this drop this side had nothing to send for, so the
        /// verdict can say what it left out.
        let unreadable: UnreadableReps

        /// Every item the gesture carried, including the ones the offer left
        /// out — what "none of them crossed" is measured against.
        var gesturedCount: Int {
            content.representations.count + unreadable.skippedBeforeOffer
        }

        init(generation: UInt64, content: ClipboardContent, skippedBeforeOffer: Int) {
            self.generation = generation
            self.content = content
            self.unreadable = UnreadableReps(skippedBeforeOffer: skippedBeforeOffer)
            self.live = Locked(generation)
        }
    }

    private let session: ClipboardControlSession
    private let reporter: ClipboardTransferReporter
    private let peerName: String
    private let progressRevealDelay: TimeInterval
    private let progressIdleGap: TimeInterval
    /// What a claim deadline is measured on — its only trigger, since by
    /// definition nothing arrives to drive it.
    private let clock: any EngineClock

    /// Called with what this side just did, for a surface to render.
    ///
    /// Set after construction rather than taken at init: an owner that holds this
    /// as a stored property has no `self` to hand over while building it.
    var onActivity: @MainActor (ClipboardEndpoint.Activity) -> Void = { _ in }

    /// Called once per drop generation when that drop is over — its verdict in,
    /// its readout finished, and nothing left for the peer to ask for.
    ///
    /// A drop's bytes can be staged somewhere only its owner knows about, and the
    /// peer pulls them long after the drag is over, so this is the moment they
    /// stop being needed. Raised only where the discipline reports a settle:
    /// never for a clipboard offer, which the peer may paste from again, nor for
    /// a drag out, which stages nothing.
    var onDropSettled: @MainActor (UInt64) -> Void = { _ in }

    private var entries: [UInt64: Entry] = [:]

    /// The clipboard offer the peer currently holds; `0` when it holds none.
    private var currentGeneration: UInt64 = 0

    private var nextGenerationStorage: UInt64

    /// The `.peerPaste` readout for the clipboard offer the peer is pulling.
    ///
    /// Held apart from the entry because it outlives it: a supersession retires
    /// the offer while the wave already streaming still has a readout to finish.
    private var pasteOperation: (generation: UInt64, operation: ClipboardTransferOperation)?

    private var lastOfferedDigestStorage: Data?

    private var discipline: ClipboardOfferDiscipline { session.outboundDiscipline }

    nonisolated private static let logger = KernovaLogger(
        subsystem: "app.kernova", category: "ClipboardOutboundOffers")

    /// Creates the outbound half of one connection.
    ///
    /// `firstGeneration` continues a counter across connections: the guest agent
    /// outlives its channels, and a reconnected host must never be handed a
    /// generation the agent already used.
    init(
        session: ClipboardControlSession,
        reporter: ClipboardTransferReporter,
        peerName: String,
        progressRevealDelay: TimeInterval = ClipboardTransferOperation.defaultRevealDelay,
        progressIdleGap: TimeInterval = ClipboardTransferOperation.defaultIdleGap,
        clock: any EngineClock = makePlatformEngineClock(),
        firstGeneration: UInt64 = 1
    ) {
        self.session = session
        self.reporter = reporter
        self.peerName = peerName
        self.progressRevealDelay = progressRevealDelay
        self.progressIdleGap = progressIdleGap
        self.clock = clock
        self.nextGenerationStorage = max(1, firstGeneration)
    }

    // MARK: - Reading what is offered

    /// The generation the next offer will carry, so a caller outliving this
    /// connection can seed the next one's counter.
    var nextGeneration: UInt64 { nextGenerationStorage }

    /// The content of the clipboard offer the peer currently holds, or `nil`.
    var currentContent: ClipboardContent? { entries[currentGeneration]?.content }

    /// The content offered under `generation`, or `nil` once it is retired.
    func content(generation: UInt64) -> ClipboardContent? {
        entries[generation]?.content
    }

    // MARK: - Offering

    /// Announces `content` to the peer, reporting what became of it.
    ///
    /// The generation is committed only once the frame is away, so a failed send
    /// leaves nothing registered for the peer to request. A clipboard offer
    /// dedups against the digest it last announced and retires the one before it;
    /// a drop or a drag out is registered alongside whatever is already live. A
    /// drop opens its readout before the send so a failure has something to
    /// report on, then announces itself as queued once the offer is away; a drag
    /// out opens none until the peer pulls, so a drag that stays in the guest
    /// leaves nothing on screen.
    ///
    /// `skippedBeforeOffer` is how many of the gesture's items this side already
    /// knows it cannot send. A drop's verdict counts them alongside the ones that
    /// fail once the peer asks, so the two stages an item can be lost at reach
    /// the user as one number.
    @discardableResult
    func offer(
        _ content: ClipboardContent, skippedBeforeOffer: Int = 0
    ) -> ClipboardEndpoint.OfferOutcome {
        if discipline.dedups, content.digest == lastOfferedDigestStorage { return .duplicate }
        // Cap to the 16-bit rep-index limit a transfer id can address; the
        // uncapped digest stays the dedup key, so unchanged content isn't
        // re-offered.
        let capped = content.cappedToOfferLimit()
        if let originalCount = capped.truncatedFrom {
            Self.logger.log(
                .warning,
                "Outbound offer truncated from \(originalCount, privacy: .public) to \(ClipboardContent.maxOfferableRepresentations, privacy: .public) representations (16-bit transfer-id limit)"
            )
        }
        let offered = capped.content
        guard !offered.representations.isEmpty else { return .nothingToOffer }

        let generation = nextGenerationStorage
        let operation: ClipboardTransferOperation? =
            discipline.readout == .upFront
            ? makeUpFrontOperation(generation: generation, content: offered) : nil
        do {
            try session.sendOffer(
                generation: generation,
                reps: offered.representations.map(\.offerRepresentationInfo),
                isConcealed: offered.isConcealed)
        } catch {
            Self.logger.log(
                .error,
                "Failed to send the outbound offer to '\(self.peerName, privacy: .public)' (conn=\(self.session.connectionTag, privacy: .public)): \(error.localizedDescription, privacy: .public)"
            )
            operation?.finish(.failed(.sendFailed))
            return .sendFailed
        }

        nextGenerationStorage += 1
        if discipline.supersedes, let previous = entries[currentGeneration] {
            retire(previous)
            session.outbox?.cancel(generation: previous.generation)
        }
        let entry = Entry(
            generation: generation, content: offered,
            skippedBeforeOffer: max(0, skippedBeforeOffer))
        entry.operation = operation
        entries[generation] = entry
        // The peer serves drops one job at a time, so a batch offered while
        // another is streaming waits its turn. Announcing it keeps it counted on
        // the readout that is showing instead of invisible until its first byte.
        operation?.markQueued()
        armClaimDeadlines()
        if discipline.supersedes {
            currentGeneration = generation
            // What the peer has just been handed is the news; the report the
            // previous gesture left standing described an offer this replaces.
            reporter.clearFinished()
        }
        if discipline.dedups { lastOfferedDigestStorage = content.digest }
        onActivity(.offerSent)
        Self.logger.log(
            .notice,
            "Sent an offer to '\(self.peerName, privacy: .public)' (gen=\(generation, privacy: .public), conn=\(self.session.connectionTag, privacy: .public), \(offered.representations.count, privacy: .public) reps, \(offered.totalByteCount, privacy: .public) bytes)"
        )
        return .sent(generation: generation)
    }

    /// Forgets what was last offered, so re-announcing the same content counts as
    /// a fresh offer.
    func resetDedup() {
        lastOfferedDigestStorage = nil
    }

    /// Latches `digest` as already announced, suppressing an offer of content the
    /// peer is itself the source of.
    func latchDedup(_ digest: Data) {
        lastOfferedDigestStorage = digest
    }

    /// Retires the clipboard offer the peer holds, reporting whether one was
    /// actually withdrawn.
    ///
    /// A release rather than an empty offer: an offer with no representations
    /// drops the peer's promise but leaves the pasteboard item behind it
    /// advertising flavors nothing can serve, where a release clears that write
    /// too. Idempotent — the released offer is forgotten, so a later call sends
    /// nothing.
    @discardableResult
    func release() -> Bool {
        guard discipline.supersedes, let entry = entries[currentGeneration] else { return false }
        do {
            try session.sendRelease(generation: entry.generation)
        } catch {
            Self.logger.log(
                .warning,
                "Failed to release offer gen=\(entry.generation, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
        retire(entry)
        session.outbox?.cancel(generation: entry.generation)
        // The send-dedup latch means "the peer already has this", which the
        // release just made false — so re-copying the released content is a new
        // copy to a peer whose clipboard this emptied, not a redundant offer.
        lastOfferedDigestStorage = nil
        Self.logger.log(
            .notice,
            "Released offer gen=\(entry.generation, privacy: .public) to '\(self.peerName, privacy: .public)' (conn=\(self.session.connectionTag, privacy: .public))"
        )
        return true
    }

    /// Withdraws the drag offered under `generation`, reporting whether one was
    /// live and the withdrawal reached the peer.
    ///
    /// For a flow whose owner withdraws by generation (a drag out); anywhere
    /// else it does nothing. Whatever is streaming from the offer is called
    /// off, and a later request for it is refused stale. Idempotent.
    @discardableResult
    func withdraw(generation: UInt64) -> Bool {
        guard discipline.ownerWithdraws, let entry = entries[generation] else { return false }
        do {
            try session.sendRelease(generation: generation)
        } catch {
            Self.logger.log(
                .warning,
                "Failed to withdraw offer gen=\(generation, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
        retire(entry)
        session.outbox?.cancel(generation: generation)
        Self.logger.log(
            .notice,
            "Withdrew offer gen=\(generation, privacy: .public) from '\(self.peerName, privacy: .public)' (conn=\(self.session.connectionTag, privacy: .public))"
        )
        return true
    }

    // MARK: - Serving the peer's pulls

    /// Answers one pull by streaming the representation it names over `link`.
    ///
    /// `link` is the transfer's data connection — one this side's listener
    /// accepted, or a dialler for the one it is about to open — and every exit
    /// path here disposes of it, so a refused pull never leaves a descriptor
    /// open or a peer parked.
    func handleRequest(_ request: ClipboardPullRequest, link: ClipboardTransferLink) {
        // Ahead of every verdict: with no outbox nothing can answer, and the
        // link is this side's to close.
        guard let outbox = session.outbox else {
            link.abandon()
            return
        }
        guard let entry = entries[request.generation], !entry.isCancelled else {
            Self.logger.log(
                .debug,
                "Refusing a stale request for gen=\(request.generation, privacy: .public) (conn=\(self.session.connectionTag, privacy: .public))"
            )
            // Refuse every dropped request so the peer's parked pull wakes
            // immediately instead of stalling to its backstop timeout. Stale is
            // the code a peer retires quietly: its paste comes back empty and
            // neither side reports a failure.
            outbox.refuse(
                link: link, transferID: request.transferID, code: .requestStale,
                message: staleMessage(for: request.generation))
            return
        }
        let repIndex = ClipboardTransferID.repIndex(of: request.transferID)
        guard repIndex < entry.content.representations.count else {
            Self.logger.log(
                .warning,
                "Request transfer_id \(request.transferID, privacy: .public) out of range for gen=\(request.generation, privacy: .public) (conn=\(self.session.connectionTag, privacy: .public))"
            )
            outbox.refuse(
                link: link, transferID: request.transferID, code: .requestRange,
                message: rangeMessage(repIndex))
            return
        }
        let representation = entry.content.representations[repIndex]
        guard representation.uti == request.uti else {
            Self.logger.log(
                .warning,
                "Request uti '\(request.uti, privacy: .public)' doesn't match offered rep \(repIndex, privacy: .public) (conn=\(self.session.connectionTag, privacy: .public))"
            )
            outbox.refuse(
                link: link, transferID: request.transferID, code: .requestUTI,
                message: utiMessage(request.uti))
            return
        }
        // Ahead of the transfer: with no readout a transfer announced here
        // would never see a terminal and its bar would stick on screen.
        guard let operation = operation(for: entry) else {
            outbox.refuse(
                link: link, transferID: request.transferID, code: .cancelled,
                message: "No readout is measuring generation \(request.generation)")
            return
        }

        if discipline.hasClaimDeadline, !entry.isClaimed {
            entry.isClaimed = true
            // Something is streaming now, so every batch behind it is waiting its
            // turn rather than going unclaimed — the guest serves one job at a
            // time. Their deadlines resume when this one ends; this one takes a
            // liveness deadline of its own in their place.
            standDownClaimDeadlines()
            armClaimDeadlines()
        }

        let xid = request.transferID
        let live = entry.live
        let activity = entry.activity
        let unreadable = entry.unreadable
        // Nothing on this side knows the peer has stopped asking, so unless the
        // peer's verdict ends the readout, the idle gap is what calls it over.
        let finishesWhenIdle = discipline.readout != .upFront
        let expectedBytes = UInt64(max(0, representation.byteCount))
        let unitName = unitName(for: representation)
        // The readout hears about the transfer from inside `serve`, once it has
        // taken the id: a request the outbox turns away as a duplicate of one
        // already streaming must not re-announce that live unit, which would
        // reset its byte count to zero and run its bar backwards.
        let served = outbox.serve(
            transferID: xid,
            generation: request.generation,
            representation: representation,
            maxAcceptByteCount: request.maxAcceptByteCount,
            // A dropped or dragged item always lands as a file; nothing about
            // it is pasteboard-inline.
            isInline: discipline.servesInline && representation.shouldInlineOnPasteboard,
            isCurrent: { generation in live.withLock { $0 == generation } },
            link: link,
            onBegin: {
                activity.withLock { $0 &+= 1 }
                operation.unitBegan(id: xid, expectedBytes: expectedBytes, name: unitName)
            },
            onProgress: { sent, total in
                activity.withLock { $0 &+= 1 }
                operation.unitProgressed(
                    id: xid, bytesTransferred: UInt64(max(0, sent)),
                    totalBytes: UInt64(max(0, total)))
            },
            // One item this side cannot read never cancels the batch: the peer
            // skips it and keeps pulling, and this is what lets the verdict name
            // how many were left behind.
            onSourceUnreadable: { unreadable.record(repIndex: repIndex) },
            // No `activity` count here: activity is bytes moving, and a
            // transfer's end is the start of the wait for the peer's next move
            // — its next pull, or its `DropComplete` — which is exactly what
            // the liveness window is there to bound.
            onComplete: { success in
                operation.unitEnded(id: xid, succeeded: success)
                // A drop's readout spans the whole set and ends with the peer's
                // `DropComplete` instead.
                if finishesWhenIdle { operation.finishWhenIdle() }
            })
        guard served else {
            Self.logger.log(
                .warning,
                "Ignoring a second request for transfer \(xid, privacy: .public), which is already streaming to '\(self.peerName, privacy: .public)' (conn=\(self.session.connectionTag, privacy: .public))"
            )
            return
        }
        onActivity(.transferServed)
        Self.logger.log(
            .debug,
            "Streaming rep \(repIndex, privacy: .public) to '\(self.peerName, privacy: .public)' (gen=\(request.generation, privacy: .public), conn=\(self.session.connectionTag, privacy: .public), \(representation.byteCount, privacy: .public) bytes offered)"
        )
    }

    // MARK: - Ending an offer

    /// Stops what the peer is pulling for `generation`, because the user
    /// cancelled its readout.
    ///
    /// A clipboard offer survives: the peer can paste again and pull the same
    /// representations, exactly as it can after any retired transfer — what it
    /// can no longer do is resume the wave the user just stopped, so later
    /// requests are refused stale. A drop or a drag out is the gesture itself,
    /// so cancelling it retires the whole offer and tells the peer.
    func cancel(generation: UInt64) {
        guard let entry = entries[generation] else { return }
        if discipline.cancelRetiresOffer {
            entry.isCancelled = true
            // Zeroed first, so a transfer between writes sees the job is gone
            // and aborts itself rather than racing the explicit cancel below.
            entry.live.withLock { $0 = 0 }
            session.outbox?.cancel(generation: generation)
            try? session.sendRelease(generation: generation)
            forget(entry)
            if discipline.reportsSettle { onDropSettled(generation) }
            // The readout dwells at the fraction it stopped on, so the cancel is
            // visibly what happened.
            entry.operation?.finish(.cancelled)
            armClaimDeadlines()
        } else {
            // With no outbox there is nothing streaming to call off.
            guard let outbox = session.outbox else { return }
            entry.isCancelled = true
            outbox.cancel(generation: generation)
        }
        Self.logger.log(
            .notice,
            "User cancelled the outbound transfer to '\(self.peerName, privacy: .public)' (gen=\(generation, privacy: .public), conn=\(self.session.connectionTag, privacy: .public))"
        )
    }

    /// Applies the peer's verdict on a drop.
    func handleDropComplete(_ complete: Kernova_V1_DropComplete) {
        guard let entry = entries[complete.generation] else { return }
        forget(entry)
        entry.live.withLock { $0 = 0 }
        // Ahead of the readout's terminal: the peer has said what became of the
        // drop, so nothing will be pulled from what this side staged for it.
        onDropSettled(complete.generation)
        defer { armClaimDeadlines() }
        switch complete.outcome {
        case .completed:
            reportCompletedDrop(entry, generation: complete.generation)
        case .cancelled:
            entry.operation?.finish(.cancelled)
            Self.logger.log(
                .notice,
                "Drop to '\(self.peerName, privacy: .public)' cancelled (gen=\(complete.generation, privacy: .public), conn=\(self.session.connectionTag, privacy: .public))"
            )
        case .failed, .unspecified, .UNRECOGNIZED:
            // The code is matched, never the message: `message` is peer-supplied
            // text and the sentence the user reads is composed on this side.
            let code = ClipboardErrorCode(rawValue: complete.code)
            Self.logger.log(
                .error,
                "Drop to '\(self.peerName, privacy: .public)' failed (gen=\(complete.generation, privacy: .public), conn=\(self.session.connectionTag, privacy: .public), code=\(complete.code, privacy: .public)): \(complete.message, privacy: .public)"
            )
            entry.operation?.finish(.failed(.peerReported(code)))
        }
    }

    /// Retires the drag the peer is done with: nothing will pull from it again.
    ///
    /// Anything still streaming from it is called off; its readout, opened on
    /// the peer's first pull, ends on its own idle gap.
    func handleDragComplete(_ complete: Kernova_V1_DragComplete) {
        guard let entry = entries[complete.generation] else { return }
        retire(entry)
        session.outbox?.cancel(generation: complete.generation)
        Self.logger.log(
            .notice,
            "'\(self.peerName, privacy: .public)' is done with the drag (gen=\(complete.generation, privacy: .public), conn=\(self.session.connectionTag, privacy: .public))"
        )
    }

    /// Ends the readout of a drop the peer served to its end, saying how many of
    /// the gesture's items this side could not send it.
    ///
    /// The peer only ever pulls what it was offered, so what it reports as
    /// complete is every item that reached it — the ones this side never offered
    /// and the ones whose transfers failed here are the batch's own news, and are
    /// owed one sentence naming them together. That sentence *is* the drop's
    /// terminal: one gesture ends once, so a batch that lost a file finishes as
    /// the refusal rather than as a completion with a refusal published beside
    /// it, where only their relative dates would keep the refusal standing.
    private func reportCompletedDrop(_ entry: Entry, generation: UInt64) {
        let unreadable = entry.unreadable.count
        let gestured = entry.gesturedCount
        guard unreadable > 0 else {
            entry.operation?.finish(.completed)
            Self.logger.log(
                .notice,
                "Drop to '\(self.peerName, privacy: .public)' completed (gen=\(generation, privacy: .public), conn=\(self.session.connectionTag, privacy: .public), \(gestured, privacy: .public) item(s))"
            )
            return
        }
        Self.logger.log(
            .warning,
            "Drop to '\(self.peerName, privacy: .public)' left \(unreadable, privacy: .public) of \(gestured, privacy: .public) item(s) unsent (gen=\(generation, privacy: .public), conn=\(self.session.connectionTag, privacy: .public))"
        )
        // With not one item across there is no rest of the batch to speak of,
        // which is the whole of what the skipped sentence promises.
        entry.operation?.finish(
            .failed(
                unreadable < gestured ? .itemsSkipped(count: unreadable) : .itemsUnreadable))
    }

    /// Retires every offer because the connection is over.
    ///
    /// A drop still open is a gesture made on this Mac whose files never landed,
    /// so it is owed an answer here; one already called off is not — the user
    /// knows. A clipboard offer's or a drag out's readout is abandoned rather
    /// than failed: the peer's paste or drop, not this side, is what it was
    /// measuring.
    func endSession() {
        for entry in entries.values {
            if discipline.reportsSettle { onDropSettled(entry.generation) }
            if discipline.failsOnSessionEnd {
                guard !entry.isCancelled else { continue }
                entry.operation?.finish(
                    .failed(.interrupted(fileCount: entry.gesturedCount)))
            } else {
                entry.operation?.abandon()
            }
        }
        pasteOperation?.operation.abandon()
        pasteOperation = nil
        for entry in entries.values {
            entry.live.withLock { $0 = 0 }
            forget(entry)
        }
        currentGeneration = 0
    }

    // MARK: - Private

    // MARK: - The claim deadline

    /// Puts every offer on the deadline its state calls for, where the
    /// discipline has one (a drop): the one the peer is serving on a liveness
    /// window of its own, and one the peer has not begun on the unclaimed clock
    /// — the latter only while nothing is streaming, since the peer serves
    /// drops one job at a time.
    ///
    /// A drop's readout is closed by the peer's `DropComplete`, so a peer that
    /// never pulls, or that stops pulling with a job open, leaves the gesture
    /// with no progress, no failure and no end until the channel itself dies.
    /// This is what answers for it — and giving the served job a clock is what
    /// keeps one wedged there from suppressing the deadline of every batch
    /// behind it.
    private func armClaimDeadlines() {
        guard discipline.hasClaimDeadline else { return }
        let isServing = entries.values.contains(where: \.isClaimed)
        for entry in entries.values where entry.isClaimed || !isServing {
            armClaimDeadline(for: entry)
        }
    }

    /// Schedules one entry's deadline, sampling the activity it must beat.
    private func armClaimDeadline(for entry: Entry) {
        guard entry.claimDeadline == nil else { return }
        let generation = entry.generation
        let activity = entry.activity.withLock { $0 }
        entry.claimDeadline = clock.schedule(after: ClipboardStreamTuning.dropClaimTimeout) {
            @MainActor [weak self] in
            guard !Task.isCancelled else { return }
            self?.claimDeadlineExpired(generation: generation, activityWhenArmed: activity)
        }
    }

    /// Stands every armed deadline down, so a batch queued behind one the peer
    /// is streaming is not called off for waiting its turn.
    private func standDownClaimDeadlines() {
        for entry in entries.values {
            entry.claimDeadline?.cancel()
            entry.claimDeadline = nil
        }
    }

    /// Calls off a drop the peer never began, or one it began and went quiet on.
    private func claimDeadlineExpired(generation: UInt64, activityWhenArmed: UInt64) {
        guard let entry = entries[generation], !entry.isCancelled else { return }
        entry.claimDeadline = nil
        // An inactivity window, never an absolute deadline: a job that has moved
        // since this was armed starts the clock again rather than being called
        // off for needing more than one window to stream.
        guard entry.activity.withLock({ $0 }) == activityWhenArmed else {
            armClaimDeadlines()
            return
        }
        let wasClaimed = entry.isClaimed
        entry.live.withLock { $0 = 0 }
        forget(entry)
        // The peer may be wedged rather than gone, so the release is what stops
        // it pulling an offer this side has already answered for.
        try? session.sendRelease(generation: generation)
        if discipline.reportsSettle { onDropSettled(generation) }
        entry.operation?.finish(.failed(wasClaimed ? .timedOut : .unclaimed))
        Self.logger.log(
            .warning,
            "Drop to '\(self.peerName, privacy: .public)' \(wasClaimed ? "stopped moving" : "went unclaimed", privacy: .public) for \(ClipboardStreamTuning.dropClaimTimeout, privacy: .public)s (gen=\(generation, privacy: .public), conn=\(self.session.connectionTag, privacy: .public))"
        )
        armClaimDeadlines()
    }

    /// Drops `entry` from the live set and ends the transfers still riding it.
    private func retire(_ entry: Entry) {
        entry.live.withLock { $0 = 0 }
        forget(entry)
        if entry.generation == currentGeneration { currentGeneration = 0 }
    }

    /// Removes `entry` from the live set, calling off its deadline with it.
    private func forget(_ entry: Entry) {
        entry.claimDeadline?.cancel()
        entry.claimDeadline = nil
        entries[entry.generation] = nil
    }

    /// The readout serving `entry`, opening one on the peer's request where
    /// the discipline opens it then.
    ///
    /// Every clipboard operation is a `.peerPaste`: the peer asks for bytes only
    /// from the pasteboard promise callback of a paste inside it, so this readout
    /// is the only thing explaining why the app the user pasted into is waiting.
    /// A drag out's is per offer, so two drags the peer pulls from at once never
    /// abandon each other's. A finished one is replaced rather than reused — the
    /// waves can be minutes apart, far longer than the idle gap, and reusing an
    /// ended operation drops the second wave's progress entirely.
    private func operation(for entry: Entry) -> ClipboardTransferOperation? {
        switch discipline.readout {
        case .upFront:
            guard let operation = entry.operation else {
                Self.logger.log(
                    .fault,
                    "Offer gen=\(entry.generation, privacy: .public) has no readout — refusing its request"
                )
                assertionFailure("Offer generation \(entry.generation) has no readout")
                return nil
            }
            return operation
        case .perEntryOnFirstRequest:
            if let existing = entry.operation, existing.isLive { return existing }
            let operation = makeOnRequestOperation(generation: entry.generation)
            entry.operation = operation
            return operation
        case .sharedPeerPaste:
            if let existing = pasteOperation, existing.generation == entry.generation,
                existing.operation.isLive
            {
                return existing.operation
            }
            pasteOperation?.operation.abandon()
            let operation = makeOnRequestOperation(generation: entry.generation)
            pasteOperation = (generation: entry.generation, operation: operation)
            return operation
        }
    }

    /// A readout opened by the peer's request, with nothing known up front.
    private func makeOnRequestOperation(generation: UInt64) -> ClipboardTransferOperation {
        ClipboardTransferOperation(
            gesture: discipline.servingGesture, direction: .outbound, peerName: peerName,
            revealDelay: progressRevealDelay, idleGap: progressIdleGap,
            onCancelRequested: cancelHandler(generation: generation),
            reporter: reporter)
    }

    /// What a Cancel on `generation`'s readout runs.
    ///
    /// The tracker calls it outside its own lock, on whichever thread noticed
    /// the click, so it hops before touching anything.
    private func cancelHandler(generation: UInt64) -> @Sendable () -> Void {
        { [weak self] in
            MainActorBridge.async { self?.cancel(generation: generation) }
        }
    }

    /// Opens the readout spanning one offer, with the set's totals as the floor
    /// so the bar's denominator is every dropped file rather than each in turn.
    private func makeUpFrontOperation(
        generation: UInt64, content: ClipboardContent
    ) -> ClipboardTransferOperation {
        ClipboardTransferOperation(
            gesture: discipline.servingGesture, direction: .outbound, peerName: peerName,
            expectedBytes: content.representations.reduce(UInt64(0)) {
                $0 &+ UInt64(max(0, $1.byteCount))
            },
            expectedItems: content.representations.count,
            revealDelay: progressRevealDelay, idleGap: progressIdleGap,
            onCancelRequested: cancelHandler(generation: generation),
            reporter: reporter)
    }

    /// The readout label for one representation: a dropped or dragged item
    /// always names its file, while an inline clipboard rep has no name to show.
    private func unitName(for representation: ClipboardContent.Representation) -> String? {
        guard !discipline.namesEveryUnit else { return representation.filename }
        return representation.filename.isEmpty ? nil : representation.filename
    }

    private func staleMessage(for generation: UInt64) -> String {
        if entries[generation]?.isCancelled == true {
            return "The transfer for generation \(generation) was cancelled"
        }
        return discipline.staleMessage(generation: generation)
    }

    private func rangeMessage(_ repIndex: Int) -> String {
        discipline.rangeMessage(repIndex: repIndex)
    }

    private func utiMessage(_ uti: String) -> String {
        discipline.utiMessage(uti: uti)
    }
}
