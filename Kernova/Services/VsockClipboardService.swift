import Foundation
import KernovaProtocol
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

    var supportsBinaryRepresentations: Bool { true }

    // MARK: - Private state

    private let channel: VsockChannel
    private let label: String
    private let staging: ClipboardFileStaging

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

    // `nonisolated` so the off-main `consume` loop can log; `Logger` is Sendable.
    nonisolated private static let logger = Logger(
        subsystem: "app.kernova", category: "VsockClipboardService")

    private static let errorCodeTransferFailure = "clipboard.transfer.send.failure"

    /// One promised guest offer.
    ///
    /// Holds its representation metadata (indexed exactly as the guest offered
    /// them, so a `transfer_id`'s rep index stays valid) and the representations
    /// materialized so far. Each rep is pulled at most once.
    private final class InboundPromise {
        let generation: UInt64
        let reps: [Kernova_V1_ClipboardRepresentationInfo]
        var materialized: [Int: ClipboardContent.Representation] = [:]
        /// Pulls in flight, keyed by rep index, so concurrent preview/copy callers
        /// share one pull per rep instead of minting a duplicate (same-transfer_id)
        /// request that would orphan a continuation.
        var inFlight: [Int: Task<ClipboardContent.Representation?, Never>] = [:]

        init(generation: UInt64, reps: [Kernova_V1_ClipboardRepresentationInfo]) {
            self.generation = generation
            self.reps = reps
        }
    }

    // MARK: - Init

    /// - Parameters:
    ///   - channel: the vsock channel carrying clipboard frames.
    ///   - label: identifies this service's staging area and log context.
    ///   - freeSpaceProvider: injected in tests to simulate a full disk;
    ///     `nil` uses the real volume free-space query.
    init(
        channel: VsockChannel, label: String,
        freeSpaceProvider: ClipboardFileStaging.FreeSpaceProvider? = nil
    ) {
        self.channel = channel
        self.label = label
        self.staging = ClipboardFileStaging(
            label: "host-\(label)", freeSpaceProvider: freeSpaceProvider)
    }

    // MARK: - Lifecycle

    func start() {
        guard consumeTask == nil else { return }
        staging.sweep()
        isConnected = true

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
            // now never arrive, so an async materialize doesn't hang forever.
            receiver.cancelAll()
        }
        Self.logger.notice("Vsock clipboard service started for '\(self.label, privacy: .public)'")
    }

    func stop() {
        consumeTask?.cancel()
        consumeTask = nil
        sender?.cancelAll()
        receiver?.cancelAll()
        sender = nil
        receiver = nil
        channel.close()
        isConnected = false
        pendingOutbound = nil
        currentOutboundGeneration.set(0)
        inboundPromise = nil
        previewMaterializationStarted = 0
        staging.sweep()
        Self.logger.notice("Vsock clipboard service stopped for '\(self.label, privacy: .public)'")
    }

    // MARK: - Public API

    func clearBuffer() {
        clipboardContent = .empty
        lastGrabbedDigest = nil
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
        let content = clipboardContent

        var offer = Frame()
        offer.protocolVersion = 1
        offer.clipboardOffer = Kernova_V1_ClipboardOffer.with {
            $0.generation = generation
            $0.repInfo = content.representations.map(Self.repInfo(for:))
        }

        do {
            try channel.send(offer)
            nextLocalGeneration += 1
            // Supersede any in-flight outbound transfer for the previous offer.
            if let previous = pendingOutbound { sender?.cancel(generation: previous.generation) }
            pendingOutbound = (generation: generation, content: content)
            currentOutboundGeneration.set(generation)
            lastGrabbedDigest = content.digest
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
            return
        }
        let repIndex = Int(request.transferID & 0xFFFF)
        guard repIndex < pending.content.representations.count else {
            Self.logger.warning(
                "Clipboard request transfer_id \(request.transferID, privacy: .public) out of range for gen=\(request.generation, privacy: .public)"
            )
            return
        }
        let representation = pending.content.representations[repIndex]
        guard representation.uti == request.uti else {
            Self.logger.warning(
                "Clipboard request uti '\(request.uti, privacy: .public)' doesn't match offered rep \(repIndex, privacy: .public)"
            )
            return
        }

        let generation = currentOutboundGeneration
        sender?.startTransfer(
            transferID: request.transferID,
            generation: request.generation,
            representation: representation,
            maxAcceptByteCount: request.maxAcceptByteCount,
            isInline: representation.shouldInlineOnPasteboard,
            isCurrent: { generationValue in generation.isCurrent(generationValue) })
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
            inboundPromise = nil
            return
        }
        // Publish metadata-only placeholders immediately so the window shows the
        // chips without waiting; renderable reps are pulled on display and the
        // rest on Copy-to-Mac. The reps keep the guest's offer order so a
        // transfer_id's rep index stays valid against the guest's offer.
        let promise = InboundPromise(generation: offer.generation, reps: offer.repInfo)
        inboundPromise = promise
        previewMaterializationStarted = 0
        republish(promise)
        lastTransferIssue = nil
        Self.logger.notice(
            "Received guest clipboard offer for '\(self.label, privacy: .public)' (gen=\(offer.generation, privacy: .public), \(offer.repInfo.count, privacy: .public) reps) — metadata only"
        )
    }

    /// Rebuilds `clipboardContent` from the promise: each rep is its materialized
    /// form when pulled, else a `.pendingRemote` placeholder.
    ///
    /// Marks the result as already-grabbed so received content is never offered
    /// back to the guest.
    private func republish(_ promise: InboundPromise) {
        var reps: [ClipboardContent.Representation] = []
        // Drop identity-skip types (transient markers, raw public.file-url) so
        // a peer can't smuggle them onto the host pasteboard — the receive-side
        // sanitization the eager path applied. Indices into `promise.reps`
        // stay valid for pulls; only the published view filters.
        for (index, info) in promise.reps.enumerated() where !Self.shouldSkip(info) {
            reps.append(
                promise.materialized[index]
                    ?? ClipboardContent.Representation(
                        pendingRemoteUTI: info.uti, byteCount: Int(clamping: info.byteCount),
                        filename: info.filename))
        }
        let content = ClipboardContent(representations: reps)
        clipboardContent = content
        lastGrabbedDigest = content.digest
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
        guard let promise = inboundPromise else { return }
        guard previewMaterializationStarted != promise.generation else { return }
        previewMaterializationStarted = promise.generation
        for (index, info) in promise.reps.enumerated() {
            guard inboundPromise === promise else { return }  // superseded
            guard Self.isEagerPreviewable(info), !Self.shouldSkip(info) else { continue }
            _ = await materialize(index: index, info: info, promise: promise)
        }
    }

    /// Pulls every not-yet-materialized representation and returns the fully
    /// resolved content for "Copy to Mac".
    ///
    /// A rep that can't be pulled (disk full, abort, supersession) is dropped from
    /// the result.
    func materializeForCopy() async -> ClipboardContent {
        guard let promise = inboundPromise else { return clipboardContent }
        // Collect each pull's RETURN value rather than re-reading
        // `promise.materialized`: a caller that coalesces onto an in-flight pull
        // gets the rep back before the owning call writes the cache, so rebuilding
        // from the cache here could silently drop a just-pulled rep.
        var resolved: [ClipboardContent.Representation] = []
        for (index, info) in promise.reps.enumerated() {
            guard inboundPromise === promise else { return clipboardContent }
            guard !Self.shouldSkip(info) else { continue }
            if let rep = await materialize(index: index, info: info, promise: promise) {
                resolved.append(rep)
            }
        }
        return ClipboardContent(representations: resolved)
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
        promise.inFlight[index] = nil
        guard inboundPromise === promise else { return rep }
        if let rep {
            promise.materialized[index] = rep
            republish(promise)
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
        let rep: ClipboardContent.Representation? = await withCheckedContinuation { continuation in
            receiver.awaitTransfer(
                transferID,
                onComplete: { rep in continuation.resume(returning: rep) },
                onAbort: { _ in continuation.resume(returning: nil) })
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
                continuation.resume(returning: nil)
            }
        }
        if rep != nil {
            // A healthy pull clears a stale issue, but a disk-full notice stays
            // visible — another rep may still have failed to arrive.
            if case .diskFull = lastTransferIssue?.kind {} else { lastTransferIssue = nil }
        }
        return rep
    }

    /// Whether the window renders this rep richly, so it's worth pulling for the
    /// preview: text within the editor limit, inline RTF, or an image up to the
    /// preview limit.
    ///
    /// Files (non-image) and over-limit payloads stay placeholders.
    private static func isEagerPreviewable(_ info: Kernova_V1_ClipboardRepresentationInfo) -> Bool {
        let type = UTType(info.uti)
        if type?.conforms(to: .image) == true {
            return info.byteCount <= UInt64(ClipboardPreviewPolicy.maxEagerPreviewBytes)
        }
        // A non-image file renders as a chip from metadata — no pull needed.
        guard info.filename.isEmpty else { return false }
        if type?.conforms(to: .rtf) == true {
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
        inboundPromise = nil
        previewMaterializationStarted = 0
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
        }
    }
}
