import AppKit
import Foundation
import KernovaKit

/// Guest-side agent for files dropped on the VM display, talking to the host's
/// `VsockDropService` on `KernovaVsockPort.drop`.
///
/// Receive-only, and independent of clipboard sharing: a drop never touches the
/// pasteboard. Each `DropOffer` becomes one job, pulled representation by
/// representation on a dedicated worker queue and landed in the guest's
/// Downloads folder with Finder's own "Keep Both" naming, then revealed in a
/// Finder window.
///
/// Published state is confined to the main dispatch queue; the worker queue is
/// what the blocking pulls park on, so no pull ever holds the main thread.
final class VsockGuestDropAgent: @unchecked Sendable {
    private static let logger = KernovaLogger(
        subsystem: "app.kernova.macosagent", category: "VsockGuestDropAgent")

    /// What the drop readout calls the machine the files come from — the guest
    /// cannot learn the host's actual computer name over the handshake.
    private static let dropSourceName = "Mac"

    private let client: VsockGuestClient
    private let reporter: ClipboardTransferReporter
    private let progressRevealDelay: TimeInterval
    private let progressIdleGap: TimeInterval
    private let downloadsDirectory: URL
    private let staging: ClipboardFileStaging
    private let pullTimeout: TimeInterval
    private let revealInFinder: @Sendable ([URL]) -> Void

    /// Whether the host advertised `drop.files.v2`, so the reconnect loop only
    /// dials a host that has a drop listener.
    var hostSupportsDrop: @Sendable () -> Bool = { false }

    /// Runs one drop job at a time, in offer order.
    ///
    /// Serial and separate from main: an inbound pull blocks its caller, and a
    /// drop has no pasteboard deadline to race, so one file streams at a time on
    /// a thread nothing else needs.
    private let jobQueue = DispatchQueue(
        label: "app.kernova.macosagent.drop-jobs", qos: .userInitiated)

    // MARK: - Main-queue state

    private var liveChannel: VsockChannel?

    /// Engine, frame routing and control-frame delivery for the current
    /// connection.
    private var session: ClipboardStreamSession?

    /// What the host has offered, and every pull that lands it.
    private var inbound: ClipboardInboundOffers?

    /// The readout of every drop the host has offered and this side has not
    /// finished, by generation.
    private var jobs: [UInt64: ClipboardTransferOperation] = [:]

    #if DEBUG
    /// Test seam.
    var liveChannelForTesting: VsockChannel? { liveChannel }
    #endif

    /// How one job ended.
    private enum JobOutcome {
        case completed
        case cancelled
        case failed(ClipboardErrorCode, String)
    }

    // MARK: - Init

    /// Production init — the real drop port and the guest user's Downloads
    /// folder.
    convenience init(reporter: ClipboardTransferReporter) {
        self.init(
            client: VsockGuestClient(port: KernovaVsockPort.drop, label: "drop"),
            reporter: reporter)
    }

    /// Designated init; tests inject a socketpair-backed client, a Downloads
    /// directory under a temp root, an isolated staging root, a
    /// `freeSpaceProvider` to simulate a full disk, and a `revealInFinder` sink
    /// in place of opening a real Finder window.
    ///
    /// The agent runs unsandboxed inside the guest, so `.downloadsDirectory`
    /// resolves to the real `~/Downloads`.
    init(
        client: VsockGuestClient,
        reporter: ClipboardTransferReporter,
        progressRevealDelay: TimeInterval = ClipboardTransferOperation.defaultRevealDelay,
        progressIdleGap: TimeInterval = ClipboardTransferOperation.defaultIdleGap,
        downloadsDirectory: URL = FileManager.default.urls(
            for: .downloadsDirectory, in: .userDomainMask
        ).first
            ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads", isDirectory: true),
        stagingTempRoot: URL = FileManager.default.temporaryDirectory,
        freeSpaceProvider: ClipboardFileStaging.FreeSpaceProvider? = nil,
        pullTimeout: TimeInterval = ClipboardStreamTuning.lazyPullTimeout,
        revealInFinder: @escaping @Sendable ([URL]) -> Void = { urls in
            DispatchQueue.main.async { NSWorkspace.shared.activateFileViewerSelecting(urls) }
        }
    ) {
        self.client = client
        self.reporter = reporter
        self.progressRevealDelay = progressRevealDelay
        self.progressIdleGap = progressIdleGap
        self.downloadsDirectory = downloadsDirectory
        self.pullTimeout = pullTimeout
        self.revealInFinder = revealInFinder
        self.staging = ClipboardFileStaging(
            label: "agent-drop", tempRoot: stagingTempRoot, freeSpaceProvider: freeSpaceProvider)
        // Default-paused: nothing dials until the host's `Hello` says it has a
        // drop listener.
        client.pause()
    }

    // MARK: - Lifecycle

    func start() {
        client.start { [weak self] channel in
            await self?.serve(channel: channel)
        }
        Self.logger.notice("Vsock drop agent started")
    }

    /// Matches the reconnect loop to what the host advertises.
    ///
    /// Called whenever the control agent learns the host's capabilities — its
    /// `Hello`, and the clearing that precedes the next one — so a host without a
    /// drop listener is never redialled every retry interval.
    func syncEnablement() {
        if hostSupportsDrop() {
            client.resume()
        } else {
            client.pause()
        }
    }

    func stop() {
        client.stop()
        DispatchQueue.main.async { [weak self] in
            self?.teardownConnectionState()
        }
        Self.logger.notice("Vsock drop agent stopped")
    }

    /// Clears per-connection state on the main queue.
    private func teardownConnectionState() {
        dispatchPrecondition(condition: .onQueue(.main))
        MainActor.assumeIsolated {
            session?.stop()
            // Unblock any worker parked on a pull; it reads the dead session as a
            // cancellation and ends its job.
            inbound?.endSession()
            for operation in jobs.values {
                // Retired, not finished: the transport measuring these is gone, so
                // there is nothing left to show finishing.
                operation.abandon()
            }
        }
        inbound = nil
        session = nil
        liveChannel = nil
        jobs.removeAll()
    }

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
                channel: channel, role: .guest, kind: .drop, label: "drop", staging: self.staging)
            self.liveChannel = channel
            self.session = session
            let inbound = ClipboardInboundOffers(
                session: session, reporter: self.reporter, staging: self.staging,
                peerName: Self.dropSourceName,
                // A drop lands in Downloads, never on a pasteboard, so no OS paste
                // deadline bounds it and nothing is capped.
                maxPasteBytes: { .max },
                lazyPullTimeout: self.pullTimeout,
                progressRevealDelay: self.progressRevealDelay,
                progressIdleGap: self.progressIdleGap)
            self.inbound = inbound
            inbound.onOfferReceived = { [weak self, weak inbound] offer in
                guard let self, let inbound else { return }
                self.takeOn(offer, on: inbound, session: session)
            }
            session.start(
                handleControlFrame: { [weak self] frame in
                    self?.handleControlFrame(frame, from: channel)
                },
                // Wake any worker blocked on a now-dead transfer immediately,
                // off-main — the teardown below runs on main.
                onEnded: { [weak inbound] in inbound?.endSession() })
            Self.logger.notice(
                "Vsock drop connected to host (conn=\(session.connectionTag, privacy: .public))")
            return session
        }

        await session.waitUntilEnded()
        await MainActor.run {
            self.teardownIfCurrent(channel)
        }
    }

    // MARK: - Frame handlers (main queue)

    private func handleControlFrame(_ frame: Frame, from channel: VsockChannel) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard liveChannel === channel, let inbound else { return }
        MainActor.assumeIsolated {
            switch frame.payload {
            case .dropOffer(let offer):
                inbound.handleDropOffer(offer)
            case .dropRelease(let release):
                inbound.handleDropRelease(release)
            case .error(let error):
                Self.logger.warning(
                    "Host drop error: \(error.code, privacy: .public) — \(error.message, privacy: .public)"
                )
            case .clipboardStreamBegin, .clipboardChunk, .clipboardStreamEnd, .clipboardStreamAck:
                // Routed off-main by the serve loop; never reaches here.
                break
            case .clipboardStreamAbort:
                // Only a sender-bound abort reaches here, and this side never sends
                // on the drop channel — there is nothing to call off.
                break
            case .hello, .heartbeat, .policyUpdate, .logRecord, .clipboardOffer,
                .clipboardRequest, .clipboardRelease, .dropComplete, .none:
                Self.logger.warning("Unexpected payload on the drop channel — wrong port")
            }
        }
    }

    /// Takes on one drop gesture: opens its readout and queues its files behind
    /// whatever is already running.
    private func takeOn(
        _ offer: ClipboardInboundOffers.InboundOffer, on inbound: ClipboardInboundOffers,
        session: ClipboardStreamSession
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
        let generation = offer.generation
        // The whole drop's totals are the floor, so the bar's denominator is
        // every dropped file rather than each in turn (§13).
        let operation = ClipboardTransferOperation(
            gesture: .drop, direction: .inbound, peerName: Self.dropSourceName,
            expectedBytes: offer.reps.reduce(UInt64(0)) { $0 &+ $1.byteCount },
            expectedItems: offer.reps.count,
            revealDelay: progressRevealDelay, idleGap: progressIdleGap,
            onCancelRequested: { [weak inbound] in
                // The tracker calls this outside its own lock, on whichever
                // thread noticed the click, so it hops before touching anything.
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { inbound?.cancelInbound(generation: generation) }
                }
            },
            reporter: reporter)
        jobs[generation] = operation
        jobQueue.async { [weak self] in
            self?.run(offer, operation: operation, on: inbound, session: session)
        }
    }

    // MARK: - Job execution (worker queue)

    /// Pulls each of the drop's files in order and lands it in Downloads.
    private func run(
        _ offer: ClipboardInboundOffers.InboundOffer, operation: ClipboardTransferOperation,
        on inbound: ClipboardInboundOffers, session: ClipboardStreamSession
    ) {
        dispatchPrecondition(condition: .notOnQueue(.main))
        let generation = offer.generation
        var landed: [URL] = []
        var outcome: JobOutcome = .completed

        for index in offer.reps.indices {
            switch inbound.pull(generation: generation, repIndex: index, operation: operation) {
            case .delivered(let representation):
                do {
                    landed.append(try land(representation, named: offer.reps[index].filename))
                } catch {
                    let failure = Self.classify(error)
                    Self.logger.error(
                        "Failed to save a dropped file into Downloads: \(error.localizedDescription, privacy: .public)"
                    )
                    outcome = .failed(failure.0, failure.1)
                }
            case .aborted(let abort):
                // A retiring code is every route a drop is called off by — a
                // release, a Cancel on the readout, the channel going. The
                // channel's own end is why liveness cannot stand in for it: the
                // session cancels every awaiter before its end reaches this loop,
                // so the job's entry is still standing when the abort lands.
                if abort.isRetiring || !inbound.hasLiveOffer(generation: generation) {
                    outcome = .cancelled
                } else {
                    Self.logger.warning(
                        "Dropped file \(index, privacy: .public) of gen=\(generation, privacy: .public) aborted (\(abort.rawCode, privacy: .public))"
                    )
                    outcome = .failed(
                        abort.code == .diskFull ? .dropDiskFull : .dropFailed, abort.message)
                }
            case .timedOut:
                outcome = .failed(.dropFailed, "The transfer stopped making progress")
            case .cancelled:
                outcome = .cancelled
            }
            if case .completed = outcome { continue }
            break
        }

        // The readout ends where it stopped: a cancelled or failed drop finishes
        // below 100 %, which is the whole of how those two read on screen.
        switch outcome {
        case .completed: operation.finish(.completed)
        case .cancelled: operation.finish(.cancelled)
        case .failed(let code, _): operation.finish(.failed(.peerReported(code)))
        }
        if case .completed = outcome, !landed.isEmpty {
            revealInFinder(landed)
        }
        send(completion: outcome, generation: generation, on: session)
        DispatchQueue.main.async { [weak self] in
            // The offer goes with the job: a drop is landed in Downloads by this
            // loop and never served again, so nothing is left to pull from it.
            MainActor.assumeIsolated { inbound.retire(generation: generation) }
            // Identity-checked, not just keyed: generations restart at 1 with
            // every accepted channel, so a worker that outlived a teardown would
            // otherwise clear the *next* connection's job of the same number —
            // leaving it unreachable by a release or a Cancel.
            guard self?.jobs[generation] === operation else { return }
            self?.jobs[generation] = nil
        }
        Self.logger.notice(
            "Drop job finished (gen=\(generation, privacy: .public), \(landed.count, privacy: .public) file(s) in Downloads)"
        )
    }

    // MARK: - Landing files in Downloads

    /// Moves a delivered representation out of staging and into the Downloads
    /// folder, naming it the way Finder would.
    ///
    /// A rename, not a copy: staging and Downloads share the guest's data volume,
    /// so nothing payload-scaled happens here. A cross-device move falls back to
    /// copy-and-delete, which is the only case where it can.
    private func land(_ representation: ClipboardContent.Representation, named filename: String)
        throws -> URL
    {
        guard let source = representation.fileURL else {
            throw CocoaError(.fileNoSuchFile)
        }
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: downloadsDirectory, withIntermediateDirectories: true)
        let destination = FinderStyleUniquing.uniqueDestination(
            in: downloadsDirectory,
            filename: filename.isEmpty ? source.lastPathComponent : filename)
        do {
            try fileManager.moveItem(at: source, to: destination)
        } catch let error as NSError where Self.isCrossDevice(error) {
            try fileManager.copyItem(at: source, to: destination)
            try? fileManager.removeItem(at: source)
        }
        return destination
    }

    private static func isCrossDevice(_ error: NSError) -> Bool {
        (error.userInfo[NSUnderlyingErrorKey] as? NSError)?.code == Int(EXDEV)
            || error.code == Int(EXDEV)
    }

    /// Maps a filesystem failure to the code the host renders a sentence from.
    private static func classify(_ error: any Error) -> (ClipboardErrorCode, String) {
        let nsError = error as NSError
        let posix =
            (nsError.userInfo[NSUnderlyingErrorKey] as? NSError).map(\.code) ?? nsError.code
        switch Int32(truncatingIfNeeded: posix) {
        case EACCES, EPERM:
            return (.dropDownloadsDenied, "The guest agent cannot write to Downloads")
        case ENOSPC, EDQUOT:
            return (.dropDiskFull, "The guest volume is full")
        default:
            return (.dropFailed, nsError.localizedDescription)
        }
    }

    // MARK: - Reporting the outcome

    private func send(
        completion: JobOutcome, generation: UInt64, on session: ClipboardStreamSession
    ) {
        switch completion {
        case .completed:
            session.sendDropComplete(generation: generation, outcome: .completed)
        case .cancelled:
            session.sendDropComplete(generation: generation, outcome: .cancelled)
        case .failed(let code, let message):
            session.sendDropComplete(
                generation: generation, outcome: .failed, code: code, message: message)
        }
    }
}
