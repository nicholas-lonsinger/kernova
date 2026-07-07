import Foundation
import KernovaKit
import UniformTypeIdentifiers
import os

/// Drives the Kernova clipboard sync protocol over a single `VsockChannel`.
///
/// Used for macOS guests (Linux guests use the SPICE-based service). The
/// service acts symmetrically: either side announces new clipboard content via a
/// metadata-only `ClipboardOffer`, and the receiver pulls each representation
/// via `ClipboardRequest` answered by a chunk-streamed
/// `ClipboardStreamBegin`/`ClipboardChunk`/`ClipboardStreamEnd` sequence. Every
/// transfer is streamed — inline representations reassemble in memory; file
/// representations stream to a temp file under a free-space guard — so there is
/// no size cap. Each offer carries a monotonically increasing `generation` so
/// requests that race a newer offer are detectable.
///
/// Inbound is lazy: an offer publishes metadata-only `.pendingRemote`
/// placeholders to `clipboardContent` immediately, the window pulls the
/// representations it renders richly (text/RTF/images up to a size limit) when
/// it displays the offer, and "Copy to Mac" pulls any remaining representations
/// on demand. Large files never cross the wire until the user copies them.
///
/// One instance manages one channel for the lifetime of one accepted
/// connection; the service self-terminates when the channel closes.
///
/// The version handshake, agent liveness, and the streaming-capability gate live
/// on the always-on control channel (`VsockControlService`). This service only
/// runs when the guest advertised `clipboard.stream.v1`, so no fallback path
/// exists here.
@MainActor
@Observable
final class VsockClipboardService: ClipboardServicing {
    // MARK: - Observable state

    /// Bidirectional clipboard buffer.
    var clipboardContent: ClipboardContent = .empty

    /// `true` once `start()` has been called.
    private(set) var isConnected: Bool = false

    /// Most recent user-visible transfer problem; cleared by the next
    /// successful transfer in either direction.
    private(set) var lastTransferIssue: ClipboardTransferIssue?

    /// The clipboard transfer currently being shown (most-significant in-flight
    /// transfer past the reveal delay), or `nil`.
    ///
    /// Drives the window's bottom bar and the toolbar button's under-bar.
    private(set) var transferProgress: ClipboardTransferProgress?

    var supportsBinaryRepresentations: Bool { true }

    // MARK: - Private state

    private let channel: VsockChannel
    private let label: String
    private let staging: ClipboardFileStaging

    /// Backstop for a lazy pull the peer never answers while the channel stays
    /// open — the host counterpart of the guest's `LazyPullCoordinator` timeout.
    ///
    /// Lowered in tests to drive the timeout-resolves-the-pull path.
    private let lazyPullTimeout: Duration

    /// Off-main authority for in-flight transfer byte counts; projected onto
    /// `transferProgress` via coalesced main-actor hops.
    private let progress = ClipboardTransferProgressTracker()

    /// Synchronous-blocking pull machinery for lazy *file* representations served
    /// to the host File Provider relay (`fetchContents`, off-main) and the
    /// toggle-off synchronous paste fallback (`provide`, on-main).
    ///
    /// Distinct from the `@MainActor` async `pull` used for eager inline/preview
    /// reps: the pasteboard / relay callers are synchronous and block their
    /// calling thread, so they need the off-main-woken coordinator (the same
    /// shared primitive the guest agent uses for both its directions). The two
    /// paths never contend a `transfer_id`: eager pulls cover inline/preview reps,
    /// this covers the single file rep — different rep indices.
    private let lazyCoordinator = LazyPullCoordinator()

    /// Per-transfer reveal timers: a transfer only shows a bar once its timer
    /// fires while it's still active, so a sub-`progressRevealDelay` transfer
    /// never flashes.
    ///
    /// Cancelled/cleared at each transfer's terminal.
    private var revealTasks: [UInt64: Task<Void, Never>] = [:]

    /// How long a transfer must keep running before its progress bar appears.
    ///
    /// Lowered to `.zero` in tests to drive the shown path, raised to never-fire
    /// to drive the no-show path.
    private let progressRevealDelay: Duration

    /// Default reveal delay: long enough that instant clipboard events never flash
    /// a bar, short enough that a genuinely slow transfer surfaces promptly.
    static let defaultProgressRevealDelay: Duration = .milliseconds(300)

    private var sender: ClipboardStreamSender?
    private var receiver: ClipboardStreamReceiver?
    private var consumeTask: Task<Void, Never>?

    /// Counter for outbound offer generations.
    ///
    /// Starts at 1 so 0 is the "no current offer" sentinel.
    private var nextLocalGeneration: UInt64 = 1

    /// The most recent offer we sent the guest, held until superseded so we can
    /// answer the guest's per-representation requests.
    private var pendingOutbound: (generation: UInt64, content: ClipboardContent)?

    /// Thread-safe mirror of `pendingOutbound.generation` for the sender's
    /// off-actor supersession check.
    private let currentOutboundGeneration = AtomicGeneration()

    /// The guest offer currently promised in `clipboardContent`, with its
    /// per-representation materialization cache.
    ///
    /// Reps are pulled lazily — on display for a rich preview, on Copy-to-Mac for
    /// the rest.
    private var inboundPromise: InboundPromise?

    /// Generation for which preview materialization has already been started, so
    /// the window can call `materializeForPreview()` freely without re-pulling.
    private var previewMaterializationStarted: UInt64 = 0

    /// Digest of the last content we successfully announced; suppresses
    /// redundant offers.
    private var lastGrabbedDigest: Data?

    /// Digest of the content `republish` last wrote from the inbound promise.
    ///
    /// When `clipboardContent.digest` no longer matches, the user replaced the
    /// offered content with their own edit, so the promise is stale and the lazy
    /// pulls must not resurrect it (Copy-to-Mac would otherwise discard the edit).
    private var lastInboundPublishedDigest: Data?

    #if DEBUG
    /// Test seam: awaited inside `materialize` in the window between a pull
    /// resolving and the supersession re-check, so a test can drive a newer
    /// offer / `stop()` into that exact gap deterministically.
    var afterInboundPullForTesting: (@MainActor () async -> Void)?
    #endif

    // `nonisolated` so the off-main `consume` loop can log; `Logger` is Sendable.
    nonisolated private static let logger = Logger(
        subsystem: "app.kernova", category: "VsockClipboardService")

    /// One promised guest offer.
    ///
    /// Holds its representation metadata (indexed exactly as the guest offered
    /// them, so a `transfer_id`'s rep index stays valid) and the representations
    /// materialized so far. Each rep is pulled at most once.
    private final class InboundPromise {
        let generation: UInt64
        let reps: [Kernova_V1_ClipboardRepresentationInfo]
        /// `true` when the guest's offer carried `org.nspasteboard.ConcealedType`:
        /// the content republishes concealed (the window hides it) and is not
        /// eagerly pulled for preview.
        let isConcealed: Bool
        var materialized: [Int: ClipboardContent.Representation] = [:]
        /// Pulls in flight, keyed by rep index, so concurrent preview/copy callers
        /// share one pull per rep instead of minting a duplicate (same-transfer_id)
        /// request that would orphan a continuation.
        var inFlight: [Int: Task<ClipboardContent.Representation?, Never>] = [:]
        /// Monotonic count of materializations cached into `materialized`, bumped
        /// on each pulled rep. `republishOffActor` captures it before its
        /// off-actor hash and re-checks it after, so a snapshot taken before the
        /// await can't clobber a fresher publish that landed during the hop — the
        /// newer materialization republishes the complete set.
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

    /// - Parameters:
    ///   - channel: the vsock channel carrying clipboard frames.
    ///   - label: identifies this service's staging area and log context.
    ///   - freeSpaceProvider: injected in tests to simulate a full disk;
    ///     `nil` uses the real volume free-space query.
    ///   - lazyPullTimeout: backstop for a pull the peer never answers while the
    ///     channel stays open; defaults to the production value, lowered in tests.
    ///   - progressRevealDelay: how long a transfer must run before its progress
    ///     bar appears; defaults to the production value, overridden in tests.
    ///   - stagingTempRoot: parent directory for the file-staging root; defaults
    ///     to the host File Provider app-group container (so the sandboxed
    ///     extension can read staged bytes), falling back to the system temp dir
    ///     when the container is unavailable (e.g. the CI test host). Tests inject
    ///     a unique temp root for isolation.
    init(
        channel: VsockChannel, label: String,
        freeSpaceProvider: ClipboardFileStaging.FreeSpaceProvider? = nil,
        lazyPullTimeout: Duration = ClipboardStreamTuning.lazyPullTimeout,
        progressRevealDelay: Duration = VsockClipboardService.defaultProgressRevealDelay,
        stagingTempRoot: URL? = nil
    ) {
        self.channel = channel
        self.label = label
        self.lazyPullTimeout = lazyPullTimeout
        self.progressRevealDelay = progressRevealDelay
        self.staging = ClipboardFileStaging(
            label: "host-\(label)",
            tempRoot: stagingTempRoot
                ?? FileProviderContainer(config: .host).stagingRootURL()
                ?? FileManager.default.temporaryDirectory,
            freeSpaceProvider: freeSpaceProvider)
    }

    // MARK: - Lifecycle

    func start() {
        guard consumeTask == nil else { return }
        staging.sweep()
        isConnected = true
        // Stand up the app-level host File Provider domain (idempotent across the
        // per-VM services that share it). This is the host "clipboard enabled"
        // signal — the service exists only when the VM enabled clipboard sharing,
        // so the domain + broker never start in the CI test host.
        HostClipboardFileProvider.shared.serviceDidStart()

        let sender = ClipboardStreamSender(channel: channel)
        let receiver = ClipboardStreamReceiver(
            channel: channel, staging: staging,
            // Lazy pulls register a per-transfer awaiter (bridged to an async
            // continuation by `pull`) that takes precedence over these
            // channel-wide closures, so they fire only for an unexpected
            // unawaited transfer.
            onComplete: { transferID, _ in
                Self.logger.warning(
                    "Unawaited inbound clipboard transfer \(transferID, privacy: .public) completed — dropped"
                )
            },
            onAbort: { info in
                Self.logger.debug(
                    "Unawaited inbound clipboard transfer \(info.transferID, privacy: .public) aborted (\(info.code, privacy: .public))"
                )
            })
        self.sender = sender
        self.receiver = receiver

        let channel = self.channel
        let label = self.label
        consumeTask = Task { [weak self] in
            await Self.consume(
                channel: channel, label: label, sender: sender, receiver: receiver,
                onControlFrame: { @MainActor frame in self?.handleControlFrame(frame) })
            // Channel closed — wake any pull parked on a transfer whose Begin will
            // now never arrive, so an async materialize doesn't hang forever, and
            // unblock any synchronous file pull (FP relay / toggle-off paste).
            receiver.cancelAll()
            self?.lazyCoordinator.failAll()
        }
        Self.logger.notice("Vsock clipboard service started for '\(self.label, privacy: .public)'")
    }

    func stop() {
        consumeTask?.cancel()
        consumeTask = nil
        sender?.cancelAll()
        receiver?.cancelAll()
        // Unblock any synchronous file pull (FP relay / toggle-off paste) parked
        // on the coordinator so it returns empty instead of blocking to its
        // backstop timeout.
        lazyCoordinator.failAll()
        sender = nil
        receiver = nil
        channel.close()
        isConnected = false
        pendingOutbound = nil
        currentOutboundGeneration.set(0)
        // Clears this service's File Provider offer (via dropInboundPromise) before
        // releasing it as the relay source below.
        dropInboundPromise()
        for task in revealTasks.values { task.cancel() }
        revealTasks.removeAll()
        progress.clearAll()
        transferProgress = nil
        staging.sweep()
        // Ref-count down the shared host File Provider domain; the last service to
        // stop tears the domain + broker down.
        HostClipboardFileProvider.shared.serviceDidStop(self)
        Self.logger.notice("Vsock clipboard service stopped for '\(self.label, privacy: .public)'")
    }

    // MARK: - Transfer progress

    /// Reacts to a tracker `record` outcome (called off-main from the sender /
    /// receiver progress callbacks) by scheduling the right main-actor work: arm
    /// the reveal timer on the first chunk, or run a coalesced flush.
    nonisolated private func scheduleProgressFollowUp(
        _ outcome: ClipboardTransferProgressTracker.RecordOutcome, transferID: UInt64
    ) {
        switch outcome {
        case .created:
            Task { @MainActor [weak self] in self?.armReveal(transferID) }
        case .updatedScheduleFlush:
            Task { @MainActor [weak self] in self?.flushTransferProgress() }
        case .updatedSuppressed:
            break
        }
    }

    /// Arms a transfer's reveal timer once; when it fires the transfer becomes
    /// visible only if it's still active (a faster transfer already finished, so
    /// `reveal` returns false and nothing shows).
    @MainActor private func armReveal(_ id: UInt64) {
        guard revealTasks[id] == nil else { return }
        let delay = progressRevealDelay
        revealTasks[id] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            // The timer has fired, so it is no longer a pending timer worth
            // cancelling — drop our own slot. This matters when the reveal Task
            // raced ahead of `finishProgress` (a sub-delay transfer that finished
            // first, so `armReveal` ran *after* the terminal cleared the slot):
            // `reveal` then returns false and nothing shows, but `finishProgress`
            // won't clear the slot again, so the task must clear it here or
            // `revealTasks` would accumulate a dead entry per such transfer. In
            // the common case (terminal cancels a still-pending timer) the guard
            // above already returned. Keeps `revealTasks` holding only live timers.
            self.revealTasks[id] = nil
            if self.progress.reveal(id) { self.refreshTransferProgress() }
        }
    }

    /// Coalesced-flush path: clears the conflation flag and republishes.
    @MainActor private func flushTransferProgress() { publish(progress.consumeFlush()) }

    /// Reveal/finish refresh path: republishes without touching the flush flag.
    @MainActor private func refreshTransferProgress() { publish(progress.projection()) }

    /// Publishes a new projection, skipping the redundant write (and the spurious
    /// observation it would fire) when nothing changed.
    @MainActor private func publish(_ next: ClipboardTransferProgress?) {
        if next != transferProgress { transferProgress = next }
    }

    /// Clears a transfer's progress at its terminal (success or abort): the single
    /// inbound clear-point (after the pull's `await`) and the outbound `onComplete`.
    ///
    /// Cancels the reveal timer so a just-finished transfer can't reappear.
    @MainActor private func finishProgress(_ id: UInt64) {
        revealTasks[id]?.cancel()
        revealTasks[id] = nil
        progress.finish(id)
        refreshTransferProgress()
    }

    // MARK: - Public API

    func clearBuffer() {
        clipboardContent = .empty
        lastGrabbedDigest = nil
        // The user emptied the buffer — any guest offer it was showing is stale.
        dropInboundPromise()
    }

    func grabIfChanged() {
        guard isConnected else { return }
        guard !clipboardContent.isEmpty else { return }
        // Never offer content that still holds not-yet-pulled placeholders — the
        // sender can't stream a `.pendingRemote` rep, and received guest content
        // shouldn't echo back. It becomes grab-able once the user replaces it
        // with their own bytes (a different digest).
        guard !clipboardContent.representations.contains(where: { $0.isPendingRemote }) else {
            return
        }
        guard clipboardContent.digest != lastGrabbedDigest else { return }

        let generation = nextLocalGeneration
        // Cap to the 16-bit rep-index limit; the buffer's own (uncapped) digest
        // stays the dedup key so an unchanged buffer isn't re-offered.
        let capped = clipboardContent.cappedToOfferLimit()
        if let originalCount = capped.truncatedFrom {
            Self.logger.warning(
                "Clipboard offer truncated from \(originalCount, privacy: .public) to \(ClipboardContent.maxOfferableRepresentations, privacy: .public) representations (16-bit transfer-id limit)"
            )
        }
        let content = capped.content

        var offer = Frame()
        offer.protocolVersion = 1
        offer.clipboardOffer = Kernova_V1_ClipboardOffer.with {
            $0.generation = generation
            $0.repInfo = content.representations.map(Self.repInfo(for:))
            $0.isConcealed = content.isConcealed
        }

        do {
            try channel.send(offer)
            nextLocalGeneration += 1
            // Supersede any in-flight outbound transfer for the previous offer.
            if let previous = pendingOutbound { sender?.cancel(generation: previous.generation) }
            pendingOutbound = (generation: generation, content: content)
            currentOutboundGeneration.set(generation)
            lastGrabbedDigest = clipboardContent.digest
            lastTransferIssue = nil
            Self.logger.notice(
                "Sent clipboard offer to '\(self.label, privacy: .public)' (gen=\(generation, privacy: .public), \(content.representations.count, privacy: .public) reps, \(content.totalByteCount, privacy: .public) bytes)"
            )
        } catch {
            Self.logger.error(
                "Failed to send clipboard offer for '\(self.label, privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    // MARK: - Frame consumer

    /// Drains the channel, routing high-frequency stream frames off the main
    /// actor.
    ///
    /// `nonisolated`, so the loop and its per-frame routing run on a cooperative
    /// thread, not the main actor: stream frames (begin/chunk/end/ack/abort) go
    /// straight to the thread-safe engine, and only the low-frequency control
    /// frames (offer/request/release/error) hop to main via `onControlFrame`.
    /// This keeps a multi-GB transfer's tens of thousands of chunk/ack frames off
    /// the main actor entirely. [M1]
    nonisolated private static func consume(
        channel: VsockChannel,
        label: String,
        sender: ClipboardStreamSender,
        receiver: ClipboardStreamReceiver,
        onControlFrame: @MainActor @Sendable @escaping (Frame) -> Void
    ) async {
        do {
            for try await frame in channel.incoming where frame.protocolVersion == 1 {
                switch frame.payload {
                case .clipboardStreamBegin(let begin):
                    receiver.handleBegin(begin)
                case .clipboardChunk(let chunk):
                    receiver.handleChunk(chunk)
                case .clipboardStreamEnd(let end):
                    receiver.handleEnd(end)
                case .clipboardStreamAck(let ack):
                    sender.handleAck(
                        transferID: ack.transferID, bytesConsumed: ack.bytesConsumed,
                        windowBytes: ack.windowBytes)
                case .clipboardStreamAbort(let abort):
                    // Route by the direction bit so an abort reaches exactly the
                    // engine that owns the id; the host receives ids that carry
                    // the bit and sends those that don't. [H3]
                    if ClipboardTransferID.hostReceives(abort.transferID) {
                        receiver.handleAbort(abort)
                    } else {
                        sender.handleAbort(transferID: abort.transferID)
                    }
                default:
                    await onControlFrame(frame)
                }
            }
            logger.info("Vsock clipboard channel closed for '\(label, privacy: .public)'")
        } catch {
            logger.warning(
                "Vsock clipboard channel ended with error for '\(label, privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Handles the control frames the consume loop hops to the main actor for.
    private func handleControlFrame(_ frame: Frame) {
        switch frame.payload {
        case .clipboardOffer(let offer):
            handleOffer(offer)
        case .clipboardRequest(let request):
            handleRequest(request)
        case .clipboardRelease(let release):
            handleRelease(release)
        case .error(let error):
            Self.logger.warning(
                "Guest clipboard error for '\(self.label, privacy: .public)': \(error.code, privacy: .public) — \(error.message, privacy: .public)"
            )
            if error.code.hasPrefix("clipboard.") {
                lastTransferIssue = ClipboardTransferIssue(
                    kind: .peerReportedError(code: error.code, message: error.message),
                    date: Date())
            }
        case .clipboardStreamBegin, .clipboardChunk, .clipboardStreamEnd, .clipboardStreamAck,
            .clipboardStreamAbort:
            // Routed off-main by the consume loop; never reaches here.
            break
        case .hello, .heartbeat, .policyUpdate, .logRecord, .none:
            Self.logger.warning(
                "Unexpected payload on clipboard channel for '\(self.label, privacy: .public)' — wrong port"
            )
        }
    }

    // MARK: - Outbound (we are the sender)

    private func handleRequest(_ request: Kernova_V1_ClipboardRequest) {
        guard let pending = pendingOutbound, pending.generation == request.generation else {
            Self.logger.debug(
                "Stale clipboard request gen=\(request.generation, privacy: .public) (pending=\(self.pendingOutbound?.generation ?? 0, privacy: .public))"
            )
            // Abort every dropped request so the guest's parked pull wakes
            // immediately off-main instead of stalling to its lazyPullTimeout
            // backstop (the supersession-mid-paste freeze). [#357]
            sender?.rejectRequest(
                transferID: request.transferID, code: "request.stale",
                message: "Request for superseded generation \(request.generation)")
            return
        }
        let repIndex = Int(request.transferID & 0xFFFF)
        guard repIndex < pending.content.representations.count else {
            Self.logger.warning(
                "Clipboard request transfer_id \(request.transferID, privacy: .public) out of range for gen=\(request.generation, privacy: .public)"
            )
            sender?.rejectRequest(
                transferID: request.transferID, code: "request.range",
                message: "Representation index \(repIndex) out of range")
            return
        }
        let representation = pending.content.representations[repIndex]
        guard representation.uti == request.uti else {
            Self.logger.warning(
                "Clipboard request uti '\(request.uti, privacy: .public)' doesn't match offered rep \(repIndex, privacy: .public)"
            )
            sender?.rejectRequest(
                transferID: request.transferID, code: "request.uti",
                message: "Requested UTI '\(request.uti)' does not match offered representation")
            return
        }

        let generation = currentOutboundGeneration
        let xid = request.transferID
        let label = representation.filename.isEmpty ? nil : representation.filename
        sender?.startTransfer(
            transferID: request.transferID,
            generation: request.generation,
            representation: representation,
            maxAcceptByteCount: request.maxAcceptByteCount,
            isInline: representation.shouldInlineOnPasteboard,
            isCurrent: { generationValue in generation.isCurrent(generationValue) },
            // Surface outbound (host→guest) progress. No resurrection gate is
            // needed here: `onProgress` and the terminal `onComplete` fire in
            // order on the sender's transfer queue, so no chunk can land after it.
            onProgress: { [weak self] sent, total in
                guard let self else { return }
                let outcome = self.progress.record(
                    xid, direction: .outbound, bytes: sent, total: total, label: label)
                self.scheduleProgressFollowUp(outcome, transferID: xid)
            },
            onComplete: { [weak self] _ in
                Task { @MainActor [weak self] in self?.finishProgress(xid) }
            })
        Self.logger.debug(
            "Streaming clipboard rep \(repIndex, privacy: .public) to '\(self.label, privacy: .public)' (gen=\(request.generation, privacy: .public), \(representation.byteCount, privacy: .public) bytes)"
        )
    }

    // MARK: - Inbound (we are the receiver)

    private func handleOffer(_ offer: Kernova_V1_ClipboardOffer) {
        // A newer offer supersedes the previous one: cancel any in-flight pull so
        // its partial temp file is deleted and a blocked continuation resumes.
        if let previous = inboundPromise { receiver?.cancel(generation: previous.generation) }

        guard !offer.repInfo.isEmpty else {
            dropInboundPromise()
            return
        }
        // Publish metadata-only placeholders immediately so the window shows the
        // chips without waiting; renderable reps are pulled on display and the
        // rest on Copy-to-Mac. The reps keep the guest's offer order so a
        // transfer_id's rep index stays valid against the guest's offer.
        let promise = InboundPromise(
            generation: offer.generation, reps: offer.repInfo, isConcealed: offer.isConcealed)
        republish(promise)
        // Every offered rep was identity-skipped (transient marker / raw file-url
        // / empty) — nothing usable to promise; mirror the guest agent's all-skip
        // handling rather than hold a promise that resolves to nothing.
        guard !clipboardContent.isEmpty else {
            dropInboundPromise()
            return
        }
        inboundPromise = promise
        previewMaterializationStarted = 0
        lastTransferIssue = nil
        Self.logger.notice(
            "Received guest clipboard offer for '\(self.label, privacy: .public)' (gen=\(offer.generation, privacy: .public), \(offer.repInfo.count, privacy: .public) reps) — metadata only"
        )
    }

    /// Rebuilds `clipboardContent` from the promise: each rep is its materialized
    /// form when pulled, else a `.pendingRemote` placeholder.
    ///
    /// Marks the result as already-grabbed so received content is never offered
    /// back to the guest. The synchronous form hashes on the owning actor and is
    /// for the placeholder-only publish (byte-less reps → trivial digest); after
    /// a pull materializes real bytes, use `republishOffActor` so a large inline
    /// payload (now uncapped) is not hashed on the main actor (§8).
    private func republish(_ promise: InboundPromise) {
        apply(
            ClipboardContent(
                representations: rebuiltReps(from: promise), isConcealed: promise.isConcealed))
    }

    /// `republish` with the content digest computed off the owning actor.
    ///
    /// Materializing a pulled rep can now deliver a memory-mapped inline payload
    /// of any size; hashing it for the content digest is `O(payload)` and must
    /// not stall the main actor (§8). `makeOffActor` runs that hash on the
    /// cooperative executor. Promise identity and the materialization epoch are
    /// re-checked after the hop, so neither a supersession nor a newer
    /// materialization that landed mid-hash is overwritten by this stale snapshot.
    private func republishOffActor(_ promise: InboundPromise) async {
        let epoch = promise.materializeEpoch
        let reps = rebuiltReps(from: promise)
        let content = await ClipboardContent.makeOffActor(
            representations: reps, isConcealed: promise.isConcealed)
        // A supersession (new promise) or a newer materialization (higher epoch)
        // landed during the off-actor hash; that pull republishes the complete
        // set, so applying this snapshot would revert a just-materialized rep back
        // to a placeholder.
        guard inboundPromise === promise, promise.materializeEpoch == epoch else { return }
        apply(content)
    }

    /// Builds the published representation list from the promise: each rep's
    /// materialized form when pulled, else a `.pendingRemote` placeholder.
    ///
    /// Drops identity-skip types (transient markers, raw public.file-url) so a
    /// peer can't smuggle them onto the host pasteboard — the receive-side
    /// sanitization the eager path applied. Indices into `promise.reps` stay
    /// valid for pulls; only the published view filters.
    private func rebuiltReps(from promise: InboundPromise) -> [ClipboardContent.Representation] {
        var reps: [ClipboardContent.Representation] = []
        for (index, info) in promise.reps.enumerated() where !Self.shouldSkip(info) {
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
        lastGrabbedDigest = content.digest
        lastInboundPublishedDigest = content.digest
    }

    /// Drops the current inbound promise and its per-generation lazy-pull state,
    /// and retracts this service's host File Provider offer (only if it's still
    /// the current one — a newer service's offer is left intact).
    private func dropInboundPromise() {
        inboundPromise = nil
        previewMaterializationStarted = 0
        lastInboundPublishedDigest = nil
        HostClipboardFileProvider.shared.clearOffer(from: self)
    }

    /// Drops any `.pendingRemote` placeholder reps — content that can't be
    /// written to the pasteboard (no bytes) — returning `content` unchanged when
    /// it has none.
    private static func withoutPlaceholders(_ content: ClipboardContent) -> ClipboardContent {
        let reps = content.representations.filter { !$0.isPendingRemote }
        return reps.count == content.representations.count
            ? content : ClipboardContent(representations: reps)
    }

    /// A representation excluded from the receive side by identity alone: an empty
    /// payload or a transient-marker / raw file-url UTI (the lazy counterpart of
    /// `ClipboardSnapshotPolicy.sanitizedForApply`).
    private static func shouldSkip(_ info: Kernova_V1_ClipboardRepresentationInfo) -> Bool {
        info.byteCount == 0 || ClipboardSnapshotPolicy.shouldSkipBeforeReading(uti: info.uti)
    }

    // MARK: - Lazy materialization (we are the receiver)

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
        // Concealed content is never previewed: the window shows a placeholder,
        // so pulling the secret bytes into host memory would be pointless (and
        // exactly what concealment avoids). They are still pulled on an explicit
        // Copy-to-Mac via materializeForCopy().
        guard !promise.isConcealed else { return }
        guard previewMaterializationStarted != promise.generation else { return }
        var allSucceeded = true
        for (index, info) in promise.reps.enumerated() {
            guard inboundPromise === promise else { return }  // superseded
            guard Self.isEagerPreviewable(info), !Self.shouldSkip(info) else { continue }
            if await materialize(index: index, info: info, promise: promise) == nil {
                allSucceeded = false
            }
        }
        // Latch only on full success so a transient pull failure (timeout/abort)
        // is retried on the next display trigger, instead of permanently leaving a
        // rich rep as a chip until a new offer arrives.
        if allSucceeded { previewMaterializationStarted = promise.generation }
    }

    /// Prepares the "Copy to Mac" items: inline/preview/directory reps pulled
    /// eagerly (`.resolved`), the single plain file rep published as a lazy File
    /// Provider placeholder or deferred to a size-capped synchronous paste
    /// (`.lazyFile`), and any file that can't be served reported as `.droppedFile`.
    ///
    /// Files are no longer pulled at copy-click — the bytes materialize on read via
    /// the File Provider's `fetchContents` (no deadline), or, with the File
    /// Provider off, on paste via the size-capped fallback. This is where the eager
    /// staging bridge is gone (#424, CLIPBOARD.md §2/§3).
    func materializeForCopy() async -> [CopyToMacItem] {
        // No active promise, or the user replaced the offered content with their
        // own edit: copy what's actually shown (resolved bytes), never a stale
        // placeholder.
        guard let promise = inboundPromise, clipboardContent.digest == lastInboundPublishedDigest
        else {
            dropInboundPromise()
            return Self.withoutPlaceholders(clipboardContent).representations.map { .resolved($0) }
        }

        // The single promisable, non-inline, non-directory file rep is eligible for
        // lazy routing (mirror the guest's `fileProviderURLs` single-file gate);
        // every other plain file rep is dropped (D2 is single-file, like D1a).
        let plainFileIndices = promise.reps.indices.filter { index in
            Self.isLazyEligibleFile(promise.reps[index])
        }
        let lazyFileIndex = plainFileIndices.count == 1 ? plainFileIndices.first : nil
        if plainFileIndices.count > 1 {
            Self.logger.notice(
                "Copy-to-Mac offer has \(plainFileIndices.count, privacy: .public) file reps — only single-file is routed lazily (D2 scope); extras dropped"
            )
        }

        // Collect each eager pull's RETURN value rather than re-reading
        // `promise.materialized`: a caller that coalesces onto an in-flight pull
        // gets the rep back before the owning call writes the cache, so rebuilding
        // from the cache here could silently drop a just-pulled rep.
        var items: [CopyToMacItem] = []
        for (index, info) in promise.reps.enumerated() {
            // A supersession mid-loop: return what THIS generation resolved.
            guard inboundPromise === promise else { return items }
            guard !Self.shouldSkip(info) else { continue }
            if index == lazyFileIndex {
                items.append(lazyFileItem(index: index, info: info, generation: promise.generation))
                continue
            }
            if Self.isLazyEligibleFile(info) {
                // An extra plain file rep beyond the single lazy-eligible one.
                items.append(.droppedFile(.multipleFiles))
                continue
            }
            // Inline, previewable, or directory rep — pull eagerly as before.
            if let rep = await materialize(index: index, info: info, promise: promise) {
                items.append(.resolved(rep))
            } else if !info.filename.isEmpty {
                // A file payload (directory or image file) we couldn't pull.
                items.append(.droppedFile(.pullFailed))
            }
        }
        return items
    }

    /// Whether `info` is a file rep eligible for lazy File Provider routing.
    ///
    /// A promisable, non-inline (so not an image file), non-directory, named file
    /// — a plain file like a PDF or archive. Mirrors the guest's `fileProviderURLs`
    /// gate.
    private static func isLazyEligibleFile(_ info: Kernova_V1_ClipboardRepresentationInfo) -> Bool {
        !info.isInline && !info.isDirectory && !info.filename.isEmpty && !shouldSkip(info)
    }

    /// Routes the single lazy-eligible file rep: a host File Provider placeholder
    /// (no bytes pulled now; materialized on read via `fetchContents`), or — when
    /// the File Provider is off — a size-capped synchronous paste, or a drop when
    /// it's too large to serve within the paste deadline.
    private func lazyFileItem(
        index: Int, info: Kernova_V1_ClipboardRepresentationInfo, generation: UInt64
    ) -> CopyToMacItem {
        if let url = HostClipboardFileProvider.shared.publishSingleFile(
            source: self, generation: generation, repIndex: index, filename: info.filename,
            byteCount: info.byteCount, uti: info.uti)
        {
            // A concrete placeholder URL in the File Provider domain — bytes pull
            // lazily on read, with no deadline.
            return .resolved(
                ClipboardContent.Representation(
                    uti: info.uti, fileURL: url, byteCount: Int(clamping: info.byteCount),
                    filename: info.filename))
        }
        // File Provider off / not ready: defer to a synchronous paste that pulls +
        // stages the bytes on demand, gated by a deadline-safe size cap.
        guard info.byteCount <= UInt64(ClipboardStreamTuning.maxDeadlineSafeFileBytes) else {
            Self.logger.notice(
                "Copy-to-Mac file rep \(index, privacy: .public) is \(info.byteCount, privacy: .public) bytes — over the deadline-safe cap with the File Provider off; dropped"
            )
            return .droppedFile(.tooLargeWithoutFileProvider)
        }
        return .lazyFile(
            generation: generation, repIndex: index, uti: info.uti, filename: info.filename)
    }

    /// Pulls representation `index` at most once across concurrent callers
    /// (on-display preview and Copy-to-Mac), caching and republishing on success.
    ///
    /// A second caller for an in-flight rep awaits the existing pull rather than
    /// minting a duplicate same-`transfer_id` request that would orphan a
    /// continuation.
    private func materialize(
        index: Int, info: Kernova_V1_ClipboardRepresentationInfo, promise: InboundPromise
    ) async -> ClipboardContent.Representation? {
        if let cached = promise.materialized[index] { return cached }
        if let existing = promise.inFlight[index] {
            let rep = await existing.value
            // The owning call writes the cache after its own continuation resumes,
            // which may be after this coalescing caller — populate it here too so a
            // reader between the two resumptions doesn't miss the rep.
            if let rep, inboundPromise === promise, promise.materialized[index] == nil {
                promise.materialized[index] = rep
            }
            return rep
        }
        let task = Task { @MainActor in
            await self.pull(repIndex: index, info: info, generation: promise.generation)
        }
        promise.inFlight[index] = task
        let rep = await task.value
        #if DEBUG
        await afterInboundPullForTesting?()
        #endif
        promise.inFlight[index] = nil
        guard inboundPromise === promise else { return rep }
        if let rep {
            promise.materialized[index] = rep
            promise.materializeEpoch += 1
            // A pulled rep can be a memory-mapped inline payload of any size;
            // hash its content digest off the main actor (§8).
            await republishOffActor(promise)
        }
        return rep
    }

    /// Streams one representation, bridging the off-actor receiver delivery to an
    /// async result.
    ///
    /// Runs the free-space pre-flight first so an over-budget file rep never
    /// starts a transfer [Safeguard 4].
    private func pull(
        repIndex: Int, info: Kernova_V1_ClipboardRepresentationInfo, generation: UInt64
    ) async -> ClipboardContent.Representation? {
        guard let receiver else { return nil }
        if !info.isInline, !staging.hasCapacity(forByteCount: Int(clamping: info.byteCount)) {
            Self.logger.warning(
                "Not enough disk space to receive clipboard rep '\(info.uti, privacy: .public)' (\(info.byteCount, privacy: .public) bytes)"
            )
            lastTransferIssue = ClipboardTransferIssue(
                kind: .diskFull(
                    needed: Int(clamping: info.byteCount),
                    available: staging.availableCapacity().map { Int(clamping: $0) }),
                date: Date())
            return nil
        }
        // The host is the receiver here, so it sets the direction bit. [H3]
        let transferID = ClipboardTransferID.make(
            generation: generation, repIndex: repIndex, hostMinted: true)
        let maxAccept =
            staging.availableCapacity().map { UInt64(clamping: $0) }
            ?? ClipboardStreamTuning.unlimitedAcceptByteCount
        let channel = self.channel
        let backstop = lazyPullTimeout
        let label = info.filename.isEmpty ? nil : info.filename
        let rep: ClipboardContent.Representation? = await withCheckedContinuation { continuation in
            // A single-resume box: the off-main awaiter, the on-main send-failure
            // catch, and the backstop timeout can all race a channel teardown, so
            // the first resume wins and the rest are no-ops (without it, the
            // awaiter firing off-main and the catch resuming on main would be a
            // double resume → continuation-misuse crash). The timeout also resolves
            // a pull the guest accepts but never streams while the channel stays
            // open — the host counterpart of the guest's `LazyPullCoordinator.pull`
            // backstop.
            // The progress-recording closure runs *under* the pull's single-resume
            // lock (in `noteProgress`), so once the pull resolves no late chunk can
            // resurrect the bar after `finishProgress` clears it below.
            let pull = PullContinuation(
                continuation,
                onLiveRecord: { [weak self] bytes, total in
                    self?.progress.record(
                        transferID, direction: .inbound, bytes: bytes, total: total, label: label)
                })
            receiver.awaitTransfer(
                transferID,
                onComplete: { pull.resume($0) },
                onAbort: { info in
                    // Surface a mid-stream disk-full: the pre-flight above covers
                    // the up-front case; this covers a volume that fills *during*
                    // the transfer (parity with the retired eager onTransferAbort).
                    // The closure fires off the main actor, so hop back to record.
                    if info.code == "disk.full" {
                        Task { @MainActor [weak self] in self?.recordPullDiskFull(info) }
                    }
                    pull.resume(nil)
                },
                // Re-arm the inactivity backstop on each chunk so a large
                // still-progressing guest→host transfer (e.g. Copy-to-Mac of a
                // multi-GB file) is never cut off mid-stream, and record byte
                // progress through the resume gate. [large-paste]
                onProgress: { [weak self] bytes, total in
                    guard let outcome = pull.noteProgress(bytesReceived: bytes, totalBytes: total)
                    else { return }
                    self?.scheduleProgressFollowUp(outcome, transferID: transferID)
                })
            pull.armTimeout(
                Task {
                    // Inactivity backstop: `backstop` is a window, not an absolute
                    // deadline. Re-arm while chunks keep arriving; fire only after a
                    // full window of silence. A cancelled sleep (the pull resolved
                    // first) must NOT resume. This is the async (off-main `Task`)
                    // counterpart of the guest's blocking `LazyPullCoordinator.pull`
                    // inactivity loop — keep the two in sync.
                    while true {
                        do { try await Task.sleep(for: backstop) } catch { return }
                        if pull.consumeProgress() { continue }
                        receiver.cancelAwait(transferID)
                        pull.resume(nil)
                        return
                    }
                })
            var request = Frame()
            request.protocolVersion = 1
            request.clipboardRequest = Kernova_V1_ClipboardRequest.with {
                $0.generation = generation
                $0.transferID = transferID
                $0.uti = info.uti
                $0.maxAcceptByteCount = maxAccept
            }
            do {
                try channel.send(request)
            } catch {
                receiver.cancelAwait(transferID)
                Self.logger.error(
                    "Failed to send clipboard request: \(error.localizedDescription, privacy: .public)"
                )
                pull.resume(nil)
            }
        }
        // Every inbound terminal — success, abort, disk-full, stall, timeout,
        // supersession, teardown — funnels through the `await` above, so this one
        // line clears the bar for all of them.
        finishProgress(transferID)
        if rep != nil {
            // A healthy pull clears a stale issue, but a disk-full notice stays
            // visible — another rep may still have failed to arrive.
            if case .diskFull = lastTransferIssue?.kind {} else { lastTransferIssue = nil }
        }
        // RATIONALE: `is_directory` rides the ClipboardOffer, not
        // ClipboardStreamBegin, so the offer-aware layer re-tags the delivered rep
        // here. Begin already carries `is_inline`/`filename`, so it *could* carry
        // `is_directory` too — but keeping the flag off the stream message avoids a
        // second wire change, and every receiver path materializes through this
        // offer-correlated layer. The window then extracts the staged `.aar` into a
        // real folder instead of pasting the archive file. (Mirrored in the guest's
        // `pullRepresentation`.)
        if let rep, info.isDirectory {
            return ClipboardContent.Representation(
                uti: rep.uti, source: rep.source, filename: rep.filename, isDirectory: true)
        }
        return rep
    }

    /// Records a disk-full transfer issue for a pull that aborted mid-stream
    /// because the staging volume filled (the up-front case is set in `pull`).
    private func recordPullDiskFull(_ info: ClipboardStreamAbortInfo) {
        lastTransferIssue = ClipboardTransferIssue(
            kind: .diskFull(needed: info.neededBytes ?? 0, available: info.availableBytes),
            date: Date())
    }

    // MARK: - Synchronous file pull (File Provider relay + toggle-off paste)

    /// Immutable, `Sendable` snapshot of the state a synchronous file pull needs,
    /// captured on the main actor before the pull blocks its calling thread.
    ///
    /// Holds the rep's scalar metadata plus the lock-protected `receiver`/`channel`
    /// /`staging` (all already used off-main), so the blocking pull touches no
    /// main-actor state.
    private struct LazyPullSnapshot: Sendable {
        let uti: String
        let byteCount: UInt64
        let isInline: Bool
        let isDirectory: Bool
        let generation: UInt64
        let repIndex: Int
        let receiver: ClipboardStreamReceiver
        let channel: VsockChannel
        let staging: ClipboardFileStaging
        let timeout: Duration
    }

    /// Snapshots the state for a synchronous file pull, validating that
    /// `(generation, repIndex)` still addresses the current live offer.
    ///
    /// Returns `nil` for a stale generation, an out-of-range index, or a dropped
    /// channel — the caller maps that to `.noCurrentOffer`.
    private func lazyPullSnapshot(generation: UInt64, repIndex: Int) -> LazyPullSnapshot? {
        guard let promise = inboundPromise, promise.generation == generation,
            promise.reps.indices.contains(repIndex), let receiver
        else { return nil }
        let info = promise.reps[repIndex]
        return LazyPullSnapshot(
            uti: info.uti, byteCount: info.byteCount, isInline: info.isInline,
            isDirectory: info.isDirectory, generation: generation, repIndex: repIndex,
            receiver: receiver, channel: channel, staging: staging, timeout: lazyPullTimeout)
    }

    /// Synchronously pulls one file rep, blocking the calling thread until the
    /// streamed bytes land (or abort/time out), staged into the host container.
    ///
    /// Mirrors the guest's `pullRepresentation`: the receiver's `awaitTransfer`
    /// handler fires off-main into the coordinator, never hopping to the thread
    /// this call blocks, so it is safe to call on main (the toggle-off paste
    /// `provide`) or off-main (the relay's XPC queue). The File Provider read path
    /// has no 60 s deadline, so holding the thread for a multi-GB transfer is safe.
    ///
    /// `nonisolated`: touches only the `Sendable` snapshot and the `Sendable`
    /// coordinator/logger, never main-actor state.
    nonisolated private func performBlockingPull(
        _ snapshot: LazyPullSnapshot
    ) -> ClipboardContent.Representation? {
        // Free-space pre-flight before the request, so an over-budget rep never
        // starts a transfer [Safeguard 4].
        if !snapshot.isInline,
            !snapshot.staging.hasCapacity(forByteCount: Int(clamping: snapshot.byteCount))
        {
            Self.logger.warning(
                "Not enough disk space to stage clipboard file rep '\(snapshot.uti, privacy: .public)' (\(snapshot.byteCount, privacy: .public) bytes)"
            )
            return nil
        }
        // The host is the receiver here, so it sets the direction bit. [H3]
        let transferID = ClipboardTransferID.make(
            generation: snapshot.generation, repIndex: snapshot.repIndex, hostMinted: true)
        let maxAccept =
            snapshot.staging.availableCapacity().map { UInt64(clamping: $0) }
            ?? ClipboardStreamTuning.unlimitedAcceptByteCount
        let coordinator = lazyCoordinator
        let receiver = snapshot.receiver
        let channel = snapshot.channel
        let uti = snapshot.uti
        let generation = snapshot.generation
        receiver.awaitTransfer(
            transferID,
            onComplete: { rep in coordinator.deliver(transferID, rep) },
            onAbort: { abort in coordinator.abort(transferID, abort) },
            // Re-arm the inactivity backstop on each chunk so a large still-
            // streaming file is never timed out mid-transfer. [large-paste]
            onProgress: { _, _ in coordinator.heartbeat(transferID) })
        let outcome = coordinator.pull(transferID: transferID, timeout: snapshot.timeout) {
            var request = Frame()
            request.protocolVersion = 1
            request.clipboardRequest = Kernova_V1_ClipboardRequest.with {
                $0.generation = generation
                $0.transferID = transferID
                $0.uti = uti
                $0.maxAcceptByteCount = maxAccept
            }
            do {
                try channel.send(request)
            } catch {
                // No request went out, so no reply will arrive — resolve the pull
                // now instead of blocking to the backstop timeout.
                receiver.cancelAwait(transferID)
                Self.logger.error(
                    "Failed to send clipboard request for file pull: \(error.localizedDescription, privacy: .public)"
                )
                coordinator.abort(
                    transferID,
                    ClipboardStreamAbortInfo(
                        transferID: transferID, code: "send.failed",
                        message: "Failed to send clipboard request", neededBytes: nil,
                        availableBytes: nil))
            }
        }
        switch outcome {
        case .delivered(let rep):
            // RATIONALE: `is_directory` rides the offer, not ClipboardStreamBegin,
            // so re-tag the delivered rep here (mirrors `pull` / the guest's
            // `pullRepresentation`). D2 routes only single non-directory files
            // through this path, but keep the tag for symmetry.
            if snapshot.isDirectory {
                return ClipboardContent.Representation(
                    uti: rep.uti, source: rep.source, filename: rep.filename, isDirectory: true)
            }
            return rep
        case .aborted(let abort):
            Self.logger.warning(
                "File clipboard pull \(transferID, privacy: .public) aborted (\(abort.code, privacy: .public))"
            )
            return nil
        case .timedOut:
            receiver.cancelAwait(transferID)
            Self.logger.warning("File clipboard pull \(transferID, privacy: .public) timed out")
            return nil
        case .cancelled:
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
        // Any RTF-family flavor, including flat-RTFD — which carries the inline
        // image and does not conform to `.rtf`, so it must be pulled here to
        // preview richly instead of falling back to the text-only flavor.
        if type?.conformsToRTFFamily == true {
            return info.byteCount <= UInt64(ClipboardPreviewPolicy.maxEagerPreviewBytes)
        }
        if info.uti == ClipboardContent.utf8TextUTI || type?.conforms(to: .text) == true {
            return info.byteCount <= UInt64(ClipboardPreviewPolicy.maxEditableTextBytes)
        }
        return false
    }

    private func handleRelease(_ release: Kernova_V1_ClipboardRelease) {
        guard let promise = inboundPromise, promise.generation == release.generation else { return }
        // Cancel any in-flight pull (resumes its continuation with nil) and drop
        // the promise; the placeholder content stays in the window, and a later
        // Copy-to-Mac resolves nothing.
        receiver?.cancel(generation: release.generation)
        // Also wake any synchronous file pull (FP relay / toggle-off paste) blocked
        // on the coordinator for the released offer.
        lazyCoordinator.failAll()
        dropInboundPromise()
        Self.logger.debug(
            "Guest released clipboard offer (gen=\(release.generation, privacy: .public)) for '\(self.label, privacy: .public)'"
        )
    }

    // MARK: - Helpers

    /// Builds the metadata advertised for a representation in an offer.
    private static func repInfo(
        for representation: ClipboardContent.Representation
    ) -> Kernova_V1_ClipboardRepresentationInfo {
        Kernova_V1_ClipboardRepresentationInfo.with {
            $0.uti = representation.uti
            $0.byteCount = UInt64(representation.byteCount)
            $0.filename = representation.filename
            $0.isInline = representation.shouldInlineOnPasteboard
            $0.isDirectory = representation.isDirectory
        }
    }
}

// MARK: - Host File Provider relay pull

extension VsockClipboardService: HostClipboardFileRepProviding {
    /// Synchronously pulls the file rep `(generation, repIndex)` and returns the
    /// path of its staged file in the host app-group container, which the
    /// sandboxed extension clones into the domain's temporary directory (relay
    /// path) or the pasteboard reads directly (toggle-off paste path).
    ///
    /// Thread-aware so one bridge serves both callers (mirroring the guest's two
    /// entry points): on the main thread it snapshots directly (the toggle-off
    /// `provide` callback already runs there); off-main it snapshots via
    /// `DispatchQueue.main.sync` (the relay's XPC queue). It then blocks the
    /// calling thread on `performBlockingPull`, woken off-main by the receiver, so
    /// blocking main is safe — the stream receive runs on its own queue.
    nonisolated func pullStagedFile(
        generation: UInt64, repIndex: Int
    ) -> Result<String, FileProviderPullError> {
        let snapshot: LazyPullSnapshot? =
            Thread.isMainThread
            ? MainActor.assumeIsolated {
                lazyPullSnapshot(generation: generation, repIndex: repIndex)
            }
            : DispatchQueue.main.sync {
                MainActor.assumeIsolated {
                    lazyPullSnapshot(generation: generation, repIndex: repIndex)
                }
            }
        guard let snapshot else { return .failure(.noCurrentOffer) }
        guard let rep = performBlockingPull(snapshot), let url = rep.fileURL else {
            return .failure(.pullFailed)
        }
        return .success(url.path)
    }
}

/// Single-resume bridge from one inbound pull's three possible resumers — the
/// off-actor receiver delivery, the on-main send-failure `catch`, and the
/// backstop timeout — to its `CheckedContinuation`.
///
/// All three can race a channel teardown; the first `resume` wins, cancels the
/// timeout, and clears the continuation, so the others are no-ops and the
/// continuation is resumed exactly once.
///
/// `@unchecked Sendable`: the continuation and timer are guarded by `lock`.
private final class PullContinuation: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ClipboardContent.Representation?, Never>?
    private var timeout: Task<Void, Never>?
    /// Set by `noteProgress` (a chunk landed), consumed by the backstop loop at
    /// each window boundary to re-arm instead of firing.
    private var progressed = false
    /// Records byte progress into the transfer tracker *under `lock`*, atomically
    /// with the resolved check, so a chunk landing after the pull resolves can't
    /// resurrect a cleared progress bar.
    ///
    /// Returns the tracker's outcome, or `nil`.
    private let onLiveRecord: (@Sendable (Int, Int) -> ClipboardTransferProgressTracker.RecordOutcome?)?

    init(
        _ continuation: CheckedContinuation<ClipboardContent.Representation?, Never>,
        onLiveRecord: (@Sendable (Int, Int) -> ClipboardTransferProgressTracker.RecordOutcome?)? = nil
    ) {
        self.continuation = continuation
        self.onLiveRecord = onLiveRecord
    }

    /// Records that the transfer made progress so the backstop loop keeps waiting
    /// past the next window boundary, and records byte progress through the
    /// tracker.
    ///
    /// Returns the tracker outcome the caller should act on, or `nil` once the
    /// pull has resolved (so no resurrecting follow-up runs).
    func noteProgress(bytesReceived: Int, totalBytes: Int)
        -> ClipboardTransferProgressTracker.RecordOutcome?
    {
        lock.withLock {
            guard continuation != nil else { return nil }
            progressed = true
            return onLiveRecord?(bytesReceived, totalBytes) ?? nil
        }
    }

    /// Returns (and clears) whether progress occurred since the last check, so
    /// the backstop loop re-arms only when a chunk actually landed in the window.
    func consumeProgress() -> Bool {
        lock.withLock {
            guard progressed else { return false }
            progressed = false
            return true
        }
    }

    /// Stores the backstop timer so the winning `resume` can cancel it; if the
    /// pull already resolved before this ran, cancels the timer immediately.
    func armTimeout(_ task: Task<Void, Never>) {
        let alreadyResolved = lock.withLock { () -> Bool in
            guard continuation != nil else { return true }
            timeout = task
            return false
        }
        if alreadyResolved { task.cancel() }
    }

    /// Resumes the continuation once; later calls are no-ops.
    func resume(_ value: ClipboardContent.Representation?) {
        let pending: CheckedContinuation<ClipboardContent.Representation?, Never>?
        let timer: Task<Void, Never>?
        (pending, timer) = lock.withLock {
            let continuation = self.continuation
            let timeout = self.timeout
            self.continuation = nil
            self.timeout = nil
            return (continuation, timeout)
        }
        timer?.cancel()
        pending?.resume(returning: value)
    }
}
