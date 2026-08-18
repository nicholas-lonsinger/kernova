import Foundation
import KernovaKit
import UniformTypeIdentifiers
import os

/// Drives the Kernova clipboard sync protocol over a single `VsockChannel` for
/// macOS guests (Linux guests use the SPICE-based service).
///
/// One instance manages one channel for the lifetime of one accepted connection
/// and self-terminates when the channel closes. Inbound is lazy: an offer
/// publishes metadata-only `.pendingRemote` placeholders immediately, the
/// Copy-to-Mac click promises reps by their offer coordinates, and bytes are
/// pulled only when the window's preview displays them or a paste consumes them.
@MainActor
@Observable
final class VsockClipboardService: ClipboardServicing, VsockDataConnectionAccepting {
    // MARK: - Observable state

    /// Bidirectional clipboard buffer.
    var clipboardContent: ClipboardContent = .empty

    /// `true` once `start()` has been called.
    private(set) var isConnected: Bool = false

    var supportsBinaryRepresentations: Bool { true }

    /// Bumped once per new inbound guest offer, never by preview/copy
    /// materialization of an already-published one — the passthrough coordinator
    /// would otherwise re-publish to the host pasteboard on every lazy pull.
    private(set) var inboundOfferSeq: UInt64 = 0

    // MARK: - Private state

    private let label: String

    /// This connection, as the clipboard protocol sees it: what each side has
    /// offered the other, and every transfer between them.
    ///
    /// `nonisolated` so a paste-time provider fire can serve from whichever
    /// thread the pasteboard server fired on.
    nonisolated private let endpoint: ClipboardEndpoint

    /// Log coordinate for this connection: generations and transfer ids restart
    /// with every accepted channel, and one instance serves exactly one.
    nonisolated private var connectionTag: ClipboardConnectionTag { endpoint.connectionTag }

    private let staging: ClipboardFileStaging

    /// Holds the files a window drop materializes from a file promise, one
    /// generation per drop.
    ///
    /// Separate from `staging`, which holds what a peer streams in: a drop's
    /// files are the *source* the buffer and the offer read from, so they retire
    /// on their own schedule (`retireUnreferencedDropDirectories`).
    private let dropStaging: ClipboardFileStaging

    /// Generation for the next drop, so each drop's files can be retired without
    /// touching another's.
    private var nextDropGeneration: UInt64 = 1

    /// Every drop's staged directory, newest last, until nothing can read from
    /// it.
    private var dropDirectories: [DropDirectory] = []

    /// This VM's transfer report, which every surface renders.
    ///
    /// It outlives this connection deliberately: a promise this service published
    /// outlives it too, so a service superseded by a reconnect still reports the
    /// failures of those promises (docs/CLIPBOARD.md §13).
    private let reporter: ClipboardTransferReporter

    /// Reveal and idle seams handed to every operation this service opens; tests
    /// zero them so a transfer surfaces while in flight.
    private let progressRevealDelay: TimeInterval
    private let progressIdleGap: TimeInterval

    /// The operation covering the current preview materialization loop, held so a
    /// teardown can retire it.
    @ObservationIgnored
    private var previewOperation: ClipboardTransferOperation?

    /// Generation whose preview materialization loop has already run, so the
    /// window can call `materializeForPreview()` freely without re-pulling.
    ///
    /// Latched before the loop's first pull, not after its last: a pull that
    /// fails raises a report, the report is an observation change, and the window
    /// answers an observation change with another trigger — so latching on
    /// success alone re-requests the rep on every notice. One loop per generation;
    /// a later paste or Copy to Mac is a fresh gesture with its own path.
    private var previewMaterializationStarted: UInt64 = 0

    /// The inbound generation whose materialization loop the user cancelled.
    ///
    /// Cancelling aborts the transfer in flight, but the loop that started it has
    /// a list of further representations to pull and would simply move to the
    /// next one — so a multi-file operation would resume a beat after Cancel.
    /// The latch is what ends the operation rather than one of its files.
    /// Cleared by the next offer; a later paste or Copy to Mac is a fresh
    /// gesture and pulls through its own path (docs/CLIPBOARD.md §9).
    private var cancelledInboundGeneration: UInt64?

    /// Digest of the content `republish` last wrote from the inbound offer.
    ///
    /// When `clipboardContent.digest` no longer matches, the user replaced the
    /// offered content with their own edit, so the promise is stale and the lazy
    /// pulls must not resurrect it (Copy-to-Mac would otherwise discard the edit).
    private var lastInboundPublishedDigest: Data?

    /// Retracts this VM's stale promised write from the host pasteboard if the
    /// pasteboard still holds it, returning whether it did.
    ///
    /// Wired by `VMInstance` to the VM's `HostClipboardPublisher` — the service
    /// never learns the publisher type. Called on inbound supersession (a newer
    /// offer, or a release): the guest rejects the superseded generation's pulls
    /// as `request.stale`, so a promise left on the pasteboard would advertise
    /// flavors that silently serve nothing. VM stop deliberately does *not*
    /// retract — a stopped session's materialized reps stay servable.
    var retractStaleHostWrite: (@MainActor () -> Bool)?

    /// Whether the host pasteboard still holds this VM's most recent write.
    ///
    /// Wired by `VMInstance`; `start()` reclaims earlier sessions' staging roots
    /// only when this reports `false` — while the pasteboard holds the write,
    /// an earlier session's staged files may still be backing its vended URLs.
    var hostPasteboardHoldsOurWrite: (@MainActor () -> Bool)?

    #if DEBUG
    /// Test seam: awaited inside `materialize` in the window between a pull
    /// resolving and the supersession re-check, so a test can drive a newer
    /// offer / `stop()` into that exact gap deterministically.
    var afterInboundPullForTesting: (@MainActor () async -> Void)? {
        get { endpoint.afterInboundPullForTesting }
        set { endpoint.afterInboundPullForTesting = newValue }
    }

    /// Waiters sharing the inbound pull for `(generation, repIndex)` — a preview
    /// loop and a paste fire on the one transfer read as 2.
    nonisolated func inboundPullWaiterCountForTesting(generation: UInt64, repIndex: Int) -> Int {
        endpoint.inboundPullWaiterCountForTesting(generation: generation, repIndex: repIndex)
    }
    #endif

    // `nonisolated` because a `Logger` needs no actor; it is Sendable.
    nonisolated private static let logger = Logger(
        subsystem: "app.kernova", category: "VsockClipboardService")

    /// One drop's staged directory, and whether the buffer or an offer has taken
    /// its files up yet.
    ///
    /// A drop nothing has read from is either still receiving its promised files
    /// or never resolved into content, and neither can be told apart from here —
    /// so only a drop seen adopted at least once is ever reclaimed mid-session.
    private struct DropDirectory {
        let generation: UInt64
        let url: URL
        var wasAdopted = false
    }

    // MARK: - Init

    /// Creates the service for one accepted channel.
    ///
    /// Tests pass `stagingTempRoot` to isolate the staging directory between
    /// parallel runs.
    init(
        channel: VsockChannel, label: String, reporter: ClipboardTransferReporter,
        freeSpaceProvider: ClipboardFileStaging.FreeSpaceProvider? = nil,
        maxPasteBytes: @escaping @MainActor () -> Int = { ClipboardPasteLimit.defaultBytes },
        lazyPullTimeout: TimeInterval = ClipboardStreamTuning.lazyPullTimeout,
        progressRevealDelay: TimeInterval = ClipboardTransferOperation.defaultRevealDelay,
        progressIdleGap: TimeInterval = ClipboardTransferOperation.defaultIdleGap,
        stagingTempRoot: URL = FileManager.default.temporaryDirectory
    ) {
        self.label = label
        self.reporter = reporter
        self.progressRevealDelay = progressRevealDelay
        self.progressIdleGap = progressIdleGap
        let staging = ClipboardFileStaging(
            label: "host-\(label)", tempRoot: stagingTempRoot,
            freeSpaceProvider: freeSpaceProvider)
        self.staging = staging
        self.dropStaging = ClipboardFileStaging(
            label: "host-drops-\(label)", tempRoot: stagingTempRoot,
            freeSpaceProvider: freeSpaceProvider)
        self.endpoint = ClipboardEndpoint(
            channel: channel,
            configuration: ClipboardEndpoint.Configuration(
                role: .host, kind: .clipboard, label: label, peerName: label,
                maxPasteBytes: maxPasteBytes, staging: staging,
                lazyPullTimeout: lazyPullTimeout, progressRevealDelay: progressRevealDelay,
                progressIdleGap: progressIdleGap),
            reporter: reporter)
        endpoint.delegate = self
    }

    // MARK: - Lifecycle

    func start() {
        guard !isConnected else { return }
        // Earlier sessions' receive and drop roots may still be serving the
        // pasteboard's current write (a stopped session's materialized reps stay
        // servable, and a dropped file's URL is copied as-is), so they are
        // reclaimed only once the pasteboard no longer holds this VM's write.
        if hostPasteboardHoldsOurWrite?() != true {
            staging.reclaimSiblingRoots()
            dropStaging.reclaimSiblingRoots()
        }
        isConnected = true
        endpoint.start()
        Self.logger.notice(
            "Vsock clipboard service started for '\(self.label, privacy: .public)' (conn=\(self.connectionTag, privacy: .public))"
        )
    }

    /// Takes over one transfer's data connection, accepted on the clipboard
    /// data port, from whatever thread the listener hands it over on.
    ///
    /// Takes ownership of `fd` on every path.
    nonisolated func acceptDataConnection(fd: Int32) {
        endpoint.acceptDataConnection(fd: fd)
    }

    func stop() {
        endpoint.stop()
        isConnected = false
        // With the offer gone, a drop the buffer no longer shows has no reader
        // left on this side.
        retireUnreferencedDropDirectories()
        // Only this service's own operations, never the VM's whole report: a
        // paste fire this teardown cut short still owes the VM its answer, and a
        // superseded service's later failure belongs to the VM either way (§13).
        previewOperation?.abandon()
        previewOperation = nil
        Self.logger.notice(
            "Vsock clipboard service stopped for '\(self.label, privacy: .public)' (conn=\(self.connectionTag, privacy: .public))"
        )
    }

    // MARK: - Transfer progress

    /// Opens one operation reporting to this VM's `reporter`.
    private func makeOperation(
        gesture: ClipboardTransferGesture,
        direction: ClipboardProgressSnapshot.Direction,
        peerName: String,
        onCancelRequested: (@Sendable () -> Void)? = nil
    ) -> ClipboardTransferOperation {
        ClipboardTransferOperation(
            gesture: gesture, direction: direction, peerName: peerName,
            revealDelay: progressRevealDelay, idleGap: progressIdleGap,
            onCancelRequested: onCancelRequested, reporter: reporter)
    }

    /// Stops the pulls the materialization loop has in flight for `generation`.
    ///
    /// The latch is what ends the loop; the pulls it holds are left rather than
    /// torn down, so a rep a paste fire is also waiting on keeps streaming.
    private func cancelInboundPulls(generation: UInt64) {
        guard endpoint.inboundOffer?.generation == generation else { return }
        cancelledInboundGeneration = generation
        endpoint.cancelJoinedPulls(generation: generation)
    }

    // MARK: - Transfer refusals

    /// Reports a refusal no operation is measuring — a pre-flight check, a peer
    /// error frame, a gesture that never opened a stream.
    private func reportRefusal(
        gesture: ClipboardTransferGesture, _ failure: ClipboardTransferFailure
    ) {
        reporter.finish(
            ClipboardTransferFinish(
                gesture: gesture, outcome: .failed(failure), peerName: label))
    }

    // MARK: - Public API

    func clearBuffer() {
        clipboardContent = .empty
        endpoint.resetOfferDedup()
        // The user emptied the buffer — any guest offer it was showing is stale.
        forgetInboundOffer()
        retireUnreferencedDropDirectories()
    }

    func reserveDropDestination() -> URL? {
        let generation = nextDropGeneration
        nextDropGeneration += 1
        guard let url = try? dropStaging.reserveScratchDirectory(generation: generation) else {
            Self.logger.error(
                "Failed to reserve a clipboard drop directory for '\(self.label, privacy: .public)' (conn=\(self.connectionTag, privacy: .public))"
            )
            return nil
        }
        dropDirectories.append(DropDirectory(generation: generation, url: url))
        // The drop this reserves is about to replace the buffer, so the drops it
        // supersedes may already be retirable.
        retireUnreferencedDropDirectories()
        return url
    }

    /// Deletes the staged files of every drop nothing can still read from.
    ///
    /// A dropped file backs a *source* representation: the buffer renders it, the
    /// guest streams from it while the offer carrying it is the pending one, and
    /// a Copy to Mac puts its own URL on the host pasteboard. Deleting behind any
    /// of those would empty a file the user can still reach, so a drop's
    /// directory goes only once all three have moved on. What survives this is
    /// still bounded by the staging generation window.
    private func retireUnreferencedDropDirectories() {
        guard !dropDirectories.isEmpty else { return }
        let sourceURLs =
            clipboardContent.representations
            + (endpoint.currentOutboundContent?.representations ?? [])
        let readableURLs = sourceURLs.compactMap { $0.fileURL ?? $0.directorySourceURL }
        func isRead(_ drop: DropDirectory) -> Bool {
            readableURLs.contains { ClipboardFileStaging.isURL($0, inside: drop.url) }
        }
        // Latched separately from the deletion below, which the pasteboard can
        // hold off for several passes: a drop must not lose the one observation
        // that proves its receipt resolved.
        for index in dropDirectories.indices where !dropDirectories[index].wasAdopted {
            dropDirectories[index].wasAdopted = isRead(dropDirectories[index])
        }
        // A Copy to Mac vends a dropped file's own path, and which write is on
        // the pasteboard is not per-drop knowledge — while this VM's write
        // stands, every drop stays.
        guard hostPasteboardHoldsOurWrite?() != true else { return }
        dropDirectories.removeAll { drop in
            guard drop.wasAdopted, !isRead(drop) else { return false }
            dropStaging.discardGeneration(drop.generation)
            Self.logger.debug(
                "Reclaimed the staged files of a superseded clipboard drop for '\(self.label, privacy: .public)' (conn=\(self.connectionTag, privacy: .public))"
            )
            return true
        }
    }

    func grabIfChanged() {
        guard isConnected else { return }
        guard !clipboardContent.isEmpty else { return }
        // Never offer content that still holds not-yet-pulled placeholders: the
        // sender can't stream a `.pendingRemote` rep, and it would echo back.
        guard !clipboardContent.representations.contains(where: { $0.isPendingRemote }) else {
            return
        }
        guard case .sent = endpoint.offer(clipboardContent) else { return }
        // The offer just replaced supersedes whatever drop it was reading from,
        // so that drop's files can go.
        retireUnreferencedDropDirectories()
    }

    // MARK: - Inbound (we are the receiver)

    /// Republishes the offer with the content digest computed off the owning
    /// actor.
    ///
    /// A pulled rep can be a memory-mapped inline payload of any size, and hashing
    /// it for the content digest is `O(payload)` — it must not stall the main
    /// actor (§8).
    private func republishOffActor(_ offer: ClipboardEndpoint.InboundOffer) async {
        let epoch = endpoint.materializationEpoch(generation: offer.generation)
        let reps = rebuiltReps(from: offer)
        let content = await ClipboardContent.makeOffActor(
            representations: reps, isConcealed: offer.isConcealed)
        // A supersession or a newer materialization landed during the off-actor
        // hash; that pull republishes the complete set, so applying this snapshot
        // would revert a just-materialized rep back to a placeholder.
        guard endpoint.inboundOffer?.generation == offer.generation,
            endpoint.materializationEpoch(generation: offer.generation) == epoch
        else { return }
        apply(content)
    }

    /// Builds the published representation list from the offer: each rep's
    /// materialized form when pulled, else a `.pendingRemote` placeholder.
    private func rebuiltReps(
        from offer: ClipboardEndpoint.InboundOffer
    ) -> [ClipboardContent.Representation] {
        offer.keptIndices.map { index in
            let info = offer.reps[index]
            return endpoint.materialized(generation: offer.generation, repIndex: index)
                ?? ClipboardContent.Representation(
                    pendingRemoteUTI: info.uti, byteCount: Int(clamping: info.byteCount),
                    filename: info.filename)
        }
    }

    /// Publishes `content` as the current inbound view and latches its digest for
    /// edit-detection and echo suppression.
    private func apply(_ content: ClipboardContent) {
        clipboardContent = content
        endpoint.latchOfferDedup(content.digest)
        lastInboundPublishedDigest = content.digest
    }

    /// Drops the current inbound offer and its per-generation state, telling the
    /// guest nothing: what replaced it is a local gesture.
    private func forgetInboundOffer() {
        endpoint.discardInboundOffer()
        previewMaterializationStarted = 0
        lastInboundPublishedDigest = nil
    }

    /// Drops any `.pendingRemote` placeholder reps — content that can't be
    /// written to the pasteboard (no bytes) — returning `content` unchanged when
    /// it has none.
    private static func withoutPlaceholders(_ content: ClipboardContent) -> ClipboardContent {
        let reps = content.representations.filter { !$0.isPendingRemote }
        return reps.count == content.representations.count
            ? content : ClipboardContent(representations: reps)
    }

    // MARK: - Lazy materialization (we are the receiver)

    /// Pulls the representations the window renders richly (text, inline RTF,
    /// images up to the preview limit) for the current offer, updating
    /// `clipboardContent` as each lands.
    ///
    /// Idempotent per generation; the window calls it when it displays a guest
    /// offer. Files and over-limit reps stay placeholders until Copy-to-Mac.
    func materializeForPreview() async {
        // Bail if there's no offer, or the user replaced the offered content with
        // their own edit (the promise is then stale).
        guard let offer = endpoint.inboundOffer,
            clipboardContent.digest == lastInboundPublishedDigest
        else { return }
        // Concealed content is never previewed — the bytes are pulled only on an
        // explicit Copy-to-Mac.
        guard !offer.isConcealed else { return }
        let generation = offer.generation
        guard previewMaterializationStarted != generation else { return }
        previewMaterializationStarted = generation
        // Transfers join as they begin rather than being declared up front:
        // another loop can claim a rep before this one reaches it, and a rep left
        // in the denominator waiting on events that never arrive would hold the
        // bar short of its total.
        let pulling = offer.keptIndices.filter { Self.isEagerPreviewable(offer.reps[$0]) }
        guard !pulling.isEmpty else { return }
        let operation = makeOperation(
            gesture: .preview, direction: .inbound, peerName: label,
            onCancelRequested: { [weak self] in
                // The tracker calls this outside its own lock, on whichever
                // thread noticed the click, so it hops before touching anything.
                MainActorBridge.async { self?.cancelInboundPulls(generation: generation) }
            })
        previewOperation = operation
        // A pull that failed has already finished the operation with its own
        // reason; this terminal is what ends a loop that ran to its end or was
        // stopped, and it is dropped for one already finished.
        defer {
            operation.finish(
                cancelledInboundGeneration == generation ? .cancelled : .completed)
        }
        for index in pulling {
            guard endpoint.inboundOffer?.generation == generation else { return }  // superseded
            // The user stopped the whole operation, not the one file that
            // happened to be in flight when they clicked.
            guard cancelledInboundGeneration != generation else { return }
            _ = await materialize(index: index, offer: offer, operation: operation)
        }
    }

    /// Prepares the "Copy to Mac" items — metadata only, synchronously; nothing
    /// crosses the wire at the click.
    ///
    /// Every usable rep of the live offer becomes a `.promised` item addressed by
    /// its offer coordinates; its bytes are pulled when a paste consumes them
    /// (`serveFileURL` / `serveData`). When the offer's paste-bound total
    /// exceeds the deadline-safe cap the refusal is per *flavor*: every
    /// `.fileURL`-serving rep reports a `.droppedFile(.overPasteBudget)` — no
    /// paste could ever serve it — while an image file's inline flavor, which the
    /// cap does not govern (docs/CLIPBOARD.md §1), still promises.
    func materializeForCopy() -> [CopyToMacItem] {
        // No active offer, or the user replaced the offered content with their
        // own edit: copy what's actually shown, never a stale placeholder.
        guard let offer = endpoint.inboundOffer,
            clipboardContent.digest == lastInboundPublishedDigest
        else {
            forgetInboundOffer()
            return Self.withoutPlaceholders(clipboardContent).representations.map { .resolved($0) }
        }

        let budget = endpoint.pasteBudget(generation: offer.generation)
        let overBudget = budget?.exceeds == true
        if let budget, overBudget {
            Self.logger.warning(
                "Copy-to-Mac refused: \(ClipboardErrorCode.copyTooLarge.rawValue, privacy: .public) — paste-bound reps total \(budget.total, privacy: .public) bytes, over the \(budget.limit, privacy: .public)-byte cap; refusing the whole file set"
            )
            // The click reports its own outcome, but an automatic passthrough
            // publish has no return path — the report is the only surface it has.
            reportRefusal(gesture: .copy, .tooLarge(limitBytes: budget.limit))
        }

        var items: [CopyToMacItem] = []
        for index in offer.keptIndices {
            let info = offer.reps[index]
            let withholdsFileURL = overBudget && ClipboardPromisePolicy.servesFileURL(info)
            if withholdsFileURL {
                // Withholding `.fileURL` is refusing the file, whether or not an
                // inline flavor of the same rep still serves — so the drop is
                // reported either way and the click names the cap.
                items.append(.droppedFile(.overPasteBudget))
                // A non-inline rep promises nothing else: the whole item goes.
                if !info.isInline { continue }
            }
            items.append(
                .promised(
                    CopyToMacPromise(
                        generation: offer.generation, repIndex: index, uti: info.uti,
                        filename: info.filename, isInline: info.isInline,
                        withholdsFileURL: withholdsFileURL)))
        }
        return items
    }

    /// Pulls representation `index`, republishing once its bytes are cached.
    ///
    /// A rep a paste fire already has in flight is not re-requested: the pull
    /// joins that transfer and both callers take its bytes.
    private func materialize(
        index: Int, offer: ClipboardEndpoint.InboundOffer,
        operation: ClipboardTransferOperation
    ) async -> ClipboardContent.Representation? {
        // The cache read moves no byte on this operation's behalf, so it begins no
        // transfer: one declared but never fed would sit in the denominator
        // waiting on events that never arrive.
        if let cached = endpoint.materialized(generation: offer.generation, repIndex: index) {
            return cached
        }
        let rep = await endpoint.join(
            generation: offer.generation, repIndex: index, operation: operation)
        guard rep != nil, endpoint.inboundOffer?.generation == offer.generation else { return rep }
        await republishOffActor(offer)
        return rep
    }

    /// Whether the window renders this rep richly, so it's worth pulling for the
    /// preview: text within the editor limit, inline rich text (RTF/RTFD), or an
    /// image up to the preview limit.
    ///
    /// Files (non-image) and over-limit payloads stay placeholders.
    private static func isEagerPreviewable(_ info: Kernova_V1_ClipboardRepresentationInfo) -> Bool {
        let type = UTType(info.uti)
        if type?.conforms(to: .image) == true {
            return info.byteCount <= UInt64(ClipboardPreviewPolicy.maxEagerPreviewBytes)
        }
        // A non-image file renders as a chip from metadata — no pull needed.
        guard info.filename.isEmpty else { return false }
        // Flat-RTFD carries the inline image and does not conform to `.rtf`, so the
        // whole RTF family is matched explicitly.
        if type?.conformsToRTFFamily == true {
            return info.byteCount <= UInt64(ClipboardPreviewPolicy.maxEagerPreviewBytes)
        }
        if info.uti == ClipboardContent.utf8TextUTI || type?.conforms(to: .text) == true {
            return info.byteCount <= UInt64(ClipboardPreviewPolicy.maxEditableTextBytes)
        }
        return false
    }
}

// MARK: - Endpoint delegate

extension VsockClipboardService: ClipboardEndpointDelegate {
    /// Publishes a newly-received guest offer as metadata-only placeholders, so
    /// the window shows the chips without waiting.
    func endpoint(
        _ endpoint: ClipboardEndpoint, didReceiveOffer offer: ClipboardEndpoint.InboundOffer
    ) {
        // A new offer is a new operation; whatever the user cancelled is over.
        cancelledInboundGeneration = nil
        previewMaterializationStarted = 0
        // Byte-less placeholder reps hash trivially; once a pull has materialized
        // real bytes, `republishOffActor` hashes off the main actor instead (§8).
        apply(
            ClipboardContent(
                representations: rebuiltReps(from: offer), isConcealed: offer.isConcealed))
        // Bumped after the offer is live, so the passthrough coordinator's
        // `materializeForCopy` sees it.
        inboundOfferSeq &+= 1
    }

    /// Answers a guest offer this side can no longer serve: the host pasteboard
    /// may still hold this VM's own promised write for it, which the guest now
    /// rejects as `request.stale`, so a paste through it would silently serve
    /// nothing.
    ///
    /// The placeholder content stays in the window either way; only the
    /// pasteboard write is withdrawn.
    func endpoint(
        _ endpoint: ClipboardEndpoint, didRetractOffer generation: UInt64?,
        reason: ClipboardEndpoint.RetractReason
    ) {
        previewMaterializationStarted = 0
        lastInboundPublishedDigest = nil
        guard retractStaleHostWrite?() == true else { return }
        // With the write retracted, no earlier session's staging can be backing a
        // live pasteboard item any more.
        staging.reclaimSiblingRoots()
        // A retraction's report is the successor offer's own explainer, so it
        // stands where the successor would otherwise have cleared the last one.
        let hasSuccessor: Bool
        switch reason {
        case .superseded(let successor): hasSuccessor = successor
        case .released: hasSuccessor = false
        }
        reportRefusal(gesture: .copy, .supersededCopyRetracted(hasSuccessor: hasSuccessor))
        Self.logger.notice(
            "Retracted the stale host-pasteboard promise for '\(self.label, privacy: .public)' (conn=\(self.connectionTag, privacy: .public)) — the guest offer it advertised is no longer servable"
        )
    }

    func endpoint(
        _ endpoint: ClipboardEndpoint, didRefuse gesture: ClipboardTransferGesture,
        failure: ClipboardTransferFailure
    ) {
        reportRefusal(gesture: gesture, failure)
    }
}

// MARK: - Paste-time representation serving

extension VsockClipboardService: ClipboardPromiseServing {
    nonisolated func serveFileURL(generation: UInt64, repIndex: Int) -> URL? {
        endpoint.serveFileURL(generation: generation, repIndex: repIndex)
    }

    nonisolated func serveData(generation: UInt64, repIndex: Int, uti: String) -> Data? {
        endpoint.serveData(generation: generation, repIndex: repIndex, uti: uti)
    }
}
