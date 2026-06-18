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

    /// Writes a single pasteboard item that **promises** the given types, lazily
    /// served by `provider` when the OS asks for one.
    ///
    /// The lazy inbound path: a host offer registers promises and pulls no bytes;
    /// each `NSPasteboardItemDataProvider.pasteboard(_:item:provideDataForType:)`
    /// callback streams the requested representation on demand.
    @discardableResult
    func writeItem(
        promisedTypes types: [NSPasteboard.PasteboardType],
        provider: NSPasteboardItemDataProvider
    ) -> Bool
}

extension NSPasteboard: Pasteboard {
    var firstItemTypes: [NSPasteboard.PasteboardType] {
        pasteboardItems?.first?.types ?? []
    }

    // RATIONALE: NSPasteboard's own `data(forType:)` reads from "the first
    // pasteboard item that contains the type". The agent only queries types
    // reported by `firstItemTypes` (item 0), so the existing method satisfies
    // the protocol requirement with the intended item-0 semantics.

    func writeItem(
        promisedTypes types: [NSPasteboard.PasteboardType],
        provider: NSPasteboardItemDataProvider
    ) -> Bool {
        let item = NSPasteboardItem()
        item.setDataProvider(provider, forTypes: types)
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

    /// Exposes the current inbound promise generation, for tests.
    var inboundPromiseGenerationForTesting: UInt64? { inboundPromise?.generation }
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

    /// The host offer currently promised on the guest pasteboard, with its
    /// per-representation materialization cache.
    ///
    /// Pulled lazily on demand.
    private var inboundPromise: InboundPromise?

    /// Bridges the synchronous `provideDataForType` callback to the off-actor
    /// stream receive, blocking the main thread until bytes land.
    private let lazyCoordinator = LazyPullCoordinator()

    /// Data providers still promised on the pasteboard, kept alive until
    /// `pasteboardFinishedWithDataProvider` fires (Apple requires it).
    ///
    /// Touched only on main.
    private var liveProviders: Set<LazyClipboardDataProvider> = []

    /// Last `NSPasteboard.changeCount` we observed; set after every poll and
    /// every host write so we don't echo our own content.
    private var lastPasteboardChangeCount: Int

    /// Digest of the most recent content we offered the host; suppresses
    /// redundant outbound offers on an unchanged clipboard.
    ///
    /// In the lazy model the immediate echo of a host-driven write is suppressed
    /// by the `changeCount` captured in `handleOffer`, not by this digest (the
    /// guest holds no resident bytes at offer time to digest); it is written only
    /// by the outbound `sendOfferIfNeeded` and reset on reconnect.
    private var lastSeenDigest: Data?

    /// Materializes streamed file payloads to local temp files; swept on
    /// connect/teardown/disable.
    private let staging: ClipboardFileStaging

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

    /// One promised inbound offer: its representation metadata and the
    /// representations materialized so far (each pulled at most once, then
    /// served to every promised type it backs).
    ///
    /// Touched only on main.
    private final class InboundPromise {
        let generation: UInt64
        let reps: [Kernova_V1_ClipboardRepresentationInfo]
        var materialized: [Int: ClipboardContent.Representation] = [:]

        init(generation: UInt64, reps: [Kernova_V1_ClipboardRepresentationInfo]) {
            self.generation = generation
            self.reps = reps
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
        // Unblock any provider thread waiting on a pull (returns empty).
        lazyCoordinator.failAll()
        sender = nil
        receiver = nil
        liveChannel = nil
        pendingOutbound = nil
        currentOutboundGeneration.set(0)
        inboundPromise = nil
        // liveProviders are NOT dropped here: Apple requires a data provider stay
        // alive while its item is still on the pasteboard. They're released when
        // pasteboardFinishedWithDataProvider fires (a later offer/clear overwrites
        // the promise).
    }

    // MARK: - Per-connection serve

    private func serve(channel: VsockChannel) async {
        // The engine is created off-main (its callbacks hop to main themselves);
        // only the published references are assigned on the main queue.
        let sender = ClipboardStreamSender(channel: channel)
        let receiver = ClipboardStreamReceiver(
            channel: channel, staging: self.staging,
            // Lazy inbound pulls register a per-transfer awaiter (via
            // LazyPullCoordinator) that takes precedence over these channel-wide
            // closures, so they fire only for an unexpected unawaited transfer.
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
        await MainActor.run {
            self.liveChannel = channel
            self.sender = sender
            self.receiver = receiver
            self.pendingOutbound = nil
            self.currentOutboundGeneration.set(0)
            self.inboundPromise = nil
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
                    // RATIONALE: clipboard control frames (offer/request/release/
                    // error) are intentionally serialized on the main queue, so
                    // while a synchronous `provideData` pull blocks main they queue
                    // behind it. The blocking pull is bounded by `lazyPullTimeout`,
                    // so a no-Begin host can't freeze the guest indefinitely; a
                    // follow-up issue tracks bounding the pre-Begin case below that
                    // 120 s ceiling.
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

        // Wake any pull blocked on a now-dead transfer immediately, off-main —
        // teardownConnectionState runs on main, which a blocked provider holds.
        self.lazyCoordinator.failAll()
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

    /// Registers a host offer as lazy promises on the guest pasteboard, pulling
    /// no bytes.
    ///
    /// One `NSPasteboardItem` is written whose promised types are backed by a
    /// `LazyClipboardDataProvider`; each representation is streamed only when the
    /// OS asks for it (`provideData`). The post-write `changeCount` is recorded
    /// immediately so the 0.5 s poll does not read — and thereby self-trigger —
    /// our own promise (echo suppression at promise time).
    private func handleOffer(_ offer: Kernova_V1_ClipboardOffer, channel: VsockChannel) {
        // A newer offer supersedes the previous one. Pulls are synchronous on
        // main, so no inbound transfer can be in flight here, but cancel + failAll
        // defensively and drop the stale promise/cache.
        if let previous = inboundPromise {
            receiver?.cancel(generation: previous.generation)
            lazyCoordinator.failAll()
        }

        let promisedTypes = Self.promisedTypes(for: offer.repInfo)
        guard !promisedTypes.isEmpty else {
            inboundPromise = nil
            return
        }

        let promise = InboundPromise(generation: offer.generation, reps: offer.repInfo)
        inboundPromise = promise
        let generation = offer.generation
        let provider = LazyClipboardDataProvider(
            provide: { [weak self] type in self?.provideData(type, generation: generation) },
            onFinished: { [weak self] provider in self?.providerFinished(provider) })
        liveProviders.insert(provider)

        pasteboard.clearContents()
        let written = pasteboard.writeItem(promisedTypes: promisedTypes, provider: provider)
        // Capture the bumped changeCount whether or not the write reported
        // success, so a partial write can't leave the poll re-offering. [Safeguard 2]
        lastPasteboardChangeCount = pasteboard.changeCount
        guard written else {
            Self.logger.warning(
                "Failed to register host clipboard promise (gen=\(generation, privacy: .public))")
            liveProviders.remove(provider)
            inboundPromise = nil
            return
        }
        Self.logger.notice(
            "Registered host clipboard promise (gen=\(generation, privacy: .public), \(promisedTypes.count, privacy: .public) type(s))"
        )
    }

    /// Streams the bytes for a promised pasteboard type on demand.
    ///
    /// Runs synchronously on the agent's main thread (the pasteboard server's
    /// `provideDataForType` callback). Pulls the backing representation at most
    /// once per offer — caching it so an image rep promised as both its UTI and
    /// `public.file-url` is fetched a single time — then formats it for the
    /// requested type. Returns `nil` (empty) on a stale generation, a failed
    /// pull, or a type we never promised.
    private func provideData(
        _ type: NSPasteboard.PasteboardType, generation: UInt64
    ) -> Data? {
        guard let promise = inboundPromise, promise.generation == generation else {
            Self.logger.debug(
                "provideData for stale clipboard generation \(generation, privacy: .public)")
            return nil
        }
        guard let channel = liveChannel, let receiver = receiver else { return nil }
        guard let repIndex = Self.repIndex(for: type, in: promise.reps) else {
            Self.logger.warning(
                "provideData for unpromised type '\(type.rawValue, privacy: .public)'")
            return nil
        }

        let representation: ClipboardContent.Representation
        if let cached = promise.materialized[repIndex] {
            representation = cached
        } else {
            guard
                let pulled = pullRepresentation(
                    repIndex, promise: promise, channel: channel, receiver: receiver)
            else { return nil }
            promise.materialized[repIndex] = pulled
            representation = pulled
        }

        if type == .fileURL {
            return fileURLData(from: representation, generation: generation)
        }
        return representation.inMemoryData
    }

    /// Sends one `ClipboardRequest` and blocks the main thread until the streamed
    /// representation lands (or aborts/times out).
    ///
    /// The deadlock-safe wakeup: a per-transfer `awaitTransfer` handler on the
    /// receiver fires off-main (the receiver's queue) into the coordinator, never
    /// hopping to the main thread this call holds. The free-space pre-flight runs
    /// here, before the request, so an over-budget file rep never starts a
    /// transfer. [Safeguard 4]
    private func pullRepresentation(
        _ repIndex: Int, promise: InboundPromise, channel: VsockChannel,
        receiver: ClipboardStreamReceiver
    ) -> ClipboardContent.Representation? {
        let info = promise.reps[repIndex]
        if !info.isInline, !staging.hasCapacity(forByteCount: Int(clamping: info.byteCount)) {
            Self.logger.warning(
                "Not enough disk space to receive clipboard rep '\(info.uti, privacy: .public)' (\(info.byteCount, privacy: .public) bytes)"
            )
            return nil
        }
        // The guest is the receiver, so it does not set the direction bit. [H3]
        let transferID = ClipboardTransferID.make(
            generation: promise.generation, repIndex: repIndex, hostMinted: false)
        let maxAccept =
            staging.availableCapacity().map { UInt64(clamping: $0) }
            ?? ClipboardStreamTuning.unlimitedAcceptByteCount

        let coordinator = lazyCoordinator
        receiver.awaitTransfer(
            transferID,
            onComplete: { rep in coordinator.deliver(transferID, rep) },
            onAbort: { abort in coordinator.abort(transferID, abort) })

        let outcome = lazyCoordinator.pull(transferID: transferID) {
            var request = Frame()
            request.protocolVersion = 1
            request.clipboardRequest = Kernova_V1_ClipboardRequest.with {
                $0.generation = promise.generation
                $0.transferID = transferID
                $0.uti = info.uti
                $0.maxAcceptByteCount = maxAccept
            }
            do {
                try channel.send(request)
            } catch {
                Self.logger.warning(
                    "Failed to send clipboard request: \(error.localizedDescription, privacy: .public)"
                )
                // No request went out, so no reply will arrive — resolve the pull
                // now instead of blocking the main thread to the backstop timeout.
                receiver.cancelAwait(transferID)
                coordinator.abort(
                    transferID,
                    ClipboardStreamAbortInfo(
                        transferID: transferID, code: "send.failed",
                        message: "Failed to send clipboard request", neededBytes: nil,
                        availableBytes: nil))
            }
        }

        switch outcome {
        case .delivered(let representation):
            return representation
        case .aborted(let abort):
            Self.logger.warning(
                "Inbound clipboard pull \(transferID, privacy: .public) aborted (\(abort.code, privacy: .public))"
            )
        case .timedOut:
            receiver.cancelAwait(transferID)
            Self.logger.warning("Inbound clipboard pull \(transferID, privacy: .public) timed out")
        case .cancelled:
            receiver.cancelAwait(transferID)
        }
        return nil
    }

    /// Returns the `public.file-url` bytes for a materialized representation,
    /// staging an inline payload (e.g. an image file shown in place yet also
    /// pasteable as a file) to a temp file when it has no on-disk URL yet.
    private func fileURLData(
        from representation: ClipboardContent.Representation, generation: UInt64
    ) -> Data? {
        if let url = representation.fileURL {
            return Data(url.absoluteString.utf8)
        }
        guard
            !representation.filename.isEmpty,
            let data = representation.inMemoryData,
            let sink = try? staging.makeSink(
                generation: generation, filename: representation.filename)
        else { return nil }
        do {
            try sink.write(data)
            let url = try sink.commit()
            return Data(url.absoluteString.utf8)
        } catch {
            // A truncated file must not reach the pasteboard — abort the stage.
            sink.abort()
            return nil
        }
    }

    /// Drops the strong reference to a provider the pasteboard no longer needs.
    private func providerFinished(_ provider: LazyClipboardDataProvider) {
        liveProviders.remove(provider)
    }

    /// Whether an offered rep may be promised and pulled — the receive-side
    /// sanitization gate.
    ///
    /// An identity-skip type (transient marker, raw `public.file-url` smuggle) or
    /// an empty rep is never surfaced. `promisedTypes` and `repIndex(for:)` MUST
    /// share this gate: if `repIndex` searched the unfiltered reps, a `.fileURL`
    /// (or inline) request could resolve to a rep `promisedTypes` dropped — the
    /// very smuggle this sanitization exists to block.
    private static func isPromisable(_ info: Kernova_V1_ClipboardRepresentationInfo) -> Bool {
        info.byteCount != 0 && !ClipboardSnapshotPolicy.shouldSkipBeforeReading(uti: info.uti)
    }

    /// The pasteboard types to promise for an offer, applying the same
    /// inline-vs-file rule as the eager path: an inline rep promises its content
    /// UTI; a file rep promises `public.file-url`; an image file promises both.
    private static func promisedTypes(
        for reps: [Kernova_V1_ClipboardRepresentationInfo]
    ) -> [NSPasteboard.PasteboardType] {
        var types: [NSPasteboard.PasteboardType] = []
        var seen: Set<String> = []
        // Receive-side sanitization (the lazy counterpart of
        // ClipboardSnapshotPolicy.sanitizedForApply): never promise an
        // identity-skip type or an empty rep.
        for info in reps where isPromisable(info) {
            if info.isInline, seen.insert(info.uti).inserted {
                types.append(NSPasteboard.PasteboardType(info.uti))
            }
            if !info.filename.isEmpty,
                seen.insert(NSPasteboard.PasteboardType.fileURL.rawValue).inserted
            {
                types.append(.fileURL)
            }
        }
        return types
    }

    /// Maps a requested pasteboard type back to the offered representation index:
    /// `public.file-url` resolves to the first file rep; any other type to the
    /// inline rep whose UTI matches.
    private static func repIndex(
        for type: NSPasteboard.PasteboardType, in reps: [Kernova_V1_ClipboardRepresentationInfo]
    ) -> Int? {
        // Resolve only to a rep that was actually promised (`isPromisable`), so a
        // request can't reach a rep `promisedTypes` sanitized away.
        // RATIONALE: `.fileURL` collapses to the FIRST promisable file rep —
        // NSPasteboard's single-item promise model carries only one
        // `public.file-url`, and current intake (host and guest) never offers more
        // than one file rep per item, so this is lossless today.
        if type == .fileURL {
            return reps.firstIndex { isPromisable($0) && !$0.filename.isEmpty }
        }
        return reps.firstIndex { isPromisable($0) && $0.isInline && $0.uti == type.rawValue }
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
        guard let promise = inboundPromise, promise.generation == release.generation else { return }
        receiver?.cancel(generation: release.generation)
        lazyCoordinator.failAll()
        inboundPromise = nil
        // Retract the un-pasted promise only if the user hasn't replaced it since
        // we wrote it — otherwise leave whatever they copied in place.
        if pasteboard.changeCount == lastPasteboardChangeCount {
            pasteboard.clearContents()
            lastPasteboardChangeCount = pasteboard.changeCount
        }
        Self.logger.debug(
            "Host released clipboard offer (gen=\(release.generation, privacy: .public))")
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
