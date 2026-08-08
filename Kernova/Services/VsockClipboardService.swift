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

    /// Most recent user-visible transfer problem; cleared by the next
    /// successful transfer in either direction.
    private(set) var lastTransferIssue: ClipboardTransferIssue?

    /// The clipboard operation currently being shown (most-significant in-flight
    /// session past the reveal delay), or `nil`.
    private(set) var transferProgress: ClipboardProgressSnapshot?

    var supportsBinaryRepresentations: Bool { true }

    /// Bumped once per new inbound guest offer, never by preview/copy
    /// materialization of an already-published one — the passthrough coordinator
    /// would otherwise re-publish to the host pasteboard on every lazy pull.
    private(set) var inboundOfferSeq: UInt64 = 0

    // MARK: - Private state

    private let channel: VsockChannel
    private let label: String

    /// Log coordinate for this connection: generations and transfer ids restart
    /// with every accepted channel, and one instance serves exactly one.
    private let connectionTag = ClipboardConnectionTag.nextHost()

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

    /// App-level aggregate this VM's readout feeds, so the menu-bar status item
    /// shows one progress readout across every live VM.
    private let progressCenter: ClipboardProgressCenter

    /// Backstop for a lazy pull the peer never answers while the channel stays
    /// open.
    private let lazyPullTimeout: TimeInterval

    /// The ceiling on a paste's file-representation total, read at each budget
    /// check rather than captured, so a Settings change reaches a live session.
    private let maxPasteBytes: @MainActor () -> Int

    /// Whether the connected guest can receive a folder archived straight onto
    /// the wire (`clipboard.stream.directory.v1`).
    ///
    /// Read at each offer, so an agent that reconnects after an update starts
    /// getting folders without restarting the service. Defaults to refusing, so
    /// a service built without capability information never offers a folder the
    /// peer might not be able to take.
    private let peerStreamsDirectories: @MainActor () -> Bool

    /// Off-main authority for this VM's clipboard progress, aggregating every
    /// transfer of one operation into the snapshot each surface renders.
    ///
    /// The initializer replaces this placeholder: the real tracker's `emit`
    /// closure captures `self`.
    @ObservationIgnored private var progress = ClipboardProgressTracker { _ in }

    /// The outbound session serving the guest's pulls of `pendingOutbound`, if one
    /// is live, with the generation it measures.
    ///
    /// The guest decides what it pulls and when — a paste can take two waves
    /// minutes apart — so transfers are declared as they are asked for, never up
    /// front.
    @ObservationIgnored
    private var outboundSession: (generation: UInt64, token: ClipboardProgressTracker.SessionToken)?

    /// Synchronous-blocking pull machinery for representations served inside a
    /// pasteboard `provideData` callback, on whichever thread the pasteboard
    /// server fires it (usually main).
    ///
    /// A paste-time pull can target a rep the async preview `pull` has in
    /// flight under the same `transfer_id`; that is safe by construction: the
    /// receiver's newest awaiter wins delivery, the guest sender ignores a
    /// duplicate-id request while one is streaming (and re-streams after it
    /// finished), and the displaced preview resolves at its inactivity backstop,
    /// retrying into the cache the paste pull populated.
    private let lazyCoordinator = LazyPullCoordinator()

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
        /// Pulls in flight, keyed by rep index, so concurrent preview/copy callers
        /// share one pull per rep instead of minting a duplicate (same-transfer_id)
        /// request that would orphan a continuation.
        var inFlight: [Int: Task<ClipboardContent.Representation?, Never>] = [:]
        /// Monotonic count of materializations cached into `materialized`, bumped
        /// on each pulled rep so `republishOffActor` can detect one that landed
        /// during its off-actor hash.
        var materializeEpoch = 0
        /// Whether the post-stop partial-file-set refusal was already surfaced
        /// for this offer, so the N provider fires of one multi-file paste raise
        /// one issue rather than N.
        var partialSetRefusalReported = false

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
        channel: VsockChannel, label: String,
        freeSpaceProvider: ClipboardFileStaging.FreeSpaceProvider? = nil,
        maxPasteBytes: @escaping @MainActor () -> Int = { ClipboardPasteLimit.defaultBytes },
        peerStreamsDirectories: @escaping @MainActor () -> Bool = { false },
        lazyPullTimeout: TimeInterval = ClipboardStreamTuning.lazyPullTimeout,
        progressRevealDelay: TimeInterval = ClipboardProgressTracker.defaultRevealDelay,
        progressIdleLinger: TimeInterval = ClipboardProgressTracker.defaultIdleLinger,
        stagingTempRoot: URL = FileManager.default.temporaryDirectory,
        progressCenter: ClipboardProgressCenter = .shared
    ) {
        self.channel = channel
        self.label = label
        self.maxPasteBytes = maxPasteBytes
        self.peerStreamsDirectories = peerStreamsDirectories
        self.lazyPullTimeout = lazyPullTimeout
        self.progressCenter = progressCenter
        self.staging = ClipboardFileStaging(
            label: "host-\(label)", tempRoot: stagingTempRoot,
            freeSpaceProvider: freeSpaceProvider)
        self.dropStaging = ClipboardFileStaging(
            label: "host-drops-\(label)", tempRoot: stagingTempRoot,
            freeSpaceProvider: freeSpaceProvider)
        // Emissions hop to main on a serial (FIFO) queue, not an unordered
        // `Task { @MainActor }`: two snapshots arriving out of order would make
        // the progress bar jump backwards.
        progress = ClipboardProgressTracker(
            revealDelay: progressRevealDelay, idleLinger: progressIdleLinger
        ) { [weak self] snapshot in
            DispatchQueue.main.async {
                guard let self else { return }
                MainActor.assumeIsolated { self.publishProgress(snapshot) }
            }
        }
    }

    // MARK: - Lifecycle

    func start() {
        guard consumeTask == nil else { return }
        // Earlier sessions' receive and drop roots may still be serving the
        // pasteboard's current write (a stopped session's materialized reps stay
        // servable, and a dropped file's URL is copied as-is), so they are
        // reclaimed only once the pasteboard no longer holds this VM's write.
        if hostPasteboardHoldsOurWrite?() != true {
            staging.reclaimSiblingRoots()
            dropStaging.reclaimSiblingRoots()
        }
        isConnected = true

        let sender = ClipboardStreamSender(channel: channel)
        let receiver = ClipboardStreamReceiver(
            channel: channel, staging: staging,
            onTransferTimed: { [label = self.label, tag = self.connectionTag] metrics in
                Self.logger.notice(
                    "Guest→host clipboard transfer \(metrics.transferID, privacy: .public) ('\(label, privacy: .public)', conn=\(tag, privacy: .public)) completed: \(metrics.logSummary, privacy: .public)"
                )
            },
            // A lazy pull's per-transfer awaiter takes precedence over these
            // channel-wide closures, so they fire only for an unawaited transfer.
            onComplete: { [tag = self.connectionTag] transferID, _ in
                Self.logger.warning(
                    "Unawaited inbound clipboard transfer \(transferID, privacy: .public) (conn=\(tag, privacy: .public)) completed — dropped"
                )
            },
            onAbort: { [tag = self.connectionTag] info in
                Self.logger.debug(
                    "Unawaited inbound clipboard transfer \(info.transferID, privacy: .public) (conn=\(tag, privacy: .public)) aborted (\(info.code, privacy: .public))"
                )
            })
        self.sender = sender
        self.receiver = receiver

        let channel = self.channel
        let label = self.label
        let connectionTag = self.connectionTag
        consumeTask = Task { [weak self] in
            await Self.consume(
                channel: channel, label: label, connectionTag: connectionTag, sender: sender,
                receiver: receiver,
                onControlFrame: { [weak self] frame in
                    // Fire-and-forget: awaiting the main-actor hop would halt
                    // stream-frame routing while main is blocked in a paste's
                    // `performBlockingPull`. Serial `DispatchQueue.main`
                    // preserves control-frame FIFO order; a per-frame Task would not.
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { self?.handleControlFrame(frame) }
                    }
                })
            // Channel closed — wake any parked pull so a materialize doesn't hang
            // forever.
            receiver.cancelAll()
            self?.lazyCoordinator.failAll()
        }
        Self.logger.notice(
            "Vsock clipboard service started for '\(self.label, privacy: .public)' (conn=\(self.connectionTag, privacy: .public))"
        )
    }

    func stop() {
        consumeTask?.cancel()
        consumeTask = nil
        sender?.cancelAll()
        receiver?.cancelAll()
        // Unblock any synchronous file pull parked on the coordinator, so it
        // returns empty instead of blocking to its backstop timeout.
        lazyCoordinator.failAll()
        sender = nil
        receiver = nil
        channel.close()
        isConnected = false
        pendingOutbound = nil
        currentOutboundGeneration.set(0)
        // With the offer gone, a drop the buffer no longer shows has no reader
        // left on this side.
        retireUnreferencedDropDirectories()
        // Every session, not just the outbound one: a materialization loop parked
        // on a pull this teardown failed would leave its readout up for a gone VM.
        outboundSession = nil
        progress.clearAll()
        // Synchronously, not via the tracker's emission hop: a readout still
        // standing for a VM that has gone is the stuck indicator §13 forbids.
        publishProgress(nil)
        // Nothing is swept here: the inbound promise and its receive staging
        // deliberately survive stop(), because the host pasteboard may still
        // advertise this offer and every materialized rep stays servable from the
        // cache and the staged files (docs/CLIPBOARD.md §3). Only supersession
        // retracts the write; the files then age out of the generation window.
        // Unconditional, unlike `publishProgress`'s change-guarded push: a stopped
        // VM's last snapshot would otherwise pin the status item's readout.
        progressCenter.progressChanged(from: self, nil)
        Self.logger.notice(
            "Vsock clipboard service stopped for '\(self.label, privacy: .public)' (conn=\(self.connectionTag, privacy: .public))"
        )
    }

    // MARK: - Transfer progress

    /// Publishes the tracker's latest snapshot to this service's own surfaces and
    /// to the app-level center that drives the menu-bar status item.
    private func publishProgress(_ snapshot: ClipboardProgressSnapshot?) {
        // A stopped service shows nothing: emissions reach here through a queue
        // hop, so one dispatched just before teardown can land just after it.
        let next = isConnected ? snapshot : nil
        guard next != transferProgress else { return }
        transferProgress = next
        progressCenter.progressChanged(from: self, next)
    }

    /// The outbound session measuring what this side is streaming for `generation`,
    /// opening one if the guest's request is the first under that generation.
    ///
    /// Every such session is a paste session: the guest asks for bytes only from
    /// the pasteboard promise callback of a paste inside it — it has no preview or
    /// copy surface of its own — so this readout is the only thing explaining why
    /// the app the user pasted into is waiting.
    ///
    /// A session the tracker already ended is replaced rather than reused: the
    /// waves can be minutes apart, far longer than the idle linger, and reusing
    /// the ended token drops the second wave's progress entirely.
    private func outboundSessionToken(for generation: UInt64)
        -> ClipboardProgressTracker.SessionToken
    {
        if let existing = outboundSession, existing.generation == generation,
            progress.isSessionLive(existing.token)
        {
            return existing.token
        }
        if let stale = outboundSession { progress.closeSession(stale.token, immediately: true) }
        let token = progress.openSession(
            direction: .outbound, peerName: label, isPaste: true)
        outboundSession = (generation: generation, token: token)
        return token
    }

    // MARK: - Public API

    func clearBuffer() {
        clipboardContent = .empty
        lastGrabbedDigest = nil
        // The user emptied the buffer — any guest offer it was showing is stale.
        dropInboundPromise()
        retireUnreferencedDropDirectories()
    }

    func reportIssue(_ issue: ClipboardTransferIssue) {
        lastTransferIssue = issue
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
            clipboardContent.representations + (pendingOutbound?.content.representations ?? [])
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
        guard clipboardContent.digest != lastGrabbedDigest else { return }

        let generation = nextLocalGeneration
        // Cap to the 16-bit rep-index limit; the buffer's own (uncapped) digest
        // stays the dedup key so an unchanged buffer isn't re-offered.
        let capped = offerableContent().cappedToOfferLimit()
        if let originalCount = capped.truncatedFrom {
            Self.logger.warning(
                "Clipboard offer truncated from \(originalCount, privacy: .public) to \(ClipboardContent.maxOfferableRepresentations, privacy: .public) representations (16-bit transfer-id limit)"
            )
        }
        let content = capped.content
        // Filtering can empty the list. Send nothing rather than an offer with no
        // representations: the peer would drop its promise and be left with a
        // pasteboard item nothing can serve, where leaving the previous offer
        // standing keeps a working clipboard. The digest still advances, so this
        // buffer isn't re-examined every poll; a reconnect builds a fresh service
        // and re-offers under whatever the peer advertises then.
        guard !content.representations.isEmpty else {
            lastGrabbedDigest = clipboardContent.digest
            return
        }

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
            if let previous = pendingOutbound { sender?.cancel(generation: previous.generation) }
            pendingOutbound = (generation: generation, content: content)
            currentOutboundGeneration.set(generation)
            lastGrabbedDigest = clipboardContent.digest
            lastTransferIssue = nil
            // The offer just replaced supersedes whatever drop it was reading
            // from, so that drop's files can go.
            retireUnreferencedDropDirectories()
            Self.logger.notice(
                "Sent clipboard offer to '\(self.label, privacy: .public)' (gen=\(generation, privacy: .public), conn=\(self.connectionTag, privacy: .public), \(content.representations.count, privacy: .public) reps, \(content.totalByteCount, privacy: .public) bytes)"
            )
        } catch {
            Self.logger.error(
                "Failed to send clipboard offer for '\(self.label, privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// The buffer's content as this peer can consume it: folder representations
    /// are dropped for a guest agent that predates
    /// `clipboard.stream.directory.v1`, which cannot receive one.
    ///
    /// Filtering here rather than at the wire keeps `pendingOutbound` and the
    /// offer built from the same list, so a `transfer_id`'s low 16 bits keep
    /// addressing the representation the guest asked for.
    private func offerableContent() -> ClipboardContent {
        guard !peerStreamsDirectories() else { return clipboardContent }
        let kept = clipboardContent.representations.filter { !$0.isDirectory }
        guard kept.count != clipboardContent.representations.count else { return clipboardContent }
        Self.logger.notice(
            "Dropping \(self.clipboardContent.representations.count - kept.count, privacy: .public) folder representation(s) from the clipboard offer to '\(self.label, privacy: .public)' — the guest agent lacks \(KernovaCapability.clipboardStreamDirectoryV1, privacy: .public) (agent needs updating)"
        )
        return ClipboardContent(representations: kept, isConcealed: clipboardContent.isConcealed)
    }

    // MARK: - Frame consumer

    /// Drains the channel, routing high-frequency stream frames off the main
    /// actor.
    ///
    /// `nonisolated` so the loop runs on a cooperative thread: stream frames go
    /// straight to the thread-safe engine and only the low-frequency control
    /// frames hop to main, keeping a multi-GB transfer's chunk/ack frames off the
    /// main actor entirely. [M1]
    nonisolated private static func consume(
        channel: VsockChannel,
        label: String,
        connectionTag: ClipboardConnectionTag,
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
                        // A sender-bound abort must not be handled off-main here:
                        // `handleRequest` registers the transfer on main, so an
                        // abort handled synchronously could race ahead of that
                        // registration and no-op on an unregistered id — the
                        // transfer would then stream despite being cancelled. The
                        // shared main-queue dispatch preserves their order.
                        onControlFrame(frame)
                    }
                default:
                    onControlFrame(frame)
                }
            }
            logger.info(
                "Vsock clipboard channel closed for '\(label, privacy: .public)' (conn=\(connectionTag, privacy: .public))"
            )
        } catch {
            logger.warning(
                "Vsock clipboard channel ended with error for '\(label, privacy: .public)' (conn=\(connectionTag, privacy: .public)): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Handles the control frames the consume loop dispatches to the main actor.
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
        case .clipboardStreamAbort(let abort):
            // Only a sender-bound abort reaches here; see the routing in `consume`.
            sender?.handleAbort(transferID: abort.transferID)
        case .clipboardStreamBegin, .clipboardChunk, .clipboardStreamEnd, .clipboardStreamAck:
            // Routed off-main by the consume loop; never reaches here.
            break
        case .hello, .heartbeat, .policyUpdate, .logRecord:
            // Control-plane and log payloads belong on their own channels; a peer
            // sending them here crossed wires. A conformant agent reconnects.
            Self.logger.warning(
                "Unexpected payload on clipboard channel for '\(self.label, privacy: .public)' — wrong port; closing the channel"
            )
            channel.close()
        case .none:
            Self.logger.debug("Frame with no payload for '\(self.label, privacy: .public)'")
        }
    }

    // MARK: - Outbound (we are the sender)

    private func handleRequest(_ request: Kernova_V1_ClipboardRequest) {
        guard let pending = pendingOutbound, pending.generation == request.generation else {
            Self.logger.debug(
                "Stale clipboard request gen=\(request.generation, privacy: .public) (pending=\(self.pendingOutbound?.generation ?? 0, privacy: .public), conn=\(self.connectionTag, privacy: .public))"
            )
            // Abort every dropped request so the guest's parked pull wakes
            // immediately instead of stalling to its backstop timeout.
            sender?.rejectRequest(
                transferID: request.transferID, code: "request.stale",
                message: "Request for superseded generation \(request.generation)")
            return
        }
        let repIndex = Int(request.transferID & 0xFFFF)
        guard repIndex < pending.content.representations.count else {
            Self.logger.warning(
                "Clipboard request transfer_id \(request.transferID, privacy: .public) out of range for gen=\(request.generation, privacy: .public) (conn=\(self.connectionTag, privacy: .public))"
            )
            sender?.rejectRequest(
                transferID: request.transferID, code: "request.range",
                message: "Representation index \(repIndex) out of range")
            return
        }
        let representation = pending.content.representations[repIndex]
        guard representation.uti == request.uti else {
            Self.logger.warning(
                "Clipboard request uti '\(request.uti, privacy: .public)' doesn't match offered rep \(repIndex, privacy: .public) (conn=\(self.connectionTag, privacy: .public))"
            )
            sender?.rejectRequest(
                transferID: request.transferID, code: "request.uti",
                message: "Requested UTI '\(request.uti)' does not match offered representation")
            return
        }

        let generation = currentOutboundGeneration
        let xid = request.transferID
        let label = representation.filename.isEmpty ? nil : representation.filename
        // Ahead of the session bookkeeping: with no sender nothing streams, so a
        // transfer announced here would never see a terminal and its readout would
        // stick on screen.
        guard let sender else { return }
        // Declared as the guest asks for it — see `outboundSession`.
        let session = outboundSessionToken(for: request.generation)
        progress.unitBegan(
            session: session, id: xid, expectedBytes: UInt64(max(0, representation.byteCount)), name: label)
        let tracker = progress
        // A directory rep is offered as a source URL plus an estimate — no
        // archive exists. Archive the tree straight onto the wire, so nothing
        // larger than the credit window is ever held (docs/CLIPBOARD.md §2).
        if case .directory(let sourceURL, let estimatedByteCount) = representation.source {
            Self.logger.notice(
                "Streaming clipboard folder '\(representation.filename, privacy: .public)' to '\(self.label, privacy: .public)' (gen=\(request.generation, privacy: .public), conn=\(self.connectionTag, privacy: .public), rep \(repIndex, privacy: .public), estimate \(estimatedByteCount, privacy: .public) bytes)"
            )
            sender.startDirectoryTransfer(
                transferID: request.transferID,
                generation: request.generation,
                sourceDirectoryURL: sourceURL,
                folderName: representation.filename,
                uti: representation.uti,
                maxAcceptByteCount: request.maxAcceptByteCount,
                isCurrent: { generationValue in generation.isCurrent(generationValue) },
                onProgress: { sent, total in
                    tracker.unitProgressed(
                        session: session, id: xid, bytesTransferred: UInt64(max(0, sent)),
                        totalBytes: UInt64(max(0, total)))
                },
                onComplete: { success in
                    tracker.unitEnded(session: session, id: xid, succeeded: success)
                })
            return
        }
        sender.startTransfer(
            transferID: request.transferID,
            generation: request.generation,
            representation: representation,
            maxAcceptByteCount: request.maxAcceptByteCount,
            isInline: representation.shouldInlineOnPasteboard,
            isCurrent: { generationValue in generation.isCurrent(generationValue) },
            onProgress: { sent, total in
                tracker.unitProgressed(
                    session: session, id: xid, bytesTransferred: UInt64(max(0, sent)),
                    totalBytes: UInt64(max(0, total)))
            },
            onComplete: { success in
                tracker.unitEnded(session: session, id: xid, succeeded: success)
            })
        Self.logger.debug(
            "Streaming clipboard rep \(repIndex, privacy: .public) to '\(self.label, privacy: .public)' (gen=\(request.generation, privacy: .public), conn=\(self.connectionTag, privacy: .public), \(representation.byteCount, privacy: .public) bytes)"
        )
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
            receiver?.cancel(generation: previous.generation)
        }
        // The host pasteboard may still hold this VM's own promised write for
        // the superseded offer, which the guest can no longer serve
        // (`request.stale`) — retract it rather than leave a paste that
        // silently serves nothing, and tell the user how to get the new copy.
        let retracted = retractStaleHostWrite?() ?? false
        if retracted {
            lastTransferIssue = .staleCopyRetracted()
            // With the write retracted, no earlier session's staging can be
            // backing a live pasteboard item any more.
            staging.reclaimSiblingRoots()
            Self.logger.notice(
                "Retracted the stale host-pasteboard promise for '\(self.label, privacy: .public)' (conn=\(self.connectionTag, privacy: .public)) superseded by guest offer gen=\(offer.generation, privacy: .public)"
            )
        }

        guard !offer.repInfo.isEmpty else {
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
        // A retraction's issue is the new offer's own explainer — keep it.
        if !retracted { lastTransferIssue = nil }
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

    /// A representation excluded from the receive side without reading a byte: a
    /// transient-marker / raw file-url UTI, or an inline payload with no bytes.
    ///
    /// The empty-payload skip is keyed on the *filename*, so it reaches only
    /// inline reps. A named rep is a file the paste creates, and an empty file is
    /// content native macOS copies; a folder's `byte_count` is an estimate of the
    /// tree's file bytes (`kernova.proto`), which a tree of empty files, bare
    /// subdirectories, or nothing at all makes 0 while the archive still carries
    /// the tree.
    private static func shouldSkip(_ info: Kernova_V1_ClipboardRepresentationInfo) -> Bool {
        (info.byteCount == 0 && info.filename.isEmpty)
            || ClipboardSnapshotPolicy.shouldSkipBeforeReading(uti: info.uti)
    }

    /// Whether a promised item serves this rep as `public.file-url` — the flavor
    /// whose bytes must pull, stage, and (for a folder) extract inside the OS
    /// pasteboard-promise deadline.
    ///
    /// `ClipboardPasteboardItemPlan` promises `.fileURL` for every promisable rep
    /// carrying a filename, so an image file — which also promises its image
    /// UTI inline — is one of them.
    private static func servesFileURL(_ info: Kernova_V1_ClipboardRepresentationInfo) -> Bool {
        !shouldSkip(info) && !info.filename.isEmpty
    }

    // MARK: - Lazy materialization (we are the receiver)

    /// Opens the progress session covering one materialization loop, or `nil` when
    /// the loop has nothing to pull.
    ///
    /// `pulling` is declared in full: another loop can claim a rep before this one
    /// reaches it, so ownership is settled per rep in `materialize`.
    private func openInboundSession(promise: InboundPromise, pulling indices: [Int])
        -> ClipboardProgressTracker.SessionToken?
    {
        guard !indices.isEmpty else { return nil }
        let units = indices.map { index -> ClipboardProgressTracker.PlannedUnit in
            let info = promise.reps[index]
            return ClipboardProgressTracker.PlannedUnit(
                id: UInt64(index), expectedBytes: info.byteCount,
                name: info.filename.isEmpty ? nil : info.filename)
        }
        return progress.openSession(direction: .inbound, peerName: label, units: units)
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
        let session = openInboundSession(
            promise: promise,
            pulling: promise.reps.indices.filter { index in
                Self.isEagerPreviewable(promise.reps[index]) && !Self.shouldSkip(promise.reps[index])
            })
        defer { if let session { progress.closeSession(session) } }
        var allSucceeded = true
        for (index, info) in promise.reps.enumerated() {
            guard inboundPromise === promise else { return }  // superseded
            guard Self.isEagerPreviewable(info), !Self.shouldSkip(info) else { continue }
            if await materialize(index: index, info: info, promise: promise, session: session) == nil {
                allSucceeded = false
            }
        }
        // Latch only on full success, so a transient pull failure is retried on the
        // next display trigger instead of leaving a rich rep as a chip.
        if allSucceeded { previewMaterializationStarted = promise.generation }
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

        let pasteBoundTotal = pasteBoundTotalBytes(for: promise)
        let limit = maxPasteBytes()
        let overBudget = pasteBoundTotal > UInt64(limit)
        if overBudget {
            Self.logger.warning(
                "Copy-to-Mac refused: \(ClipboardErrorCode.copyTooLarge.rawValue, privacy: .public) — paste-bound reps total \(pasteBoundTotal, privacy: .public) bytes, over the \(limit, privacy: .public)-byte cap; refusing the whole file set"
            )
            // The click reports its own outcome, but an automatic passthrough
            // publish has no return path — the issue is the only surface it has.
            lastTransferIssue = .overCopyBudget(limitBytes: limit)
        }

        var items: [CopyToMacItem] = []
        for (index, info) in promise.reps.enumerated() where !Self.shouldSkip(info) {
            let withholdsFileURL = overBudget && Self.servesFileURL(info)
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

    /// Total byte count of the offer's paste-bound reps — the ones served as
    /// `public.file-url`, whose bytes must pull, stage, and (for a folder)
    /// extract inside the OS pasteboard-promise deadline — against which the
    /// deadline-safe cap is compared.
    ///
    /// A directory rep contributes its stat-walk estimate, the honest measure of
    /// the extract the deadline also covers. The sum saturates, so an absurd
    /// declared total fails the cap rather than wrapping under it.
    private func pasteBoundTotalBytes(for promise: InboundPromise) -> UInt64 {
        var total: UInt64 = 0
        for info in promise.reps where Self.servesFileURL(info) {
            total = total.saturatingAdding(info.byteCount)
        }
        return total
    }

    /// The already-materialized representation for `(generation, repIndex)` of the
    /// live offer, or `nil` — the paste-time cache read that lets a provider fire
    /// reuse preview-pulled bytes (or an earlier flavor's pull) without touching
    /// the wire.
    @MainActor
    private func cachedMaterialized(
        generation: UInt64, repIndex: Int
    ) -> ClipboardContent.Representation? {
        guard let promise = inboundPromise, promise.generation == generation else { return nil }
        return promise.materialized[repIndex]
    }

    /// Whether a `.fileURL` fire for the live offer must be refused because the
    /// service has stopped with the offer's file set only partially
    /// materialized — all-or-nothing, so a multi-file paste after VM stop never
    /// silently lands a subset of the copied files.
    ///
    /// The file set is the offer's `.fileURL`-serving reps (every promisable rep
    /// with a filename, the ones a Finder paste creates files from). With the
    /// receiver gone the unmaterialized siblings can never arrive, so every
    /// file fire of the generation serves nothing and the first raises the
    /// transfer issue; a fully-materialized set keeps serving from the cache
    /// and staged files, and inline flavors keep serving regardless.
    @MainActor
    private func refusesPasteBoundFire(generation: UInt64) -> Bool {
        guard receiver == nil, let promise = inboundPromise, promise.generation == generation
        else { return false }
        let fileSet = promise.reps.indices.filter { Self.servesFileURL(promise.reps[$0]) }
        guard fileSet.contains(where: { promise.materialized[$0] == nil }) else { return false }
        if !promise.partialSetRefusalReported {
            promise.partialSetRefusalReported = true
            Self.logger.warning(
                "Clipboard paste fired for gen=\(generation, privacy: .public) of '\(self.label, privacy: .public)' (conn=\(self.connectionTag, privacy: .public)) after the service stopped with the file set partially materialized — \(ClipboardErrorCode.pasteIncompleteSet.rawValue, privacy: .public); serving nothing"
            )
            lastTransferIssue = .partialFileSetUnservable()
        }
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
            lastTransferIssue = .overCopyBudget(limitBytes: limit)
            return nil
        }
        return snapshot
    }

    /// Pulls representation `index` at most once across concurrent preview
    /// callers, caching and republishing on success.
    ///
    /// A second caller for an in-flight rep awaits the existing pull rather than
    /// minting a duplicate same-`transfer_id` request that would orphan a
    /// continuation.
    private func materialize(
        index: Int, info: Kernova_V1_ClipboardRepresentationInfo, promise: InboundPromise,
        session: ClipboardProgressTracker.SessionToken?
    ) async -> ClipboardContent.Representation? {
        // Neither early return moves a byte on this session's behalf, so both give
        // the unit back: left declared, it would sit in the denominator waiting on
        // events that never arrive.
        if let cached = promise.materialized[index] {
            if let session { progress.discardUnit(session: session, id: UInt64(index)) }
            return cached
        }
        if let existing = promise.inFlight[index] {
            if let session { progress.discardUnit(session: session, id: UInt64(index)) }
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
            await self.pull(
                repIndex: index, info: info, generation: promise.generation, session: session)
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
        repIndex: Int, info: Kernova_V1_ClipboardRepresentationInfo, generation: UInt64,
        session: ClipboardProgressTracker.SessionToken?
    ) async -> ClipboardContent.Representation? {
        guard let receiver else { return nil }
        if !info.isInline, !staging.hasCapacity(forByteCount: Int(clamping: info.byteCount)) {
            Self.logger.warning(
                "Not enough disk space to receive clipboard rep '\(info.uti, privacy: .public)' (\(info.byteCount, privacy: .public) bytes)"
            )
            lastTransferIssue = .diskFull(
                needed: info.byteCount, available: staging.availableCapacity())
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
        if let session {
            progress.unitBegan(
                session: session, id: UInt64(repIndex), expectedBytes: info.byteCount, name: label)
        }
        let rep: ClipboardContent.Representation? = await withCheckedContinuation { continuation in
            // Single-resume: the off-main awaiter, the on-main send-failure catch,
            // and the backstop timeout can all race a channel teardown, and a
            // double resume is a continuation-misuse crash.
            let pull = PullContinuation(
                continuation,
                onLiveRecord: { [tracker = progress] bytes, total in
                    guard let session else { return }
                    tracker.unitProgressed(
                        session: session, id: UInt64(repIndex),
                        bytesTransferred: UInt64(max(0, bytes)), totalBytes: UInt64(max(0, total)))
                })
            receiver.awaitTransfer(
                transferID,
                // A folder's bytes are an archive of its tree, extracted as they
                // arrive: the stream layer learns that here, from the offer this
                // side already read, rather than from the wire.
                extractsDirectoryNamed: info.isDirectory ? info.filename : nil,
                onComplete: { pull.resume($0) },
                onAbort: { [weak self] info in
                    // A volume that fills *during* the transfer; the pre-flight
                    // above covers the up-front case. Fires off the main actor.
                    if info.code == "disk.full" {
                        Task { @MainActor [weak self] in self?.recordPullDiskFull(info) }
                    } else if info.code == "extract.error" {
                        Task { @MainActor [weak self] in
                            self?.lastTransferIssue = .pasteFolderUnpackFailed()
                        }
                    }
                    pull.resume(nil)
                },
                // Re-arm the inactivity backstop on each chunk so a large
                // still-progressing transfer is never cut off mid-stream.
                // [large-paste]
                onProgress: { bytes, total in
                    pull.noteProgress(bytesReceived: bytes, totalBytes: total)
                })
            pull.armTimeout(
                Task {
                    // Inactivity window, not an absolute deadline: re-arm while
                    // chunks keep arriving, fire only after a full window of
                    // silence. A cancelled sleep (the pull resolved first) must
                    // NOT resume.
                    while true {
                        do { try await Task.sleep(for: .seconds(backstop)) } catch { return }
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
        if let session {
            progress.unitEnded(session: session, id: UInt64(repIndex), succeeded: rep != nil)
        }
        if rep != nil {
            // A healthy pull clears a stale issue, except the two kinds a
            // succeeding sibling does not disprove: a disk-full notice (another
            // rep may still have failed to arrive) and an outcome this side
            // produced (its own surface — an over-cap file set is refused, and a
            // paste that timed out stays failed, while the same offer's small
            // inline rep pulls fine).
            switch lastTransferIssue?.kind {
            case .diskFull, .localFailure: break
            case .peerReportedError, .staleCopyRetracted, .none: lastTransferIssue = nil
            }
        }
        return rep
    }

    /// Records a disk-full transfer issue for a pull that aborted mid-stream
    /// because the staging volume filled (the up-front case is set in `pull`).
    private func recordPullDiskFull(_ info: ClipboardStreamAbortInfo) {
        lastTransferIssue = .diskFull(from: info)
    }

    // MARK: - Synchronous blocking pull (paste-time provider)

    /// Immutable, `Sendable` snapshot of the state a synchronous file pull needs,
    /// captured on the main actor before the pull blocks its calling thread.
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
        let channel: VsockChannel
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
        guard let receiver else {
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
            pasteBoundTotal: pasteBoundTotalBytes(for: promise),
            receiver: receiver, channel: channel, staging: staging, timeout: lazyPullTimeout)
    }

    /// Abort codes that retire a pull rather than fail it: the local teardown or
    /// supersession `ClipboardStreamReceiver` reports, the sending side dropping
    /// a superseded offer, and the peer rejecting a request for a generation it
    /// has moved past.
    ///
    /// A paste fire raises no issue for these — whatever superseded the offer
    /// publishes its own explainer, and a teardown is not the user's problem to
    /// act on.
    // `nonisolated` so the blocking pull can read it off the main actor.
    nonisolated private static let retiringAbortCodes: Set<String> = [
        "cancelled", "superseded", "request.stale",
    ]

    /// Records a user-visible issue for a paste-time fire that will serve
    /// nothing.
    ///
    /// A provider fire has no return path to the gesture, so the issue the
    /// clipboard window renders is the only host-side account of why a paste
    /// produced nothing.
    nonisolated private func recordPasteIssue(_ issue: ClipboardTransferIssue) {
        onMain { self.lastTransferIssue = issue }
    }

    /// Synchronously pulls one file rep, blocking the calling thread until the
    /// streamed bytes land (or abort/time out), staged into the host container.
    ///
    /// Safe to call on main: the receiver's `awaitTransfer` handler fires off-main
    /// into the coordinator, never hopping to the thread this call blocks.
    /// `onProgress` is the **only** progress this function reports — the session
    /// owning the pull ends its own unit, and reporting here would double-count.
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
            recordPasteIssue(
                .diskFull(
                    needed: snapshot.byteCount,
                    available: snapshot.staging.availableCapacity()))
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
            // A folder's bytes are an archive of its tree, extracted as they
            // arrive: the stream layer learns that here, from the offer this side
            // already read, rather than from the wire.
            extractsDirectoryNamed: snapshot.isDirectory ? snapshot.filename : nil,
            onComplete: { rep in coordinator.deliver(transferID, rep) },
            onAbort: { abort in coordinator.abort(transferID, abort) },
            // Re-arm the inactivity backstop on each chunk so a large still-
            // streaming file is never timed out mid-transfer. [large-paste]
            onProgress: { bytes, total in
                coordinator.heartbeat(transferID)
                onProgress(UInt64(bytes), UInt64(total))
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
        switch outcome {
        case .delivered(let rep):
            return rep
        case .aborted(let abort):
            Self.logger.warning(
                "File clipboard pull \(transferID, privacy: .public) (conn=\(self.connectionTag, privacy: .public)) aborted (\(abort.code, privacy: .public))"
            )
            if abort.code == "disk.full" {
                recordPasteIssue(.diskFull(from: abort))
            } else if abort.code == "extract.error" {
                recordPasteIssue(.pasteFolderUnpackFailed())
            } else if !Self.retiringAbortCodes.contains(abort.code) {
                recordPasteIssue(.pasteTransferFailed())
            }
            return nil
        case .timedOut:
            receiver.cancelAwait(transferID)
            Self.logger.warning(
                "File clipboard pull \(transferID, privacy: .public) (conn=\(self.connectionTag, privacy: .public)) timed out"
            )
            recordPasteIssue(.pasteTimedOut())
            return nil
        case .cancelled:
            Self.logger.debug(
                "File clipboard pull \(transferID, privacy: .public) (conn=\(self.connectionTag, privacy: .public)) cancelled"
            )
            // No issue: a teardown or release retired the pull, and the
            // supersession that caused it raises its own explainer.
            // Nothing will ever deliver or abort this transferID now, so release
            // the registered awaiter rather than leaking it.
            receiver.cancelAwait(transferID)
            return nil
        case .superseded:
            // A newer pull for this id has taken over the awaiter/slot
            // registration — touch nothing keyed by `transferID`; the retry owns
            // it, must resolve on its own, and raises the issue for both fires if
            // it fails.
            Self.logger.debug(
                "File clipboard pull \(transferID, privacy: .public) (conn=\(self.connectionTag, privacy: .public)) superseded by a newer fetch"
            )
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
        guard let promise = inboundPromise, promise.generation == release.generation else { return }
        // The placeholder content stays in the window; a later Copy-to-Mac resolves
        // nothing.
        receiver?.cancel(generation: release.generation)
        // Wake any synchronous file pull blocked on the coordinator.
        lazyCoordinator.failAll()
        dropInboundPromise()
        // A release is a supersession: retract the now-unservable pasteboard
        // promise like a newer offer would. The released generation's staged
        // files ride the grace window rather than being swept (docs/CLIPBOARD.md
        // §3), so a paste mid-copy survives.
        if retractStaleHostWrite?() == true {
            lastTransferIssue = .staleCopyRetracted()
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
    /// materialization cache first, else the deadline-bound blocking pull.
    ///
    /// The cache/cap reads hop to main (they touch main-confined promise state);
    /// the blocking pull then runs on the calling thread, woken off-main by the
    /// receiver.
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
            let rep = pullWithOwnSession(snapshot)
        else { return nil }
        return pasteFileURL(for: rep, generation: generation)
    }

    /// Serves an inline pasteboard flavor's bytes for a promised rep at paste
    /// time: the materialization cache first, else the blocking pull.
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
            let rep = pullWithOwnSession(snapshot)
        else { return nil }
        return Self.residentBytes(of: rep)
    }

    /// Runs one paste-time blocking pull under its own single-transfer progress
    /// session (a paste has no other session to join), caching the delivered rep
    /// so the item's sibling flavors — and later fires — reuse it.
    nonisolated private func pullWithOwnSession(
        _ snapshot: LazyPullSnapshot
    ) -> ClipboardContent.Representation? {
        let tracker = onMain { self.progress }
        let repIndex = snapshot.repIndex
        let session = tracker.openSession(
            direction: .inbound, peerName: onMain { self.label },
            units: [
                ClipboardProgressTracker.PlannedUnit(
                    id: UInt64(repIndex), expectedBytes: snapshot.byteCount,
                    name: snapshot.filename.isEmpty ? nil : snapshot.filename)
            ])
        tracker.unitBegan(session: session, id: UInt64(repIndex))
        let rep = performBlockingPull(snapshot) { bytes, total in
            tracker.unitProgressed(
                session: session, id: UInt64(repIndex), bytesTransferred: bytes,
                totalBytes: total)
        }
        tracker.unitEnded(session: session, id: UInt64(repIndex), succeeded: rep != nil)
        tracker.closeSession(session)
        if let rep {
            onMain {
                guard let promise = self.inboundPromise,
                    promise.generation == snapshot.generation,
                    promise.materialized[repIndex] == nil
                else { return }
                promise.materialized[repIndex] = rep
                promise.materializeEpoch += 1
            }
        }
        return rep
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
            recordPasteIssue(.pasteFileStagingFailed())
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
            recordPasteIssue(.pasteFileStagingFailed())
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

/// Single-resume bridge from one inbound pull's three possible resumers — the
/// off-actor receiver delivery, the on-main send-failure `catch`, and the
/// backstop timeout — to its `CheckedContinuation`.
///
/// All three can race a channel teardown; the first `resume` wins and cancels the
/// timeout, so the continuation is resumed exactly once. `@unchecked Sendable`:
/// `lock` guards the continuation and the timer.
private final class PullContinuation: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ClipboardContent.Representation?, Never>?
    private var timeout: Task<Void, Never>?
    /// Set by `noteProgress` (a chunk landed), consumed by the backstop loop at
    /// each window boundary to re-arm instead of firing.
    private var progressed = false
    /// Records byte progress into the progress tracker *under `lock`*, atomically
    /// with the resolved check, so a chunk landing after the pull resolves can't
    /// resurrect a readout its terminal already ended.
    private let onLiveRecord: (@Sendable (Int, Int) -> Void)?

    init(
        _ continuation: CheckedContinuation<ClipboardContent.Representation?, Never>,
        onLiveRecord: (@Sendable (Int, Int) -> Void)? = nil
    ) {
        self.continuation = continuation
        self.onLiveRecord = onLiveRecord
    }

    /// Records that the transfer made progress, so the backstop loop keeps waiting
    /// past the next window boundary.
    ///
    /// Does nothing once the pull has resolved, so no late chunk reopens a unit
    /// its terminal already closed.
    func noteProgress(bytesReceived: Int, totalBytes: Int) {
        lock.withLock {
            guard continuation != nil else { return }
            progressed = true
            onLiveRecord?(bytesReceived, totalBytes)
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
