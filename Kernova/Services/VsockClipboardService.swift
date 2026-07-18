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

    /// Whether the guest advertised the folder placeholder-tree capability
    /// (`clipboard.dirtree.v1`) — the mutually negotiated gate.
    ///
    /// Wired from the
    /// per-VM control service at construction; read at offer/consume time so it
    /// tracks reconnects. `{ false }` in tests and before the control Hello lands
    /// (safe — the archive path always works).
    var peerSupportsDirTree: @MainActor () -> Bool = { false }

    var supportsDirectoryTree: Bool { peerSupportsDirTree() }

    /// Bumped once per new inbound guest offer (see `ClipboardServicing`).
    ///
    /// So the passthrough coordinator publishes guest content to the host
    /// pasteboard exactly once; not bumped by preview/copy materialization of an
    /// already-published offer — that would re-publish on every lazy pull.
    private(set) var inboundOfferSeq: UInt64 = 0

    // MARK: - Private state

    private let channel: VsockChannel
    private let label: String
    private let staging: ClipboardFileStaging

    /// The app-level host File Provider coordinator (`HostClipboardFileProvider`
    /// in production, a fake in tests): stands the shared domain up/down, warms
    /// the relay before a paste, publishes the offer's file reps as placeholders
    /// at paste time, and reports availability for the Copy-to-Mac advisory.
    private let fileProvider: any HostClipboardDomainCoordinating

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
        /// File-Provider routing for this offer — rep index → domain URL —
        /// latched by the first paste-time provider fire whose publish succeeded.
        ///
        /// `nil` while undecided. A failed/unusable publish deliberately does NOT
        /// latch, so a later provider fire retries the File Provider — the
        /// paste-time re-check that replaced the #429 availability-flip re-publish
        /// (enable the toggle, paste again, and it routes lazily). Mirrors the
        /// guest agent's `InboundPromise.fpRoutedURLs`.
        var fpRoutedURLs: [Int: URL]?
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
    ///   - fileProvider: the app-level host File Provider coordinator; defaults to
    ///     the process-wide `HostClipboardFileProvider.shared`, injected in tests
    ///     to drive paste-time routing and the copy-click advisory without a live
    ///     domain.
    init(
        channel: VsockChannel, label: String,
        freeSpaceProvider: ClipboardFileStaging.FreeSpaceProvider? = nil,
        lazyPullTimeout: Duration = ClipboardStreamTuning.lazyPullTimeout,
        progressRevealDelay: Duration = VsockClipboardService.defaultProgressRevealDelay,
        stagingTempRoot: URL? = nil,
        fileProvider: any HostClipboardDomainCoordinating = HostClipboardFileProvider.shared
    ) {
        self.channel = channel
        self.label = label
        self.lazyPullTimeout = lazyPullTimeout
        self.progressRevealDelay = progressRevealDelay
        self.fileProvider = fileProvider
        self.staging = ClipboardFileStaging(
            label: "host-\(label)",
            tempRoot: stagingTempRoot
                ?? FileProviderContainer(config: .host()).stagingRootURL()
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
        fileProvider.serviceDidStart()

        let sender = ClipboardStreamSender(channel: channel)
        let receiver = ClipboardStreamReceiver(
            channel: channel, staging: staging,
            // Per-transfer throughput baseline for #377 — the only measured
            // number for the real vsock link, so it logs at `.notice`
            // (persisted) rather than `.debug`.
            onTransferTimed: { [label = self.label] metrics in
                Self.logger.notice(
                    "Guest→host clipboard transfer \(metrics.transferID, privacy: .public) ('\(label, privacy: .public)') completed: \(metrics.logSummary, privacy: .public)"
                )
            },
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
                onControlFrame: { [weak self] frame in
                    // Fire-and-forget onto the serial main queue so the consume loop
                    // never suspends on the main-actor hop — a control frame arriving
                    // while main is blocked in a toggle-off paste's
                    // performBlockingPull must not halt stream-frame routing (#458).
                    // Serial DispatchQueue.main preserves control-frame FIFO order; a
                    // per-frame detached Task would not. Mirrors the guest's #357
                    // pattern (VsockGuestClipboardAgent.serve).
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { self?.handleControlFrame(frame) }
                    }
                })
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
        fileProvider.serviceDidStop(self)
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
            $0.repInfo = content.representations.map(\.offerRepresentationInfo)
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
    /// thread, not the main actor: stream frames (begin/chunk/end/ack, and a
    /// receiver-bound abort) go straight to the thread-safe engine, and the
    /// low-frequency control frames (offer/request/release/error), plus a
    /// sender-bound abort, hop to main via `onControlFrame`. This keeps a
    /// multi-GB transfer's tens of thousands of chunk/ack frames off the main
    /// actor entirely. [M1]
    ///
    /// `onControlFrame` dispatches fire-and-forget rather than being awaited, so
    /// the loop never suspends on the main-actor hop: a control frame arriving
    /// while main is blocked elsewhere (e.g. `performBlockingPull`) must not halt
    /// stream-frame routing (#458), mirroring the guest's fire-and-forget
    /// `DispatchQueue.main.async` dispatch (#357).
    nonisolated private static func consume(
        channel: VsockChannel,
        label: String,
        sender: ClipboardStreamSender,
        receiver: ClipboardStreamReceiver,
        onControlFrame: @Sendable @escaping (Frame) -> Void
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
                        // A sender-bound abort (e.g. the peer cancelling its own
                        // in-flight pull, #464/#500) must not be handled directly
                        // here: `handleRequest` now registers the transfer via
                        // `sender.startTransfer` fire-and-forget on main (#458),
                        // so an abort for the same transfer_id handled
                        // synchronously off-main could race ahead of that
                        // registration and land as a silent no-op on an
                        // unregistered id — the transfer then streams anyway
                        // despite having been cancelled. Routing it through the
                        // same `onControlFrame` main-queue dispatch as the
                        // request preserves their relative order (#503).
                        onControlFrame(frame)
                    }
                default:
                    onControlFrame(frame)
                }
            }
            logger.info("Vsock clipboard channel closed for '\(label, privacy: .public)'")
        } catch {
            logger.warning(
                "Vsock clipboard channel ended with error for '\(label, privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Handles the control frames the consume loop dispatches to the main actor
    /// for, fire-and-forget (#458) — never awaited, so a control frame processed
    /// here can never itself hold up the consume loop's stream-frame routing.
    private func handleControlFrame(_ frame: Frame) {
        switch frame.payload {
        case .clipboardOffer(let offer):
            handleOffer(offer)
        case .clipboardRequest(let request):
            handleRequest(request)
        case .clipboardTreeFetch(let fetch):
            handleTreeFetch(fetch)
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
        case .clipboardStreamAbort(let abort):
            // Only a sender-bound abort reaches here (routed through this same
            // dispatch, not off-main, so it can't race ahead of a still-pending
            // `sender.startTransfer` registration for the same transfer_id —
            // see the routing comment in `consume`, #503). A receiver-bound
            // abort is routed off-main directly and never reaches here.
            sender?.handleAbort(transferID: abort.transferID)
        case .clipboardStreamBegin, .clipboardChunk, .clipboardStreamEnd, .clipboardStreamAck:
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
        // A source-directory rep (folder placeholder tree) has no archive to
        // stream: a consumer that couldn't route it through its File Provider is
        // falling back to the archive path, so archive it at REQUEST time (off the
        // main actor) and stream that (#422 endgame — no eager copy-time archive).
        // The tree path uses `ClipboardTreeFetch`, never this plain request.
        if case .directory(let sourceURL, _) = representation.source {
            archiveAndStream(
                sourceURL: sourceURL, folderName: representation.filename, request: request,
                isCurrent: generation, label: label)
            return
        }
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

    /// Archives a source directory at request time and streams the `.aar` — the
    /// toggle-off fallback for a folder the consumer couldn't route through its
    /// File Provider.
    ///
    /// Runs the walk + LZFSE compress off the main actor.
    private func archiveAndStream(
        sourceURL: URL, folderName: String, request: Kernova_V1_ClipboardRequest,
        isCurrent: AtomicGeneration, label: String?
    ) {
        guard let sender else { return }
        let staging = self.staging
        let transferID = request.transferID
        let requestGeneration = request.generation
        let maxAccept = request.maxAcceptByteCount
        let progress = self.progress
        // Build the progress closures on the main actor (capturing `self` weakly)
        // and pass them into the off-main dispatch, so the dispatched closure never
        // references the main-actor `self` in concurrently-executing code.
        let onProgress: @Sendable (Int, Int) -> Void = { [weak self] sent, total in
            let outcome = progress.record(
                transferID, direction: .outbound, bytes: sent, total: total, label: label)
            self?.scheduleProgressFollowUp(outcome, transferID: transferID)
        }
        let onComplete: @Sendable (Bool) -> Void = { [weak self] _ in
            Task { @MainActor in self?.finishProgress(transferID) }
        }
        DispatchQueue.global(qos: .userInitiated).async {
            guard
                let rep = try? ClipboardDirectoryArchive.archivedRepresentation(
                    ofDirectoryAt: sourceURL, named: folderName, into: staging,
                    generation: requestGeneration)
            else {
                Self.logger.error(
                    "Failed to archive folder '\(folderName, privacy: .public)' at request time")
                sender.rejectRequest(
                    transferID: transferID, code: "archive.error",
                    message: "Could not archive the folder")
                return
            }
            sender.startTransfer(
                transferID: transferID, generation: requestGeneration, representation: rep,
                maxAcceptByteCount: maxAccept, isInline: false,
                isCurrent: { value in isCurrent.isCurrent(value) },
                onProgress: onProgress, onComplete: onComplete)
        }
    }

    /// Serves a directory rep's placeholder-tree fetch (folder D1b): a tree
    /// listing (empty `relative_path`) or one confined child file, streamed back
    /// over the shared stream transport keyed by the fetch's `transfer_id`.
    private func handleTreeFetch(_ fetch: Kernova_V1_ClipboardTreeFetch) {
        guard let sender else { return }
        guard let pending = pendingOutbound, pending.generation == fetch.generation else {
            sender.rejectRequest(
                transferID: fetch.transferID, code: "request.stale",
                message: "Tree fetch for superseded generation \(fetch.generation)")
            return
        }
        let repIndex = Int(fetch.repIndex)
        guard repIndex < pending.content.representations.count,
            let sourceURL = pending.content.representations[repIndex].directorySourceURL
        else {
            sender.rejectRequest(
                transferID: fetch.transferID, code: "request.range",
                message: "Tree fetch for a non-directory or out-of-range rep \(repIndex)")
            return
        }
        let generation = currentOutboundGeneration
        ClipboardDirectoryTree.serveFetch(fetch, sourceURL: sourceURL, sender: sender) { value in
            generation.isCurrent(value)
        }
    }

    // MARK: - Inbound (we are the receiver)

    private func handleOffer(_ offer: Kernova_V1_ClipboardOffer) {
        // A newer offer supersedes the previous one: cancel any in-flight pull so
        // its partial temp file is deleted and a blocked continuation resumes, and
        // retract this service's paste-published File Provider placeholder so the
        // superseded offer's dirents don't linger in "Kernova Clipboard (Mac)".
        // With placeholders now paste-scoped (#559), a new offer no longer
        // overwrites the manifest at copy-click, so nothing else clears the stale
        // offer until some later paste — hence the explicit retract here, mirroring
        // the guest agent's `handleOffer` clear. `clearOffer(from:)` is
        // source-guarded, so a stopping/older service can't wipe a newer service's
        // live offer.
        if let previous = inboundPromise {
            receiver?.cancel(generation: previous.generation)
            fileProvider.clearOffer(from: self)
        }

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
        // A genuinely new offer with usable content landed — signal the
        // passthrough coordinator (once per offer, after the promise is live so
        // its `materializeForCopy` sees it).
        inboundOfferSeq &+= 1
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
        fileProvider.clearOffer(from: self)
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

    /// Prepares the "Copy to Mac" items.
    ///
    /// Inline/preview/directory reps are pulled eagerly (`.resolved`); every
    /// lazy-eligible plain file rep is deferred as a `.lazyFile` whose routing — a
    /// host File Provider placeholder or a size-capped synchronous paste — is
    /// decided at paste time inside the provider closure (`copyToMacFileURL`,
    /// decision 1). Files that can't be served are reported as `.droppedFile`.
    ///
    /// Files are no longer pulled — nor is the File Provider published — at
    /// copy-click: the bytes materialize on read via the File Provider's
    /// `fetchContents` (no deadline), or, with the File Provider off, on paste via
    /// the size-capped fallback (#424/#427 host mirror, CLIPBOARD.md §2/§3). The
    /// one exception is an advisory up-front refusal (below).
    func materializeForCopy() async -> [CopyToMacItem] {
        // No active promise, or the user replaced the offered content with their
        // own edit: copy what's actually shown (resolved bytes), never a stale
        // placeholder.
        guard let promise = inboundPromise, clipboardContent.digest == lastInboundPublishedDigest
        else {
            dropInboundPromise()
            return Self.withoutPlaceholders(clipboardContent).representations.map { .resolved($0) }
        }

        // Every promisable, non-inline, non-directory file rep is lazy-eligible;
        // routing (File Provider vs. size-capped sync) is decided per rep at paste
        // time. The single-file D2 scope limit is dissolved (#559) — the host now
        // mirrors the guest's D1b multi-file routing.
        let plainFileIndices = promise.reps.indices.filter { index in
            isLazyEligibleFile(promise.reps[index])
        }
        // Advisory up-front over-total refusal (decision 4): only when the File
        // Provider is ALREADY known unusable at click, so the user sees the
        // enable-File-Provider message in the window immediately instead of a
        // silent paste failure. When usable/unprobed, the paste-time total gate in
        // `copyToMacFileURL` enforces it. The total counts plain-file reps only —
        // directories are pulled eagerly here, never through a deadline-bound
        // callback (unlike the guest).
        let advisoryRefusal =
            !plainFileIndices.isEmpty
            && Self.isKnownUnusable(fileProvider.availability)
            && plainFileIndices.reduce(UInt64(0)) { $0 &+ promise.reps[$1].byteCount }
                > UInt64(ClipboardStreamTuning.maxDeadlineSafeFileBytes)
        if advisoryRefusal {
            Self.logger.notice(
                "Copy-to-Mac plain-file set (\(plainFileIndices.count, privacy: .public) reps) totals over the deadline-safe cap with the File Provider unusable — refusing the whole set"
            )
        } else if !plainFileIndices.isEmpty {
            // Warm the servicing relay so the first paste-time publish doesn't also
            // pay doorbell/extension-launch latency inside the paste (mirrors the
            // guest's offer-time `prepareForOffer`).
            fileProvider.prepareForCopy()
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
            if isLazyEligibleFile(info) {
                items.append(
                    advisoryRefusal
                        ? .droppedFile(.tooLargeWithoutFileProvider)
                        : .lazyFile(
                            generation: promise.generation, repIndex: index, uti: info.uti,
                            filename: info.filename))
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

    /// Whether `info` is a rep eligible for lazy File Provider routing: a
    /// promisable, non-inline, named plain file (a PDF, archive, …), plus a
    /// directory rep when the folder placeholder-tree capability
    /// (`clipboard.dirtree.v1`) is negotiated with the guest.
    ///
    /// Mirrors the guest's
    /// eligibility gate; an image file is inline (dual-flavor) and stays sync, and
    /// a directory's estimate `byteCount` may be 0 (empty folder), so it isn't
    /// gated on a non-zero size.
    private func isLazyEligibleFile(_ info: Kernova_V1_ClipboardRepresentationInfo) -> Bool {
        guard !info.filename.isEmpty else { return false }
        if info.isDirectory {
            return peerSupportsDirTree()
                && !ClipboardSnapshotPolicy.shouldSkipBeforeReading(uti: info.uti)
        }
        return !info.isInline && !Self.shouldSkip(info)
    }

    /// Whether the File Provider is confirmed off (toggle off, or the extension is
    /// broken), so a large paste is certain to hit the size-capped sync path — the
    /// copy-click advisory refusal fires. `.inactive` (not yet probed) and
    /// `.ready` do not, so routing is left to the paste-time re-check.
    private static func isKnownUnusable(_ availability: FileProviderAvailability) -> Bool {
        switch availability {
        case .needsEnabling, .unavailable: return true
        case .inactive, .ready: return false
        }
    }

    // MARK: - Paste-time file routing (we are the receiver)

    /// How a lazy plain-file rep's `.fileURL` is served at paste time, decided on
    /// the main actor: an FP-routed domain URL, a snapshot for the deadline-bound
    /// synchronous pull, or nothing (stale offer / over-total refusal).
    private enum CopyFileURLDecision: Sendable {
        case routed(URL)
        case sync(LazyPullSnapshot)
        case none
    }

    /// Decides how to serve a lazy plain-file rep's `.fileURL` at paste time.
    ///
    /// The host mirror of the guest's `provideRoutedFileURL`: File Provider first
    /// (every eligible rep published together, latched on success), else the
    /// deadline-bound synchronous pull gated by the offer's sync-bound total.
    @MainActor
    private func decideCopyFileURL(generation: UInt64, repIndex: Int) -> CopyFileURLDecision {
        guard let promise = inboundPromise, promise.generation == generation,
            promise.reps.indices.contains(repIndex)
        else { return .none }
        if let url = ensureCopyFileProviderRouting(promise)[repIndex] { return .routed(url) }
        // File Provider unusable: the deadline-safe cap (#561) applies to the
        // TOTAL of the offer's sync-bound plain-file reps, all-or-nothing
        // (decision 4) — a set that together exceeds the cap is refused whole
        // rather than pasted piecemeal (a paste that silently lands 2 of 3 files
        // misleads more than one that refuses). The copy-click advisory already
        // surfaced the enable-File-Provider message when availability was known
        // unusable; this enforces the gate at paste.
        let total = syncBoundTotalBytes(for: promise)
        guard total <= UInt64(ClipboardStreamTuning.maxDeadlineSafeFileBytes) else {
            Self.logger.notice(
                "Copy-to-Mac sync-bound file reps total \(total, privacy: .public) bytes — over the deadline-safe cap with the File Provider off; refusing the paste"
            )
            return .none
        }
        guard let snapshot = lazyPullSnapshot(generation: generation, repIndex: repIndex) else {
            return .none
        }
        return .sync(snapshot)
    }

    /// The offer's File-Provider routing, publishing every eligible plain-file rep
    /// on first use.
    ///
    /// Latched on SUCCESS only: a failed/unusable publish returns empty without
    /// latching, so THIS fire falls back to the synchronous path and a later fire
    /// retries the File Provider — the paste-time re-check that replaced the #429
    /// availability-flip re-publish. All eligible reps publish together on the
    /// first fire (one manifest write, one enumeration), and every sibling fire of
    /// the same paste reads the latch. Mirrors the guest's `ensureFileProviderRouting`.
    @MainActor
    private func ensureCopyFileProviderRouting(_ promise: InboundPromise) -> [Int: URL] {
        if let latched = promise.fpRoutedURLs { return latched }
        let eligible = promise.reps.indices.filter { isLazyEligibleFile(promise.reps[$0]) }
        guard !eligible.isEmpty else { return [:] }
        // Plain files publish as flat placeholders; directory reps publish as
        // placeholder trees — each first fetching its listing (a bounded vsock
        // round-trip). A folder's listing is fetched only when the domain is
        // `.ready`, so the toggle-off path never pays a wasted tree-listing pull
        // (§3); a skipped folder falls back to the sync archive path on its own
        // provider fire. Plain files always go through `publishItemsForPaste` (which
        // declines when not ready), matching the single-file path. Mirrors the
        // guest's `ensureFileProviderRouting`.
        let treeReady = fileProvider.availability == .ready
        var items: [FileProviderPublishItem] = []
        var folders: [FileProviderPublishFolder] = []
        for index in eligible {
            let info = promise.reps[index]
            if info.isDirectory {
                guard treeReady,
                    let folder = buildPublishFolder(repIndex: index, info: info, promise: promise)
                else { continue }
                folders.append(folder)
            } else {
                items.append(
                    FileProviderPublishItem(
                        repIndex: index, filename: info.filename, byteCount: info.byteCount,
                        uti: info.uti))
            }
        }
        guard !items.isEmpty || !folders.isEmpty else { return [:] }
        guard
            let urls = fileProvider.publishItemsForPaste(
                source: self, generation: promise.generation, items: items, folders: folders)
        else { return [:] }
        promise.fpRoutedURLs = urls
        Self.logger.notice(
            "Routed \(items.count, privacy: .public) file(s) + \(folders.count, privacy: .public) folder(s) through the File Provider at paste (gen=\(promise.generation, privacy: .public))"
        )
        return urls
    }

    /// Fetches a directory rep's tree listing and builds a publishable folder tree
    /// (folder D1b, host mirror of the guest's `buildPublishFolder`).
    ///
    /// Returns `nil`
    /// when the listing can't be fetched. Runs on the main actor (paste-time
    /// routing); the listing pull blocks (woken off-main), like the publish barrier.
    @MainActor
    private func buildPublishFolder(
        repIndex: Int, info: Kernova_V1_ClipboardRepresentationInfo, promise: InboundPromise
    ) -> FileProviderPublishFolder? {
        guard let entries = pullTreeListing(generation: promise.generation, repIndex: repIndex)
        else { return nil }
        let isPackage = Self.isPackageUTI(info.uti)
        let folder = ClipboardDirectoryTree.makeFolderRep(
            sessionSalt: 0, generation: promise.generation, repIndex: repIndex,
            filename: info.filename, isPackage: isPackage, estimatedByteCount: info.byteCount,
            rootMtimeMs: 0, entries: entries)
        return FileProviderPublishFolder(
            repIndex: repIndex, filename: info.filename, uti: folder.uti, isPackage: isPackage,
            byteCount: info.byteCount, mtimeMs: folder.mtimeMs, nodes: folder.nodes)
    }

    /// Whether an offered directory rep's content UTI names an OS package.
    private static func isPackageUTI(_ uti: String) -> Bool {
        guard let type = UTType(uti) else { return false }
        return type.conforms(to: .package) || type.conforms(to: .bundle)
    }

    /// Total byte count of the offer's sync-bound plain-file reps — the
    /// lazy-eligible file reps NOT routed through the File Provider — against which
    /// the deadline-safe cap is compared (decision 4).
    ///
    /// Without the folder placeholder-tree capability, directories are excluded
    /// (they're pulled eagerly at copy-click, never through a deadline-bound
    /// callback). With it, a directory rep is lazy-eligible and — if its listing
    /// couldn't be fetched / the toggle is off — counts toward this total by its
    /// estimate, exactly like the guest. Reads the routing latch, so it is for
    /// paste-time callers only.
    private func syncBoundTotalBytes(for promise: InboundPromise) -> UInt64 {
        let routed = promise.fpRoutedURLs ?? [:]
        var total: UInt64 = 0
        for (index, info) in promise.reps.enumerated()
        where isLazyEligibleFile(info) && routed[index] == nil {
            total &+= info.byteCount
        }
        return total
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
                onAbort: { [weak self] info in
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
        /// Filename for the in-app progress bar's label (#426); `nil`-mapped when
        /// empty at the record site.
        let filename: String
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
            isDirectory: info.isDirectory, filename: info.filename,
            generation: generation, repIndex: repIndex,
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
    /// `nonisolated`: touches only the `Sendable` snapshot, the `Sendable`
    /// coordinator/logger, and the `Sendable` progress tracker — never main-actor
    /// state directly (the in-app bar clears via a `finishProgress` main hop).
    ///
    /// `onProgress` forwards the receiver's cumulative `(bytesTransferred,
    /// totalBytes)` to the servicing-XPC push (the relay path passes a real
    /// closure; the toggle-off sync paste passes the default no-op). Independently,
    /// this records the same bytes into the window's in-app bar (#426, #354),
    /// direction `.inbound`, cleared at every terminal (except supersession — the
    /// #500 retry owns the shared `transferID` entry and clears it itself).
    nonisolated private func performBlockingPull(
        _ snapshot: LazyPullSnapshot,
        onProgress: @escaping @Sendable (UInt64, UInt64) -> Void = { _, _ in }
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
        let label = snapshot.filename.isEmpty ? nil : snapshot.filename
        receiver.awaitTransfer(
            transferID,
            onComplete: { rep in coordinator.deliver(transferID, rep) },
            onAbort: { abort in coordinator.abort(transferID, abort) },
            // Re-arm the inactivity backstop on each chunk so a large still-
            // streaming file is never timed out mid-transfer [large-paste]; push
            // the bytes to the servicing-XPC channel (the extension's determinate
            // download bar, #426); and record the same bytes into the window's
            // in-app bar (#354/#426, direction `.inbound`).
            //
            // No resurrection gate is needed here (unlike the async `pull`, which
            // has off-transfer-queue resume racers): this `onProgress` and the
            // terminal `onComplete`/`onAbort` fire in order on the receiver's
            // transfer queue, and the coordinator's timeout is inactivity-gated
            // (re-armed by `heartbeat`), so no chunk can record after the terminal
            // that triggers `finishProgress` — the same reasoning the sender path
            // documents in `handleRequest`.
            onProgress: { [weak self] bytes, total in
                coordinator.heartbeat(transferID)
                onProgress(UInt64(bytes), UInt64(total))
                guard let self else { return }
                let outcome = self.progress.record(
                    transferID, direction: .inbound, bytes: bytes, total: total, label: label)
                self.scheduleProgressFollowUp(outcome, transferID: transferID)
            })
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
        // Clear the in-app bar at the terminal — success, abort, timeout, or
        // consumer-cancel. Supersession is the exception (#500): the retry now owns
        // this transferID's shared tracker entry and clears it at its own terminal,
        // so clearing here would wipe the successor's live bar.
        if case .superseded = outcome {
            // The retry owns this transferID's shared tracker entry and clears the
            // bar itself; clearing here would wipe the successor's live bar.
        } else {
            Task { @MainActor [weak self] in self?.finishProgress(transferID) }
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
            // `.debug`, not `.warning`: `.cancelled` also covers benign
            // teardown/supersession (`failAll`), which is deliberately silent
            // elsewhere (see `ClipboardStreamReceiver.teardown`'s doc) — this
            // is only a diagnostic trace for the consumer-cancel case
            // (`LazyPullCoordinator.cancelBeforeStart`), not a warning-worthy
            // anomaly like `.aborted`/`.timedOut`.
            Self.logger.debug("File clipboard pull \(transferID, privacy: .public) cancelled")
            // Mirrors the `.timedOut` branch: nothing will ever deliver/abort
            // this transferID now (no request was sent, or the request was
            // pre-empted before it went out — see `LazyPullCoordinator.cancelBeforeStart`),
            // so release the registered awaiter rather than leaking it.
            receiver.cancelAwait(transferID)
            return nil
        case .superseded:
            // A newer pull for this id (a retry after this fetch's owner
            // connection dropped) has already taken over the awaiter/slot
            // registration (#500) — touch nothing keyed by `transferID`: the
            // retry owns it now and must resolve on its own.
            Self.logger.debug("File clipboard pull \(transferID, privacy: .public) superseded by a newer fetch")
            return nil
        }
    }

    // MARK: - Folder placeholder tree pulls (we are the receiver)

    /// Registers a per-transfer awaiter and sends `sendRequest`, blocking the
    /// calling thread until the transfer resolves — the shared transport core for
    /// the host's folder-tree listing and child pulls (mirrors the guest's
    /// `awaitPull`). `nonisolated`: touches only the `Sendable` coordinator and the
    /// immutable `lazyPullTimeout`, so it runs on main (listing pull) or off-main
    /// (child pull), woken off-main either way.
    nonisolated private func awaitTreePull(
        transferID: UInt64, receiver: ClipboardStreamReceiver,
        onProgress: (@Sendable (_ bytesTransferred: UInt64, _ totalBytes: UInt64) -> Void)?,
        sendRequest: @escaping () throws -> Void
    ) -> LazyPullOutcome {
        let coordinator = lazyCoordinator
        receiver.awaitTransfer(
            transferID,
            onComplete: { rep in coordinator.deliver(transferID, rep) },
            onAbort: { abort in coordinator.abort(transferID, abort) },
            onProgress: { bytes, total in
                coordinator.heartbeat(transferID)
                onProgress?(UInt64(bytes), UInt64(total))
            })
        return coordinator.pull(transferID: transferID, timeout: lazyPullTimeout) {
            do {
                try sendRequest()
            } catch {
                receiver.cancelAwait(transferID)
                coordinator.abort(
                    transferID,
                    ClipboardStreamAbortInfo(
                        transferID: transferID, code: "send.failed",
                        message: "Failed to send clipboard tree fetch", neededBytes: nil,
                        availableBytes: nil))
            }
        }
    }

    /// Pulls a directory rep's tree listing (folder D1b) — blocking on the main
    /// actor (paste-time routing), woken off-main.
    ///
    /// Returns its entries, or `nil`.
    @MainActor
    private func pullTreeListing(generation: UInt64, repIndex: Int)
        -> [Kernova_V1_ClipboardTreeEntry]?
    {
        guard let receiver else { return nil }
        // The host is the receiver, so it sets the direction bit. [H3]
        let transferID = ClipboardTransferID.makeChild(
            generation: generation, repIndex: repIndex, childSeq: 0, hostMinted: true)
        let channel = self.channel
        let outcome = awaitTreePull(transferID: transferID, receiver: receiver, onProgress: nil) {
            var frame = Frame()
            frame.protocolVersion = 1
            frame.clipboardTreeFetch = Kernova_V1_ClipboardTreeFetch.with {
                $0.generation = generation
                $0.transferID = transferID
                $0.repIndex = UInt32(repIndex)
                $0.relativePath = ""
                $0.maxAcceptByteCount = ClipboardStreamTuning.unlimitedAcceptByteCount
            }
            try channel.send(frame)
        }
        switch outcome {
        case .delivered(let rep):
            guard let data = rep.inMemoryData,
                let entries = try? ClipboardDirectoryTree.deserializeListing(data)
            else {
                Self.logger.warning(
                    "Tree listing for rep \(repIndex, privacy: .public) could not be decoded")
                return nil
            }
            return entries
        case .timedOut:
            receiver.cancelAwait(transferID)
            Self.logger.warning("Tree listing pull \(transferID, privacy: .public) timed out")
            return nil
        case .aborted(let abort):
            Self.logger.warning("Tree listing pull aborted (\(abort.code, privacy: .public))")
            return nil
        case .cancelled, .superseded:
            return nil
        }
    }

    /// Pulls one child file of a directory rep's tree (folder D1b) — off-main, for
    /// the File Provider relay.
    ///
    /// Returns the staged `.file` rep, or `nil`.
    nonisolated private func pullChild(
        generation: UInt64, repIndex: Int, childSeq: UInt32, relativePath: String,
        onProgress: @escaping @Sendable (UInt64, UInt64) -> Void
    ) -> ClipboardContent.Representation? {
        let context: (receiver: ClipboardStreamReceiver, channel: VsockChannel)? = onMain {
            guard let promise = self.inboundPromise, promise.generation == generation,
                promise.reps.indices.contains(repIndex), let receiver = self.receiver
            else { return nil }
            return (receiver, self.channel)
        }
        guard let context else { return nil }
        // The host is the receiver, so it sets the direction bit. [H3]
        let transferID = ClipboardTransferID.makeChild(
            generation: generation, repIndex: repIndex, childSeq: childSeq, hostMinted: true)
        let maxAccept =
            staging.availableCapacity().map { UInt64(clamping: $0) }
            ?? ClipboardStreamTuning.unlimitedAcceptByteCount
        let channel = context.channel
        let outcome = awaitTreePull(
            transferID: transferID, receiver: context.receiver, onProgress: onProgress
        ) {
            var frame = Frame()
            frame.protocolVersion = 1
            frame.clipboardTreeFetch = Kernova_V1_ClipboardTreeFetch.with {
                $0.generation = generation
                $0.transferID = transferID
                $0.repIndex = UInt32(repIndex)
                $0.relativePath = relativePath
                $0.maxAcceptByteCount = maxAccept
            }
            try channel.send(frame)
        }
        switch outcome {
        case .delivered(let rep):
            return rep
        case .timedOut:
            context.receiver.cancelAwait(transferID)
            Self.logger.warning("Child pull \(transferID, privacy: .public) timed out")
            return nil
        case .aborted(let abort):
            Self.logger.warning("Child pull aborted (\(abort.code, privacy: .public))")
            return nil
        case .cancelled, .superseded:
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
    /// blocking main is safe — the stream receive runs on `consume`'s own
    /// cooperative thread, which routes control frames to main fire-and-forget
    /// (never awaited) and so never parks waiting on this very thread (#458).
    nonisolated func pullStagedFile(
        generation: UInt64, repIndex: Int,
        onProgress: @escaping @Sendable (UInt64, UInt64) -> Void = { _, _ in }
    ) -> Result<String, FileProviderPullError> {
        let snapshot = onMain { self.lazyPullSnapshot(generation: generation, repIndex: repIndex) }
        guard let snapshot else { return .failure(.noCurrentOffer) }
        guard let rep = performBlockingPull(snapshot, onProgress: onProgress), let url = rep.fileURL
        else {
            return .failure(.pullFailed)
        }
        return .success(url.path)
    }

    /// Off-main entry point for a folder placeholder tree's per-child fetch (folder
    /// D1b): pulls the child at `relativePath` within directory rep `(generation,
    /// repIndex)` and returns its staged path.
    ///
    /// The host mirror of the guest agent's
    /// `fetchStagedChild`.
    nonisolated func pullStagedChild(
        generation: UInt64, repIndex: Int, childSeq: UInt32, relativePath: String,
        onProgress: @escaping @Sendable (UInt64, UInt64) -> Void = { _, _ in }
    ) -> Result<String, FileProviderPullError> {
        guard
            let rep = pullChild(
                generation: generation, repIndex: repIndex, childSeq: childSeq,
                relativePath: relativePath, onProgress: onProgress),
            let url = rep.fileURL
        else { return .failure(.pullFailed) }
        return .success(url.path)
    }

    /// Aborts an in-flight `pullStagedChild` for `(generation, repIndex, childSeq)`
    /// (#464), addressing the transfer by its deterministic child `transferID`.
    nonisolated func cancelStagedChildPull(generation: UInt64, repIndex: Int, childSeq: UInt32) {
        let transferID = ClipboardTransferID.makeChild(
            generation: generation, repIndex: repIndex, childSeq: childSeq, hostMinted: true)
        let receiver = onMain { self.receiver }
        Self.logger.notice(
            "Cancelling child clipboard pull \(transferID, privacy: .public) on consumer request")
        receiver?.cancel(transferID: transferID)
        lazyCoordinator.cancelBeforeStart(transferID)
    }

    /// Serves the pasteboard `.fileURL` for a lazy plain-file rep at paste time.
    ///
    /// File Provider routing first (latched on success), else the
    /// offer-total-gated deadline-bound synchronous pull — the host mirror of the
    /// guest's `provideRoutedFileURL`.
    ///
    /// Thread-aware like `pullStagedFile`: the routing decision hops to main (it
    /// reads/latches main-confined promise state and calls the main-only
    /// `publishItemsForPaste`); the blocking sync pull then runs on the calling
    /// thread, woken off-main by the receiver.
    nonisolated func copyToMacFileURL(generation: UInt64, repIndex: Int) -> URL? {
        switch onMain({ self.decideCopyFileURL(generation: generation, repIndex: repIndex) }) {
        case .routed(let url):
            return url
        case .sync(let snapshot):
            guard let rep = performBlockingPull(snapshot), let url = rep.fileURL else { return nil }
            return url
        case .none:
            return nil
        }
    }

    /// Runs `body` on the main actor synchronously, from either the main thread
    /// (the toggle-off pasteboard `provide` callback) or off-main (the File
    /// Provider relay's XPC queue) — the shared thread-hop for every synchronous
    /// file-pull bridge, so the `isMainThread`/`DispatchQueue.main.sync` pattern
    /// lives in one place.
    nonisolated private func onMain<T: Sendable>(_ body: @MainActor () -> T) -> T {
        Thread.isMainThread
            ? MainActor.assumeIsolated { body() }
            : DispatchQueue.main.sync { MainActor.assumeIsolated { body() } }
    }

    /// Aborts an in-flight `pullStagedFile` for `(generation, repIndex)` (#464).
    ///
    /// Thread-aware like `pullStagedFile`: reads the current receiver directly on
    /// main, or via `DispatchQueue.main.sync` off-main (the relay's XPC queue).
    /// Addresses the transfer purely by its deterministic `transferID` — not by
    /// re-validating `generation` against the current offer — so a cancel that
    /// arrives after a newer offer superseded this one still reaches the (already
    /// superseded, but possibly still-live) receiver's bookkeeping for that id.
    ///
    /// Also marks the id pre-cancelled on `lazyCoordinator` so a cancel that
    /// arrives before `performBlockingPull` has even called `coordinator.pull`
    /// (the fetch is dispatched onto the relay's own concurrent queue and may
    /// not have started yet) still takes effect instead of being silently lost —
    /// closing the race `receiver.cancel(transferID:)` alone can't, since it has
    /// nothing to tear down until a Begin/awaiter exists.
    nonisolated func cancelStagedPull(generation: UInt64, repIndex: Int) {
        let transferID = ClipboardTransferID.make(
            generation: generation, repIndex: repIndex, hostMinted: true)
        let receiver = onMain { self.receiver }
        Self.logger.notice(
            "Cancelling file clipboard pull \(transferID, privacy: .public) on consumer request")
        receiver?.cancel(transferID: transferID)
        lazyCoordinator.cancelBeforeStart(transferID)
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
