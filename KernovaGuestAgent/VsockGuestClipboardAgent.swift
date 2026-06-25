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
    /// the pasteboard holds nothing. Used for the inline (non-file) snapshot,
    /// which is genuinely one item — see `ClipboardContent`.
    var firstItemTypes: [NSPasteboard.PasteboardType] { get }

    /// File URLs of every pasteboard item that carries a concrete
    /// `public.file-url`, in item order; empty when no item is a file.
    ///
    /// A multi-select copy (Finder ⌘C of several files) puts one file URL per
    /// item, so the outbound poll offers them all rather than just item 0.
    var itemFileURLs: [URL] { get }

    func data(forType type: NSPasteboard.PasteboardType) -> Data?

    @discardableResult func clearContents() -> Int

    /// Writes one pasteboard item per entry, each **promising** its types lazily
    /// served by its own `provider` when the OS asks for one.
    ///
    /// The lazy inbound path: a host offer registers promises and pulls no
    /// bytes; each `NSPasteboardItemDataProvider.pasteboard(_:item:provideDataForType:)`
    /// callback streams the requested representation on demand. An offer with
    /// several file reps writes one item per file so the OS pulls each
    /// independently — hence one provider per item, each closing over the reps
    /// that item serves.
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

    // RATIONALE: NSPasteboard's own `data(forType:)` reads from "the first
    // pasteboard item that contains the type". The agent only queries types
    // reported by `firstItemTypes` (item 0), so the existing method satisfies
    // the protocol requirement with the intended item-0 semantics.

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
// retained even though the agent now runs inside an @main NSApplication: the
// lazy-pasteboard pull blocks the main thread synchronously, and the existing
// main-queue serialization models that precisely without the actor-hop churn a
// @MainActor conversion would impose on the streaming engine's off-main
// callbacks. The menu-bar UI reads `clipboardActivity` on the same main queue.
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

    /// Holds folder archives built to *send* to the host, kept separate from
    /// `staging` so an outbound archive's generation can't share a directory
    /// with an inbound transfer (which keys on the host's offer generation).
    ///
    /// Swept alongside `staging`.
    private let sendStaging: ClipboardFileStaging

    /// Monotonic generation for outbound folder archives in `sendStaging`, so a
    /// new send supersedes older archive temps instead of accumulating.
    private var sendArchiveGeneration: UInt64 = 1

    /// `true` while an off-main folder archive for an outbound offer is running,
    /// so overlapping 0.5 s polls don't kick off a second archive of the same
    /// content.
    ///
    /// Reset on the archive's completion and on teardown.
    private var archiveInFlight = false

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

    /// Most recent clipboard activity, surfaced to the menu-bar UI.
    ///
    /// Mutated only on the main queue (like all other state here); read by the
    /// menu on main.
    private var clipboardActivityStorage: ClipboardActivity = .disabled

    /// The most recent clipboard activity, for the menu-bar status line.
    ///
    /// Reads the main-queue-confined state; the caller must be on the main queue
    /// (the menu delegate is). See `ClipboardActivity` for why this is a
    /// last-event signal rather than a live one.
    var clipboardActivity: ClipboardActivity {
        dispatchPrecondition(condition: .onQueue(.main))
        return clipboardActivityStorage
    }

    /// One promised inbound offer: its representation metadata and the
    /// representations materialized so far (each pulled at most once, then
    /// served to every promised type it backs).
    ///
    /// Touched only on main.
    private final class InboundPromise {
        let generation: UInt64
        let reps: [Kernova_V1_ClipboardRepresentationInfo]
        var materialized: [Int: ClipboardContent.Representation] = [:]
        /// Temp-file URLs for inline payloads staged on demand (an image file
        /// served as a file URL), keyed by rep index, so a repeated `.fileURL`
        /// pull returns the same staged file instead of re-staging a duplicate.
        var stagedInlineURLs: [Int: URL] = [:]

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
            // Feature turned on — reset the line to the quiet "enabled" baseline
            // (clears a prior "disabled"); a flow event overwrites it next.
            clipboardActivityStorage = .enabled
            Self.logger.notice("Clipboard sharing enabled by host policy")
        } else {
            client.pause()
            pollingTimer?.cancel()
            pollingTimer = nil
            teardownConnectionState()
            staging.sweep()
            sendStaging.sweep()
            // Feature turned off — reflect it on the line (a mere reconnect leaves
            // the last activity intact, since teardownConnectionState doesn't touch it).
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
        // A stale in-flight archive's completion checks `liveChannel` and drops
        // itself; clear the flag now so the next connection can archive again.
        archiveInFlight = false
        // liveProviders are NOT dropped here: Apple requires a data provider stay
        // alive while its item is still on the pasteboard. They're released when
        // pasteboardFinishedWithDataProvider fires (a later offer/clear overwrites
        // the promise).
    }

    /// Tears the connection down only if `channel` is still the live one.
    // RATIONALE: defensive against a future overlapping-connection refactor. The
    // current VsockGuestClient reconnect loop serves connections strictly
    // sequentially (serve(A) returns before serve(B) connects), so a stale
    // connection never races a live one in production today — the identity check
    // is reliably true and the stale branch is never taken.
    private func teardownIfCurrent(_ channel: VsockChannel) {
        if liveChannel === channel { teardownConnectionState() }
    }

    #if DEBUG
    /// Drives `teardownIfCurrent` from the guest test target, which compiles
    /// these sources directly (no `@testable` needed for internal members).
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
                    // behind it. The host now Aborts every request it drops without
                    // starting a transfer (#357), and that Abort routes off-main
                    // straight to the pull's awaiter — waking it immediately rather
                    // than letting it park to `lazyPullTimeout`. The 120 s timeout
                    // is now a should-never-fire backstop for a host that sends
                    // neither Begin nor Abort.
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

        // Snapshot-level `org.nspasteboard.*` marker handling, from the
        // unfiltered first-item type list (before per-rep filtering strips the
        // markers). A transient/auto-generated snapshot is never offered; a
        // concealed snapshot (a password) is offered so the host can still paste
        // it, but flagged so the host window hides it. Folders are never
        // concealed secrets, so the archive path below ignores the flag.
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
        // bytes stream later when the host requests them. A multi-select copy
        // offers all of them. A copied *folder* must be archived first.
        let fileCandidates = fileExpansionCandidates()
        if !fileCandidates.isEmpty {
            if fileCandidates.contains(where: { $0.isDirectory }) {
                // A folder must be archived (eagerly, off the main queue) before
                // it can be offered — the offer needs the archive's size and the
                // stream its SHA-256. Offer once the archive lands back on main.
                archiveAndOffer(fileCandidates, channel: channel, changeCount: currentCount)
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
        // marker called for it. `withConcealed` reuses the digest (isConcealed is
        // excluded from it), so no second hash of the payload.
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
            $0.repInfo = offered.representations.map(Self.repInfo(for:))
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
    /// A folder (`isDirectory`) carries no `byteCount` yet — it's filled in once
    /// the folder is archived; a file's `byteCount` is its stat'd size.
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
    /// Returns the URL, content type, name, and (for a file) stat'd size of each
    /// on-disk item — no size cap, since file bytes stream on demand and a folder
    /// is archived later. A directory is flagged via `.isDirectoryKey` (its inode
    /// `.fileSize` is meaningless, so it's not gated on size) and tagged
    /// `public.folder`. An item inside our own staging root (materialized from a
    /// prior inbound paste) is skipped per item so it can't be offered back to
    /// the host (echo suppression).
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
                        url: url, type: .folder, filename: url.lastPathComponent, byteCount: 0,
                        isDirectory: true))
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

    /// Archives any folder candidate off the main queue, then offers the mixed
    /// file/folder content back on main.
    ///
    /// A folder tree walk + LZFSE compress would freeze the agent's run loop, so
    /// it hops to a global queue and back. The `archiveInFlight` flag keeps an
    /// overlapping 0.5 s poll from launching a second archive of the same
    /// content; the completion drops itself if the user copied again (the
    /// `changeCount` moved) or the connection changed while archiving.
    private func archiveAndOffer(
        _ candidates: [FileCandidate], channel: VsockChannel, changeCount: Int
    ) {
        guard !archiveInFlight else { return }
        archiveInFlight = true
        let generation = sendArchiveGeneration
        sendArchiveGeneration += 1
        let sendStaging = self.sendStaging
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let reps: [ClipboardContent.Representation] = candidates.compactMap { candidate in
                if candidate.isDirectory {
                    return Self.archivedDirectoryRep(
                        candidate, staging: sendStaging, generation: generation)
                }
                return ClipboardContent.Representation(
                    uti: candidate.type.identifier, fileURL: candidate.url,
                    byteCount: candidate.byteCount, filename: candidate.filename)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                // A stale archive (this connection was torn down and replaced)
                // must not touch the live connection's in-flight flag or
                // bookkeeping — leave the newer archive's `archiveInFlight` intact
                // (teardown already reset it for the old one).
                guard self.liveChannel === channel else { return }
                self.archiveInFlight = false
                // Advance the change-count gate regardless of outcome so a folder
                // that fails to archive (reps empty) or was superseded isn't
                // re-walked/re-compressed every 0.5 s poll; a genuine new copy
                // bumps the count and is picked up on the next tick.
                self.lastPasteboardChangeCount = changeCount
                guard self.pasteboard.changeCount == changeCount, !reps.isEmpty else { return }
                self.sendOfferIfNeeded(
                    ClipboardContent(representations: reps), channel: channel,
                    changeCount: changeCount)
            }
        }
    }

    /// Archives the folder for `candidate` into a `.file` directory
    /// representation, or `nil` if archiving fails (the folder is then dropped
    /// from the offer).
    ///
    /// A thin logging wrapper over the shared
    /// `ClipboardDirectoryArchive.archivedRepresentation`, which the host intake
    /// also calls so the archive/UTI/sizing rules stay identical on both ends.
    nonisolated private static func archivedDirectoryRep(
        _ candidate: FileCandidate, staging: ClipboardFileStaging, generation: UInt64
    ) -> ClipboardContent.Representation? {
        do {
            return try ClipboardDirectoryArchive.archivedRepresentation(
                ofDirectoryAt: candidate.url, named: candidate.filename, into: staging,
                generation: generation)
        } catch {
            Self.logger.error(
                "Failed to archive folder '\(candidate.filename, privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
            return nil
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
            // Abort every dropped request so the host's parked pull (Copy-to-Mac /
            // preview) wakes immediately off-main instead of stalling to its
            // lazyPullTimeout backstop. [#357]
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
        sender?.startTransfer(
            transferID: request.transferID,
            generation: request.generation,
            representation: representation,
            maxAcceptByteCount: request.maxAcceptByteCount,
            isInline: Self.shouldInline(representation),
            isCurrent: { value in generation.isCurrent(value) })
        // The host pulled our clipboard — the outbound stream is starting. (See
        // `ClipboardActivity` for why this is marked at start, not completion.)
        clipboardActivityStorage = .sentToHost
        Self.logger.debug(
            "Streaming clipboard rep \(repIndex, privacy: .public) (gen=\(request.generation, privacy: .public), \(representation.byteCount, privacy: .public) bytes)"
        )
    }

    // MARK: - Inbound (we are the receiver)

    /// Registers a host offer as lazy promises on the guest pasteboard, pulling
    /// no bytes.
    ///
    /// One `NSPasteboardItem` is written per promised item (one for inline
    /// content, one per file rep), each backed by its own
    /// `LazyClipboardDataProvider`; each representation is streamed only when the
    /// OS asks for it (`provideData`). The post-write `changeCount` is recorded
    /// immediately so the 0.5 s poll does not read — and thereby self-trigger —
    /// our own promise (echo suppression at promise time).
    private func handleOffer(_ offer: Kernova_V1_ClipboardOffer) {
        // A newer offer supersedes the previous one. Pulls are synchronous on
        // main, so no inbound transfer can be in flight here, but cancel + failAll
        // defensively and drop the stale promise/cache.
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
        let generation = offer.generation

        // One provider per promised item, each resolving a requested type to a
        // rep index against *its own* type map — so an offer's several file reps
        // each resolve `.fileURL` to their own file instead of all collapsing to
        // the first.
        var newProviders: [LazyClipboardDataProvider] = []
        let writes = items.map {
            item -> (types: [NSPasteboard.PasteboardType], provider: NSPasteboardItemDataProvider) in
            let provider = LazyClipboardDataProvider(
                provide: { [weak self] type in
                    self?.provideData(type, itemTypes: item, generation: generation)
                },
                onFinished: { [weak self] provider in self?.providerFinished(provider) })
            newProviders.append(provider)
            return (types: item.map { $0.type }, provider: provider)
        }
        newProviders.forEach { liveProviders.insert($0) }

        pasteboard.clearContents()
        let written = pasteboard.writeItems(writes)
        // Capture the bumped changeCount whether or not the write reported
        // success, so a partial write can't leave the poll re-offering. [Safeguard 2]
        lastPasteboardChangeCount = pasteboard.changeCount
        guard written else {
            Self.logger.warning(
                "Failed to register host clipboard promise (gen=\(generation, privacy: .public))")
            newProviders.forEach { liveProviders.remove($0) }
            inboundPromise = nil
            return
        }
        clipboardActivityStorage = .offeredFromHost
        Self.logger.notice(
            "Registered host clipboard promise (gen=\(generation, privacy: .public), \(items.count, privacy: .public) item(s))"
        )
    }

    /// Streams the bytes for a promised pasteboard type on demand.
    ///
    /// Runs synchronously on the agent's main thread (the pasteboard server's
    /// `provideDataForType` callback). `itemTypes` is the promising item's own
    /// type → rep-index map, so a `.fileURL` pull resolves to *this* item's file
    /// rep rather than the first file rep across the offer. Pulls the backing
    /// representation at most once per offer — caching it so an image rep
    /// promised as both its UTI and `public.file-url` is fetched a single time —
    /// then formats it for the requested type. Returns `nil` (empty) on a stale
    /// generation, a failed pull, or a type this item never promised.
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
            // The guest has no UI; tell the host so it shows the failure.
            sendPasteError(
                code: "clipboard.paste.disk.full",
                message: "Not enough disk space in the guest to receive \(info.byteCount) bytes",
                on: channel)
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
            onAbort: { abort in coordinator.abort(transferID, abort) },
            // Re-arm the pull's inactivity backstop on every chunk so a large
            // still-streaming file is never timed out mid-transfer. [large-paste]
            onProgress: { coordinator.heartbeat(transferID) })

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
            // The bytes landed on the guest pasteboard — record it for the menu.
            // (This runs after the main-thread pull unblocks, so it's observable.)
            clipboardActivityStorage = .receivedFromHost
            // RATIONALE: `is_directory` rides the offer, not ClipboardStreamBegin,
            // so the offer-aware layer re-tags the delivered rep here, mirroring
            // VsockClipboardService.pull (see its note for why the flag stays off
            // the stream message). `fileURLData` then extracts the `.aar` into a
            // real folder instead of pasting the archive file.
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
                code: "clipboard.paste.timeout",
                message: "The clipboard transfer to the guest timed out", on: channel)
        case .cancelled:
            receiver.cancelAwait(transferID)
        }
        return nil
    }

    /// Abort codes that are a normal supersession/teardown, not a failure worth
    /// surfacing to the user (the user copied something new, or the channel
    /// closed).
    private static let benignAbortCodes: Set<String> = ["superseded", "cancelled", "request.stale"]

    /// Maps a receiver/peer abort code to the user-facing `clipboard.paste.*`
    /// code the host renders.
    ///
    /// Disk-full and a stalled (silent-sender) transfer get specific messages;
    /// every other receive error is a generic failure — the precise internal
    /// code is still captured in the guest log.
    private static func pasteErrorCode(forAbortCode code: String) -> String {
        switch code {
        case "disk.full": return "clipboard.paste.disk.full"
        case "stall.timeout": return "clipboard.paste.timeout"
        default: return "clipboard.paste.failed"
        }
    }

    /// Sends an `Error` frame so the host surfaces an inbound-paste failure in
    /// its clipboard window — the guest agent has no UI of its own.
    ///
    /// The host maps a `clipboard.*` code to a
    /// `ClipboardTransferIssue.peerReportedError`.
    private func sendPasteError(code: String, message: String, on channel: VsockChannel) {
        try? channel.sendErrorFrame(code: code, message: message, inReplyTo: "clipboard.request")
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
    /// staging an inline payload (e.g. an image file shown in place yet also
    /// pasteable as a file) to a temp file when it has no on-disk URL yet.
    private func fileURLData(
        from representation: ClipboardContent.Representation, repIndex: Int,
        promise: InboundPromise, generation: UInt64
    ) -> Data? {
        if representation.isDirectory {
            // A directory rep's bytes are an `.aar` of the tree. Extract it into a
            // real folder and offer that folder's URL so a Finder paste recreates
            // the tree, not the archive file. Cache the extracted folder per rep
            // so a repeated `.fileURL` pull returns it instead of re-extracting.
            if let cached = promise.stagedInlineURLs[repIndex],
                FileManager.default.fileExists(atPath: cached.path)
            {
                return Data(cached.absoluteString.utf8)
            }
            // The shared helper (also used by the host) does the free-space floor
            // check + reserveDirectory + extract, returning nil on any failure.
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
        // payload returns the same file instead of re-staging a duplicate
        // (`ClipboardFileStaging` would otherwise mint `name (2).ext`).
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

    /// Drops the strong reference to a provider the pasteboard no longer needs.
    private func providerFinished(_ provider: LazyClipboardDataProvider) {
        liveProviders.remove(provider)
    }

    /// One promised pasteboard item: each pasteboard type it offers paired with
    /// the offer-rep index that backs it.
    ///
    /// Carrying the index per type lets each item's provider resolve a requested
    /// type to the correct rep *within that item* — so an offer's several file
    /// reps each map their `.fileURL` to their own file instead of all
    /// collapsing to the first.
    private typealias PromisedItem = [(type: NSPasteboard.PasteboardType, repIndex: Int)]

    /// Whether an offered rep may be promised and pulled — the receive-side
    /// sanitization gate.
    ///
    /// An identity-skip type (transient marker, raw `public.file-url` smuggle) or
    /// an empty rep is never surfaced. `promisedItems` carries each surviving
    /// rep's index alongside its promised type, so a `provideData` pull can only
    /// reach a rep this gate kept — a smuggle is dropped here and is therefore
    /// unreachable, with no separate index lookup to keep in sync.
    private static func isPromisable(_ info: Kernova_V1_ClipboardRepresentationInfo) -> Bool {
        info.byteCount != 0 && !ClipboardSnapshotPolicy.shouldSkipBeforeReading(uti: info.uti)
    }

    /// The promised pasteboard items for an offer, applying the same
    /// inline-vs-file rule as the eager path.
    ///
    /// Inline-only reps (no filename) share one item promising each rep's content
    /// UTI; each file rep gets its own item promising `public.file-url` (and its
    /// image UTI when it's an image file). Receive-side sanitization (the lazy
    /// counterpart of `ClipboardSnapshotPolicy.sanitizedForApply`): an
    /// identity-skip type or an empty rep is never promised. Each promised type
    /// carries the offer-rep index that backs it.
    private static func promisedItems(
        for reps: [Kernova_V1_ClipboardRepresentationInfo]
    ) -> [PromisedItem] {
        var items: [PromisedItem] = []

        // One shared inline item for all inline-only (filename-less) reps.
        var inlineItem: PromisedItem = []
        var seen: Set<String> = []
        for (index, info) in reps.enumerated() where isPromisable(info) {
            guard info.filename.isEmpty, info.isInline else { continue }
            if seen.insert(info.uti).inserted {
                inlineItem.append((NSPasteboard.PasteboardType(info.uti), index))
            }
        }
        if !inlineItem.isEmpty { items.append(inlineItem) }

        // One item per file rep (image files also promise their image UTI).
        for (index, info) in reps.enumerated() where isPromisable(info) {
            guard !info.filename.isEmpty else { continue }
            var item: PromisedItem = []
            if info.isInline {
                item.append((NSPasteboard.PasteboardType(info.uti), index))
            }
            item.append((.fileURL, index))
            items.append(item)
        }
        return items
    }

    /// Whether a representation's bytes should be written inline (vs. carried
    /// only as a materialized file URL).
    ///
    /// Non-file content and image file
    /// payloads inline; every other file payload is file-only. A directory is
    /// always file-only — its bytes are an archive of the tree, never inlined.
    static func shouldInline(_ representation: ClipboardContent.Representation) -> Bool {
        if representation.isDirectory { return false }
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
            $0.isDirectory = representation.isDirectory
        }
    }
}
