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
final class VsockClipboardService: ClipboardServicing {
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

    /// This connection's engine, frame routing and control-frame delivery.
    ///
    /// `nonisolated` so a paste-time provider fire can reach the channel and the
    /// receiver from whichever thread the pasteboard server fired on.
    nonisolated private let session: ClipboardStreamSession

    /// What this side has offered the guest, and the transfers answering its
    /// pulls.
    private let outbound: ClipboardOutboundOffers

    /// Log coordinate for this connection: generations and transfer ids restart
    /// with every accepted channel, and one instance serves exactly one.
    nonisolated private var connectionTag: ClipboardConnectionTag { session.connectionTag }

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
    ///
    /// `nonisolated` so a paste-time provider fire can hand it to the operation
    /// it opens from whichever thread the pasteboard server fired on; every call
    /// on it still crosses to the main actor.
    nonisolated private let reporter: ClipboardTransferReporter

    /// Backstop for a lazy pull the peer never answers while the channel stays
    /// open.
    private let lazyPullTimeout: TimeInterval

    /// Reveal and idle seams handed to every operation this service opens; tests
    /// zero them so a transfer surfaces while in flight.
    nonisolated private let progressRevealDelay: TimeInterval
    nonisolated private let progressIdleGap: TimeInterval

    /// The ceiling on a paste's file-representation total, read at each budget
    /// check rather than captured, so a Settings change reaches a live session.
    private let maxPasteBytes: @MainActor () -> Int

    /// The operation covering the current preview materialization loop, held so a
    /// teardown can retire it.
    @ObservationIgnored
    private var previewOperation: ClipboardTransferOperation?

    /// The one place an inbound pull lives, for both the preview loop and the
    /// synchronous pulls served inside a pasteboard `provideData` callback (on
    /// whichever thread the pasteboard server fires it — usually main, where the
    /// wait runs the event loop rather than parking).
    ///
    /// A paste-time fire and a preview fetch for the same rep share one slot, one
    /// awaiter and one request: whichever arrives first starts the pull and the
    /// other joins it, in either order. What keeps a joined paste's wait short is
    /// the preview side's own bounds — only `isEagerPreviewable` reps are pulled
    /// at all, capped by `ClipboardPreviewPolicy.maxEagerPreviewBytes` — plus the
    /// inactivity backstop below.
    private let lazyCoordinator = LazyPullCoordinator()

    /// The guest offer currently promised in `clipboardContent`, with its
    /// per-representation materialization cache.
    private var inboundPromise: InboundPromise?

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

    /// Digest of the content `republish` last wrote from the inbound promise.
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
    var afterInboundPullForTesting: (@MainActor () async -> Void)?

    /// Waiters sharing the inbound pull for `(generation, repIndex)` — a preview
    /// loop and a paste fire on the one transfer read as 2.
    nonisolated func inboundPullWaiterCountForTesting(generation: UInt64, repIndex: Int) -> Int {
        lazyCoordinator.waiterCountForTesting(
            Self.inboundTransferID(generation: generation, repIndex: repIndex))
    }
    #endif

    // `nonisolated` so the off-main `consume` loop can log; `Logger` is Sendable.
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

    /// One promised guest offer.
    ///
    /// Reps are indexed exactly as the guest offered them, so a `transfer_id`'s
    /// rep index stays valid; each is pulled at most once.
    private final class InboundPromise {
        let generation: UInt64
        let reps: [Kernova_V1_ClipboardRepresentationInfo]
        /// `true` when the offer carried `org.nspasteboard.ConcealedType`: the
        /// content is never eagerly pulled for preview.
        let isConcealed: Bool
        var materialized: [Int: ClipboardContent.Representation] = [:]
        /// The preview loop's waiter on each rep it currently has in flight, so a
        /// Cancel on the readout can leave those pulls — and only those — rather
        /// than tearing down a transfer a paste is also waiting on.
        var previewWaiters: [Int: LazyPullCoordinator.Waiter] = [:]
        /// Monotonic count of materializations cached into `materialized`, bumped
        /// on each pulled rep so `republishOffActor` can detect one that landed
        /// during its off-actor hash.
        var materializeEpoch = 0

        init(
            generation: UInt64, reps: [Kernova_V1_ClipboardRepresentationInfo], isConcealed: Bool
        ) {
            self.generation = generation
            self.reps = reps
            self.isConcealed = isConcealed
        }
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
        self.maxPasteBytes = maxPasteBytes
        self.lazyPullTimeout = lazyPullTimeout
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
        let session = ClipboardStreamSession(
            channel: channel, role: .host, kind: .clipboard, label: label, staging: staging)
        self.session = session
        self.outbound = ClipboardOutboundOffers(
            session: session, reporter: reporter, peerName: label,
            progressRevealDelay: progressRevealDelay, progressIdleGap: progressIdleGap)
    }

    // MARK: - Lifecycle

    func start() {
        guard !isConnected else { return }
        // A fresh connection retires whatever the last one left standing: that
        // report described a transfer of a session that is over.
        reporter.clearFinished()
        // Earlier sessions' receive and drop roots may still be serving the
        // pasteboard's current write (a stopped session's materialized reps stay
        // servable, and a dropped file's URL is copied as-is), so they are
        // reclaimed only once the pasteboard no longer holds this VM's write.
        if hostPasteboardHoldsOurWrite?() != true {
            staging.reclaimSiblingRoots()
            dropStaging.reclaimSiblingRoots()
        }
        isConnected = true

        session.start(
            handleControlFrame: { [weak self] frame in self?.handleControlFrame(frame) },
            // Wake any parked pull off the main actor the moment the channel is
            // gone, so a materialize doesn't hang forever behind the very hop it
            // is blocking.
            onEnded: { [coordinator = self.lazyCoordinator] in coordinator.failAll() })
        Self.logger.notice(
            "Vsock clipboard service started for '\(self.label, privacy: .public)' (conn=\(self.connectionTag, privacy: .public))"
        )
    }

    func stop() {
        session.stop()
        // Unblock any synchronous file pull parked on the coordinator, so it
        // returns empty instead of blocking to its backstop timeout.
        lazyCoordinator.failAll()
        isConnected = false
        outbound.endSession()
        // With the offer gone, a drop the buffer no longer shows has no reader
        // left on this side.
        retireUnreferencedDropDirectories()
        // Only this service's own operations, never the VM's whole report: a
        // paste fire this teardown cut short still owes the VM its answer, and a
        // superseded service's later failure belongs to the VM either way (§13).
        previewOperation?.abandon()
        previewOperation = nil
        // Nothing is swept here: the inbound promise and its receive staging
        // deliberately survive stop(), because the host pasteboard may still
        // advertise this offer and every materialized rep stays servable from the
        // cache and the staged files (docs/CLIPBOARD.md §3). Only supersession
        // retracts the write; the files then age out of the generation window.
        Self.logger.notice(
            "Vsock clipboard service stopped for '\(self.label, privacy: .public)' (conn=\(self.connectionTag, privacy: .public))"
        )
    }

    // MARK: - Transfer progress

    /// Opens one operation reporting to this VM's `reporter`.
    ///
    /// `nonisolated` because a paste-time provider fire opens one from whichever
    /// thread the pasteboard server fired on.
    nonisolated private func makeOperation(
        gesture: ClipboardTransferGesture,
        direction: ClipboardProgressSnapshot.Direction,
        peerName: String,
        expectedBytes: UInt64 = 0,
        expectedItems: Int = 0,
        onCancelRequested: (@Sendable () -> Void)? = nil
    ) -> ClipboardTransferOperation {
        ClipboardTransferOperation(
            gesture: gesture, direction: direction, peerName: peerName,
            expectedBytes: expectedBytes, expectedItems: expectedItems,
            revealDelay: progressRevealDelay, idleGap: progressIdleGap,
            onCancelRequested: onCancelRequested, reporter: reporter)
    }

    /// Stops the pulls the materialization loop has in flight for `generation`.
    ///
    /// The loop leaves its pulls rather than ending them, and only one it was the
    /// last waiter on is torn down: a rep a paste fire is also waiting on keeps
    /// streaming, since this Cancel is on the preview readout and the paste is a
    /// gesture of its own. An abandoned pull is ended on both sides — an abort
    /// frame tells the guest's sender to stop producing bytes, and the local
    /// cancel deletes the partial temp file — while the waiter itself wakes with
    /// the benign `cancelled` code, so the loop ends without raising an issue.
    private func cancelInboundPulls(generation: UInt64) {
        guard let promise = livePromise(generation: generation) else { return }
        cancelledInboundGeneration = generation
        // Leaving is the step; its answer is whether this side is done with the
        // transfer, and only then is it torn down.
        for (repIndex, waiter) in promise.previewWaiters where !lazyCoordinator.leave(waiter) {
            let transferID = Self.inboundTransferID(generation: generation, repIndex: repIndex)
            session.sendStreamAbort(
                transferID: transferID, code: .userCancelled, message: "Cancelled by the user")
            session.receiver?.cancel(transferID: transferID)
        }
        Self.logger.notice(
            "User cancelled the inbound clipboard transfer from '\(self.label, privacy: .public)' (gen=\(generation, privacy: .public), conn=\(self.connectionTag, privacy: .public))"
        )
    }

    /// Runs `body` on the main actor on the next turn of the main queue.
    ///
    /// The hop is what makes a cancel closure safe to invoke from anywhere: the
    /// tracker calls it outside its own lock, but on whichever thread noticed the
    /// click.
    nonisolated private static func onMainQueue(_ body: @escaping @MainActor () -> Void) {
        DispatchQueue.main.async { MainActor.assumeIsolated { body() } }
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

    /// Explains a paste fire this connection's end cut short: the fire serves
    /// nothing, and unlike a supersession nothing else says why.
    ///
    /// Called by the fire itself, off the outcome it saw — a fire the end never
    /// touched (its bytes had already landed) has nothing to explain. The N fires
    /// of one multi-file paste each report the same refusal; the reporter absorbs
    /// the repeats into one message.
    nonisolated private func recordPasteInterruption(_ operation: ClipboardTransferOperation) {
        guard session.hasEnded else { return }
        operation.finish(.failed(.interrupted(fileCount: nil)))
    }

    // MARK: - Public API

    func clearBuffer() {
        clipboardContent = .empty
        outbound.resetDedup()
        // The user emptied the buffer — any guest offer it was showing is stale.
        dropInboundPromise()
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
            + (outbound.currentContent?.representations ?? [])
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
        guard outbound.offer(clipboardContent) != nil else { return }
        reporter.clearFinished()
        // The offer just replaced supersedes whatever drop it was reading from,
        // so that drop's files can go.
        retireUnreferencedDropDirectories()
    }

    // MARK: - Frame consumer

    /// Handles the control frames the consume loop dispatches to the main actor.
    private func handleControlFrame(_ frame: Frame) {
        switch frame.payload {
        case .clipboardOffer(let offer):
            handleOffer(offer)
        case .clipboardRequest(let request):
            outbound.handleRequest(request)
        case .clipboardRelease(let release):
            handleRelease(release)
        case .error(let error):
            Self.logger.warning(
                "Guest clipboard error for '\(self.label, privacy: .public)': \(error.code, privacy: .public) — \(error.message, privacy: .public)"
            )
            if error.code.hasPrefix("clipboard.") {
                let code = ClipboardErrorCode(rawValue: error.code)
                reportRefusal(
                    gesture: .peerPaste,
                    code == .pasteTooLarge
                        ? .tooLarge(limitBytes: maxPasteBytes()) : .peerReported(code))
            }
        case .clipboardStreamAbort(let abort):
            // Only a sender-bound abort reaches here; see `ClipboardStreamRouting`.
            session.sender?.handleAbort(transferID: abort.transferID)
        case .clipboardStreamBegin, .clipboardChunk, .clipboardStreamEnd, .clipboardStreamAck:
            // Routed off-main by the consume loop; never reaches here.
            break
        case .hello, .heartbeat, .policyUpdate, .logRecord, .dropOffer, .dropComplete,
            .dropRelease:
            // Control-plane and log payloads belong on their own channels; a peer
            // sending them here crossed wires. A conformant agent reconnects.
            Self.logger.warning(
                "Unexpected payload on clipboard channel for '\(self.label, privacy: .public)' — wrong port; closing the channel"
            )
            session.channel.close()
        case .none:
            Self.logger.debug("Frame with no payload for '\(self.label, privacy: .public)'")
        }
    }

    // MARK: - Inbound (we are the receiver)

    private func handleOffer(_ offer: Kernova_V1_ClipboardOffer) {
        // A newer offer supersedes the previous one: cancel any in-flight pull so
        // its partial temp file is deleted and a blocked continuation resumes.
        // The superseded generation's staged files are NOT swept — they ride the
        // `maxGenerations` grace window (docs/CLIPBOARD.md §3), so a paste still
        // being copied out by Finder, or a re-paste of an already-vended URL,
        // survives the guest's next copy.
        if let previous = inboundPromise {
            session.receiver?.cancel(generation: previous.generation)
        }
        // The host pasteboard may still hold this VM's own promised write for
        // the superseded offer, which the guest can no longer serve
        // (`request.stale`) — retract it rather than leave a paste that
        // silently serves nothing. The notice is raised at each exit below rather
        // than here: whether it may point at Copy to Mac depends on whether this
        // offer leaves anything to copy.
        let retracted = retractStaleHostWrite?() ?? false
        if retracted {
            // With the write retracted, no earlier session's staging can be
            // backing a live pasteboard item any more.
            staging.reclaimSiblingRoots()
            Self.logger.notice(
                "Retracted the stale host-pasteboard promise for '\(self.label, privacy: .public)' (conn=\(self.connectionTag, privacy: .public)) superseded by guest offer gen=\(offer.generation, privacy: .public)"
            )
        }

        guard !offer.repInfo.isEmpty else {
            if retracted {
                reportRefusal(gesture: .copy, .supersededCopyRetracted(hasSuccessor: false))
            }
            dropInboundPromise()
            return
        }
        // Every field of the offer is guest-supplied. Bound the rep count and
        // each declared size once, here at intake, so no budget, capacity, or
        // progress arithmetic downstream reasons about a value that can't be
        // real.
        let bounded = ClipboardOfferBounds.bounded(offer.repInfo)
        if let truncatedFrom = bounded.truncatedFrom {
            Self.logger.warning(
                "Guest clipboard offer for '\(self.label, privacy: .public)' (conn=\(self.connectionTag, privacy: .public)) declared \(truncatedFrom, privacy: .public) representations — truncated to \(bounded.reps.count, privacy: .public)"
            )
        }
        if bounded.clampedCount > 0 {
            Self.logger.warning(
                "Clamped \(bounded.clampedCount, privacy: .public) implausible declared byte count(s) in the guest clipboard offer for '\(self.label, privacy: .public)' (conn=\(self.connectionTag, privacy: .public))"
            )
        }
        // A new offer is a new operation; whatever the user cancelled is over.
        cancelledInboundGeneration = nil
        let promise = InboundPromise(
            generation: offer.generation, reps: bounded.reps, isConcealed: offer.isConcealed)
        let placeholders = rebuiltReps(from: promise)
        // Every offered rep was filtered — nothing usable to promise. Decided
        // before publishing, so the window keeps whatever it is showing instead
        // of being wiped by an empty apply.
        guard !placeholders.isEmpty else {
            Self.logger.warning(
                "Dropped the guest clipboard offer for '\(self.label, privacy: .public)' (gen=\(offer.generation, privacy: .public), conn=\(self.connectionTag, privacy: .public)): none of its \(bounded.reps.count, privacy: .public) representation(s) survived receive-side filtering"
            )
            if retracted {
                reportRefusal(gesture: .copy, .supersededCopyRetracted(hasSuccessor: false))
            }
            dropInboundPromise()
            return
        }
        // Publish metadata-only placeholders immediately so the window shows the
        // chips without waiting. Their byte-less reps hash trivially; once a pull
        // has materialized real bytes, `republishOffActor` hashes off the main
        // actor instead (§8).
        apply(
            ClipboardContent(representations: placeholders, isConcealed: promise.isConcealed))
        inboundPromise = promise
        previewMaterializationStarted = 0
        // A retraction's report is the new offer's own explainer, so it replaces
        // whatever stood here rather than being cleared with it.
        if retracted {
            reportRefusal(gesture: .copy, .supersededCopyRetracted(hasSuccessor: true))
        } else {
            reporter.clearFinished()
        }
        // Bumped after the promise is live, so the passthrough coordinator's
        // `materializeForCopy` sees it.
        inboundOfferSeq &+= 1
        Self.logger.notice(
            "Received guest clipboard offer for '\(self.label, privacy: .public)' (gen=\(offer.generation, privacy: .public), conn=\(self.connectionTag, privacy: .public), \(promise.reps.count, privacy: .public) reps) — metadata only"
        )
    }

    /// Republishes the promise with the content digest computed off the owning
    /// actor.
    ///
    /// A pulled rep can be a memory-mapped inline payload of any size, and hashing
    /// it for the content digest is `O(payload)` — it must not stall the main
    /// actor (§8).
    private func republishOffActor(_ promise: InboundPromise) async {
        let epoch = promise.materializeEpoch
        let reps = rebuiltReps(from: promise)
        let content = await ClipboardContent.makeOffActor(
            representations: reps, isConcealed: promise.isConcealed)
        // A supersession or a newer materialization landed during the off-actor
        // hash; that pull republishes the complete set, so applying this snapshot
        // would revert a just-materialized rep back to a placeholder.
        guard inboundPromise === promise, promise.materializeEpoch == epoch else { return }
        apply(content)
    }

    /// Builds the published representation list from the promise: each rep's
    /// materialized form when pulled, else a `.pendingRemote` placeholder.
    ///
    /// Drops identity-skip types so a peer can't smuggle them onto the host
    /// pasteboard. Indices into `promise.reps` stay valid for pulls; only the
    /// published view filters.
    private func rebuiltReps(from promise: InboundPromise) -> [ClipboardContent.Representation] {
        var reps: [ClipboardContent.Representation] = []
        for (index, info) in promise.reps.enumerated() where ClipboardPromisePolicy.keeps(info) {
            reps.append(
                promise.materialized[index]
                    ?? ClipboardContent.Representation(
                        pendingRemoteUTI: info.uti, byteCount: Int(clamping: info.byteCount),
                        filename: info.filename))
        }
        return reps
    }

    /// Publishes `content` as the current inbound view and latches its digest for
    /// edit-detection and echo suppression.
    private func apply(_ content: ClipboardContent) {
        clipboardContent = content
        outbound.latchDedup(content.digest)
        lastInboundPublishedDigest = content.digest
    }

    /// Drops the current inbound promise and its per-generation lazy-pull state.
    private func dropInboundPromise() {
        inboundPromise = nil
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

    /// Opens the operation covering one materialization loop, or `nil` when the
    /// loop has nothing to pull.
    ///
    /// Transfers join as they begin rather than being declared up front: another
    /// loop can claim a rep before this one reaches it, and a rep left in the
    /// denominator waiting on events that never arrive would hold the bar short
    /// of its total.
    private func openPreviewOperation(promise: InboundPromise, pulling indices: [Int])
        -> ClipboardTransferOperation?
    {
        guard !indices.isEmpty else { return nil }
        let generation = promise.generation
        let operation = makeOperation(
            gesture: .preview, direction: .inbound, peerName: label,
            onCancelRequested: { [weak self] in
                Self.onMainQueue { self?.cancelInboundPulls(generation: generation) }
            })
        previewOperation = operation
        return operation
    }

    /// Pulls the representations the window renders richly (text, inline RTF,
    /// images up to the preview limit) for the current offer, updating
    /// `clipboardContent` as each lands.
    ///
    /// Idempotent per generation; the window calls it when it displays a guest
    /// offer. Files and over-limit reps stay placeholders until Copy-to-Mac.
    func materializeForPreview() async {
        // Bail if there's no promise, or the user replaced the offered content
        // with their own edit (the promise is then stale).
        guard let promise = inboundPromise, clipboardContent.digest == lastInboundPublishedDigest
        else { return }
        // Concealed content is never previewed — the bytes are pulled only on an
        // explicit Copy-to-Mac.
        guard !promise.isConcealed else { return }
        guard previewMaterializationStarted != promise.generation else { return }
        guard
            let operation = openPreviewOperation(
                promise: promise,
                pulling: promise.reps.indices.filter { index in
                    Self.isEagerPreviewable(promise.reps[index])
                        && ClipboardPromisePolicy.keeps(promise.reps[index])
                })
        else {
            previewMaterializationStarted = promise.generation
            return
        }
        previewMaterializationStarted = promise.generation
        // A pull that failed has already finished the operation with its own
        // reason; this terminal is what ends a loop that ran to its end or was
        // stopped, and it is dropped for one already finished.
        defer {
            operation.finish(
                cancelledInboundGeneration == promise.generation ? .cancelled : .completed)
        }
        for (index, info) in promise.reps.enumerated() {
            guard inboundPromise === promise else { return }  // superseded
            // The user stopped the whole operation, not the one file that
            // happened to be in flight when they clicked.
            guard cancelledInboundGeneration != promise.generation else { return }
            guard Self.isEagerPreviewable(info), ClipboardPromisePolicy.keeps(info) else { continue }
            _ = await materialize(index: index, info: info, promise: promise, operation: operation)
        }
    }

    /// Prepares the "Copy to Mac" items — metadata only, synchronously; nothing
    /// crosses the wire at the click.
    ///
    /// Every usable rep of the live offer becomes a `.promised` item addressed by
    /// its offer coordinates; its bytes are pulled when a paste consumes them
    /// (`copyToMacFileURL` / `copyToMacData`). When the offer's paste-bound total
    /// exceeds the deadline-safe cap the refusal is per *flavor*: every
    /// `.fileURL`-serving rep reports a `.droppedFile(.overPasteBudget)` — no
    /// paste could ever serve it — while an image file's inline flavor, which the
    /// cap does not govern (docs/CLIPBOARD.md §1), still promises.
    func materializeForCopy() -> [CopyToMacItem] {
        // No active promise, or the user replaced the offered content with their
        // own edit: copy what's actually shown, never a stale placeholder.
        guard let promise = inboundPromise, clipboardContent.digest == lastInboundPublishedDigest
        else {
            dropInboundPromise()
            return Self.withoutPlaceholders(clipboardContent).representations.map { .resolved($0) }
        }

        let pasteBoundTotal = ClipboardPromisePolicy.pasteBoundTotal(promise.reps)
        let limit = maxPasteBytes()
        let overBudget = ClipboardPromisePolicy.exceedsPasteBudget(promise.reps, limit: limit)
        if overBudget {
            Self.logger.warning(
                "Copy-to-Mac refused: \(ClipboardErrorCode.copyTooLarge.rawValue, privacy: .public) — paste-bound reps total \(pasteBoundTotal, privacy: .public) bytes, over the \(limit, privacy: .public)-byte cap; refusing the whole file set"
            )
            // The click reports its own outcome, but an automatic passthrough
            // publish has no return path — the report is the only surface it has.
            reportRefusal(gesture: .copy, .tooLarge(limitBytes: limit))
        }

        var items: [CopyToMacItem] = []
        for (index, info) in promise.reps.enumerated() where ClipboardPromisePolicy.keeps(info) {
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
                        generation: promise.generation, repIndex: index, uti: info.uti,
                        filename: info.filename, isInline: info.isInline,
                        withholdsFileURL: withholdsFileURL)))
        }
        return items
    }

    // MARK: - Paste-time serving (we are the receiver)

    /// The already-materialized representation for `(generation, repIndex)` of the
    /// live offer, or `nil` — the paste-time cache read that lets a provider fire
    /// reuse preview-pulled bytes (or an earlier flavor's pull) without touching
    /// the wire.
    @MainActor
    private func cachedMaterialized(
        generation: UInt64, repIndex: Int
    ) -> ClipboardContent.Representation? {
        livePromise(generation: generation)?.materialized[repIndex]
    }

    /// Whether a `.fileURL` fire for the live offer must be refused because the
    /// service has stopped with the offer's file set only partially
    /// materialized — all-or-nothing, so a multi-file paste after VM stop never
    /// silently lands a subset of the copied files.
    ///
    /// The file set is the offer's `.fileURL`-serving reps (every promisable rep
    /// with a filename, the ones a Finder paste creates files from). With the
    /// receiver gone the unmaterialized siblings can never arrive, so every
    /// file fire of the generation serves nothing and reports the refusal; a
    /// fully-materialized set keeps serving from the cache and staged files, and
    /// inline flavors keep serving regardless.
    @MainActor
    private func refusesPasteBoundFire(generation: UInt64) -> Bool {
        guard session.receiver == nil, let promise = livePromise(generation: generation) else {
            return false
        }
        let fileSet = promise.reps.indices.filter {
            ClipboardPromisePolicy.servesFileURL(promise.reps[$0])
        }
        guard fileSet.contains(where: { promise.materialized[$0] == nil }) else { return false }
        Self.logger.warning(
            "Clipboard paste fired for gen=\(generation, privacy: .public) of '\(self.label, privacy: .public)' (conn=\(self.connectionTag, privacy: .public)) after the service stopped with the file set partially materialized — \(ClipboardErrorCode.pasteIncompleteSet.rawValue, privacy: .public); serving nothing"
        )
        // The N fires of one multi-file paste each report the same refusal; the
        // reporter absorbs the repeats into one message.
        reportRefusal(gesture: .paste, .incompleteFileSet)
        return true
    }

    /// Snapshots the pull state for a paste-bound `.fileURL` fire, enforcing the
    /// deadline-safe cap over the offer's paste-bound total — all-or-nothing, so a
    /// set over the cap is refused whole rather than landing 2 of 3 files.
    @MainActor
    private func pasteBoundSnapshot(generation: UInt64, repIndex: Int) -> LazyPullSnapshot? {
        guard let snapshot = lazyPullSnapshot(generation: generation, repIndex: repIndex) else {
            return nil
        }
        let limit = maxPasteBytes()
        guard snapshot.pasteBoundTotal <= UInt64(limit) else {
            Self.logger.warning(
                "Paste refused: \(ClipboardErrorCode.copyTooLarge.rawValue, privacy: .public) — paste-bound reps total \(snapshot.pasteBoundTotal, privacy: .public) bytes, over the \(limit, privacy: .public)-byte cap"
            )
            reportRefusal(gesture: .copy, .tooLarge(limitBytes: limit))
            return nil
        }
        return snapshot
    }

    /// Pulls representation `index`, caching and republishing on success.
    ///
    /// A rep a paste fire already has in flight is not re-requested: the pull
    /// joins that transfer and both callers take its bytes.
    private func materialize(
        index: Int, info: Kernova_V1_ClipboardRepresentationInfo, promise: InboundPromise,
        operation: ClipboardTransferOperation
    ) async -> ClipboardContent.Representation? {
        // The cache read moves no byte on this operation's behalf, so it begins no
        // transfer: one declared but never fed would sit in the denominator
        // waiting on events that never arrive.
        if let cached = promise.materialized[index] {
            return cached
        }
        let rep = await pull(
            repIndex: index, info: info, promise: promise, operation: operation)
        #if DEBUG
        await afterInboundPullForTesting?()
        #endif
        guard inboundPromise === promise else { return rep }
        if let rep {
            promise.materialized[index] = rep
            promise.materializeEpoch += 1
            await republishOffActor(promise)
        }
        return rep
    }

    /// Starts or joins the pull for one representation, bridging the coordinator's
    /// off-thread resolution to an async result.
    ///
    /// Runs the free-space pre-flight first so an over-budget file rep never
    /// starts a transfer [Safeguard 4]. The waiter is held on the promise for the
    /// duration, so a Cancel on the readout can leave this pull without touching
    /// a paste fire sharing it.
    private func pull(
        repIndex: Int, info: Kernova_V1_ClipboardRepresentationInfo, promise: InboundPromise,
        operation: ClipboardTransferOperation
    ) async -> ClipboardContent.Representation? {
        guard let receiver = session.receiver else { return nil }
        if !info.isInline, !staging.hasCapacity(forByteCount: Int(clamping: info.byteCount)) {
            Self.logger.warning(
                "Not enough disk space to receive clipboard rep '\(info.uti, privacy: .public)' (\(info.byteCount, privacy: .public) bytes)"
            )
            operation.finish(
                .failed(
                    .diskFull(needed: info.byteCount, available: staging.availableCapacity())))
            return nil
        }
        let generation = promise.generation
        let transferID = Self.inboundTransferID(generation: generation, repIndex: repIndex)
        let request = InboundPullRequest(
            transferID: transferID, generation: generation, uti: info.uti,
            extractsDirectoryNamed: info.isDirectory ? info.filename : nil,
            advertisedByteCount: Int(clamping: info.byteCount),
            maxAcceptByteCount: staging.availableCapacity().map { UInt64(clamping: $0) }
                ?? ClipboardStreamTuning.unlimitedAcceptByteCount,
            receiver: receiver, session: session)
        let coordinator = lazyCoordinator
        operation.unitBegan(
            id: UInt64(repIndex), expectedBytes: info.byteCount,
            name: info.filename.isEmpty ? nil : info.filename)
        let outcome: LazyPullOutcome = await withCheckedContinuation { continuation in
            let waiter = coordinator.join(
                transferID: transferID, timeout: lazyPullTimeout,
                onProgress: { bytes, total in
                    operation.unitProgressed(
                        id: UInt64(repIndex), bytesTransferred: UInt64(max(0, bytes)),
                        totalBytes: UInt64(max(0, total)))
                },
                retire: { receiver.cancelAwait(transferID) },
                start: { Self.beginInboundPull(request, coordinator: coordinator) },
                // Resumed from whichever thread resolved the pull — never routed
                // through main, which a paste fire may be holding (§8).
                onResolve: { continuation.resume(returning: $0) })
            promise.previewWaiters[repIndex] = waiter
        }
        promise.previewWaiters[repIndex] = nil
        let rep: ClipboardContent.Representation?
        switch outcome {
        case .delivered(let delivered):
            rep = delivered
        case .aborted(let abort):
            // A retiring abort names no failure of its own — the loop simply ends
            // and its own terminal stands.
            if let failure = ClipboardTransferFailure.inboundPullAborted(abort) {
                operation.finish(.failed(failure))
            }
            rep = nil
        case .timedOut, .cancelled:
            rep = nil
        }
        operation.unitEnded(id: UInt64(repIndex), succeeded: rep != nil)
        return rep
    }

    /// Everything one inbound pull's `start` needs, captured on the main actor so
    /// the request can go out from whichever thread starts the pull.
    private struct InboundPullRequest: Sendable {
        let transferID: UInt64
        let generation: UInt64
        let uti: String
        /// Non-`nil` for a folder rep: the archive is its tree, extracted into a
        /// folder of that name as it streams.
        let extractsDirectoryNamed: String?
        let advertisedByteCount: Int
        let maxAcceptByteCount: UInt64
        let receiver: ClipboardStreamReceiver
        let session: ClipboardStreamSession
    }

    /// Opens one inbound pull: registers the transfer's awaiter, then sends the
    /// `ClipboardRequest`.
    ///
    /// The single place a pull begins, for the preview loop and a paste-time fire
    /// alike — the coordinator runs it for whichever of them arrives first, so
    /// one awaiter and one request cover both. A send that fails resolves the
    /// pull immediately rather than leaving it to the backstop.
    nonisolated private static func beginInboundPull(
        _ request: InboundPullRequest, coordinator: LazyPullCoordinator
    ) {
        let transferID = request.transferID
        let receiver = request.receiver
        receiver.awaitTransfer(
            transferID,
            // A folder's bytes are an archive of its tree, extracted as they
            // arrive: the stream layer learns that here, from the offer this side
            // already read, rather than from the wire — including the size the
            // extract is held to.
            extractsDirectoryNamed: request.extractsDirectoryNamed,
            advertisedByteCount: request.advertisedByteCount,
            onComplete: { rep in coordinator.deliver(transferID, rep) },
            onAbort: { abort in coordinator.abort(transferID, abort) },
            // Re-arms the inactivity backstop and feeds every waiter's readout, so
            // a large still-streaming transfer is never cut off mid-flight.
            // [large-paste]
            onProgress: { bytes, total in
                coordinator.progress(transferID, bytesReceived: bytes, totalBytes: total)
            })
        do {
            try request.session.sendRequest(
                generation: request.generation, transferID: transferID, uti: request.uti,
                maxAcceptByteCount: request.maxAcceptByteCount)
        } catch {
            // No request went out, so no reply will arrive — resolve the pull now
            // instead of blocking to the backstop timeout.
            receiver.cancelAwait(transferID)
            logger.error(
                "Failed to send clipboard request: \(error.localizedDescription, privacy: .public)"
            )
            coordinator.abort(
                transferID,
                ClipboardStreamAbortInfo(
                    transferID: transferID, code: .sendFailed,
                    message: "Failed to send clipboard request", neededBytes: nil,
                    availableBytes: nil))
        }
    }

    // MARK: - Synchronous pull (paste-time provider)

    /// Immutable, `Sendable` snapshot of the state a synchronous file pull needs,
    /// captured on the main actor before the pull holds its calling thread.
    private struct LazyPullSnapshot: Sendable {
        let uti: String
        let byteCount: UInt64
        let isInline: Bool
        let isDirectory: Bool
        /// Filename for the progress readout's label, empty when the rep has none.
        let filename: String
        let generation: UInt64
        let repIndex: Int
        /// The offer's paste-bound (non-inline) byte total, for the `.fileURL`
        /// path's deadline-safe cap check in `pasteBoundSnapshot`.
        let pasteBoundTotal: UInt64
        let receiver: ClipboardStreamReceiver
        let session: ClipboardStreamSession
        let staging: ClipboardFileStaging
        let timeout: TimeInterval
    }

    /// Snapshots the state for a synchronous file pull, validating that
    /// `(generation, repIndex)` still addresses the current live offer.
    ///
    /// The single site every uncached provider fire passes through, so each nil
    /// return logs why it serves nothing — the fire has no other surface. A
    /// stale generation logs `.debug` (the benign supersession race: the newer
    /// offer's re-publish is what retires these promises); the other misses
    /// persist as `.warning`.
    private func lazyPullSnapshot(generation: UInt64, repIndex: Int) -> LazyPullSnapshot? {
        guard let promise = inboundPromise else {
            Self.logger.warning(
                "Clipboard paste requested rep \(repIndex, privacy: .public) of gen=\(generation, privacy: .public) for '\(self.label, privacy: .public)' (conn=\(self.connectionTag, privacy: .public)) with no live offer — serving nothing"
            )
            return nil
        }
        guard promise.generation == generation else {
            Self.logger.debug(
                "Clipboard paste requested rep \(repIndex, privacy: .public) of superseded gen=\(generation, privacy: .public) for '\(self.label, privacy: .public)' (live gen=\(promise.generation, privacy: .public), conn=\(self.connectionTag, privacy: .public)) — serving nothing"
            )
            return nil
        }
        guard promise.reps.indices.contains(repIndex) else {
            Self.logger.warning(
                "Clipboard paste requested out-of-range rep \(repIndex, privacy: .public) of gen=\(generation, privacy: .public) for '\(self.label, privacy: .public)' (conn=\(self.connectionTag, privacy: .public)) — serving nothing"
            )
            return nil
        }
        guard let receiver = session.receiver else {
            Self.logger.warning(
                "Clipboard paste requested un-materialized rep \(repIndex, privacy: .public) of gen=\(generation, privacy: .public) for '\(self.label, privacy: .public)' (conn=\(self.connectionTag, privacy: .public)) after the service stopped — serving nothing"
            )
            return nil
        }
        let info = promise.reps[repIndex]
        return LazyPullSnapshot(
            uti: info.uti, byteCount: info.byteCount, isInline: info.isInline,
            isDirectory: info.isDirectory, filename: info.filename,
            generation: generation, repIndex: repIndex,
            pasteBoundTotal: ClipboardPromisePolicy.pasteBoundTotal(promise.reps),
            receiver: receiver, session: session, staging: staging, timeout: lazyPullTimeout)
    }

    /// Reports a paste-time refusal raised with no operation measuring it.
    ///
    /// A provider fire has no return path to the gesture, so the report every
    /// surface renders is the only host-side account of why a paste produced
    /// nothing.
    nonisolated private func reportPasteRefusal(_ failure: ClipboardTransferFailure) {
        onMain { self.reportRefusal(gesture: .paste, failure) }
    }

    /// Synchronously pulls one rep, holding the calling thread until the streamed
    /// bytes land (or abort/time out), staged into the host container.
    ///
    /// Safe to call on main: the receiver's `awaitTransfer` handler fires off-main
    /// into the coordinator, never hopping to the thread this call holds — and on
    /// main that thread keeps running the event loop meanwhile
    /// (`LazyPullCoordinator`). Byte progress is reported through
    /// `operation.unitProgressed` only — the caller ends the unit itself, and
    /// recording a terminal here would double-count.
    nonisolated private func performBlockingPull(
        _ snapshot: LazyPullSnapshot, operation: ClipboardTransferOperation
    ) -> ClipboardContent.Representation? {
        // Free-space pre-flight before the request, so an over-budget rep never
        // starts a transfer [Safeguard 4].
        if !snapshot.isInline,
            !snapshot.staging.hasCapacity(forByteCount: Int(clamping: snapshot.byteCount))
        {
            Self.logger.warning(
                "Not enough disk space to stage clipboard file rep '\(snapshot.uti, privacy: .public)' (\(snapshot.byteCount, privacy: .public) bytes)"
            )
            operation.finish(
                .failed(
                    .diskFull(
                        needed: snapshot.byteCount,
                        available: snapshot.staging.availableCapacity())))
            return nil
        }
        let transferID = Self.inboundTransferID(
            generation: snapshot.generation, repIndex: snapshot.repIndex)
        let coordinator = lazyCoordinator
        let receiver = snapshot.receiver
        let request = InboundPullRequest(
            transferID: transferID, generation: snapshot.generation, uti: snapshot.uti,
            extractsDirectoryNamed: snapshot.isDirectory ? snapshot.filename : nil,
            advertisedByteCount: Int(clamping: snapshot.byteCount),
            maxAcceptByteCount: snapshot.staging.availableCapacity().map { UInt64(clamping: $0) }
                ?? ClipboardStreamTuning.unlimitedAcceptByteCount,
            receiver: receiver, session: snapshot.session)
        let outcome = coordinator.pull(
            transferID: transferID, timeout: snapshot.timeout,
            onProgress: { bytes, total in
                operation.unitProgressed(
                    id: UInt64(snapshot.repIndex), bytesTransferred: UInt64(max(0, bytes)),
                    totalBytes: UInt64(max(0, total)))
            },
            retire: { receiver.cancelAwait(transferID) },
            start: { Self.beginInboundPull(request, coordinator: coordinator) })
        switch outcome {
        case .delivered(let rep):
            return rep
        case .aborted(let abort):
            Self.logger.warning(
                "File clipboard pull \(transferID, privacy: .public) (conn=\(self.connectionTag, privacy: .public)) aborted (\(abort.rawCode, privacy: .public))"
            )
            if let failure = ClipboardTransferFailure.inboundPullAborted(abort) {
                operation.finish(.failed(failure))
            } else {
                // A retiring abort names no failure of its own; the one this
                // connection's end delivers is explained here.
                recordPasteInterruption(operation)
            }
            return nil
        case .timedOut:
            Self.logger.warning(
                "File clipboard pull \(transferID, privacy: .public) (conn=\(self.connectionTag, privacy: .public)) timed out"
            )
            operation.finish(.failed(.timedOut))
            return nil
        case .cancelled:
            Self.logger.debug(
                "File clipboard pull \(transferID, privacy: .public) (conn=\(self.connectionTag, privacy: .public)) cancelled"
            )
            // A supersession or release raises its own explainer; the end of
            // this connection has none but this.
            recordPasteInterruption(operation)
            return nil
        }
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

    private func handleRelease(_ release: Kernova_V1_ClipboardRelease) {
        guard livePromise(generation: release.generation) != nil else { return }
        // The placeholder content stays in the window; a later Copy-to-Mac resolves
        // nothing.
        session.receiver?.cancel(generation: release.generation)
        // Wake any synchronous file pull blocked on the coordinator.
        lazyCoordinator.failAll()
        dropInboundPromise()
        // A release is a supersession: retract the now-unservable pasteboard
        // promise like a newer offer would. The released generation's staged
        // files ride the grace window rather than being swept (docs/CLIPBOARD.md
        // §3), so a paste mid-copy survives.
        if retractStaleHostWrite?() == true {
            reportRefusal(gesture: .copy, .supersededCopyRetracted(hasSuccessor: false))
            staging.reclaimSiblingRoots()
            Self.logger.notice(
                "Retracted the stale host-pasteboard promise for '\(self.label, privacy: .public)' (conn=\(self.connectionTag, privacy: .public)) after the guest released gen=\(release.generation, privacy: .public)"
            )
        }
        Self.logger.debug(
            "Guest released clipboard offer (gen=\(release.generation, privacy: .public), conn=\(self.connectionTag, privacy: .public)) for '\(self.label, privacy: .public)'"
        )
    }
}

// MARK: - Paste-time representation serving

extension VsockClipboardService: ClipboardPasteboardRepProviding {
    /// Serves the pasteboard `.fileURL` for a promised rep at paste time: the
    /// materialization cache first, else the deadline-bound synchronous pull.
    ///
    /// The cache/cap reads hop to main (they touch main-confined promise state);
    /// the pull then holds the calling thread, resolved off-main by the receiver.
    nonisolated func copyToMacFileURL(generation: UInt64, repIndex: Int) -> URL? {
        // Post-stop all-or-nothing: a partially-materialized file set serves no
        // file at all rather than a silent subset.
        if onMain({ self.refusesPasteBoundFire(generation: generation) }) { return nil }
        if let cached = onMain({ self.cachedMaterialized(generation: generation, repIndex: repIndex) }) {
            Self.logger.debug(
                "Served clipboard rep \(repIndex, privacy: .public) (gen=\(generation, privacy: .public), conn=\(self.connectionTag, privacy: .public), '\(cached.uti, privacy: .public)') from cache — no transfer"
            )
            return pasteFileURL(for: cached, generation: generation)
        }
        guard
            let snapshot = onMain({
                self.pasteBoundSnapshot(generation: generation, repIndex: repIndex)
            }),
            let rep = pullWithOwnOperation(snapshot)
        else { return nil }
        return pasteFileURL(for: rep, generation: generation)
    }

    /// Serves an inline pasteboard flavor's bytes for a promised rep at paste
    /// time: the materialization cache first, else the synchronous pull.
    ///
    /// Inline reps are exempt from the paste-budget cap — Kernova imposes no size
    /// cap on inline content (docs/CLIPBOARD.md §1).
    nonisolated func copyToMacData(generation: UInt64, repIndex: Int, uti: String) -> Data? {
        if let cached = onMain({ self.cachedMaterialized(generation: generation, repIndex: repIndex) }) {
            Self.logger.debug(
                "Served clipboard rep \(repIndex, privacy: .public) (gen=\(generation, privacy: .public), conn=\(self.connectionTag, privacy: .public), '\(cached.uti, privacy: .public)') from cache — no transfer"
            )
            return Self.residentBytes(of: cached)
        }
        guard
            let snapshot = onMain({
                self.lazyPullSnapshot(generation: generation, repIndex: repIndex)
            }),
            snapshot.uti == uti,
            let rep = pullWithOwnOperation(snapshot)
        else { return nil }
        return Self.residentBytes(of: rep)
    }

    /// Runs one paste-time pull under its own operation (a paste has no other
    /// operation to join), caching the delivered rep so the item's sibling
    /// flavors — and later fires — reuse it.
    ///
    /// The operation is not cancellable: it spans one provider fire, and the
    /// pasteboard fires once per item, so a Cancel could stop only the item in
    /// flight while the consumer moves on to the next.
    nonisolated private func pullWithOwnOperation(
        _ snapshot: LazyPullSnapshot
    ) -> ClipboardContent.Representation? {
        let repIndex = snapshot.repIndex
        let generation = snapshot.generation
        let operation = makeOperation(gesture: .paste, direction: .inbound, peerName: label)
        operation.unitBegan(
            id: UInt64(repIndex), expectedBytes: snapshot.byteCount,
            name: snapshot.filename.isEmpty ? nil : snapshot.filename)
        let pulled = performBlockingPull(snapshot, operation: operation)
        let rep = onMain { () -> ClipboardContent.Representation? in
            guard let pulled else { return nil }
            guard let promise = self.livePromise(generation: generation) else { return pulled }
            if promise.materialized[repIndex] == nil {
                promise.materialized[repIndex] = pulled
                promise.materializeEpoch += 1
            }
            return pulled
        }
        operation.unitEnded(id: UInt64(repIndex), succeeded: rep != nil)
        if rep != nil {
            operation.finish(.completed)
        } else {
            // Every path that owes the user a reason has already finished this
            // operation with it; what is left is a supersession or a benign
            // retiring abort, which explain themselves elsewhere.
            operation.abandon()
        }
        return rep
    }

    /// The `transfer_id` of an inbound pull: the host is the receiver, so it
    /// sets the direction bit. [H3]
    nonisolated private static func inboundTransferID(generation: UInt64, repIndex: Int) -> UInt64 {
        ClipboardTransferID.make(generation: generation, repIndex: repIndex, hostMinted: true)
    }

    /// The inbound promise when it is still the one `generation` addresses.
    private func livePromise(generation: UInt64) -> InboundPromise? {
        guard let promise = inboundPromise, promise.generation == generation else { return nil }
        return promise
    }

    /// The `public.file-url` value for a pulled (or cached) rep: the staged file
    /// or extracted folder when one exists, else resident bytes staged to a fresh
    /// sink so the URL a paste consumes points at a real file.
    ///
    /// A folder rep arrives already unpacked — its transfer extracted the tree as
    /// the archive streamed — so serving it costs nothing inside the paste
    /// deadline, and a repeated paste re-serves the same tree.
    nonisolated private func pasteFileURL(
        for rep: ClipboardContent.Representation, generation: UInt64
    ) -> URL? {
        let staging = onMain { self.staging }
        if let url = rep.fileURL { return url }
        // A named inline rep (an image file) reassembles in memory — stage it so
        // the `.fileURL` flavor serves a durable path.
        guard let data = rep.inMemoryData,
            let sink = try? staging.makeSink(generation: generation, filename: rep.filename)
        else {
            Self.logger.error(
                "Failed to stage clipboard file '\(rep.filename, privacy: .public)' from '\(self.label, privacy: .public)' (gen=\(generation, privacy: .public), conn=\(self.connectionTag, privacy: .public)) — serving nothing"
            )
            reportPasteRefusal(.stagingFailed)
            return nil
        }
        do {
            try sink.write(data)
            return try sink.commit()
        } catch {
            // Don't offer a truncated file — abort the partial stage.
            sink.abort()
            Self.logger.error(
                "Failed to write staged clipboard file '\(rep.filename, privacy: .public)' from '\(self.label, privacy: .public)' (gen=\(generation, privacy: .public), conn=\(self.connectionTag, privacy: .public)): \(error.localizedDescription, privacy: .public)"
            )
            reportPasteRefusal(.stagingFailed)
            return nil
        }
    }

    /// Resident bytes for an inline flavor, memory-mapped from the staged file
    /// when the payload spilled so a multi-GB rep is never loaded into the heap.
    nonisolated private static func residentBytes(
        of rep: ClipboardContent.Representation
    ) -> Data? {
        if let resident = rep.inMemoryData { return resident }
        if let url = rep.fileURL {
            return try? Data(contentsOf: url, options: .mappedIfSafe)
        }
        return nil
    }

    /// Runs `body` on the main actor synchronously, from either the main thread or
    /// off-main — the shared thread-hop for every synchronous file-pull bridge.
    nonisolated private func onMain<T: Sendable>(_ body: @MainActor () -> T) -> T {
        Thread.isMainThread
            ? MainActor.assumeIsolated { body() }
            : DispatchQueue.main.sync { MainActor.assumeIsolated { body() } }
    }
}
