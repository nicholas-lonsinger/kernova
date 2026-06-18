import Foundation
import KernovaProtocol
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
/// This is the eager-pull stepping stone: on an inbound offer the host pulls
/// every representation immediately and updates `clipboardContent`. The lazy
/// "pull on Copy to Mac" path is a later change.
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

    /// The inbound generation currently being pulled, with its per-transfer
    /// progress.
    private var pendingInbound: InboundCollection?

    /// Digest of the last content we successfully announced; suppresses
    /// redundant offers.
    private var lastGrabbedDigest: Data?

    // `nonisolated` so the off-main `consume` loop can log; `Logger` is Sendable.
    nonisolated private static let logger = Logger(
        subsystem: "app.kernova", category: "VsockClipboardService")

    private static let errorCodeTransferFailure = "clipboard.transfer.send.failure"

    /// Collects the streamed representations of one inbound offer generation
    /// until every requested transfer finishes (or aborts), then commits.
    private final class InboundCollection {
        let generation: UInt64
        var pending: Set<UInt64>
        var received: [UInt64: ClipboardContent.Representation] = [:]

        init(generation: UInt64, pending: Set<UInt64>) {
            self.generation = generation
            self.pending = pending
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
            onComplete: { [weak self] transferID, representation in
                Task { @MainActor in self?.onTransferComplete(transferID, representation) }
            },
            onAbort: { [weak self] info in
                Task { @MainActor in self?.onTransferAbort(info) }
            })
        self.sender = sender
        self.receiver = receiver

        let channel = self.channel
        let label = self.label
        consumeTask = Task { [weak self] in
            await Self.consume(
                channel: channel, label: label, sender: sender, receiver: receiver,
                onControlFrame: { @MainActor frame in self?.handleControlFrame(frame) })
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
        pendingInbound = nil
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
        // A newer offer supersedes the previous one: cancel its in-flight
        // inbound transfers so their partial temp files are deleted rather than
        // leaked.
        if let previous = pendingInbound { receiver?.cancel(generation: previous.generation) }

        // Eager pull: request every representation now. A file rep gets a
        // free-space pre-flight first (Review Safeguard 4) so an over-budget
        // transfer never starts.
        var pending: Set<UInt64> = []
        // Advertise the real free-space ceiling; an unknown capacity maps to the
        // "no explicit ceiling" sentinel rather than 0 (which is a real, full
        // ceiling). [M2]
        let maxAccept =
            staging.availableCapacity().map { UInt64(clamping: $0) }
            ?? ClipboardStreamTuning.unlimitedAcceptByteCount
        var anyRequested = false
        for (index, info) in offer.repInfo.enumerated() {
            // The host is the receiver here, so it sets the direction bit. [H3]
            let transferID = ClipboardTransferID.make(
                generation: offer.generation, repIndex: index, hostMinted: true)
            if !info.isInline,
                !staging.hasCapacity(forByteCount: Int(clamping: info.byteCount))
            {
                Self.logger.warning(
                    "Skipping clipboard rep '\(info.uti, privacy: .public)' (\(info.byteCount, privacy: .public) bytes) — not enough disk space"
                )
                lastTransferIssue = ClipboardTransferIssue(
                    kind: .diskFull(
                        needed: Int(clamping: info.byteCount),
                        available: staging.availableCapacity().map { Int(clamping: $0) }),
                    date: Date())
                continue
            }
            var request = Frame()
            request.protocolVersion = 1
            request.clipboardRequest = Kernova_V1_ClipboardRequest.with {
                $0.generation = offer.generation
                $0.transferID = transferID
                $0.uti = info.uti
                $0.maxAcceptByteCount = maxAccept
            }
            do {
                try channel.send(request)
                pending.insert(transferID)
                anyRequested = true
            } catch {
                Self.logger.error(
                    "Failed to send clipboard request: \(error.localizedDescription, privacy: .public)"
                )
            }
        }

        guard anyRequested else {
            pendingInbound = nil
            return
        }
        pendingInbound = InboundCollection(generation: offer.generation, pending: pending)
        Self.logger.debug(
            "Requested \(pending.count, privacy: .public) clipboard rep(s) from '\(self.label, privacy: .public)' (gen=\(offer.generation, privacy: .public))"
        )
    }

    private func onTransferComplete(
        _ transferID: UInt64, _ representation: ClipboardContent.Representation
    ) {
        guard let collection = pendingInbound, collection.pending.contains(transferID) else {
            Self.logger.debug(
                "Completed clipboard transfer \(transferID, privacy: .public) no longer pending — dropping"
            )
            return
        }
        collection.received[transferID] = representation
        collection.pending.remove(transferID)
        if collection.pending.isEmpty { commitInbound(collection) }
    }

    private func onTransferAbort(_ info: ClipboardStreamAbortInfo) {
        guard let collection = pendingInbound, collection.pending.contains(info.transferID) else {
            // An abort for a transfer this connection no longer tracks (e.g. a
            // superseded generation) must not surface a UI issue. [L5]
            return
        }
        if info.code == "disk.full" {
            lastTransferIssue = ClipboardTransferIssue(
                kind: .diskFull(needed: info.neededBytes ?? 0, available: info.availableBytes),
                date: Date())
        }
        collection.pending.remove(info.transferID)
        Self.logger.warning(
            "Clipboard transfer \(info.transferID, privacy: .public) aborted (\(info.code, privacy: .public)) for '\(self.label, privacy: .public)'"
        )
        if collection.pending.isEmpty { commitInbound(collection) }
    }

    /// Assembles the collected representations (in offer order) and publishes
    /// them, re-validating the generation and connection first.
    private func commitInbound(_ collection: InboundCollection) {
        guard pendingInbound === collection else { return }
        pendingInbound = nil

        let representations =
            collection.received
            .sorted { ($0.key & 0xFFFF) < ($1.key & 0xFFFF) }
            .map(\.value)
        let sanitized = ClipboardSnapshotPolicy.sanitizedForApply(representations)
        guard !sanitized.isEmpty else {
            Self.logger.debug(
                "Inbound clipboard gen=\(collection.generation, privacy: .public) produced no usable representations"
            )
            return
        }
        let content = ClipboardContent(representations: sanitized)
        clipboardContent = content
        lastGrabbedDigest = nil
        // Clear a healthy transfer's stale issue, but keep a disk-full notice
        // visible — a representation still failed to arrive even if others did.
        if case .diskFull = lastTransferIssue?.kind {} else { lastTransferIssue = nil }
        Self.logger.notice(
            "Received guest clipboard content for '\(self.label, privacy: .public)' (\(content.representations.count, privacy: .public) reps, \(content.totalByteCount, privacy: .public) bytes)"
        )
    }

    private func handleRelease(_ release: Kernova_V1_ClipboardRelease) {
        if let collection = pendingInbound, collection.generation == release.generation {
            for transferID in collection.pending {
                receiver?.handleAbort(
                    .with {
                        $0.transferID = transferID
                        $0.code = "released"
                    })
            }
            pendingInbound = nil
            Self.logger.debug(
                "Guest released clipboard offer (gen=\(release.generation, privacy: .public)) for '\(self.label, privacy: .public)'"
            )
        }
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
