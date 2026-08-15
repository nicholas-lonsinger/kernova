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

    /// How long a reported paste refusal silences further refusals of the same
    /// offer.
    ///
    /// One paste gesture fires one data provider per promised item, so its
    /// refusals arrive as a burst and are worth one message; a paste made after
    /// the window is a second gesture and is owed its own answer.
    static let refusalBurstWindow: TimeInterval = 2

    /// What the paste progress readout calls the machine the bytes come from —
    /// the guest can't learn the host's actual computer name over the control
    /// handshake.
    private static let pasteSourceName = "Mac"

    private let client: VsockGuestClient
    private let pasteboard: Pasteboard

    /// Time source for the refusal-burst window; a manually advanced clock in
    /// tests, the platform clock in production.
    private let clock: any EngineClock

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

    /// Log coordinate for the connection being served: generations and transfer
    /// ids restart with each one, and with the agent process itself.
    private var connectionTag = ClipboardConnectionTag.guestUnconnected

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

    /// The outbound generation whose transfers the user cancelled.
    ///
    /// Cancelling aborts what is streaming, but the host decides what it pulls
    /// and would simply request the next representation of a still-live offer,
    /// bringing the readout back a beat later. The latch is what ends the
    /// operation rather than one of its files; a later paste is a fresh gesture
    /// against a fresh generation.
    private var cancelledOutboundGeneration: UInt64?

    /// The host offer currently promised on the guest pasteboard, with its
    /// per-representation materialization cache.
    private var inboundPromise: InboundPromise?

    /// Bridges the synchronous `provideDataForType` callback to the off-actor
    /// stream receive, holding the main thread — its event loop still running —
    /// until bytes land.
    private let lazyCoordinator = LazyPullCoordinator()

    /// Owner of the data providers still promised on the pasteboard, keeping each
    /// alive until `pasteboardFinishedWithDataProvider` fires (Apple requires it).
    private let retainer = LazyClipboardProviderRegistry()

    /// Last `NSPasteboard.changeCount` we observed; set after every poll and
    /// every host write so we don't echo our own content.
    ///
    /// `Self.unobservedChangeCount` until a poll on this connection has seen the
    /// pasteboard, so whatever is standing is re-evaluated for the new host.
    private var lastPasteboardChangeCount: Int

    /// `lastPasteboardChangeCount` before this connection has observed anything.
    ///
    /// No real `changeCount` is negative, so the first poll of a connection
    /// always re-evaluates the standing snapshot — and knows it is looking at
    /// one it never watched arrive.
    private static let unobservedChangeCount = -1

    /// Digest of the most recent content we offered the host; suppresses
    /// redundant outbound offers on an unchanged clipboard.
    private var lastSeenDigest: Data?

    /// Materializes streamed file payloads to local temp files.
    ///
    /// Never swept on teardown/disable — its files may still back vended
    /// pasteboard URLs; the generation window bounds it, and `reclaimAll` at
    /// agent launch clears earlier processes' roots.
    private let staging: ClipboardFileStaging

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

    /// Ceiling on the total of an inbound paste's file representations, as
    /// pushed by the host.
    ///
    /// Starts at the built-in default and is replaced by the host's first
    /// `PolicyUpdate` — which is also what turns sharing on, so no paste is ever
    /// gated on the placeholder.
    ///
    /// Main-queue confined, like `enabled`: `provideData` — and the
    /// `allowsFileURLPull` gate inside it — runs on the agent's main thread.
    private var maxPasteBytes: Int = ClipboardPasteLimit.defaultBytes

    #if DEBUG
    /// Test seam.
    var isEnabledForTesting: Bool { enabled }

    /// Test seam for the applied ceiling, so a test can wait for a pushed policy
    /// to land instead of polling for its side effects.
    var pasteLimitForTesting: Int { maxPasteBytes }
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
        /// When this offer's last refusal was reported, opening the burst window
        /// that keeps the rest of one paste's provider fires quiet.
        var lastRefusalReportedAt: EngineInstant?

        init(generation: UInt64, reps: [Kernova_V1_ClipboardRepresentationInfo]) {
            self.generation = generation
            self.reps = reps
        }
    }

    // MARK: - Init

    /// Production init — uses real `NSPasteboard.general` on the clipboard port,
    /// reporting progress through the agent-wide `progressTracker` and clipboard
    /// refusals through `onClipboardNotice`.
    convenience init(
        progressTracker: ClipboardProgressTracker,
        onClipboardNotice: @escaping @Sendable () -> Void
    ) {
        self.init(
            pasteboard: NSPasteboard.general,
            client: VsockGuestClient(port: KernovaVsockPort.clipboard, label: "clipboard"),
            progressTracker: progressTracker,
            onClipboardNotice: onClipboardNotice
        )
    }

    /// Designated init; tests inject a fake pasteboard and socketpair-backed
    /// client, and optionally a manually advanced `clock` to cross the
    /// refusal-burst window without waiting, a `freeSpaceProvider` to simulate a
    /// full disk, a `stagingTempRoot` to isolate the staging directory between
    /// parallel tests, an `onProgress` sink to observe the readout the status
    /// item renders, an `onClipboardNotice` sink to observe refusals, and zeroed
    /// reveal/linger delays so a test transfer surfaces while in flight.
    ///
    /// `progressTracker` is the agent's single readout authority, shared with
    /// every other agent that transfers files, so one status item never has two
    /// sources deciding what it shows. A test that only cares about the clipboard
    /// leaves it out and gets one built from `progressRevealDelay` /
    /// `progressIdleLinger` / `onProgress`.
    init(
        pasteboard: Pasteboard, client: VsockGuestClient,
        clock: any EngineClock = makePlatformEngineClock(),
        freeSpaceProvider: ClipboardFileStaging.FreeSpaceProvider? = nil,
        stagingTempRoot: URL = FileManager.default.temporaryDirectory,
        progressTracker: ClipboardProgressTracker? = nil,
        progressRevealDelay: TimeInterval = ClipboardProgressTracker.defaultRevealDelay,
        progressIdleLinger: TimeInterval = ClipboardProgressTracker.defaultIdleLinger,
        onProgress: @escaping @Sendable (ClipboardProgressSnapshot?) -> Void = { _ in },
        onClipboardNotice: @escaping @Sendable () -> Void = {}
    ) {
        self.pasteboard = pasteboard
        self.client = client
        self.clock = clock
        self.onClipboardNotice = onClipboardNotice
        self.progressTracker =
            progressTracker
            ?? ClipboardProgressTracker(
                revealDelay: progressRevealDelay, idleLinger: progressIdleLinger, emit: onProgress)
        self.staging = ClipboardFileStaging(
            label: "agent", tempRoot: stagingTempRoot, freeSpaceProvider: freeSpaceProvider)
        self.lastPasteboardChangeCount = pasteboard.changeCount
        // Default-disabled: pause the reconnect loop until the host enables.
        self.client.pause()
    }

    // MARK: - Lifecycle

    func start() {
        client.start { [weak self] channel in
            await self?.serve(channel: channel)
        }
        Self.logger.notice("Vsock clipboard agent started")
    }

    /// Applies a host policy update: whether clipboard sharing is on, and the
    /// ceiling this side enforces on an inbound paste's file reps.
    ///
    /// One call rather than a setter per field — the control agent delivers the
    /// policy off-main, and two independently scheduled hops could apply a
    /// snapshot's halves out of order.
    func applyPolicy(enabled: Bool, maxPasteBytes: Int) {
        DispatchQueue.main.async { [weak self] in
            self?.maxPasteBytes = maxPasteBytes
            self?.applyEnabledOnMain(enabled)
        }
    }

    private func applyEnabledOnMain(_ enabled: Bool) {
        // Ahead of the no-change guard, so an update that only restates
        // "enabled" still reaches `resume()` — see its doc comment.
        if enabled { client.resume() }
        guard self.enabled != enabled else { return }
        self.enabled = enabled
        if enabled {
            startPolling()
            clipboardActivityStorage = .enabled
            Self.logger.notice("Clipboard sharing enabled by host policy")
        } else {
            client.pause()
            pollingTimer?.cancel()
            pollingTimer = nil
            teardownConnectionState()
            // Receive staging survives a disable: its files may still back
            // `public.file-url`s the guest pasteboard vended, and a URL vended to
            // a pasteboard outlives the session that staged it (mirrors the
            // host's stop()).
            clipboardActivityStorage = .disabled
            Self.logger.notice("Clipboard sharing disabled by host policy")
        }
    }

    /// Tears down the connection and the poll timer.
    ///
    /// Receive staging is deliberately left in place — see `applyEnabledOnMain`.
    func stop() {
        client.stop()
        DispatchQueue.main.async { [weak self] in
            self?.pollingTimer?.cancel()
            self?.pollingTimer = nil
            self?.teardownConnectionState()
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
            direction: .outbound, peerName: Self.pasteSourceName,
            onCancelRequested: { [weak self] in
                DispatchQueue.main.async { self?.cancelOutboundTransfers(generation: generation) }
            })
        outboundSession = (generation: generation, token: token)
        return token
    }

    /// Stops streaming what the host is pulling for `generation`, because the
    /// user cancelled the readout in this guest.
    ///
    /// The offer stands: the host can paste again and pull the same
    /// representations. The sender's abort carries `superseded`, which the host
    /// already retires quietly, so the host's paste comes back empty without
    /// either side reporting a failure.
    private func cancelOutboundTransfers(generation: UInt64) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let sender else { return }
        cancelledOutboundGeneration = generation
        sender.cancel(generation: generation)
        Self.logger.notice(
            "User cancelled the outbound clipboard transfer (gen=\(generation, privacy: .public), conn=\(self.connectionTag, privacy: .public))"
        )
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
        // Only this agent's own session is retired, never `clearAll()`: the
        // tracker is the whole agent's readout authority and another agent's
        // transfer may be live on it, which a clipboard teardown has no business
        // wiping off the status item.
        if let session = outboundSession {
            progressTracker.closeSession(session.token, immediately: true)
        }
        outboundSession = nil
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
        let connectionTag = ClipboardConnectionTag.nextGuest()
        // The engine is created off-main (its callbacks hop to main themselves);
        // only the published references are assigned on the main queue.
        let sender = ClipboardStreamSender(
            channel: channel,
            // Reaches the host through log forwarding, which is what makes a
            // guest→host send readable without attaching to the guest — so it
            // logs at `.notice` (persisted) rather than `.debug`.
            onTransferTimed: { metrics in
                Self.logger.notice(
                    "Guest→host clipboard transfer \(metrics.transferID, privacy: .public) (conn=\(connectionTag, privacy: .public)) sent: \(metrics.logSummary, privacy: .public)"
                )
            })
        let receiver = ClipboardStreamReceiver(
            channel: channel, staging: self.staging,
            // The only measured throughput number for the real vsock link, so it
            // logs at `.notice` (persisted) rather than `.debug`.
            onTransferTimed: { metrics in
                Self.logger.notice(
                    "Host→guest clipboard transfer \(metrics.transferID, privacy: .public) (conn=\(connectionTag, privacy: .public)) completed: \(metrics.logSummary, privacy: .public)"
                )
            },
            // A lazy pull's per-transfer awaiter takes precedence over these
            // channel-wide closures, so they fire only for an unawaited transfer.
            onComplete: { transferID, _ in
                Self.logger.warning(
                    "Unawaited inbound clipboard transfer \(transferID, privacy: .public) (conn=\(connectionTag, privacy: .public)) completed — dropped"
                )
            },
            onAbort: { info in
                Self.logger.debug(
                    "Unawaited inbound clipboard transfer \(info.transferID, privacy: .public) (conn=\(connectionTag, privacy: .public)) aborted (\(info.rawCode, privacy: .public))"
                )
            })
        await MainActor.run {
            self.connectionTag = connectionTag
            self.liveChannel = channel
            self.sender = sender
            self.receiver = receiver
            self.pendingOutbound = nil
            self.currentOutboundGeneration.set(0)
            self.inboundPromise = nil
            // A brand-new host has no record of prior offers; re-announce.
            self.lastSeenDigest = nil
            self.lastPasteboardChangeCount = Self.unobservedChangeCount
        }
        Self.logger.notice(
            "Vsock clipboard connected to host (conn=\(connectionTag, privacy: .public))")

        do {
            for try await frame in channel.incoming where frame.protocolVersion == 1 {
                // High-frequency stream frames go straight to the thread-safe
                // engine off the main queue; only control frames hop to main.
                ClipboardStreamRouting.route(
                    frame, role: .guest, sender: sender, receiver: receiver,
                    senderAbortDelivery: .direct,
                    onControlFrame: { frame in
                        // Control frames are serialized on the main queue, so
                        // while a synchronous `provideData` pull blocks main they
                        // queue behind it; a pull is woken by its off-main Abort,
                        // not by these.
                        DispatchQueue.main.async { [weak self] in
                            self?.handleControlFrame(frame)
                        }
                    })
            }
            Self.logger.notice(
                "Vsock clipboard channel closed by host (conn=\(connectionTag, privacy: .public))")
        } catch {
            Self.logger.warning(
                "Vsock clipboard channel ended with error (conn=\(connectionTag, privacy: .public)): \(error.localizedDescription, privacy: .public)"
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

        // Read once: the marker disposition, the flavors worth reading, and the
        // account an empty result owes the menu all have to describe the same
        // snapshot.
        let firstItemTypes = pasteboard.firstItemTypes

        // `org.nspasteboard.*` marker handling, from the unfiltered first-item
        // type list: a transient/auto-generated snapshot is never offered; a
        // concealed one (a password) is offered but flagged so the host window
        // hides it. Folders are never concealed secrets, so the estimate path
        // below ignores the flag.
        let disposition = ClipboardSnapshotPolicy.disposition(
            forTypes: firstItemTypes.map(\.rawValue))
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
        let raw: [(uti: String, data: Data)] = firstItemTypes.compactMap { type in
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
        guard !content.isEmpty else {
            noteSnapshotOfferedNothing(
                pasteboardHeldSomething: !firstItemTypes.isEmpty, changeCount: currentCount)
            return
        }
        sendOfferIfNeeded(content, channel: channel, changeCount: currentCount)
    }

    /// Retires the host's offer for a snapshot that yielded nothing offerable,
    /// and tells the guest's own menu when a copy is what came up empty.
    ///
    /// `pasteboardHeldSomething` separates a copy whose every flavor was
    /// filtered out from a pasteboard emptied outright, which are not the same
    /// news. Only a snapshot a poll on this connection watched arrive is a copy
    /// at all: the first poll re-evaluates whatever was already standing —
    /// including a promise this agent wrote, whose providers stop serving the
    /// moment the promise behind them is dropped — so it re-announces silently
    /// rather than reporting a gesture nobody just made.
    private func noteSnapshotOfferedNothing(pasteboardHeldSomething: Bool, changeCount: Int) {
        // The pasteboard still moved on, so the host's previous offer is retired
        // rather than left serving a copy the user has replaced.
        let released = releaseOutboundOffer("the copy left nothing that can cross")
        let watchedItArrive = lastPasteboardChangeCount != Self.unobservedChangeCount
        lastPasteboardChangeCount = changeCount
        guard pasteboardHeldSomething, watchedItArrive else {
            // Nobody's copy came up short here, so the only line that can be
            // left wrong is one claiming the offer this just withdrew.
            if released { clipboardActivityStorage = .enabled }
            return
        }
        // A copy was made in this guest and none of it could cross. Its own menu
        // is the only account of that (docs/CLIPBOARD.md §13), and without one
        // the line still reads as the copy before it, which did.
        Self.logger.notice(
            "Copy left nothing that can be offered to the host (conn=\(self.connectionTag, privacy: .public))"
        )
        clipboardActivityStorage = .copyCarriedNothing
        onClipboardNotice()
    }

    /// Announces `content` to the host when it's non-empty and not an echo of
    /// what we last wrote/sent, advancing the dedup + change-count bookkeeping.
    private func sendOfferIfNeeded(
        _ content: ClipboardContent, channel: VsockChannel, changeCount: Int
    ) {
        guard !content.isEmpty else {
            // A caller that can observe an empty snapshot classifies it itself;
            // one that hasn't can't claim a copy came up short.
            noteSnapshotOfferedNothing(pasteboardHeldSomething: false, changeCount: changeCount)
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
                "Sent clipboard offer (gen=\(generation, privacy: .public), conn=\(self.connectionTag, privacy: .public), \(offered.representations.count, privacy: .public) reps, \(offered.totalByteCount, privacy: .public) bytes)"
            )
        } catch {
            Self.logger.warning(
                "Failed to send clipboard offer: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Retires the offer the host still holds, because this snapshot left nothing
    /// to replace it with, reporting whether one was actually withdrawn.
    ///
    /// `ClipboardRelease` rather than an empty offer: an offer with no
    /// representations drops the host's promise but leaves the pasteboard item
    /// behind it advertising flavors nothing can serve, where a release clears
    /// that write too. Idempotent — the released offer is forgotten, so the later
    /// calls a still-unofferable snapshot draws send nothing. A snapshot an
    /// `org.nspasteboard.*` marker suppressed never reaches here: by that
    /// marker's convention it is not a copy, and the clipboard before it still
    /// stands.
    @discardableResult
    private func releaseOutboundOffer(_ reason: String) -> Bool {
        guard let channel = liveChannel, let previous = pendingOutbound else { return false }
        var frame = Frame()
        frame.protocolVersion = 1
        frame.clipboardRelease = Kernova_V1_ClipboardRelease.with {
            $0.generation = previous.generation
        }
        do {
            try channel.send(frame)
        } catch {
            Self.logger.warning(
                "Failed to release clipboard offer gen=\(previous.generation, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
        sender?.cancel(generation: previous.generation)
        pendingOutbound = nil
        currentOutboundGeneration.set(0)
        // The send-dedup latch means "the host already has this", which the
        // release just made false — so re-copying the released content is a new
        // copy to a host whose clipboard this emptied, not a redundant offer.
        // A fresh connection clears it for the same reason.
        lastSeenDigest = nil
        Self.logger.notice(
            "Released clipboard offer gen=\(previous.generation, privacy: .public) (conn=\(self.connectionTag, privacy: .public)) — \(reason, privacy: .public)"
        )
        return true
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
    /// Size gates nothing: a directory's inode `.fileSize` is meaningless, and a
    /// zero-byte file is content native macOS copies. An item inside our own
    /// staging root (materialized from a prior inbound paste) is skipped so it
    /// can't be offered back to the host — that one is by design, so only the
    /// unreadable items below are counted and logged.
    private func fileExpansionCandidates() -> [FileCandidate] {
        var candidates: [FileCandidate] = []
        var unreadable = 0
        for url in pasteboard.itemFileURLs where !staging.isInStagingRoot(url) {
            guard
                let values = try? url.resourceValues(forKeys: [
                    .contentTypeKey, .isDirectoryKey, .fileSizeKey,
                ])
            else {
                unreadable += 1
                continue
            }
            if values.isDirectory == true {
                candidates.append(
                    FileCandidate(
                        url: url, type: values.contentType ?? .folder,
                        filename: url.lastPathComponent, byteCount: 0, isDirectory: true))
            } else {
                guard let type = values.contentType, let size = values.fileSize else {
                    unreadable += 1
                    continue
                }
                candidates.append(
                    FileCandidate(
                        url: url, type: type, filename: url.lastPathComponent, byteCount: size,
                        isDirectory: false))
            }
        }
        if unreadable > 0 {
            Self.logger.warning(
                "Skipped \(unreadable, privacy: .public) unreadable copied item(s) — not offered to the host"
            )
        }
        return candidates
    }

    /// Sizes any folder candidate off the main queue — a stat-walk estimate, no
    /// archive — then offers the mixed file/folder content back on main.
    ///
    /// A large tree's walk would freeze the agent's run loop, so it hops to a
    /// global queue and back; the tree is encoded only when the host requests the
    /// rep, and then straight onto the wire.
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
                        estimatedByteCount: ClipboardArchive.estimatedByteCount(
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
        case .hello, .heartbeat, .policyUpdate, .logRecord, .dropOffer, .dropComplete,
            .dropRelease, .none:
            Self.logger.warning("Unexpected payload on clipboard channel — wrong port")
        }
    }

    // MARK: - Outbound (we are the sender)

    private func handleRequest(_ request: Kernova_V1_ClipboardRequest) {
        guard cancelledOutboundGeneration != request.generation else {
            Self.logger.debug(
                "Clipboard request for cancelled gen=\(request.generation, privacy: .public) (conn=\(self.connectionTag, privacy: .public)) — refusing"
            )
            // Refused as stale, which the host already retires quietly: its paste
            // comes back empty and neither side reports a failure.
            sender?.rejectRequest(
                transferID: request.transferID, code: .requestStale,
                message: "The transfer for generation \(request.generation) was cancelled")
            return
        }
        guard let pending = pendingOutbound, pending.generation == request.generation else {
            Self.logger.debug(
                "Stale clipboard request gen=\(request.generation, privacy: .public) (pending=\(self.pendingOutbound?.generation ?? 0, privacy: .public), conn=\(self.connectionTag, privacy: .public))"
            )
            // Abort every dropped request so the host's parked pull wakes
            // immediately instead of stalling to its lazyPullTimeout backstop.
            sender?.rejectRequest(
                transferID: request.transferID, code: .requestStale,
                message: "Request for superseded generation \(request.generation)")
            return
        }
        let repIndex = Int(request.transferID & 0xFFFF)
        guard repIndex < pending.content.representations.count else {
            Self.logger.warning(
                "Clipboard request transfer_id \(request.transferID, privacy: .public) (conn=\(self.connectionTag, privacy: .public)) out of range"
            )
            sender?.rejectRequest(
                transferID: request.transferID, code: .requestRange,
                message: "Representation index \(repIndex) out of range")
            return
        }
        let representation = pending.content.representations[repIndex]
        guard representation.uti == request.uti else {
            Self.logger.warning(
                "Clipboard request uti '\(request.uti, privacy: .public)' doesn't match offered rep \(repIndex, privacy: .public) (conn=\(self.connectionTag, privacy: .public))"
            )
            sender?.rejectRequest(
                transferID: request.transferID, code: .requestUTI,
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
            "Streaming clipboard rep \(repIndex, privacy: .public) (gen=\(request.generation, privacy: .public), conn=\(self.connectionTag, privacy: .public), \(representation.byteCount, privacy: .public) bytes offered)"
        )
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

        // Every field of the offer is host-supplied. Bound the rep count and each
        // declared size once, here at intake, so no deadline, capacity, or
        // progress arithmetic downstream reasons about a value that can't be
        // real.
        let bounded = ClipboardOfferBounds.bounded(offer.repInfo)
        if let truncatedFrom = bounded.truncatedFrom {
            Self.logger.warning(
                "Host clipboard offer (gen=\(offer.generation, privacy: .public), conn=\(self.connectionTag, privacy: .public)) declared \(truncatedFrom, privacy: .public) representations — truncated to \(bounded.reps.count, privacy: .public)"
            )
        }
        if bounded.clampedCount > 0 {
            Self.logger.warning(
                "Clamped \(bounded.clampedCount, privacy: .public) implausible declared byte count(s) in the host clipboard offer (gen=\(offer.generation, privacy: .public), conn=\(self.connectionTag, privacy: .public))"
            )
        }

        let items = Self.promisedItems(for: bounded.reps)
        guard !items.isEmpty else {
            Self.logger.warning(
                "Dropped the host clipboard offer (gen=\(offer.generation, privacy: .public), conn=\(self.connectionTag, privacy: .public)): none of its \(bounded.reps.count, privacy: .public) representation(s) survived receive-side filtering — nothing promised"
            )
            inboundPromise = nil
            return
        }

        let promise = InboundPromise(generation: offer.generation, reps: bounded.reps)
        inboundPromise = promise

        guard writePasteboardPromise(promise: promise, items: items) else {
            Self.logger.warning(
                "Failed to register host clipboard promise (gen=\(offer.generation, privacy: .public), conn=\(self.connectionTag, privacy: .public))"
            )
            // The write failed, so the providers were never retained — there is
            // nothing to retract.
            inboundPromise = nil
            return
        }
        Self.logger.notice(
            "Registered host clipboard promise (gen=\(offer.generation, privacy: .public), conn=\(self.connectionTag, privacy: .public), \(items.count, privacy: .public) item(s))"
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

        // `.currentHostOnly` (docs/CLIPBOARD.md §3) is per-write state, reset by
        // every prepare/clear, so it is applied at this single publication choke
        // point.
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
    /// `provideDataForType` callback), whose event loop keeps running while the
    /// pull waits — so control frames, the poll and even a second promise
    /// callback can land mid-pull; a supersession landing there cancels the pull.
    /// `itemTypes` is the promising item's own type → rep-index map, so a
    /// `.fileURL` pull resolves to *this* item's file rep rather than the first
    /// file rep across the offer. Returns `nil` on a stale generation, a type
    /// this item never promised, or a failed pull.
    private func provideData(
        _ type: NSPasteboard.PasteboardType, itemTypes: PromisedItem, generation: UInt64
    ) -> Data? {
        guard let promise = inboundPromise, promise.generation == generation else {
            Self.logger.debug(
                "provideData for stale clipboard generation \(generation, privacy: .public) (conn=\(self.connectionTag, privacy: .public))"
            )
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
            // The deadline cap and the free-space pre-flight both belong to the
            // `.fileURL` flavor: it is the one whose bytes have to land as a file
            // inside the OS paste deadline. The same rep's inline flavor — an
            // image file promises both — carries no size bound (§1).
            guard type != .fileURL || allowsFileURLPull(repIndex, promise: promise, channel: channel)
            else { return nil }
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
    /// holds the calling thread until the transfer resolves — the shared
    /// transport core of every inbound pull.
    ///
    /// The deadlock-safe wakeup: the receiver's `awaitTransfer` handler fires
    /// off-main into the coordinator, never hopping to the thread this call
    /// holds.
    private func awaitPull(
        transferID: UInt64, receiver: ClipboardStreamReceiver,
        extractsDirectoryNamed: String? = nil, advertisedByteCount: Int = 0,
        sendRequest: @escaping () throws -> Void
    ) -> LazyPullOutcome {
        let coordinator = lazyCoordinator
        receiver.awaitTransfer(
            transferID,
            extractsDirectoryNamed: extractsDirectoryNamed,
            advertisedByteCount: advertisedByteCount,
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
                        transferID: transferID, code: .sendFailed,
                        message: "Failed to send clipboard request", neededBytes: nil,
                        availableBytes: nil))
            }
        }
    }

    /// Whether a `.fileURL` fire may start its pull: the offer's deadline-bound
    /// total is within the cap, and the rep fits the staging volume.
    ///
    /// Both gates report their refusal before returning `false`, on the guest's
    /// own menu and to the host.
    private func allowsFileURLPull(
        _ repIndex: Int, promise: InboundPromise, channel: VsockChannel
    ) -> Bool {
        let info = promise.reps[repIndex]
        // The cap applies to the TOTAL of the offer's deadline-bound reps,
        // all-or-nothing: one paste is one deadline-bound operation, so the OS
        // clock sees the sum, not each file. Checked before the disk-space gate:
        // an over-cap offer never gets far enough to need the space.
        let totalBytes = Self.syncDeadlineBoundLoad(for: promise)
        if totalBytes > UInt64(maxPasteBytes) {
            Self.logger.warning(
                "Deadline-bound clipboard reps total \(totalBytes, privacy: .public) bytes — over the \(self.maxPasteBytes, privacy: .public)-byte cap; refusing the paste pull"
            )
            reportPasteFailure(
                code: .pasteTooLarge,
                message: "Too large to paste into the guest (\(totalBytes) bytes total)",
                promise: promise, on: channel)
            return false
        }
        if !staging.hasCapacity(forByteCount: Int(clamping: info.byteCount)) {
            Self.logger.warning(
                "Not enough disk space to receive clipboard rep '\(info.uti, privacy: .public)' (\(info.byteCount, privacy: .public) bytes)"
            )
            reportPasteFailure(
                code: .pasteDiskFull,
                message: "Not enough disk space in the guest to receive \(info.byteCount) bytes",
                promise: promise, on: channel)
            return false
        }
        return true
    }

    /// Sends one `ClipboardRequest` and blocks the calling thread until the
    /// streamed representation lands (or aborts/times out).
    ///
    /// The `.fileURL` flavor's deadline and free-space gates run in
    /// `allowsFileURLPull` before this is reached.
    private func pullRepresentation(
        _ repIndex: Int, promise: InboundPromise, channel: VsockChannel,
        receiver: ClipboardStreamReceiver
    ) -> ClipboardContent.Representation? {
        let info = promise.reps[repIndex]
        // The guest is the receiver, so it does not set the direction bit.
        let transferID = ClipboardTransferID.make(
            generation: promise.generation, repIndex: repIndex, hostMinted: false)
        let maxAccept =
            staging.availableCapacity().map { UInt64(clamping: $0) }
            ?? ClipboardStreamTuning.unlimitedAcceptByteCount

        let generation = promise.generation
        let uti = info.uti
        // A folder's bytes are an archive of its tree, extracted as they arrive:
        // the stream layer learns that here, from the offer this side already
        // read, rather than from the wire — including the size the extract is
        // held to.
        let outcome = awaitPull(
            transferID: transferID, receiver: receiver,
            extractsDirectoryNamed: info.isDirectory ? info.filename : nil,
            advertisedByteCount: Int(clamping: info.byteCount)
        ) {
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
            return representation
        case .aborted(let abort):
            Self.logger.warning(
                "Inbound clipboard pull \(transferID, privacy: .public) (conn=\(self.connectionTag, privacy: .public)) aborted (\(abort.rawCode, privacy: .public))"
            )
            // Report a genuine receive failure; stay quiet for a normal
            // supersession/teardown (the user simply copied something new).
            if !abort.isRetiring {
                reportPasteFailure(
                    code: Self.pasteErrorCode(forAbortCode: abort.code),
                    message: abort.message, promise: promise, on: channel)
            }
        case .timedOut:
            receiver.cancelAwait(transferID)
            Self.logger.warning(
                "Inbound clipboard pull \(transferID, privacy: .public) (conn=\(self.connectionTag, privacy: .public)) timed out"
            )
            // Stop any stream the host is still sending for this abandoned pull,
            // then report the failure.
            sendStreamAbort(
                transferID: transferID, code: .pasteTimeout,
                message: "Receiver gave up waiting for the clipboard transfer", on: channel)
            reportPasteFailure(
                code: .pasteTimeout,
                message: "The clipboard transfer to the guest timed out", promise: promise,
                on: channel)
        case .cancelled:
            // `.debug`, not `.warning`: `.cancelled` also covers benign
            // teardown/supersession, which is deliberately silent elsewhere.
            Self.logger.debug(
                "Inbound clipboard pull \(transferID, privacy: .public) (conn=\(self.connectionTag, privacy: .public)) cancelled"
            )
            receiver.cancelAwait(transferID)
        case .superseded:
            // A newer pull for this id has already taken over the awaiter/slot
            // registration — touch nothing keyed by `transferID` (no
            // `cancelAwait`, no abort frame, no paste error): the retry owns it
            // now and must resolve on its own.
            Self.logger.debug(
                "Inbound clipboard pull \(transferID, privacy: .public) (conn=\(self.connectionTag, privacy: .public)) superseded by a newer fetch"
            )
        }
        return nil
    }

    /// Records the "received from host" menu signal on the queue that owns it.
    private func recordReceivedFromHost() {
        DispatchQueue.main.async { [weak self] in
            self?.clipboardActivityStorage = .receivedFromHost
        }
    }

    /// Records a paste failure on the queue that owns the menu state, then raises
    /// the notice so the surface reveals it.
    ///
    /// The activity is written before the notice, so the dropdown the notice pops
    /// is rebuilt with the line already in it. `generation` is re-checked here
    /// because the hop runs after `provideData` has returned: an offer that
    /// landed in the meantime is live and pastable, and must not be overwritten
    /// with the previous offer's failure.
    private func recordPasteFailure(code: ClipboardErrorCode, generation: UInt64) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.inboundPromise?.generation == generation else { return }
            // Capture the ceiling now: a host that raises it after this refusal
            // must not rewrite the figure this refusal names.
            self.clipboardActivityStorage = .pasteRefused(
                code, pasteLimitBytes: code == .pasteTooLarge ? self.maxPasteBytes : nil)
            self.onClipboardNotice()
        }
    }

    #if DEBUG
    /// Test seam for the hop's staleness check.
    func recordPasteFailureForTesting(code: ClipboardErrorCode, generation: UInt64) {
        recordPasteFailure(code: code, generation: generation)
    }
    #endif

    /// Whether a refusal for `promise` may be reported now, opening the burst
    /// window when it may.
    private func allowsRefusalReport(for promise: InboundPromise) -> Bool {
        let now = clock.now
        if let last = promise.lastRefusalReportedAt, last.seconds(to: now) < Self.refusalBurstWindow {
            return false
        }
        promise.lastRefusalReportedAt = now
        return true
    }

    /// Maps a receiver/peer abort code to the user-facing paste code the host
    /// renders.
    private static func pasteErrorCode(
        forAbortCode code: ClipboardStreamAbortCode?
    ) -> ClipboardErrorCode {
        switch code {
        case .diskFull: return .pasteDiskFull
        case .stallTimeout: return .pasteTimeout
        default: return .pasteFailed
        }
    }

    /// Reports an inbound-paste failure on both surfaces the gesture is owed: the
    /// guest's own menu, since the paste was made here, and an `Error` frame so
    /// the host's clipboard window shows it too.
    ///
    /// The single choke point for every paste failure, deduped by the offer's
    /// refusal-burst window — one paste fires one provider per promised item, so
    /// its failures are reported once, while a later paste of the same offer is a
    /// fresh gesture and reports again.
    private func reportPasteFailure(
        code: ClipboardErrorCode, message: String, promise: InboundPromise, on channel: VsockChannel
    ) {
        guard allowsRefusalReport(for: promise) else { return }
        try? channel.sendErrorFrame(
            code: code.rawValue, message: message, inReplyTo: "clipboard.request")
        recordPasteFailure(code: code, generation: promise.generation)
    }

    /// Sends a `ClipboardStreamAbort` for an inbound transfer the receiver is
    /// abandoning, so the host's sender stops streaming the remaining bytes.
    private func sendStreamAbort(
        transferID: UInt64, code: ClipboardStreamAbortCode, message: String, on channel: VsockChannel
    ) {
        var frame = Frame()
        frame.protocolVersion = 1
        frame.clipboardStreamAbort = .with {
            $0.transferID = transferID
            $0.code = code.rawValue
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
        // A folder rep arrives already unpacked — its transfer extracted the tree
        // as the archive streamed — so `fileURL` below is the tree itself and
        // serving it costs nothing inside the paste deadline.
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
    /// an inline payload with no bytes is never surfaced, and a `provideData`
    /// pull can only reach a rep this gate kept.
    ///
    /// The empty-payload skip is keyed on the *filename*, so it reaches only
    /// inline reps. A named rep is a file the paste creates, and an empty file is
    /// content native macOS copies; a folder's `byte_count` is an estimate of the
    /// tree's file bytes (`kernova.proto`), which a tree of empty files, bare
    /// subdirectories, or nothing at all makes 0 while the archive still carries
    /// the tree.
    private static func isPromisable(_ info: Kernova_V1_ClipboardRepresentationInfo) -> Bool {
        (info.byteCount != 0 || !info.filename.isEmpty)
            && !ClipboardSnapshotPolicy.shouldSkipBeforeReading(uti: info.uti)
    }

    /// Whether a promised item serves this rep as `public.file-url` — the flavor
    /// whose bytes have to land as a file inside the OS paste deadline.
    ///
    /// `ClipboardPasteboardItemPlan` promises `.fileURL` for every promisable rep
    /// carrying a filename, so an image file — which also promises its image UTI
    /// inline — is one of them.
    private static func servesFileURL(_ info: Kernova_V1_ClipboardRepresentationInfo) -> Bool {
        isPromisable(info) && !info.filename.isEmpty
    }

    /// The offer's deadline-bound load — the total byte count of the reps served
    /// as `public.file-url`, the payload one paste pulls against the OS deadline.
    ///
    /// A directory rep contributes the producer's estimate, the same figure the
    /// wire carries as its `byte_count`. The sum saturates, so an absurd declared
    /// total fails the cap rather than wrapping under it.
    private static func syncDeadlineBoundLoad(for promise: InboundPromise) -> UInt64 {
        var total: UInt64 = 0
        for info in promise.reps where servesFileURL(info) {
            total = total.saturatingAdding(info.byteCount)
        }
        return total
    }

    /// The promised pasteboard items for an offer.
    ///
    /// Inline-only reps (no filename) share one item promising each rep's content
    /// UTI; each file rep gets its own item promising `public.file-url` (and its
    /// image UTI when it's an image file). Only reps `isPromisable` keeps are
    /// promised. Each promised type carries the offer-rep index that backs it.
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
            "Host released clipboard offer (gen=\(release.generation, privacy: .public), conn=\(self.connectionTag, privacy: .public))"
        )
    }
}
