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

    /// Where what this side streams to the host is reported, and the seams every
    /// operation opened here is built with.
    private let reporter: ClipboardTransferReporter
    private let progressRevealDelay: TimeInterval
    private let progressIdleGap: TimeInterval

    /// Raised on the main queue when a refusal has just landed in
    /// `clipboardActivity`, so the menu-bar surface can reveal it instead of
    /// waiting for the user to open the dropdown.
    private let onClipboardNotice: @Sendable () -> Void

    // MARK: - Main-queue state

    /// Live channel for the current connection, if any.
    private var liveChannel: VsockChannel?

    /// Log coordinate for the connection being served: generations and transfer
    /// ids restart with each one, and with the agent process itself.
    private var connectionTag = ClipboardConnectionTag.guestUnconnected

    /// Engine, frame routing and control-frame delivery for the current
    /// connection.
    private var session: ClipboardStreamSession?

    /// What this side has offered the host over the current connection, and the
    /// transfers answering its pulls.
    private var outbound: ClipboardOutboundOffers?

    #if DEBUG
    /// Test seam.
    var liveChannelForTesting: VsockChannel? { liveChannel }

    /// Test seam.
    var inboundPromiseGenerationForTesting: UInt64? { inboundPromise?.generation }
    #endif

    /// Generation the next connection's offers continue from, carried across
    /// connections: the agent outlives its channels, and a reconnected host must
    /// never be handed a generation this agent already used.
    private var nextLocalGeneration: UInt64 = 1

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

    /// A run-loop timer, not a dispatch timer on `.main`: the poll reads promised
    /// flavors, and a fire it reaches — a promise this agent wrote — gets a wait
    /// that can drain the main queue only from the run loop's base
    /// (`NestedEventLoopWait`).
    private var pollingTimer: Timer?

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

    /// Fires on the main queue once a copied folder's off-main estimate walk has
    /// landed — whether or not it offered — so a test can await the walk instead
    /// of polling for its side effects.
    var onFolderEstimateCompletedForTesting: (() -> Void)?

    /// Delivers a control frame as the consume loop's main-queue hop would, but
    /// synchronously on the caller's main-queue turn, so a test can order it
    /// against a poll's own asynchronous completion.
    func handleControlFrameForTesting(_ frame: Frame) {
        dispatchPrecondition(condition: .onQueue(.main))
        handleControlFrame(frame)
    }

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
    /// reporting progress through the agent-wide `reporter` and clipboard
    /// refusals through `onClipboardNotice`.
    convenience init(
        reporter: ClipboardTransferReporter,
        onClipboardNotice: @escaping @Sendable () -> Void
    ) {
        self.init(
            pasteboard: NSPasteboard.general,
            client: VsockGuestClient(port: KernovaVsockPort.clipboard, label: "clipboard"),
            reporter: reporter,
            onClipboardNotice: onClipboardNotice
        )
    }

    /// Designated init; tests inject a fake pasteboard and socketpair-backed
    /// client, and optionally a manually advanced `clock` to cross the
    /// refusal-burst window without waiting, a `freeSpaceProvider` to simulate a
    /// full disk, a `stagingTempRoot` to isolate the staging directory between
    /// parallel tests, a `reporter` to observe the readout the status item
    /// renders, an `onClipboardNotice` sink to observe refusals, and zeroed
    /// reveal/idle delays so a test transfer surfaces while in flight.
    ///
    /// `reporter` is the agent's single readout authority, shared with every
    /// other agent that transfers files, so one status item never has two sources
    /// deciding what it shows.
    init(
        pasteboard: Pasteboard, client: VsockGuestClient,
        clock: any EngineClock = makePlatformEngineClock(),
        freeSpaceProvider: ClipboardFileStaging.FreeSpaceProvider? = nil,
        stagingTempRoot: URL = FileManager.default.temporaryDirectory,
        reporter: ClipboardTransferReporter,
        progressRevealDelay: TimeInterval = ClipboardTransferOperation.defaultRevealDelay,
        progressIdleGap: TimeInterval = ClipboardTransferOperation.defaultIdleGap,
        onClipboardNotice: @escaping @Sendable () -> Void = {}
    ) {
        self.pasteboard = pasteboard
        self.client = client
        self.clock = clock
        self.onClipboardNotice = onClipboardNotice
        self.reporter = reporter
        self.progressRevealDelay = progressRevealDelay
        self.progressIdleGap = progressIdleGap
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
            pollingTimer?.invalidate()
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
            self?.pollingTimer?.invalidate()
            self?.pollingTimer = nil
            self?.teardownConnectionState()
        }
        Self.logger.notice("Vsock clipboard agent stopped")
    }

    /// Runs `body` with main-actor isolation assumed, hopping first when the
    /// caller is off-main.
    ///
    /// The agent's state is confined to the main dispatch queue, and the
    /// `@MainActor` KernovaKit types it drives run on that same thread — this is
    /// what tells the compiler so.
    private func onMainActor<T: Sendable>(_ body: @MainActor () -> T) -> T {
        Thread.isMainThread
            ? MainActor.assumeIsolated(body)
            : DispatchQueue.main.sync { MainActor.assumeIsolated(body) }
    }

    /// Clears per-connection streaming + pending state on the main queue.
    private func teardownConnectionState() {
        onMainActor {
            session?.stop()
            // Unblock any provider thread waiting on a pull (returns empty).
            lazyCoordinator.failAll()
            if let outbound {
                nextLocalGeneration = outbound.nextGeneration
                // Only this agent's own operations are retired: the reporter is
                // the whole agent's readout authority and another agent's
                // transfer may be live on it, which a clipboard teardown has no
                // business wiping off the status item.
                outbound.endSession()
            }
        }
        outbound = nil
        session = nil
        liveChannel = nil
        inboundPromise = nil
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
        let session = await MainActor.run { () -> ClipboardStreamSession in
            let session = ClipboardStreamSession(
                channel: channel, role: .guest, kind: .clipboard, label: "clipboard",
                staging: self.staging)
            self.connectionTag = session.connectionTag
            self.liveChannel = channel
            self.session = session
            // A brand-new host has no record of prior offers; the fresh dedup
            // latch is what re-announces the standing snapshot.
            self.outbound = ClipboardOutboundOffers(
                session: session, reporter: self.reporter, peerName: Self.pasteSourceName,
                progressRevealDelay: self.progressRevealDelay,
                progressIdleGap: self.progressIdleGap,
                firstGeneration: self.nextLocalGeneration,
                onActivity: { [weak self] activity in self?.record(activity) })
            self.inboundPromise = nil
            self.lastPasteboardChangeCount = Self.unobservedChangeCount
            session.start(
                handleControlFrame: { [weak self] frame in self?.handleControlFrame(frame) },
                // Wake any pull blocked on a now-dead transfer immediately,
                // off-main — the teardown below runs on main, which a blocked
                // provider holds.
                onEnded: { [coordinator = self.lazyCoordinator] in coordinator.failAll() })
            Self.logger.notice(
                "Vsock clipboard connected to host (conn=\(session.connectionTag, privacy: .public))"
            )
            return session
        }

        await session.waitUntilEnded()
        await MainActor.run {
            self.teardownIfCurrent(channel)
        }
    }

    /// Mirrors what the outbound half just did onto the menu-bar status line.
    private func record(_ activity: ClipboardOutboundOffers.Activity) {
        switch activity {
        case .offerSent: clipboardActivityStorage = .offeredToHost
        case .transferServed: clipboardActivityStorage = .sentToHost
        }
    }

    // MARK: - Pasteboard polling (main queue)

    private func startPolling() {
        // Default mode only: a tick that would land inside a tracking or modal
        // loop waits for the loop to end rather than parking the main thread on
        // a fire it reaches.
        pollingTimer = Timer.scheduledTimer(withTimeInterval: Self.pollingInterval, repeats: true) {
            [weak self] _ in
            // The main run loop fires this on the main thread.
            self?.checkClipboardChange()
        }
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
                sendOfferIfNeeded(content, changeCount: currentCount)
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
        sendOfferIfNeeded(content, changeCount: currentCount)
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
        let released = onMainActor { outbound?.release() ?? false }
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
    /// what we last wrote/sent, advancing the change-count bookkeeping.
    private func sendOfferIfNeeded(_ content: ClipboardContent, changeCount: Int) {
        guard let outbound else { return }
        guard !content.isEmpty else {
            // A caller that can observe an empty snapshot classifies it itself;
            // one that hasn't can't claim a copy came up short.
            noteSnapshotOfferedNothing(pasteboardHeldSomething: false, changeCount: changeCount)
            return
        }
        // Dedup on the buffer's own (uncapped) digest — the poll rebuilds the
        // same content each tick, so an unchanged pasteboard hits this guard, and
        // the change-count gate is what keeps it from re-reading.
        guard content.digest != onMainActor({ outbound.lastOfferedDigest }) else {
            lastPasteboardChangeCount = changeCount
            return
        }
        guard onMainActor({ outbound.offer(content) }) != nil else { return }
        lastPasteboardChangeCount = changeCount
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
                #if DEBUG
                defer { self.onFolderEstimateCompletedForTesting?() }
                #endif
                // A pasteboard that moved on during the walk is another poll's to
                // read — or already this agent's own promise write, whose gate
                // must not be wound back to a count that would make the next
                // poll read the promise as a copy.
                guard self.pasteboard.changeCount == changeCount else { return }
                // Advance the change-count gate so the folder isn't re-walked
                // every 0.5 s poll; a genuine new copy bumps the count.
                self.lastPasteboardChangeCount = changeCount
                guard !reps.isEmpty else { return }
                self.sendOfferIfNeeded(
                    ClipboardContent(representations: reps), changeCount: changeCount)
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
            onMainActor { outbound?.handleRequest(request) }
        case .clipboardRelease(let release):
            handleRelease(release)
        case .error(let error):
            Self.logger.warning(
                "Host clipboard error: \(error.code, privacy: .public) — \(error.message, privacy: .public)"
            )
        case .clipboardStreamAbort(let abort):
            // Only a sender-bound abort reaches here; see `ClipboardStreamRouting`.
            onMainActor { session?.sender?.handleAbort(transferID: abort.transferID) }
        case .clipboardStreamBegin, .clipboardChunk, .clipboardStreamEnd, .clipboardStreamAck:
            // Routed off-main by the consume loop; never reaches here.
            break
        case .hello, .heartbeat, .policyUpdate, .logRecord, .dropOffer, .dropComplete,
            .dropRelease, .none:
            Self.logger.warning("Unexpected payload on clipboard channel — wrong port")
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
            onMainActor { session?.receiver?.cancel(generation: previous.generation) }
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
        guard let session, let receiver = onMainActor({ session.receiver }) else { return nil }
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
            guard type != .fileURL || allowsFileURLPull(repIndex, promise: promise, session: session)
            else { return nil }
            // The wait runs the run loop, so a sibling flavor of this same rep —
            // an image file promises both at one repIndex — can fire nested. It
            // joins this pull rather than displacing it, and both flavors are
            // served from the one transfer.
            guard
                let pulled = pullRepresentation(
                    repIndex, promise: promise, session: session, receiver: receiver)
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

    /// Starts or joins the pull for `transferID` and holds the calling thread
    /// until it resolves — the shared transport core of every inbound pull.
    ///
    /// The awaiter registration and the request ride the coordinator's `start`,
    /// so a nested fire for the same rep — a sibling flavor asked for while this
    /// wait runs the run loop — joins this transfer instead of opening a second
    /// one, and both fires take its bytes.
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
        return coordinator.pull(
            transferID: transferID,
            retire: { receiver.cancelAwait(transferID) },
            start: {
                receiver.awaitTransfer(
                    transferID,
                    extractsDirectoryNamed: extractsDirectoryNamed,
                    advertisedByteCount: advertisedByteCount,
                    onComplete: { rep in coordinator.deliver(transferID, rep) },
                    onAbort: { abort in coordinator.abort(transferID, abort) },
                    // Re-arms the pull's inactivity backstop on every chunk so a
                    // large still-streaming transfer is never timed out mid-flight.
                    onProgress: { bytes, total in
                        coordinator.progress(
                            transferID, bytesReceived: bytes, totalBytes: total)
                    })
                do {
                    try sendRequest()
                } catch {
                    Self.logger.warning(
                        "Failed to send clipboard request: \(error.localizedDescription, privacy: .public)"
                    )
                    // No request went out, so no reply will arrive — resolve the
                    // pull now instead of blocking the calling thread to the
                    // backstop timeout.
                    receiver.cancelAwait(transferID)
                    coordinator.abort(
                        transferID,
                        ClipboardStreamAbortInfo(
                            transferID: transferID, code: .sendFailed,
                            message: "Failed to send clipboard request", neededBytes: nil,
                            availableBytes: nil))
                }
            })
    }

    /// Whether a `.fileURL` fire may start its pull: the offer's deadline-bound
    /// total is within the cap, and the rep fits the staging volume.
    ///
    /// Both gates report their refusal before returning `false`, on the guest's
    /// own menu and to the host.
    private func allowsFileURLPull(
        _ repIndex: Int, promise: InboundPromise, session: ClipboardStreamSession
    ) -> Bool {
        let info = promise.reps[repIndex]
        // The cap applies to the TOTAL of the offer's deadline-bound reps,
        // all-or-nothing: one paste is one deadline-bound operation, so the OS
        // clock sees the sum, not each file. Checked before the disk-space gate:
        // an over-cap offer never gets far enough to need the space.
        let totalBytes = ClipboardPromisePolicy.pasteBoundTotal(promise.reps)
        if totalBytes > UInt64(maxPasteBytes) {
            Self.logger.warning(
                "Deadline-bound clipboard reps total \(totalBytes, privacy: .public) bytes — over the \(self.maxPasteBytes, privacy: .public)-byte cap; refusing the paste pull"
            )
            reportPasteFailure(
                code: .pasteTooLarge,
                message: "Too large to paste into the guest (\(totalBytes) bytes total)",
                promise: promise, on: session)
            return false
        }
        if !staging.hasCapacity(forByteCount: Int(clamping: info.byteCount)) {
            Self.logger.warning(
                "Not enough disk space to receive clipboard rep '\(info.uti, privacy: .public)' (\(info.byteCount, privacy: .public) bytes)"
            )
            reportPasteFailure(
                code: .pasteDiskFull,
                message: "Not enough disk space in the guest to receive \(info.byteCount) bytes",
                promise: promise, on: session)
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
        _ repIndex: Int, promise: InboundPromise, session: ClipboardStreamSession,
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
            try session.sendRequest(
                generation: generation, transferID: transferID, uti: uti,
                maxAcceptByteCount: maxAccept)
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
                    message: abort.message, promise: promise, on: session)
            }
        case .timedOut:
            Self.logger.warning(
                "Inbound clipboard pull \(transferID, privacy: .public) (conn=\(self.connectionTag, privacy: .public)) timed out"
            )
            // Stop any stream the host is still sending for this abandoned pull,
            // then report the failure.
            session.sendStreamAbort(
                transferID: transferID, code: .pasteTimeout,
                message: "Receiver gave up waiting for the clipboard transfer")
            reportPasteFailure(
                code: .pasteTimeout,
                message: "The clipboard transfer to the guest timed out", promise: promise,
                on: session)
        case .cancelled:
            // `.debug`, not `.warning`: `.cancelled` also covers benign
            // teardown/supersession, which is deliberately silent elsewhere.
            Self.logger.debug(
                "Inbound clipboard pull \(transferID, privacy: .public) (conn=\(self.connectionTag, privacy: .public)) cancelled"
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
        code: ClipboardErrorCode, message: String, promise: InboundPromise,
        on session: ClipboardStreamSession
    ) {
        guard allowsRefusalReport(for: promise) else { return }
        session.sendError(code: code, message: message, inReplyTo: "clipboard.request")
        recordPasteFailure(code: code, generation: promise.generation)
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

    /// The promised pasteboard items for an offer.
    ///
    /// Inline-only reps (no filename) share one item promising each rep's content
    /// UTI; each file rep gets its own item promising `public.file-url` (and its
    /// image UTI when it's an image file). Only reps `ClipboardPromisePolicy`
    /// keeps are promised. Each promised type carries the offer-rep index that
    /// backs it.
    private static func promisedItems(
        for reps: [Kernova_V1_ClipboardRepresentationInfo]
    ) -> [PromisedItem] {
        let descriptors = ClipboardPromisePolicy.descriptors(for: reps)
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
        onMainActor { session?.receiver?.cancel(generation: release.generation) }
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
