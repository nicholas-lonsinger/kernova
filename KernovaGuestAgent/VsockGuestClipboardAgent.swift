import AppKit
import Foundation
import KernovaProtocol
import UniformTypeIdentifiers

// MARK: - Pasteboard protocol

/// Subset of `NSPasteboard` actually used by `VsockGuestClipboardAgent`.
///
/// RATIONALE: `NSPasteboard.general` is a process-wide singleton with no
/// mockable surface; this protocol is the cheapest seam that lets tests run
/// without touching the developer's real clipboard.
protocol Pasteboard: AnyObject {
    var changeCount: Int { get }

    /// Types of the **first** pasteboard item, in fidelity order; empty when
    /// the pasteboard holds nothing. The agent models one logical item — see
    /// `ClipboardContent`.
    var firstItemTypes: [NSPasteboard.PasteboardType] { get }

    func data(forType type: NSPasteboard.PasteboardType) -> Data?

    @discardableResult func clearContents() -> Int

    /// Writes a single pasteboard item carrying every representation.
    @discardableResult
    func writeItem(representations: [(type: NSPasteboard.PasteboardType, data: Data)]) -> Bool
}

extension NSPasteboard: Pasteboard {
    var firstItemTypes: [NSPasteboard.PasteboardType] {
        pasteboardItems?.first?.types ?? []
    }

    // RATIONALE: NSPasteboard's own `data(forType:)` reads from "the first
    // pasteboard item that contains the type". The agent only queries types
    // reported by `firstItemTypes` (item 0), so the existing method satisfies
    // the protocol requirement with the intended item-0 semantics.

    func writeItem(representations: [(type: NSPasteboard.PasteboardType, data: Data)]) -> Bool {
        let item = NSPasteboardItem()
        for representation in representations {
            item.setData(representation.data, forType: representation.type)
        }
        return writeObjects([item])
    }
}

// MARK: - VsockGuestClipboardAgent

/// Guest-side clipboard agent that talks to the host's `VsockClipboardService`
/// on `KernovaVsockPort.clipboard` (49152).
///
/// Runs the offer/request/stream state machine symmetrically:
/// - Outbound: a 0.5 s `NSPasteboard` poll detects local clipboard changes,
///   snapshots the first item's representations (inline bytes, or a disk-backed
///   `.file` rep for a copied file — named, never read at offer time), and
///   announces them via a metadata-only `ClipboardOffer`. The host pulls each
///   representation with a `ClipboardRequest`, which the agent answers by
///   chunk-streaming the bytes.
/// - Inbound: when the host sends an offer the agent immediately requests each
///   representation; the streamed bytes reassemble in memory (inline) or to a
///   temp file (file) and are written to the guest's `NSPasteboard.general`.
///
/// Connection lifecycle (connect, retry on failure, EOF handling) is owned by
/// `VsockGuestClient`. This class layers the protocol on top.
///
/// All mutable state is accessed exclusively on the main dispatch queue.
// RATIONALE: @unchecked Sendable with DispatchQueue.main serialization is
// used because @MainActor is impractical here — the entry point is
// main.swift top-level code (nonisolated in Swift 6), not an @main app.
final class VsockGuestClipboardAgent: @unchecked Sendable {
    private static let logger = KernovaLogger(subsystem: "app.kernova.agent", category: "VsockGuestClipboardAgent")
    private static let pollingInterval: TimeInterval = 0.5

    private let client: VsockGuestClient
    private let pasteboard: Pasteboard

    // MARK: - Main-queue state

    /// Live channel for the current connection, if any.
    ///
    /// Nil between connections.
    private var liveChannel: VsockChannel?

    /// Streaming engine for the current connection.
    private var sender: ClipboardStreamSender?
    private var receiver: ClipboardStreamReceiver?

    #if DEBUG
    /// Exposes `liveChannel` as an internal read for tests that need to wait
    /// until the main-queue async assignment completes before driving polls.
    var liveChannelForTesting: VsockChannel? { liveChannel }

    /// Exposes the inbound generation currently being pulled, for tests.
    var pendingInboundGenerationForTesting: UInt64? { pendingInbound?.generation }
    #endif

    /// Counter for outbound offer generations.
    ///
    /// Starts at 1 so 0 is the "no current offer" sentinel.
    private var nextLocalGeneration: UInt64 = 1

    /// The most recent offer we sent the host, held until superseded so we can
    /// answer per-representation requests.
    private var pendingOutbound: (generation: UInt64, content: ClipboardContent)?

    /// Thread-safe mirror of the current outbound generation for the sender's
    /// off-queue supersession check.
    private let currentOutboundGeneration = AtomicGeneration()

    /// The inbound generation currently being pulled, with per-transfer progress.
    private var pendingInbound: InboundCollection?

    /// Last `NSPasteboard.changeCount` we observed; set after every poll and
    /// every host write so we don't echo our own content.
    private var lastPasteboardChangeCount: Int

    /// Digest of the most recent content we sent or wrote; suppresses re-offering
    /// after a host-driven write and redundant offers on an unchanged clipboard.
    private var lastSeenDigest: Data?

    /// Materializes streamed file payloads to local temp files; swept on
    /// connect/teardown/disable.
    private let staging: ClipboardFileStaging

    // RATIONALE: a *serial* queue (not `DispatchQueue.global`) for inbound
    // staging keeps two pipelined generations writing in arrival order, so an
    // older generation's late write can't clobber the newer one's directory.
    private let inboundStagingQueue = DispatchQueue(
        label: "app.kernova.agent.clipboard-inbound", qos: .userInitiated)

    private var pollingTimer: DispatchSourceTimer?

    /// Whether clipboard sync is currently allowed by host policy.
    ///
    /// Default
    /// `false` so the agent doesn't connect or poll until the host's first
    /// `PolicyUpdate(clipboardSharingEnabled: true)`. Mutated only on main.
    private var enabled: Bool = false

    #if DEBUG
    /// Test seam.
    var isEnabledForTesting: Bool { enabled }
    #endif

    /// Collects the streamed representations of one inbound offer generation.
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

    /// Production init — uses real `NSPasteboard.general` on the clipboard port.
    convenience init() {
        self.init(
            pasteboard: NSPasteboard.general,
            client: VsockGuestClient(port: KernovaVsockPort.clipboard, label: "clipboard")
        )
    }

    /// Designated init; tests inject a fake pasteboard and socketpair-backed
    /// client, and optionally a `freeSpaceProvider` to simulate a full disk and a
    /// `stagingTempRoot` to isolate the staging directory between parallel tests.
    init(
        pasteboard: Pasteboard, client: VsockGuestClient,
        freeSpaceProvider: ClipboardFileStaging.FreeSpaceProvider? = nil,
        stagingTempRoot: URL = FileManager.default.temporaryDirectory
    ) {
        self.pasteboard = pasteboard
        self.client = client
        self.staging = ClipboardFileStaging(
            label: "agent", tempRoot: stagingTempRoot, freeSpaceProvider: freeSpaceProvider)
        self.lastPasteboardChangeCount = pasteboard.changeCount
        // Default-disabled: pause the reconnect loop until the host enables.
        self.client.pause()
    }

    // MARK: - Lifecycle

    func start() {
        staging.sweep()
        client.start { [weak self] channel in
            await self?.serve(channel: channel)
        }
        Self.logger.notice("Vsock clipboard agent started")
    }

    /// Applies a host policy update for clipboard sharing.
    func setEnabled(_ enabled: Bool) {
        DispatchQueue.main.async { [weak self] in
            self?.applyEnabledOnMain(enabled)
        }
    }

    private func applyEnabledOnMain(_ enabled: Bool) {
        guard self.enabled != enabled else { return }
        self.enabled = enabled
        if enabled {
            client.resume()
            startPolling()
            Self.logger.notice("Clipboard sharing enabled by host policy")
        } else {
            client.pause()
            pollingTimer?.cancel()
            pollingTimer = nil
            teardownConnectionState()
            staging.sweep()
            Self.logger.notice("Clipboard sharing disabled by host policy")
        }
    }

    /// Tears down the connection and the poll timer.
    func stop() {
        client.stop()
        DispatchQueue.main.async { [weak self] in
            self?.pollingTimer?.cancel()
            self?.pollingTimer = nil
            self?.teardownConnectionState()
            self?.staging.sweep()
        }
        Self.logger.notice("Vsock clipboard agent stopped")
    }

    /// Clears per-connection streaming + pending state on the main queue.
    private func teardownConnectionState() {
        sender?.cancelAll()
        receiver?.cancelAll()
        sender = nil
        receiver = nil
        liveChannel = nil
        pendingOutbound = nil
        currentOutboundGeneration.set(0)
        pendingInbound = nil
    }

    // MARK: - Per-connection serve

    private func serve(channel: VsockChannel) async {
        // The engine is created off-main (its callbacks hop to main themselves);
        // only the published references are assigned on the main queue.
        let sender = ClipboardStreamSender(channel: channel)
        let receiver = ClipboardStreamReceiver(
            channel: channel, staging: self.staging,
            onComplete: { [weak self] transferID, representation in
                DispatchQueue.main.async {
                    self?.onTransferComplete(transferID, representation, channel: channel)
                }
            },
            onAbort: { [weak self] info in
                DispatchQueue.main.async { self?.onTransferAbort(info) }
            })
        await MainActor.run {
            self.liveChannel = channel
            self.sender = sender
            self.receiver = receiver
            self.pendingOutbound = nil
            self.currentOutboundGeneration.set(0)
            self.pendingInbound = nil
            // A brand-new host has no record of prior offers; re-announce.
            self.lastSeenDigest = nil
            self.lastPasteboardChangeCount = -1
        }
        Self.logger.notice("Vsock clipboard connected to host")

        do {
            for try await frame in channel.incoming where frame.protocolVersion == 1 {
                // High-frequency stream frames go straight to the thread-safe
                // engine off the main queue; only control frames hop to main.
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
                    // Route by the direction bit: a host-received id (bit set) is
                    // one this guest sends; otherwise this guest receives it. [H3]
                    if ClipboardTransferID.hostReceives(abort.transferID) {
                        sender.handleAbort(transferID: abort.transferID)
                    } else {
                        receiver.handleAbort(abort)
                    }
                default:
                    DispatchQueue.main.async { [weak self] in
                        self?.handleControlFrame(frame, channel: channel)
                    }
                }
            }
            Self.logger.notice("Vsock clipboard channel closed by host")
        } catch {
            Self.logger.warning(
                "Vsock clipboard channel ended with error: \(error.localizedDescription, privacy: .public)"
            )
        }

        await MainActor.run {
            if self.liveChannel === channel {
                self.teardownConnectionState()
            }
        }
    }

    // MARK: - Pasteboard polling (main queue)

    private func startPolling() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + Self.pollingInterval, repeating: Self.pollingInterval)
        timer.setEventHandler { [weak self] in
            self?.checkClipboardChange()
        }
        timer.resume()
        pollingTimer = timer
    }

    func checkClipboardChange() {
        guard let channel = liveChannel else { return }
        let currentCount = pasteboard.changeCount
        guard currentCount != lastPasteboardChangeCount else { return }

        // A copied *file* (Finder ⌘C) puts only a file URL on the pasteboard —
        // build a disk-backed rep from a stat (no read, no size cap); the bytes
        // are streamed later when the host requests them.
        if let candidate = fileExpansionCandidate() {
            let content = ClipboardContent(representations: [
                ClipboardContent.Representation(
                    uti: candidate.type.identifier, fileURL: candidate.url,
                    byteCount: candidate.byteCount, filename: candidate.filename)
            ])
            sendOfferIfNeeded(content, channel: channel, changeCount: currentCount)
            return
        }

        // Non-file snapshot. NSPasteboard reads run on the main queue.
        let raw: [(uti: String, data: Data)] = pasteboard.firstItemTypes.compactMap { type in
            guard !ClipboardSnapshotPolicy.shouldSkipBeforeReading(uti: type.rawValue) else {
                return nil
            }
            guard let data = pasteboard.data(forType: type) else { return nil }
            return (uti: type.rawValue, data: data)
        }
        let outcome = ClipboardSnapshotPolicy.evaluate(raw)

        if !outcome.skipped.isEmpty {
            let summary = outcome.skipped
                .map { "\($0.uti): \(String(describing: $0.reason))" }
                .joined(separator: ", ")
            Self.logger.notice(
                "Clipboard snapshot skipped \(outcome.skipped.count, privacy: .public) representation(s): \(summary, privacy: .public)"
            )
        }
        sendOfferIfNeeded(outcome.content, channel: channel, changeCount: currentCount)
    }

    /// Announces `content` to the host when it's non-empty and not an echo of
    /// what we last wrote/sent, advancing the dedup + change-count bookkeeping.
    private func sendOfferIfNeeded(
        _ content: ClipboardContent, channel: VsockChannel, changeCount: Int
    ) {
        guard !content.isEmpty else {
            lastPasteboardChangeCount = changeCount
            return
        }
        guard content.digest != lastSeenDigest else {
            lastPasteboardChangeCount = changeCount
            return
        }

        let generation = nextLocalGeneration
        var offer = Frame()
        offer.protocolVersion = 1
        offer.clipboardOffer = Kernova_V1_ClipboardOffer.with {
            $0.generation = generation
            $0.repInfo = content.representations.map(Self.repInfo(for:))
        }
        do {
            try channel.send(offer)
            nextLocalGeneration += 1
            if let previous = pendingOutbound { sender?.cancel(generation: previous.generation) }
            pendingOutbound = (generation: generation, content: content)
            currentOutboundGeneration.set(generation)
            lastSeenDigest = content.digest
            lastPasteboardChangeCount = changeCount
            Self.logger.notice(
                "Sent clipboard offer (gen=\(generation, privacy: .public), \(content.representations.count, privacy: .public) reps, \(content.totalByteCount, privacy: .public) bytes)"
            )
        } catch {
            Self.logger.warning(
                "Failed to send clipboard offer: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Cheap main-queue metadata check for a single copied *file*.
    ///
    /// Returns the file URL, content type, name, and stat'd size when the first
    /// item is one on-disk file — with no size cap, since the bytes are streamed
    /// on demand rather than read here. A file already inside our own staging
    /// root (one we materialized from a prior inbound paste) is skipped so it
    /// can't be offered back to the host (echo suppression for files).
    private func fileExpansionCandidate() -> (url: URL, type: UTType, filename: String, byteCount: Int)? {
        guard pasteboard.firstItemTypes.contains(.fileURL),
            let urlData = pasteboard.data(forType: .fileURL),
            let urlString = String(data: urlData, encoding: .utf8),
            let url = URL(string: urlString), url.isFileURL
        else { return nil }

        guard !staging.isInStagingRoot(url) else { return nil }

        guard let values = try? url.resourceValues(forKeys: [.contentTypeKey, .fileSizeKey]),
            let type = values.contentType
        else { return nil }

        let size = values.fileSize ?? 0
        guard size > 0 else { return nil }
        return (url: url, type: type, filename: url.lastPathComponent, byteCount: size)
    }

    // MARK: - Frame handlers (main queue)

    /// Handles the control frames the consume loop hops to the main queue for
    /// (stream frames are routed off-main directly to the engine).
    private func handleControlFrame(_ frame: Frame, channel: VsockChannel) {
        switch frame.payload {
        case .clipboardOffer(let offer):
            handleOffer(offer, channel: channel)
        case .clipboardRequest(let request):
            handleRequest(request)
        case .clipboardRelease(let release):
            handleRelease(release)
        case .error(let error):
            Self.logger.warning(
                "Host clipboard error: \(error.code, privacy: .public) — \(error.message, privacy: .public)"
            )
        case .clipboardStreamBegin, .clipboardChunk, .clipboardStreamEnd, .clipboardStreamAck,
            .clipboardStreamAbort:
            // Routed off-main by the consume loop; never reaches here.
            break
        case .hello, .heartbeat, .policyUpdate, .logRecord, .none:
            Self.logger.warning("Unexpected payload on clipboard channel — wrong port")
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
                "Clipboard request transfer_id \(request.transferID, privacy: .public) out of range"
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
            isInline: Self.shouldInline(representation),
            isCurrent: { value in generation.isCurrent(value) })
        Self.logger.debug(
            "Streaming clipboard rep \(repIndex, privacy: .public) (gen=\(request.generation, privacy: .public), \(representation.byteCount, privacy: .public) bytes)"
        )
    }

    // MARK: - Inbound (we are the receiver)

    private func handleOffer(_ offer: Kernova_V1_ClipboardOffer, channel: VsockChannel) {
        // A newer offer supersedes the previous one: cancel its in-flight inbound
        // transfers so their partial temp files are deleted rather than leaked.
        if let previous = pendingInbound { receiver?.cancel(generation: previous.generation) }

        var pending: Set<UInt64> = []
        // Advertise the real free-space ceiling; an unknown capacity maps to the
        // "no explicit ceiling" sentinel rather than 0 (a real, full ceiling). [M2]
        let maxAccept =
            staging.availableCapacity().map { UInt64(clamping: $0) }
            ?? ClipboardStreamTuning.unlimitedAcceptByteCount
        for (index, info) in offer.repInfo.enumerated() {
            // The guest is the receiver here, so it does not set the direction
            // bit (only the host does). [H3]
            let transferID = ClipboardTransferID.make(
                generation: offer.generation, repIndex: index, hostMinted: false)
            if !info.isInline, !staging.hasCapacity(forByteCount: Int(clamping: info.byteCount)) {
                Self.logger.warning(
                    "Skipping clipboard rep '\(info.uti, privacy: .public)' (\(info.byteCount, privacy: .public) bytes) — not enough disk space"
                )
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
            } catch {
                Self.logger.warning(
                    "Failed to send clipboard request: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        guard !pending.isEmpty else {
            pendingInbound = nil
            return
        }
        pendingInbound = InboundCollection(generation: offer.generation, pending: pending)
        Self.logger.debug(
            "Requested \(pending.count, privacy: .public) clipboard rep(s) from host (gen=\(offer.generation, privacy: .public))"
        )
    }

    private func onTransferComplete(
        _ transferID: UInt64, _ representation: ClipboardContent.Representation,
        channel: VsockChannel
    ) {
        guard liveChannel === channel else { return }
        guard let collection = pendingInbound, collection.pending.contains(transferID) else {
            return
        }
        collection.received[transferID] = representation
        collection.pending.remove(transferID)
        if collection.pending.isEmpty { finishInbound(collection, channel: channel) }
    }

    private func onTransferAbort(_ info: ClipboardStreamAbortInfo) {
        guard let collection = pendingInbound, collection.pending.contains(info.transferID) else {
            return
        }
        collection.pending.remove(info.transferID)
        Self.logger.warning(
            "Inbound clipboard transfer \(info.transferID, privacy: .public) aborted (\(info.code, privacy: .public))"
        )
        if collection.pending.isEmpty {
            if let channel = liveChannel { finishInbound(collection, channel: channel) }
        }
    }

    /// Assembles the collected representations and writes them to the
    /// pasteboard.
    ///
    /// File URLs are materialized off the main queue (the `.file`
    /// reps are already staged; inline filename-bearing reps — e.g. image files
    /// shown in place yet also pasteable as files — are staged here).
    private func finishInbound(_ collection: InboundCollection, channel: VsockChannel) {
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
        let generation = collection.generation
        let staging = self.staging
        inboundStagingQueue.async { [weak self] in
            let pairs = Self.pasteboardPairs(for: content, generation: generation, staging: staging)
            DispatchQueue.main.async {
                self?.applyPairs(pairs, content: content, channel: channel)
            }
        }
    }

    /// Builds the (type, data) pairs to write for `content`, materializing file
    /// URLs.
    ///
    /// Runs off the main queue.
    private static func pasteboardPairs(
        for content: ClipboardContent, generation: UInt64, staging: ClipboardFileStaging
    ) -> [(type: NSPasteboard.PasteboardType, data: Data)] {
        var pairs: [(type: NSPasteboard.PasteboardType, data: Data)] = []
        for representation in content.representations {
            if shouldInline(representation), let data = representation.inMemoryData {
                pairs.append(
                    (type: NSPasteboard.PasteboardType(rawValue: representation.uti), data: data))
            }
            guard !representation.filename.isEmpty else { continue }
            let fileURL: URL?
            if let existing = representation.fileURL {
                fileURL = existing  // already streamed to a temp file by the receiver
            } else if let data = representation.inMemoryData,
                let sink = try? staging.makeSink(
                    generation: generation, filename: representation.filename)
            {
                // Inline payload (e.g. image file) also offered as a file URL.
                try? sink.write(data)
                fileURL = try? sink.commit()
            } else {
                fileURL = nil
            }
            if let fileURL {
                pairs.append((type: .fileURL, data: Data(fileURL.absoluteString.utf8)))
            }
        }
        return pairs
    }

    /// Writes the assembled pairs to the pasteboard and records dedup state.
    private func applyPairs(
        _ pairs: [(type: NSPasteboard.PasteboardType, data: Data)],
        content: ClipboardContent, channel: VsockChannel
    ) {
        guard liveChannel === channel else { return }
        guard !pairs.isEmpty else {
            Self.logger.warning(
                "Clipboard apply produced no pasteboard representations; leaving the pasteboard untouched"
            )
            return
        }
        pasteboard.clearContents()
        let written = pasteboard.writeItem(representations: pairs)
        guard written else {
            Self.logger.warning(
                "Failed to write host clipboard to pasteboard (\(content.totalByteCount, privacy: .public) bytes). Echo-suppression state preserved."
            )
            return
        }
        lastPasteboardChangeCount = pasteboard.changeCount
        lastSeenDigest = content.digest
        Self.logger.notice(
            "Wrote host clipboard to pasteboard (\(content.representations.count, privacy: .public) reps, \(content.totalByteCount, privacy: .public) bytes)"
        )
    }

    /// Whether a representation's bytes should be written inline (vs. carried
    /// only as a materialized file URL).
    ///
    /// Non-file content and image file
    /// payloads inline; every other file payload is file-only.
    static func shouldInline(_ representation: ClipboardContent.Representation) -> Bool {
        if representation.filename.isEmpty { return true }
        return UTType(representation.uti)?.conforms(to: .image) == true
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
                "Host released clipboard offer (gen=\(release.generation, privacy: .public))"
            )
        }
    }

    // MARK: - Helpers

    private static func repInfo(
        for representation: ClipboardContent.Representation
    ) -> Kernova_V1_ClipboardRepresentationInfo {
        Kernova_V1_ClipboardRepresentationInfo.with {
            $0.uti = representation.uti
            $0.byteCount = UInt64(representation.byteCount)
            $0.filename = representation.filename
            $0.isInline = shouldInline(representation)
        }
    }
}
