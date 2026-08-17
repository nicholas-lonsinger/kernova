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

    /// What the host has offered over the current connection, its materialization
    /// cache, and every pull that fills it.
    ///
    /// Cleared with the connection, but the data providers still on the
    /// pasteboard hold it: a representation already pulled stays pastable after
    /// the host goes away (docs/CLIPBOARD.md §3).
    private var inbound: ClipboardInboundOffers?

    #if DEBUG
    /// Test seam.
    var liveChannelForTesting: VsockChannel? { liveChannel }

    /// Test seam.
    var inboundPromiseGenerationForTesting: UInt64? {
        MainActor.assumeIsolated { inbound?.inboundOffer?.generation }
    }
    #endif

    /// Generation the next connection's offers continue from, carried across
    /// connections: the agent outlives its channels, and a reconnected host must
    /// never be handed a generation this agent already used.
    private var nextLocalGeneration: UInt64 = 1

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
            // Unblock any provider thread waiting on a pull (returns empty). The
            // offers it holds stay servable from their cache, which is what the
            // pasteboard's providers keep it alive for.
            inbound?.endSession()
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
        inbound = nil
        session = nil
        liveChannel = nil
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
            let inbound = ClipboardInboundOffers(
                session: session, reporter: self.reporter, staging: self.staging,
                peerName: Self.pasteSourceName,
                maxPasteBytes: { [weak self] in
                    self?.maxPasteBytes ?? ClipboardPasteLimit.defaultBytes
                },
                progressRevealDelay: self.progressRevealDelay,
                progressIdleGap: self.progressIdleGap, clock: self.clock)
            self.inbound = inbound
            // Weak on both sides: the promise's data providers are what hold the
            // inbound half alive past this connection, and a callback capturing
            // it strongly would keep every connection's alive forever.
            inbound.onOfferReceived = { [weak self, weak inbound] offer in
                guard let self, let inbound else { return }
                self.registerPromise(for: offer, on: inbound)
            }
            inbound.onOfferRetracted = { [weak self] _, reason in
                guard reason == .released else { return }
                self?.retractPromiseIfUnchanged()
            }
            inbound.onActivity = { [weak self] activity in self?.record(activity) }
            self.lastPasteboardChangeCount = Self.unobservedChangeCount
            session.start(
                handleControlFrame: { [weak self] frame in self?.handleControlFrame(frame) },
                // Wake any pull blocked on a now-dead transfer immediately,
                // off-main — the teardown below runs on main, which a blocked
                // provider holds.
                onEnded: { [weak inbound] in inbound?.endSession() })
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

    /// Mirrors what an inbound paste just did onto the menu-bar status line.
    ///
    /// The refusal line is written before the notice, so the dropdown the notice
    /// pops is rebuilt with the line already in it.
    private func record(_ activity: ClipboardInboundOffers.Activity) {
        switch activity {
        case .representationReceived:
            clipboardActivityStorage = .receivedFromHost
        case .pasteRefused(let code, let limitBytes):
            clipboardActivityStorage = .pasteRefused(code, pasteLimitBytes: limitBytes)
            onClipboardNotice()
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
            onMainActor { inbound?.handleOffer(offer) }
        case .clipboardRequest(let request):
            onMainActor { outbound?.handleRequest(request) }
        case .clipboardRelease(let release):
            onMainActor { inbound?.handleRelease(release) }
        case .error(let error):
            onMainActor { inbound?.handlePeerError(error) }
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
    @MainActor
    private func registerPromise(
        for offer: ClipboardInboundOffers.InboundOffer, on inbound: ClipboardInboundOffers
    ) {
        let items = inbound.promisePlan(generation: offer.generation).map(Self.promisedItems(for:))
        guard let items, !items.isEmpty else {
            Self.logger.warning(
                "Dropped the host clipboard offer (gen=\(offer.generation, privacy: .public), conn=\(self.connectionTag, privacy: .public)): none of its \(offer.reps.count, privacy: .public) representation(s) can be promised — nothing written"
            )
            inbound.discardInboundOffer()
            return
        }
        guard writePasteboardPromise(items, generation: offer.generation, serving: inbound) else {
            Self.logger.warning(
                "Failed to register host clipboard promise (gen=\(offer.generation, privacy: .public), conn=\(self.connectionTag, privacy: .public))"
            )
            // The write failed, so the providers were never retained — there is
            // nothing to retract.
            inbound.discardInboundOffer()
            return
        }
        Self.logger.notice(
            "Registered host clipboard promise (gen=\(offer.generation, privacy: .public), conn=\(self.connectionTag, privacy: .public), \(items.count, privacy: .public) item(s))"
        )
        clipboardActivityStorage = .offeredFromHost
    }

    /// Clears the promise the host has withdrawn, unless the user has replaced it
    /// since we wrote it — then whatever they copied stays.
    private func retractPromiseIfUnchanged() {
        guard pasteboard.changeCount == lastPasteboardChangeCount else { return }
        pasteboard.clearContents()
        lastPasteboardChangeCount = pasteboard.changeCount
    }

    /// Writes `items` to the pasteboard as lazy providers, every promised type
    /// served by `serving` when the OS asks for it.
    ///
    /// Captures `lastPasteboardChangeCount` after the write regardless of
    /// outcome (echo suppression — a partial write can't leave the poll
    /// re-offering), and retains the providers only on success.
    ///
    /// Each provider holds `serving` strongly: the pasteboard can ask for a
    /// promised flavor long after the connection that offered it is gone, and a
    /// representation already pulled is still pastable then.
    @discardableResult
    private func writePasteboardPromise(
        _ items: [PromisedItem], generation: UInt64, serving: ClipboardInboundOffers
    ) -> Bool {
        var newProviders: [LazyClipboardDataProvider] = []
        let writes = items.map {
            item -> (types: [NSPasteboard.PasteboardType], provider: NSPasteboardItemDataProvider) in
            let provider = LazyClipboardDataProvider(
                provide: { type in
                    Self.provideData(
                        type, itemTypes: item, generation: generation, serving: serving)
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

    /// Serves the bytes for a promised pasteboard type on demand.
    ///
    /// Runs synchronously on the agent's main thread (the pasteboard server's
    /// `provideDataForType` callback), whose event loop keeps running while the
    /// pull waits. `itemTypes` is the promising item's own type → rep-index map,
    /// so a `.fileURL` pull resolves to *this* item's file rep rather than the
    /// first file rep across the offer.
    private static func provideData(
        _ type: NSPasteboard.PasteboardType, itemTypes: PromisedItem, generation: UInt64,
        serving: ClipboardInboundOffers
    ) -> Data? {
        guard let repIndex = itemTypes.first(where: { $0.type == type })?.repIndex else {
            Self.logger.warning(
                "provideData for unpromised type '\(type.rawValue, privacy: .public)'")
            return nil
        }
        guard type == .fileURL else {
            return serving.serveData(
                generation: generation, repIndex: repIndex, uti: type.rawValue)
        }
        return serving.serveFileURL(generation: generation, repIndex: repIndex)
            .map { Data($0.absoluteString.utf8) }
    }

    #if DEBUG
    /// Test seam for the refusal hop's staleness check.
    func recordPasteFailureForTesting(code: ClipboardErrorCode, generation: UInt64) {
        onMainActor { inbound?.recordRefusalForTesting(code, generation: generation) }
    }
    #endif

    /// One promised pasteboard item: each pasteboard type it offers paired with
    /// the offer-rep index that backs it.
    private typealias PromisedItem = [(type: NSPasteboard.PasteboardType, repIndex: Int)]

    /// The promised pasteboard items for one offer's plan.
    ///
    /// Inline-only reps (no filename) share one item promising each rep's content
    /// UTI; each file rep gets its own item promising `public.file-url` (and its
    /// image UTI when it's an image file). Each promised type carries the
    /// offer-rep index that backs it.
    private static func promisedItems(for plan: ClipboardPasteboardItemPlan) -> [PromisedItem] {
        plan.items.map { item in
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
}
