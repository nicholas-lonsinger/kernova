import Foundation

/// One peer's pull of a single representation, however it reached this side.
///
/// A guest's pull arrives as the first frame on the data connection it dialled;
/// a host's arrives as a `ClipboardRequest` on the control channel, and the
/// connection follows. The fields are the same either way, so the owner logic
/// that answers one is written once.
public struct ClipboardPullRequest: Sendable {
    /// The offer generation being pulled from.
    public let generation: UInt64
    /// Names the transfer answering this pull.
    public let transferID: UInt64
    /// The single representation being consumed.
    public let uti: String
    /// The requester's payload ceiling, in the unit the offer advertised.
    public let maxAcceptByteCount: UInt64

    /// Describes one pull.
    public init(generation: UInt64, transferID: UInt64, uti: String, maxAcceptByteCount: UInt64) {
        self.generation = generation
        self.transferID = transferID
        self.uti = uti
        self.maxAcceptByteCount = maxAcceptByteCount
    }

    /// The pull a control-channel `ClipboardRequest` names.
    public init(_ request: Kernova_V1_ClipboardRequest) {
        self.init(
            generation: request.generation, transferID: request.transferID, uti: request.uti,
            maxAcceptByteCount: request.maxAcceptByteCount)
    }

    /// The pull a data connection's opening frame names.
    public init(_ request: Kernova_V1_ClipboardTransferRequest) {
        self.init(
            generation: request.generation, transferID: request.transferID, uti: request.uti,
            maxAcceptByteCount: request.maxAcceptByteCount)
    }
}

/// What this side has offered the peer, and the transfers it serves in answer.
///
/// The peer decides what it pulls and when — a paste can take two waves minutes
/// apart — so transfers are declared as they are asked for, never up front.
///
/// The two channels differ in exactly one thing here, and it is the reason
/// `kind` is read off the session rather than passed twice: a clipboard offer
/// **supersedes** the one before it, while every drop is an independent job the
/// user asked for separately.
@MainActor
public final class ClipboardOutboundOffers {
    /// One offer this side has made and can still serve.
    private final class Entry {
        let generation: UInt64
        let content: ClipboardContent
        /// Read from each transfer's own queue to decide whether the offer is
        /// still wanted; zeroed once it is not, which aborts its transfers.
        let live = AtomicGeneration()
        /// The readout measuring this offer, opened up front for a drop and on
        /// the peer's first request for a clipboard offer.
        var operation: ClipboardTransferOperation?
        /// Whether the user called the offer off, so later requests are refused
        /// rather than answered.
        var isCancelled = false
        /// Whether the peer has asked for at least one of this offer's items.
        var isClaimed = false
        /// Whether a deadline is scheduled for this offer, which is true in every
        /// state but "something else is streaming".
        var isClaimDeadlineArmed = false
        /// Which arming of that deadline is live: a stand-down or a re-arm bumps
        /// it, so one already scheduled can tell it was superseded.
        var claimArming: UInt64 = 0

        init(generation: UInt64, content: ClipboardContent) {
            self.generation = generation
            self.content = content
            live.set(generation)
        }
    }

    private let session: ClipboardControlSession
    private let reporter: ClipboardTransferReporter
    private let peerName: String
    private let progressRevealDelay: TimeInterval
    private let progressIdleGap: TimeInterval
    private let dropClaimTimeout: TimeInterval
    /// Runs the unclaimed-drop deadline after a delay — its only trigger, since
    /// by definition nothing arrives to drive it.
    private let dropClaimSchedule:
        @Sendable (_ after: TimeInterval, _ work: @escaping @MainActor @Sendable () -> Void) ->
            Void

    /// Called with what this side just did, for a surface to render.
    ///
    /// Set after construction rather than taken at init: an owner that holds this
    /// as a stored property has no `self` to hand over while building it.
    public var onActivity: @MainActor (ClipboardEndpoint.Activity) -> Void = { _ in }

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

    private var kind: ClipboardControlSession.Kind { session.kind }

    /// The production deadline scheduler: the main queue, where every other
    /// readout event is already serialized.
    nonisolated public static let scheduleOnMainQueue:
        @Sendable (TimeInterval, @escaping @MainActor @Sendable () -> Void) -> Void = {
            after, work in
            DispatchQueue.main.asyncAfter(deadline: .now() + after) {
                MainActor.assumeIsolated { work() }
            }
        }

    nonisolated private static let logger = KernovaLogger(
        subsystem: "app.kernova", category: "ClipboardOutboundOffers")

    /// Creates the outbound half of one connection.
    ///
    /// `firstGeneration` continues a counter across connections: the guest agent
    /// outlives its channels, and a reconnected host must never be handed a
    /// generation the agent already used.
    public init(
        session: ClipboardControlSession,
        reporter: ClipboardTransferReporter,
        peerName: String,
        progressRevealDelay: TimeInterval = ClipboardTransferOperation.defaultRevealDelay,
        progressIdleGap: TimeInterval = ClipboardTransferOperation.defaultIdleGap,
        dropClaimTimeout: TimeInterval = ClipboardStreamTuning.dropClaimTimeout,
        dropClaimSchedule:
            @escaping @Sendable (
                TimeInterval, @escaping @MainActor @Sendable () -> Void
            ) -> Void = ClipboardOutboundOffers.scheduleOnMainQueue,
        firstGeneration: UInt64 = 1
    ) {
        self.session = session
        self.reporter = reporter
        self.peerName = peerName
        self.progressRevealDelay = progressRevealDelay
        self.progressIdleGap = progressIdleGap
        self.dropClaimTimeout = dropClaimTimeout
        self.dropClaimSchedule = dropClaimSchedule
        self.nextGenerationStorage = max(1, firstGeneration)
    }

    // MARK: - Reading what is offered

    /// The generation the next offer will carry, so a caller outliving this
    /// connection can seed the next one's counter.
    public var nextGeneration: UInt64 { nextGenerationStorage }

    /// The content of the clipboard offer the peer currently holds, or `nil`.
    public var currentContent: ClipboardContent? { entries[currentGeneration]?.content }

    /// The content offered under `generation`, or `nil` once it is retired.
    public func content(generation: UInt64) -> ClipboardContent? {
        entries[generation]?.content
    }

    // MARK: - Offering

    /// Announces `content` to the peer, reporting what became of it.
    ///
    /// The generation is committed only once the frame is away, so a failed send
    /// leaves nothing registered for the peer to request. A clipboard offer
    /// dedups against the digest it last announced and retires the one before it;
    /// a drop is registered alongside whatever is already streaming, and opens
    /// its readout before the send so a failure has something to report on, then
    /// announces itself as queued once the offer is away.
    @discardableResult
    public func offer(_ content: ClipboardContent) -> ClipboardEndpoint.OfferOutcome {
        if kind == .clipboard, content.digest == lastOfferedDigestStorage { return .duplicate }
        // Cap to the 16-bit rep-index limit a transfer id can address; the
        // uncapped digest stays the dedup key, so unchanged content isn't
        // re-offered.
        let capped = content.cappedToOfferLimit()
        if let originalCount = capped.truncatedFrom {
            Self.logger.warning(
                "Outbound offer truncated from \(originalCount, privacy: .public) to \(ClipboardContent.maxOfferableRepresentations, privacy: .public) representations (16-bit transfer-id limit)"
            )
        }
        let offered = capped.content
        guard !offered.representations.isEmpty else { return .nothingToOffer }

        let generation = nextGenerationStorage
        let operation: ClipboardTransferOperation? =
            kind == .drop ? makeDropOperation(generation: generation, content: offered) : nil
        do {
            try session.sendOffer(
                generation: generation,
                reps: offered.representations.map(\.offerRepresentationInfo),
                isConcealed: offered.isConcealed)
        } catch {
            Self.logger.error(
                "Failed to send the outbound offer to '\(self.peerName, privacy: .public)' (conn=\(self.session.connectionTag, privacy: .public)): \(error.localizedDescription, privacy: .public)"
            )
            operation?.finish(.failed(.sendFailed))
            return .sendFailed
        }

        nextGenerationStorage += 1
        if kind == .clipboard, let previous = entries[currentGeneration] {
            retire(previous)
            session.outbox?.cancel(generation: previous.generation)
        }
        let entry = Entry(generation: generation, content: offered)
        entry.operation = operation
        entries[generation] = entry
        // The peer serves drops one job at a time, so a batch offered while
        // another is streaming waits its turn. Announcing it keeps it counted on
        // the readout that is showing instead of invisible until its first byte.
        if kind == .drop {
            operation?.markQueued()
            armClaimDeadlines()
        }
        if kind == .clipboard {
            currentGeneration = generation
            lastOfferedDigestStorage = content.digest
            // What the peer has just been handed is the news; the report the
            // previous gesture left standing described an offer this replaces.
            reporter.clearFinished()
        }
        onActivity(.offerSent)
        Self.logger.notice(
            "Sent an offer to '\(self.peerName, privacy: .public)' (gen=\(generation, privacy: .public), conn=\(self.session.connectionTag, privacy: .public), \(offered.representations.count, privacy: .public) reps, \(offered.totalByteCount, privacy: .public) bytes)"
        )
        return .sent(generation: generation)
    }

    /// Forgets what was last offered, so re-announcing the same content counts as
    /// a fresh offer.
    public func resetDedup() {
        lastOfferedDigestStorage = nil
    }

    /// Latches `digest` as already announced, suppressing an offer of content the
    /// peer is itself the source of.
    public func latchDedup(_ digest: Data) {
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
    public func release() -> Bool {
        guard kind == .clipboard, let entry = entries[currentGeneration] else { return false }
        do {
            try session.sendRelease(generation: entry.generation)
        } catch {
            Self.logger.warning(
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
        Self.logger.notice(
            "Released offer gen=\(entry.generation, privacy: .public) to '\(self.peerName, privacy: .public)' (conn=\(self.session.connectionTag, privacy: .public))"
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
    public func handleRequest(_ request: ClipboardPullRequest, link: ClipboardTransferLink) {
        // Ahead of every verdict: with no outbox nothing can answer, and the
        // link is this side's to close.
        guard let outbox = session.outbox else {
            link.abandon()
            return
        }
        guard let entry = entries[request.generation], !entry.isCancelled else {
            Self.logger.debug(
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
            Self.logger.warning(
                "Request transfer_id \(request.transferID, privacy: .public) out of range for gen=\(request.generation, privacy: .public) (conn=\(self.session.connectionTag, privacy: .public))"
            )
            outbox.refuse(
                link: link, transferID: request.transferID, code: .requestRange,
                message: rangeMessage(repIndex))
            return
        }
        let representation = entry.content.representations[repIndex]
        guard representation.uti == request.uti else {
            Self.logger.warning(
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

        if kind == .drop, !entry.isClaimed {
            entry.isClaimed = true
            // Something is streaming now, so every batch behind it is waiting its
            // turn rather than going unclaimed — the guest serves one job at a
            // time. Their deadlines resume when this one ends.
            standDownClaimDeadlines()
        }

        let xid = request.transferID
        let live = entry.live
        let isClipboard = kind == .clipboard
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
            // A drop always lands as a file in the guest's Downloads; nothing
            // about it is pasteboard-inline.
            isInline: isClipboard && representation.shouldInlineOnPasteboard,
            isCurrent: { live.isCurrent($0) },
            link: link,
            onBegin: {
                operation.unitBegan(id: xid, expectedBytes: expectedBytes, name: unitName)
            },
            onProgress: { sent, total in
                operation.unitProgressed(
                    id: xid, bytesTransferred: UInt64(max(0, sent)),
                    totalBytes: UInt64(max(0, total)))
            },
            onComplete: { success in
                operation.unitEnded(id: xid, succeeded: success)
                // Nothing on this side knows the peer has stopped asking, so the
                // idle gap is what calls a paste over. A drop's readout spans the
                // whole set and ends with the peer's `DropComplete`.
                if isClipboard { operation.finishWhenIdle() }
            })
        guard served else {
            Self.logger.warning(
                "Ignoring a second request for transfer \(xid, privacy: .public), which is already streaming to '\(self.peerName, privacy: .public)' (conn=\(self.session.connectionTag, privacy: .public))"
            )
            return
        }
        onActivity(.transferServed)
        Self.logger.debug(
            "Streaming rep \(repIndex, privacy: .public) to '\(self.peerName, privacy: .public)' (gen=\(request.generation, privacy: .public), conn=\(self.session.connectionTag, privacy: .public), \(representation.byteCount, privacy: .public) bytes offered)"
        )
    }

    // MARK: - Ending an offer

    /// Stops what the peer is pulling for `generation`, because the user
    /// cancelled its readout.
    ///
    /// A clipboard offer survives: the peer can paste again and pull the same
    /// representations, exactly as it can after any retired transfer
    /// (docs/CLIPBOARD.md §9) — what it can no longer do is resume the wave the
    /// user just stopped, so later requests are refused stale. A drop is the
    /// gesture itself, so cancelling it retires the whole job.
    public func cancel(generation: UInt64) {
        guard let entry = entries[generation] else { return }
        switch kind {
        case .clipboard:
            // With no outbox there is nothing streaming to call off.
            guard let outbox = session.outbox else { return }
            entry.isCancelled = true
            outbox.cancel(generation: generation)
        case .drop:
            entry.isCancelled = true
            // Zeroed first, so a transfer between writes sees the job is gone
            // and aborts itself rather than racing the explicit cancel below.
            entry.live.set(0)
            session.outbox?.cancel(generation: generation)
            try? session.sendRelease(generation: generation)
            // The readout dwells at the fraction it stopped on, so the cancel is
            // visibly what happened.
            entry.operation?.finish(.cancelled)
            entries[generation] = nil
            armClaimDeadlines()
        }
        Self.logger.notice(
            "User cancelled the outbound transfer to '\(self.peerName, privacy: .public)' (gen=\(generation, privacy: .public), conn=\(self.session.connectionTag, privacy: .public))"
        )
    }

    /// Applies the peer's verdict on a drop.
    public func handleDropComplete(_ complete: Kernova_V1_DropComplete) {
        guard let entry = entries.removeValue(forKey: complete.generation) else { return }
        entry.live.set(0)
        defer { armClaimDeadlines() }
        switch complete.outcome {
        case .completed:
            entry.operation?.finish(.completed)
            Self.logger.notice(
                "Drop to '\(self.peerName, privacy: .public)' completed (gen=\(complete.generation, privacy: .public), conn=\(self.session.connectionTag, privacy: .public), \(entry.content.representations.count, privacy: .public) item(s))"
            )
        case .cancelled:
            entry.operation?.finish(.cancelled)
            Self.logger.notice(
                "Drop to '\(self.peerName, privacy: .public)' cancelled (gen=\(complete.generation, privacy: .public), conn=\(self.session.connectionTag, privacy: .public))"
            )
        case .failed, .unspecified, .UNRECOGNIZED:
            // The code is matched, never the message: `message` is peer-supplied
            // text and the sentence the user reads is composed on this side.
            let code = ClipboardErrorCode(rawValue: complete.code)
            Self.logger.error(
                "Drop to '\(self.peerName, privacy: .public)' failed (gen=\(complete.generation, privacy: .public), conn=\(self.session.connectionTag, privacy: .public), code=\(complete.code, privacy: .public)): \(complete.message, privacy: .public)"
            )
            entry.operation?.finish(.failed(.peerReported(code)))
        }
    }

    /// Retires every offer because the connection is over.
    ///
    /// A drop still open is a gesture made on this Mac whose files never landed,
    /// so it is owed an answer here; one already called off is not — the user
    /// knows. A clipboard offer's readout is abandoned rather than failed: the
    /// peer's paste, not this side, is what it was measuring.
    public func endSession() {
        if kind == .drop {
            for entry in entries.values where !entry.isCancelled {
                entry.operation?.finish(
                    .failed(.interrupted(fileCount: entry.content.representations.count)))
            }
        }
        pasteOperation?.operation.abandon()
        pasteOperation = nil
        for entry in entries.values { entry.live.set(0) }
        entries.removeAll()
        currentGeneration = 0
    }

    // MARK: - Private

    // MARK: - The unclaimed-drop deadline

    /// Starts the deadline on every drop the peer has not begun, unless one it
    /// *has* begun is still open.
    ///
    /// A drop's readout is closed by the peer's `DropComplete`, so a peer that
    /// never pulls leaves the gesture with no progress, no failure and no end
    /// until the channel itself dies. This is what answers for it.
    private func armClaimDeadlines() {
        guard kind == .drop, !entries.values.contains(where: \.isClaimed) else { return }
        for entry in entries.values where !entry.isClaimed && !entry.isClaimDeadlineArmed {
            entry.isClaimDeadlineArmed = true
            entry.claimArming &+= 1
            let generation = entry.generation
            let arming = entry.claimArming
            dropClaimSchedule(dropClaimTimeout) { [weak self] in
                self?.claimDeadlineExpired(generation: generation, arming: arming)
            }
        }
    }

    /// Stands every armed deadline down, so a batch queued behind one the peer
    /// is streaming is not called off for waiting its turn.
    private func standDownClaimDeadlines() {
        for entry in entries.values {
            entry.claimArming &+= 1
            entry.isClaimDeadlineArmed = false
        }
    }

    /// Calls off a drop the peer never began.
    private func claimDeadlineExpired(generation: UInt64, arming: UInt64) {
        guard let entry = entries[generation], entry.claimArming == arming, !entry.isClaimed,
            !entry.isCancelled
        else { return }
        entry.isClaimDeadlineArmed = false
        entry.live.set(0)
        entries[generation] = nil
        // The peer may be wedged rather than gone, so the release is what stops
        // it pulling an offer this side has already answered for.
        try? session.sendRelease(generation: generation)
        entry.operation?.finish(.failed(.unclaimed))
        Self.logger.warning(
            "Drop to '\(self.peerName, privacy: .public)' went unclaimed for \(self.dropClaimTimeout, privacy: .public)s (gen=\(generation, privacy: .public), conn=\(self.session.connectionTag, privacy: .public))"
        )
        armClaimDeadlines()
    }

    /// Drops `entry` from the live set and ends the transfers still riding it.
    private func retire(_ entry: Entry) {
        entry.live.set(0)
        entries[entry.generation] = nil
        if entry.generation == currentGeneration { currentGeneration = 0 }
    }

    /// The readout serving `entry`, opening one when a clipboard offer's first
    /// request arrives.
    ///
    /// Every clipboard operation is a `.peerPaste`: the peer asks for bytes only
    /// from the pasteboard promise callback of a paste inside it, so this readout
    /// is the only thing explaining why the app the user pasted into is waiting.
    /// A finished one is replaced rather than reused — the waves can be minutes
    /// apart, far longer than the idle gap, and reusing an ended operation drops
    /// the second wave's progress entirely.
    private func operation(for entry: Entry) -> ClipboardTransferOperation? {
        guard kind == .clipboard else {
            guard let operation = entry.operation else {
                Self.logger.fault(
                    "Drop gen=\(entry.generation, privacy: .public) has no readout — refusing its request"
                )
                assertionFailure("Drop generation \(entry.generation) has no readout")
                return nil
            }
            return operation
        }
        if let existing = pasteOperation, existing.generation == entry.generation,
            existing.operation.isLive
        {
            return existing.operation
        }
        pasteOperation?.operation.abandon()
        let generation = entry.generation
        let operation = ClipboardTransferOperation(
            gesture: .peerPaste, direction: .outbound, peerName: peerName,
            revealDelay: progressRevealDelay, idleGap: progressIdleGap,
            onCancelRequested: cancelHandler(generation: generation),
            reporter: reporter)
        pasteOperation = (generation: generation, operation: operation)
        return operation
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

    /// Opens the readout spanning one drop, with the set's totals as the floor so
    /// the bar's denominator is every dropped file rather than each in turn (§13).
    private func makeDropOperation(
        generation: UInt64, content: ClipboardContent
    ) -> ClipboardTransferOperation {
        ClipboardTransferOperation(
            gesture: .drop, direction: .outbound, peerName: peerName,
            expectedBytes: content.representations.reduce(UInt64(0)) {
                $0 &+ UInt64(max(0, $1.byteCount))
            },
            expectedItems: content.representations.count,
            revealDelay: progressRevealDelay, idleGap: progressIdleGap,
            onCancelRequested: cancelHandler(generation: generation),
            reporter: reporter)
    }

    /// The readout label for one representation: a drop always names its file,
    /// while an inline clipboard rep has no name to show.
    private func unitName(for representation: ClipboardContent.Representation) -> String? {
        switch kind {
        case .clipboard: representation.filename.isEmpty ? nil : representation.filename
        case .drop: representation.filename
        }
    }

    private func staleMessage(for generation: UInt64) -> String {
        if entries[generation]?.isCancelled == true {
            return "The transfer for generation \(generation) was cancelled"
        }
        switch kind {
        case .clipboard: return "Request for superseded generation \(generation)"
        case .drop: return "No live drop for generation \(generation)"
        }
    }

    private func rangeMessage(_ repIndex: Int) -> String {
        switch kind {
        case .clipboard: "Representation index \(repIndex) out of range"
        case .drop: "Item index \(repIndex) out of range"
        }
    }

    private func utiMessage(_ uti: String) -> String {
        switch kind {
        case .clipboard: "Requested UTI '\(uti)' does not match offered representation"
        case .drop: "Requested UTI '\(uti)' does not match the dropped item"
        }
    }
}
