import AppKit
import Foundation
import KernovaKit
import UniformTypeIdentifiers

// MARK: - Pasteboard protocol

/// Subset of `NSPasteboard` actually used by `VsockGuestClipboardAgent`.
protocol Pasteboard: AnyObject {
    var changeCount: Int { get }

    /// Types of the **first** pasteboard item, in fidelity order; empty when
    /// the pasteboard holds nothing.
    var firstItemTypes: [NSPasteboard.PasteboardType] { get }

    /// File URLs of every pasteboard item that carries a concrete
    /// `public.file-url`, in item order; empty when no item is a file.
    var itemFileURLs: [URL] { get }

    func data(forType type: NSPasteboard.PasteboardType) -> Data?

    @discardableResult func clearContents() -> Int

    /// Clears the pasteboard and applies `options` to the contents about to be
    /// written.
    @discardableResult func prepareForNewContents(with options: NSPasteboard.ContentsOptions) -> Int

    /// Writes one pasteboard item per entry, each **promising** its types lazily
    /// served by its own `provider` when the OS asks for one.
    @discardableResult
    func writeItems(
        _ items: [(types: [NSPasteboard.PasteboardType], provider: NSPasteboardItemDataProvider)]
    ) -> Bool
}

extension NSPasteboard: Pasteboard {
    var firstItemTypes: [NSPasteboard.PasteboardType] {
        pasteboardItems?.first?.types ?? []
    }

    var itemFileURLs: [URL] {
        (pasteboardItems ?? []).compactMap { item in
            guard let string = item.string(forType: .fileURL),
                let url = URL(string: string), url.isFileURL
            else { return nil }
            return url
        }
    }

    // `NSPasteboard.data(forType:)` reads from "the first pasteboard item that
    // contains the type", which is the item-0 semantics this protocol wants, so
    // no explicit implementation is needed here.

    func writeItems(
        _ items: [(types: [NSPasteboard.PasteboardType], provider: NSPasteboardItemDataProvider)]
    ) -> Bool {
        let pasteboardItems = items.map { entry -> NSPasteboardItem in
            let item = NSPasteboardItem()
            item.setDataProvider(entry.provider, forTypes: entry.types)
            return item
        }
        return writeObjects(pasteboardItems)
    }
}

// MARK: - VsockGuestClipboardAgent

/// Guest-side clipboard agent that talks to the host's `VsockClipboardService`
/// on `KernovaVsockPort.clipboard`.
///
/// All mutable state is accessed exclusively on the main dispatch queue.
final class VsockGuestClipboardAgent: @unchecked Sendable {
    private static let logger = KernovaLogger(subsystem: "app.kernova.macosagent", category: "VsockGuestClipboardAgent")
    private static let pollingInterval: TimeInterval = 0.5
    /// What the paste progress readout calls the machine the bytes come from —
    /// the guest can't learn the host's actual computer name over the control
    /// handshake.
    private static let pasteSourceName = "Mac"

    private let client: VsockGuestClient
    private let pasteboard: Pasteboard

    /// Aggregates what this side streams to the host into the status item's
    /// readout.
    private let progressTracker: ClipboardProgressTracker

    /// Raised on the main queue when a refusal has just landed in
    /// `clipboardActivity`, so the menu-bar surface can reveal it instead of
    /// waiting for the user to open the dropdown.
    private let onClipboardNotice: @Sendable () -> Void

    /// The outbound session serving the host's pulls of `pendingOutbound`, with
    /// the generation it measures.
    private var outboundSession: (generation: UInt64, token: ClipboardProgressTracker.SessionToken)?

    // MARK: - Main-queue state

    /// Live channel for the current connection, if any.
    private var liveChannel: VsockChannel?

    /// Streaming engine for the current connection.
    private var sender: ClipboardStreamSender?
    private var receiver: ClipboardStreamReceiver?

    #if DEBUG
    /// Test seam.
    var liveChannelForTesting: VsockChannel? { liveChannel }

    /// Test seam.
    var inboundPromiseGenerationForTesting: UInt64? { inboundPromise?.generation }
    #endif

    /// Counter for outbound offer generations, starting at 1 so 0 is the "no
    /// current offer" sentinel.
    private var nextLocalGeneration: UInt64 = 1

    /// The most recent offer we sent the host, held until superseded so we can
    /// answer per-representation requests.
    private var pendingOutbound: (generation: UInt64, content: ClipboardContent)?

    /// Thread-safe mirror of the current outbound generation for the sender's
    /// off-queue supersession check.
    private let currentOutboundGeneration = AtomicGeneration()

    /// The host offer currently promised on the guest pasteboard, with its
    /// per-representation materialization cache.
    private var inboundPromise: InboundPromise?

    /// Bridges the synchronous `provideDataForType` callback to the off-actor
    /// stream receive, blocking the main thread until bytes land.
    private let lazyCoordinator = LazyPullCoordinator()

    /// Owner of the data providers still promised on the pasteboard, keeping each
    /// alive until `pasteboardFinishedWithDataProvider` fires (Apple requires it).
    private let retainer = LazyClipboardProviderRegistry()

    /// Last `NSPasteboard.changeCount` we observed; set after every poll and
    /// every host write so we don't echo our own content.
    private var lastPasteboardChangeCount: Int

    /// Digest of the most recent content we offered the host; suppresses
    /// redundant outbound offers on an unchanged clipboard.
    private var lastSeenDigest: Data?

    /// Materializes streamed file payloads to local temp files; swept on
    /// connect/teardown/disable.
    private let staging: ClipboardFileStaging

    /// Holds folder archives built to *send* to the host, kept separate from
    /// `staging` so an outbound archive's generation can't share a directory
    /// with an inbound transfer (which keys on the host's offer generation).
    private let sendStaging: ClipboardFileStaging

    /// Monotonic generation for outbound folder archives in `sendStaging`, so a
    /// new send supersedes older archive temps instead of accumulating.
    private var sendArchiveGeneration: UInt64 = 1

    /// `true` while an off-main folder estimate walk for an outbound offer is
    /// running, so overlapping 0.5 s polls don't kick off a second walk of the
    /// same content.
    private var estimateInFlight = false

    private var pollingTimer: DispatchSourceTimer?

    /// Whether clipboard sync is currently allowed by host policy.
    ///
    /// Defaults to `false` — the agent doesn't connect or poll until the host's
    /// first `PolicyUpdate(clipboardSharingEnabled: true)`.
    private var enabled: Bool = false

    #if DEBUG
    /// Test seam.
    var isEnabledForTesting: Bool { enabled }
    #endif

    /// Most recent clipboard activity, surfaced to the menu-bar UI.
    private var clipboardActivityStorage: ClipboardActivity = .disabled

    /// The most recent clipboard activity, for the menu-bar status line.
    ///
    /// The caller must be on the main queue.
    var clipboardActivity: ClipboardActivity {
        dispatchPrecondition(condition: .onQueue(.main))
        return clipboardActivityStorage
    }

    /// One promised inbound offer: its representation metadata and the
    /// representations materialized so far (each pulled at most once, then
    /// served to every promised type it backs).
    private final class InboundPromise {
        let generation: UInt64
        let reps: [Kernova_V1_ClipboardRepresentationInfo]
        var materialized: [Int: ClipboardContent.Representation] = [:]
        /// Temp-file URLs for inline payloads staged on demand, keyed by rep
        /// index, so a repeated `.fileURL` pull returns the same staged file
        /// instead of re-staging a duplicate.
        var stagedInlineURLs: [Int: URL] = [:]
        /// Whether the over-cap refusal was already surfaced for this offer, so
        /// the N provider fires of one multi-file paste raise one notice and send
        /// one error frame rather than N of each.
        var tooLargeReported = false

        init(generation: UInt64, reps: [Kernova_V1_ClipboardRepresentationInfo]) {
            self.generation = generation
            self.reps = reps
        }
    }

    // MARK: - Init

    /// Production init — uses real `NSPasteboard.general` on the clipboard port,
    /// publishing transfer progress through `onProgress` and clipboard refusals
    /// through `onClipboardNotice`.
    convenience init(
        onProgress: @escaping @Sendable (ClipboardProgressSnapshot?) -> Void,
        onClipboardNotice: @escaping @Sendable () -> Void
    ) {
        self.init(
            pasteboard: NSPasteboard.general,
            client: VsockGuestClient(port: KernovaVsockPort.clipboard, label: "clipboard"),
            onProgress: onProgress,
            onClipboardNotice: onClipboardNotice
        )
    }

    /// Designated init; tests inject a fake pasteboard and socketpair-backed
    /// client, and optionally a `freeSpaceProvider` to simulate a full disk, a
    /// `stagingTempRoot` to isolate the staging directory between parallel tests,
    /// an `onProgress` sink to observe the readout the status item renders, an
    /// `onClipboardNotice` sink to observe refusals, and zeroed reveal/linger
    /// delays so a test transfer surfaces while in flight.
    init(
        pasteboard: Pasteboard, client: VsockGuestClient,
        freeSpaceProvider: ClipboardFileStaging.FreeSpaceProvider? = nil,
        stagingTempRoot: URL = FileManager.default.temporaryDirectory,
        progressRevealDelay: TimeInterval = ClipboardProgressTracker.defaultRevealDelay,
        progressIdleLinger: TimeInterval = ClipboardProgressTracker.defaultIdleLinger,
        onProgress: @escaping @Sendable (ClipboardProgressSnapshot?) -> Void = { _ in },
        onClipboardNotice: @escaping @Sendable () -> Void = {}
    ) {
        self.pasteboard = pasteboard
        self.client = client
        self.onClipboardNotice = onClipboardNotice
        self.progressTracker = ClipboardProgressTracker(
            revealDelay: progressRevealDelay, idleLinger: progressIdleLinger, emit: onProgress)
        self.staging = ClipboardFileStaging(
            label: "agent", tempRoot: stagingTempRoot, freeSpaceProvider: freeSpaceProvider)
        self.sendStaging = ClipboardFileStaging(
            label: "agent-send", tempRoot: stagingTempRoot, freeSpaceProvider: freeSpaceProvider)
        self.lastPasteboardChangeCount = pasteboard.changeCount
        // Default-disabled: pause the reconnect loop until the host enables.
        self.client.pause()
    }

    // MARK: - Lifecycle

    func start() {
        staging.sweep()
        sendStaging.sweep()
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
            clipboardActivityStorage = .enabled
            Self.logger.notice("Clipboard sharing enabled by host policy")
        } else {
            client.pause()
            pollingTimer?.cancel()
            pollingTimer = nil
            teardownConnectionState()
            staging.sweep()
            sendStaging.sweep()
            clipboardActivityStorage = .disabled
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
            self?.sendStaging.sweep()
        }
        Self.logger.notice("Vsock clipboard agent stopped")
    }

    /// The outbound session measuring what this side is streaming for
    /// `generation`, opening one if the host's request is the first under it.
    ///
    /// A session the tracker has already ended is replaced rather than reused:
    /// the host's preview wave and its paste wave can be minutes apart, far
    /// longer than the idle linger, and reusing an ended token drops the paste's
    /// progress entirely.
    private func outboundSessionToken(for generation: UInt64)
        -> ClipboardProgressTracker.SessionToken
    {
        if let existing = outboundSession, existing.generation == generation,
            progressTracker.isSessionLive(existing.token)
        {
            return existing.token
        }
        if let stale = outboundSession { progressTracker.closeSession(stale.token, immediately: true) }
        let token = progressTracker.openSession(
            direction: .outbound, peerName: Self.pasteSourceName)
        outboundSession = (generation: generation, token: token)
        return token
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
        outboundSession = nil
        progressTracker.clearAll()
        // A stale in-flight estimate walk's completion checks `liveChannel` and
        // drops itself; clear the flag now so the next connection can walk again.
        estimateInFlight = false
        // The retainer's providers are NOT dropped here: Apple requires a data
        // provider stay alive while its item is still on the pasteboard. They're
        // released when pasteboardFinishedWithDataProvider fires.
    }

    /// Tears the connection down only if `channel` is still the live one.
    private func teardownIfCurrent(_ channel: VsockChannel) {
        if liveChannel === channel { teardownConnectionState() }
    }

    #if DEBUG
    /// Test seam for `teardownIfCurrent`.
    func teardownIfCurrentForTesting(_ channel: VsockChannel) {
        teardownIfCurrent(channel)
    }
    #endif

    // MARK: - Per-connection serve

    private func serve(channel: VsockChannel) async {
        // The engine is created off-main (its callbacks hop to main themselves);
        // only the published references are assigned on the main queue.
        let sender = ClipboardStreamSender(channel: channel)
        let receiver = ClipboardStreamReceiver(
            channel: channel, staging: self.staging,
            // The only measured throughput number for the real vsock link, so it
            // logs at `.notice` (persisted) rather than `.debug`.
            onTransferTimed: { metrics in
                Self.logger.notice(
                    "Host→guest clipboard transfer \(metrics.transferID, privacy: .public) completed: \(metrics.logSummary, privacy: .public)"
                )
            },
            // A lazy pull's per-transfer awaiter takes precedence over these
            // channel-wide closures, so they fire only for an unawaited transfer.
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
                    // one this guest sends; otherwise this guest receives it.
                    if ClipboardTransferID.hostReceives(abort.transferID) {
                        sender.handleAbort(transferID: abort.transferID)
                    } else {
                        receiver.handleAbort(abort)
                    }
                default:
                    // Control frames are serialized on the main queue, so while a
                    // synchronous `provideData` pull blocks main they queue behind
                    // it; a pull is woken by its off-main Abort, not by these.
                    DispatchQueue.main.async { [weak self] in
                        self?.handleControlFrame(frame)
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
            self.teardownIfCurrent(channel)
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

        // `org.nspasteboard.*` marker handling, from the unfiltered first-item
        // type list: a transient/auto-generated snapshot is never offered; a
        // concealed one (a password) is offered but flagged so the host window
        // hides it. Folders are never concealed secrets, so the estimate path
        // below ignores the flag.
        let disposition = ClipboardSnapshotPolicy.disposition(
            forTypes: pasteboard.firstItemTypes.map(\.rawValue))
        if case .suppress(let reason) = disposition {
            Self.logger.notice(
                "Clipboard snapshot suppressed by \(String(describing: reason), privacy: .public) marker"
            )
            lastPasteboardChangeCount = currentCount
            return
        }
        let isConcealed = disposition == .conceal

        // Copied *files* (Finder ⌘C) leave one file URL per pasteboard item —
        // build a disk-backed rep from each (a stat, no read, no size cap); the
        // bytes stream later when the host requests them.
        let fileCandidates = fileExpansionCandidates()
        if !fileCandidates.isEmpty {
            if fileCandidates.contains(where: { $0.isDirectory }) {
                // A folder's stat-walk size estimate runs off the main queue
                // first — the offer's `byte_count` is that estimate; no archive
                // is built until the host requests the rep.
                estimateAndOffer(fileCandidates, channel: channel, changeCount: currentCount)
            } else {
                let content = ClipboardContent(
                    representations: fileCandidates.map { candidate in
                        ClipboardContent.Representation(
                            uti: candidate.type.identifier, fileURL: candidate.url,
                            byteCount: candidate.byteCount, filename: candidate.filename)
                    }, isConcealed: isConcealed)
                sendOfferIfNeeded(content, channel: channel, changeCount: currentCount)
            }
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
        // `evaluate` builds non-concealed content; re-stamp the flag when the
        // marker called for it.
        let content = outcome.content.withConcealed(isConcealed)
        sendOfferIfNeeded(content, channel: channel, changeCount: currentCount)
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
        // Dedup on the buffer's own (uncapped) digest — the poll rebuilds the
        // same content each tick, so an unchanged pasteboard hits this guard.
        guard content.digest != lastSeenDigest else {
            lastPasteboardChangeCount = changeCount
            return
        }
        // Cap only what's offered/answered to the 16-bit rep-index limit.
        let capped = content.cappedToOfferLimit()
        if let originalCount = capped.truncatedFrom {
            Self.logger.warning(
                "Clipboard offer truncated from \(originalCount, privacy: .public) to \(ClipboardContent.maxOfferableRepresentations, privacy: .public) representations (16-bit transfer-id limit)"
            )
        }
        let offered = capped.content

        let generation = nextLocalGeneration
        var offer = Frame()
        offer.protocolVersion = 1
        offer.clipboardOffer = Kernova_V1_ClipboardOffer.with {
            $0.generation = generation
            $0.repInfo = offered.representations.map(\.offerRepresentationInfo)
            $0.isConcealed = offered.isConcealed
        }
        do {
            try channel.send(offer)
            nextLocalGeneration += 1
            if let previous = pendingOutbound { sender?.cancel(generation: previous.generation) }
            pendingOutbound = (generation: generation, content: offered)
            currentOutboundGeneration.set(generation)
            lastSeenDigest = content.digest
            lastPasteboardChangeCount = changeCount
            clipboardActivityStorage = .offeredToHost
            Self.logger.notice(
                "Sent clipboard offer (gen=\(generation, privacy: .public), \(offered.representations.count, privacy: .public) reps, \(offered.totalByteCount, privacy: .public) bytes)"
            )
        } catch {
            Self.logger.warning(
                "Failed to send clipboard offer: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// One on-disk pasteboard file or folder gathered for an outbound offer.
    ///
    /// A folder (`isDirectory`) carries no `byteCount` yet — the off-main
    /// estimate walk fills it in; a file's `byteCount` is its stat'd size.
    private struct FileCandidate {
        let url: URL
        let type: UTType
        let filename: String
        let byteCount: Int
        let isDirectory: Bool
    }

    /// Cheap main-queue metadata check for copied *files and folders*, one per
    /// pasteboard item.
    ///
    /// A directory is not gated on size (its inode `.fileSize` is meaningless).
    /// An item inside our own staging root (materialized from a prior inbound
    /// paste) is skipped so it can't be offered back to the host.
    private func fileExpansionCandidates() -> [FileCandidate] {
        var candidates: [FileCandidate] = []
        for url in pasteboard.itemFileURLs where !staging.isInStagingRoot(url) {
            guard
                let values = try? url.resourceValues(forKeys: [
                    .contentTypeKey, .isDirectoryKey, .fileSizeKey,
                ])
            else { continue }
            if values.isDirectory == true {
                candidates.append(
                    FileCandidate(
                        url: url, type: values.contentType ?? .folder,
                        filename: url.lastPathComponent, byteCount: 0, isDirectory: true))
            } else {
                guard let type = values.contentType, let size = values.fileSize, size > 0
                else { continue }
                candidates.append(
                    FileCandidate(
                        url: url, type: type, filename: url.lastPathComponent, byteCount: size,
                        isDirectory: false))
            }
        }
        return candidates
    }

    /// Sizes any folder candidate off the main queue — a stat-walk estimate, no
    /// archive — then offers the mixed file/folder content back on main.
    ///
    /// A large tree's walk would freeze the agent's run loop, so it hops to a
    /// global queue and back; the archive is built only when the host requests
    /// the rep (`archiveAndStream`).
    private func estimateAndOffer(
        _ candidates: [FileCandidate], channel: VsockChannel, changeCount: Int
    ) {
        guard !estimateInFlight else { return }
        estimateInFlight = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let reps: [ClipboardContent.Representation] = candidates.map { candidate in
                if candidate.isDirectory {
                    return ClipboardContent.Representation(
                        directorySourceURL: candidate.url,
                        estimatedByteCount: ClipboardDirectoryArchive.estimatedByteCount(
                            at: candidate.url),
                        filename: candidate.filename, uti: candidate.type.identifier)
                }
                return ClipboardContent.Representation(
                    uti: candidate.type.identifier, fileURL: candidate.url,
                    byteCount: candidate.byteCount, filename: candidate.filename)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                // A stale walk must not touch the live connection's in-flight
                // flag or bookkeeping — leave the newer walk's
                // `estimateInFlight` intact.
                guard self.liveChannel === channel else { return }
                self.estimateInFlight = false
                // Advance the change-count gate so the folder isn't re-walked
                // every 0.5 s poll; a genuine new copy bumps the count.
                self.lastPasteboardChangeCount = changeCount
                guard self.pasteboard.changeCount == changeCount, !reps.isEmpty else { return }
                self.sendOfferIfNeeded(
                    ClipboardContent(representations: reps), channel: channel,
                    changeCount: changeCount)
            }
        }
    }

    // MARK: - Frame handlers (main queue)

    /// Handles the control frames the consume loop hops to the main queue for
    /// (stream frames are routed off-main directly to the engine).
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
            // Abort every dropped request so the host's parked pull wakes
            // immediately instead of stalling to its lazyPullTimeout backstop.
            sender?.rejectRequest(
                transferID: request.transferID, code: "request.stale",
                message: "Request for superseded generation \(request.generation)")
            return
        }
        let repIndex = Int(request.transferID & 0xFFFF)
        guard repIndex < pending.content.representations.count else {
            Self.logger.warning(
                "Clipboard request transfer_id \(request.transferID, privacy: .public) out of range"
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
        // Ahead of the session bookkeeping: with no sender nothing streams, so a
        // transfer announced here would never see a terminal — the session would
        // stay active forever and its readout would stick on screen.
        guard let sender else { return }
        let xid = request.transferID
        let session = outboundSessionToken(for: request.generation)
        let name = representation.filename.isEmpty ? nil : representation.filename
        progressTracker.unitBegan(
            session: session, id: xid, expectedBytes: UInt64(max(0, representation.byteCount)),
            name: name)
        let tracker = progressTracker
        if case .directory(let sourceURL, _) = representation.source {
            archiveAndStream(
                sourceURL: sourceURL, folderName: representation.filename, request: request,
                isCurrent: generation, session: session, sender: sender)
            clipboardActivityStorage = .sentToHost
            return
        }
        sender.startTransfer(
            transferID: request.transferID,
            generation: request.generation,
            representation: representation,
            maxAcceptByteCount: request.maxAcceptByteCount,
            isInline: representation.shouldInlineOnPasteboard,
            isCurrent: { value in generation.isCurrent(value) },
            onProgress: { sent, total in
                tracker.unitProgressed(
                    session: session, id: xid, bytesTransferred: UInt64(max(0, sent)),
                    totalBytes: UInt64(max(0, total)))
            },
            onComplete: { success in
                tracker.unitEnded(session: session, id: xid, succeeded: success)
            })
        clipboardActivityStorage = .sentToHost
        Self.logger.debug(
            "Streaming clipboard rep \(repIndex, privacy: .public) (gen=\(request.generation, privacy: .public), \(representation.byteCount, privacy: .public) bytes)"
        )
    }

    /// Archives a source directory at request time and streams the `.aar` — the
    /// serving path for every folder rep the host pulls.
    ///
    /// Runs off the main run loop (walk + LZFSE compress).
    private func archiveAndStream(
        sourceURL: URL, folderName: String, request: Kernova_V1_ClipboardRequest,
        isCurrent: AtomicGeneration, session: ClipboardProgressTracker.SessionToken,
        sender: ClipboardStreamSender
    ) {
        let staging = self.sendStaging
        let archiveGeneration = sendArchiveGeneration
        sendArchiveGeneration += 1
        let transferID = request.transferID
        let requestGeneration = request.generation
        let maxAccept = request.maxAcceptByteCount
        let tracker = progressTracker
        DispatchQueue.global(qos: .userInitiated).async {
            guard
                let rep = try? ClipboardDirectoryArchive.archivedRepresentation(
                    ofDirectoryAt: sourceURL, named: folderName, into: staging,
                    generation: archiveGeneration)
            else {
                Self.logger.error(
                    "Failed to archive folder '\(folderName, privacy: .public)' at request time")
                sender.rejectRequest(
                    transferID: transferID, code: "archive.error",
                    message: "Could not archive the folder")
                // The unit began when the request was accepted, so it must end here
                // too — a unit left active keeps the session from ever going idle.
                tracker.unitEnded(session: session, id: transferID, succeeded: false)
                return
            }
            sender.startTransfer(
                transferID: transferID, generation: requestGeneration, representation: rep,
                maxAcceptByteCount: maxAccept, isInline: false,
                isCurrent: { value in isCurrent.isCurrent(value) },
                onProgress: { sent, total in
                    tracker.unitProgressed(
                        session: session, id: transferID, bytesTransferred: UInt64(max(0, sent)),
                        totalBytes: UInt64(max(0, total)))
                },
                onComplete: { success in
                    tracker.unitEnded(session: session, id: transferID, succeeded: success)
                })
        }
    }

    // MARK: - Inbound (we are the receiver)

    /// Registers a host offer as lazy promises on the guest pasteboard, pulling
    /// no bytes.
    ///
    /// The post-write `changeCount` is recorded immediately so the 0.5 s poll
    /// does not read — and thereby self-trigger — our own promise.
    private func handleOffer(_ offer: Kernova_V1_ClipboardOffer) {
        // A newer offer supersedes the previous one; drop the stale promise and
        // its materialization cache.
        if let previous = inboundPromise {
            receiver?.cancel(generation: previous.generation)
            lazyCoordinator.failAll()
        }

        let items = Self.promisedItems(for: offer.repInfo)
        guard !items.isEmpty else {
            inboundPromise = nil
            return
        }

        let promise = InboundPromise(generation: offer.generation, reps: offer.repInfo)
        inboundPromise = promise

        guard writePasteboardPromise(promise: promise, items: items) else {
            Self.logger.warning(
                "Failed to register host clipboard promise (gen=\(offer.generation, privacy: .public))"
            )
            // The write failed, so the providers were never retained — there is
            // nothing to retract.
            inboundPromise = nil
            return
        }
        Self.logger.notice(
            "Registered host clipboard promise (gen=\(offer.generation, privacy: .public), \(items.count, privacy: .public) item(s))"
        )
        clipboardActivityStorage = .offeredFromHost
    }

    /// Writes `items` to the pasteboard as lazy providers, every promised type
    /// served by `provideData`.
    ///
    /// Captures `lastPasteboardChangeCount` after the write regardless of
    /// outcome (echo suppression — a partial write can't leave the poll
    /// re-offering), and retains the providers only on success.
    @discardableResult
    private func writePasteboardPromise(promise: InboundPromise, items: [PromisedItem]) -> Bool {
        let generation = promise.generation
        var newProviders: [LazyClipboardDataProvider] = []
        let writes = items.map {
            item -> (types: [NSPasteboard.PasteboardType], provider: NSPasteboardItemDataProvider) in
            let provider = LazyClipboardDataProvider(
                provide: { [weak self] type in
                    self?.provideData(type, itemTypes: item, generation: generation)
                },
                onFinished: { [weak self] provider in self?.retainer.release(provider) })
            newProviders.append(provider)
            return (types: item.map { $0.type }, provider: provider)
        }

        // RATIONALE: `.currentHostOnly` keeps the continuity-pasteboard
        // advertiser from fetching the promised flavors at offer time — on the
        // sync path, producing `public.file-url` materializes the whole file with
        // zero user interaction (docs/CLIPBOARD.md §3). The option is per-write
        // state, reset by every prepare/clear, so it is applied at this single
        // publication choke point.
        pasteboard.prepareForNewContents(with: .currentHostOnly)
        let written = pasteboard.writeItems(writes)
        lastPasteboardChangeCount = pasteboard.changeCount
        guard written else { return false }
        // Hand the providers to the agent-lifetime registry so each survives
        // until the pasteboard finishes with it.
        retainer.retain(newProviders)
        return true
    }

    /// Streams the bytes for a promised pasteboard type on demand.
    ///
    /// Runs synchronously on the agent's main thread (the pasteboard server's
    /// `provideDataForType` callback). `itemTypes` is the promising item's own
    /// type → rep-index map, so a `.fileURL` pull resolves to *this* item's file
    /// rep rather than the first file rep across the offer. Returns `nil` on a
    /// stale generation, a type this item never promised, or a failed pull.
    private func provideData(
        _ type: NSPasteboard.PasteboardType, itemTypes: PromisedItem, generation: UInt64
    ) -> Data? {
        guard let promise = inboundPromise, promise.generation == generation else {
            Self.logger.debug(
                "provideData for stale clipboard generation \(generation, privacy: .public)")
            return nil
        }
        guard let channel = liveChannel, let receiver = receiver else { return nil }
        guard let repIndex = itemTypes.first(where: { $0.type == type })?.repIndex else {
            Self.logger.warning(
                "provideData for unpromised type '\(type.rawValue, privacy: .public)'")
            return nil
        }

        let representation: ClipboardContent.Representation
        if let cached = promise.materialized[repIndex] {
            // Already pulled — serving from cache mints no new transfer id.
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
            return fileURLData(
                from: representation, repIndex: repIndex, promise: promise, generation: generation)
        }
        return representation.inMemoryData
    }

    /// Registers a per-transfer awaiter, sends the request via `sendRequest`, and
    /// blocks the calling thread until the transfer resolves — the shared
    /// transport core of every inbound pull.
    ///
    /// The deadlock-safe wakeup: the receiver's `awaitTransfer` handler fires
    /// off-main into the coordinator, never hopping to the thread this call
    /// holds.
    private func awaitPull(
        transferID: UInt64, receiver: ClipboardStreamReceiver,
        sendRequest: @escaping () throws -> Void
    ) -> LazyPullOutcome {
        let coordinator = lazyCoordinator
        receiver.awaitTransfer(
            transferID,
            onComplete: { rep in coordinator.deliver(transferID, rep) },
            onAbort: { abort in coordinator.abort(transferID, abort) },
            // Re-arm the pull's inactivity backstop on every chunk so a large
            // still-streaming transfer is never timed out mid-flight.
            onProgress: { _, _ in coordinator.heartbeat(transferID) })
        return coordinator.pull(transferID: transferID) {
            do {
                try sendRequest()
            } catch {
                Self.logger.warning(
                    "Failed to send clipboard request: \(error.localizedDescription, privacy: .public)"
                )
                // No request went out, so no reply will arrive — resolve the pull
                // now instead of blocking the calling thread to the backstop timeout.
                receiver.cancelAwait(transferID)
                coordinator.abort(
                    transferID,
                    ClipboardStreamAbortInfo(
                        transferID: transferID, code: "send.failed",
                        message: "Failed to send clipboard request", neededBytes: nil,
                        availableBytes: nil))
            }
        }
    }

    /// Sends one `ClipboardRequest` and blocks the calling thread until the
    /// streamed representation lands (or aborts/times out).
    private func pullRepresentation(
        _ repIndex: Int, promise: InboundPromise, channel: VsockChannel,
        receiver: ClipboardStreamReceiver
    ) -> ClipboardContent.Representation? {
        let info = promise.reps[repIndex]
        // The cap applies to the TOTAL of the offer's deadline-bound reps,
        // all-or-nothing: one paste is one deadline-bound operation, so the OS
        // clock sees the sum, not each file. Checked before the disk-space gate:
        // an over-cap offer never gets far enough to need the space.
        if !info.isInline {
            let totalBytes = Self.syncDeadlineBoundLoad(for: promise)
            if totalBytes > UInt64(ClipboardStreamTuning.maxDeadlineSafePasteBytes) {
                Self.logger.warning(
                    "Deadline-bound clipboard reps total \(totalBytes, privacy: .public) bytes — over the deadline-safe cap; refusing the paste pull"
                )
                // The gesture was made here, so the notice goes up here; the host
                // is told too, since its window may be the surface in view.
                if !promise.tooLargeReported {
                    promise.tooLargeReported = true
                    recordPasteRefusedTooLarge()
                    sendPasteError(
                        code: .pasteTooLarge,
                        message:
                            "Too large to paste into the guest (\(totalBytes) bytes total)",
                        on: channel)
                }
                return nil
            }
        }
        if !info.isInline, !staging.hasCapacity(forByteCount: Int(clamping: info.byteCount)) {
            Self.logger.warning(
                "Not enough disk space to receive clipboard rep '\(info.uti, privacy: .public)' (\(info.byteCount, privacy: .public) bytes)"
            )
            // The guest has no UI; tell the host so it shows the failure.
            sendPasteError(
                code: .pasteDiskFull,
                message: "Not enough disk space in the guest to receive \(info.byteCount) bytes",
                on: channel)
            return nil
        }
        // The guest is the receiver, so it does not set the direction bit.
        let transferID = ClipboardTransferID.make(
            generation: promise.generation, repIndex: repIndex, hostMinted: false)
        let maxAccept =
            staging.availableCapacity().map { UInt64(clamping: $0) }
            ?? ClipboardStreamTuning.unlimitedAcceptByteCount

        let generation = promise.generation
        let uti = info.uti
        let outcome = awaitPull(transferID: transferID, receiver: receiver) {
            var request = Frame()
            request.protocolVersion = 1
            request.clipboardRequest = Kernova_V1_ClipboardRequest.with {
                $0.generation = generation
                $0.transferID = transferID
                $0.uti = uti
                $0.maxAcceptByteCount = maxAccept
            }
            try channel.send(request)
        }

        switch outcome {
        case .delivered(let representation):
            recordReceivedFromHost()
            // `is_directory` rides the offer, not `ClipboardStreamBegin`, so the
            // offer-aware layer re-tags the delivered rep here; `fileURLData`
            // then extracts the `.aar` into a real folder.
            if info.isDirectory {
                return ClipboardContent.Representation(
                    uti: representation.uti, source: representation.source,
                    filename: representation.filename, isDirectory: true)
            }
            return representation
        case .aborted(let abort):
            Self.logger.warning(
                "Inbound clipboard pull \(transferID, privacy: .public) aborted (\(abort.code, privacy: .public))"
            )
            // Surface a genuine receive failure to the host UI; stay quiet for a
            // normal supersession/teardown (the user simply copied something new).
            if !Self.benignAbortCodes.contains(abort.code) {
                sendPasteError(
                    code: Self.pasteErrorCode(forAbortCode: abort.code),
                    message: abort.message, on: channel)
            }
        case .timedOut:
            receiver.cancelAwait(transferID)
            Self.logger.warning("Inbound clipboard pull \(transferID, privacy: .public) timed out")
            // Stop any stream the host is still sending for this abandoned pull,
            // then surface the failure (the guest has no UI of its own).
            sendStreamAbort(
                transferID: transferID, code: "paste.timeout",
                message: "Receiver gave up waiting for the clipboard transfer", on: channel)
            sendPasteError(
                code: .pasteTimeout,
                message: "The clipboard transfer to the guest timed out", on: channel)
        case .cancelled:
            // `.debug`, not `.warning`: `.cancelled` also covers benign
            // teardown/supersession, which is deliberately silent elsewhere.
            Self.logger.debug("Inbound clipboard pull \(transferID, privacy: .public) cancelled")
            receiver.cancelAwait(transferID)
        case .superseded:
            // A newer pull for this id has already taken over the awaiter/slot
            // registration — touch nothing keyed by `transferID` (no
            // `cancelAwait`, no abort frame, no paste error): the retry owns it
            // now and must resolve on its own.
            Self.logger.debug("Inbound clipboard pull \(transferID, privacy: .public) superseded by a newer fetch")
        }
        return nil
    }

    /// Records the "received from host" menu signal on the queue that owns it.
    private func recordReceivedFromHost() {
        DispatchQueue.main.async { [weak self] in
            self?.clipboardActivityStorage = .receivedFromHost
        }
    }

    /// Records the over-cap paste refusal on the queue that owns the menu state,
    /// then raises the notice so the surface reveals it.
    ///
    /// The refusal returns out of `provideData` without pulling anything, so
    /// nothing is holding the main thread by the time the hop runs.
    private func recordPasteRefusedTooLarge() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.clipboardActivityStorage = .pasteRefusedTooLarge
            self.onClipboardNotice()
        }
    }

    /// Abort codes that are a normal supersession/teardown, not a failure worth
    /// surfacing to the user.
    private static let benignAbortCodes: Set<String> = ["superseded", "cancelled", "request.stale"]

    /// Maps a receiver/peer abort code to the user-facing paste code the host
    /// renders.
    private static func pasteErrorCode(forAbortCode code: String) -> ClipboardErrorCode {
        switch code {
        case "disk.full": return .pasteDiskFull
        case "stall.timeout": return .pasteTimeout
        default: return .pasteFailed
        }
    }

    /// Sends an `Error` frame so the host surfaces an inbound-paste failure in
    /// its clipboard window too.
    private func sendPasteError(
        code: ClipboardErrorCode, message: String, on channel: VsockChannel
    ) {
        try? channel.sendErrorFrame(
            code: code.rawValue, message: message, inReplyTo: "clipboard.request")
    }

    /// Sends a `ClipboardStreamAbort` for an inbound transfer the receiver is
    /// abandoning, so the host's sender stops streaming the remaining bytes.
    private func sendStreamAbort(
        transferID: UInt64, code: String, message: String, on channel: VsockChannel
    ) {
        var frame = Frame()
        frame.protocolVersion = 1
        frame.clipboardStreamAbort = .with {
            $0.transferID = transferID
            $0.code = code
            $0.message = message
        }
        try? channel.send(frame)
    }

    /// Returns the `public.file-url` bytes for a materialized representation,
    /// staging an inline payload to a temp file when it has no on-disk URL yet.
    private func fileURLData(
        from representation: ClipboardContent.Representation, repIndex: Int,
        promise: InboundPromise, generation: UInt64
    ) -> Data? {
        if representation.isDirectory {
            // A directory rep's bytes are an `.aar` of the tree. Extract it into a
            // real folder and offer that folder's URL so a Finder paste recreates
            // the tree, not the archive file.
            if let cached = promise.stagedInlineURLs[repIndex],
                FileManager.default.fileExists(atPath: cached.path)
            {
                return Data(cached.absoluteString.utf8)
            }
            guard
                let directory = ClipboardDirectoryArchive.extractedDirectoryURL(
                    for: representation, into: staging, generation: generation)
            else { return nil }
            promise.stagedInlineURLs[repIndex] = directory
            return Data(directory.absoluteString.utf8)
        }
        if let url = representation.fileURL {
            return Data(url.absoluteString.utf8)
        }
        // Cache the staged URL per rep so a repeated `.fileURL` pull of an inline
        // payload returns the same file instead of minting `name (2).ext`.
        if let cached = promise.stagedInlineURLs[repIndex],
            FileManager.default.fileExists(atPath: cached.path)
        {
            return Data(cached.absoluteString.utf8)
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
            promise.stagedInlineURLs[repIndex] = url
            return Data(url.absoluteString.utf8)
        } catch {
            // A truncated file must not reach the pasteboard — abort the stage.
            sink.abort()
            return nil
        }
    }

    /// One promised pasteboard item: each pasteboard type it offers paired with
    /// the offer-rep index that backs it.
    private typealias PromisedItem = [(type: NSPasteboard.PasteboardType, repIndex: Int)]

    /// Whether an offered rep may be promised and pulled — the receive-side
    /// sanitization gate.
    ///
    /// An identity-skip type (transient marker, raw `public.file-url` smuggle) or
    /// an empty rep is never surfaced, and a `provideData` pull can only reach a
    /// rep this gate kept.
    private static func isPromisable(_ info: Kernova_V1_ClipboardRepresentationInfo) -> Bool {
        info.byteCount != 0 && !ClipboardSnapshotPolicy.shouldSkipBeforeReading(uti: info.uti)
    }

    /// The offer's deadline-bound load — the total byte count of its non-inline,
    /// promisable reps, the payload one paste pulls against the OS deadline.
    ///
    /// A directory rep contributes the producer's estimate, the same figure the
    /// wire carries as its `byte_count`.
    private static func syncDeadlineBoundLoad(for promise: InboundPromise) -> UInt64 {
        var total: UInt64 = 0
        for info in promise.reps where !info.isInline && isPromisable(info) {
            total &+= info.byteCount
        }
        return total
    }

    /// The promised pasteboard items for an offer.
    ///
    /// Inline-only reps (no filename) share one item promising each rep's content
    /// UTI; each file rep gets its own item promising `public.file-url` (and its
    /// image UTI when it's an image file). An identity-skip type or an empty rep
    /// is never promised. Each promised type carries the offer-rep index that
    /// backs it.
    private static func promisedItems(
        for reps: [Kernova_V1_ClipboardRepresentationInfo]
    ) -> [PromisedItem] {
        let descriptors = reps.map {
            ClipboardRepresentationDescriptor(
                uti: $0.uti, filename: $0.filename, isInline: $0.isInline,
                isPromisable: isPromisable($0))
        }
        return ClipboardPasteboardItemPlan.plan(for: descriptors).items.map { item in
            item.types.map { promised in
                (
                    type: promised.isFileURL
                        ? NSPasteboard.PasteboardType.fileURL
                        : NSPasteboard.PasteboardType(promised.uti),
                    repIndex: promised.representationIndex
                )
            }
        }
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
}
