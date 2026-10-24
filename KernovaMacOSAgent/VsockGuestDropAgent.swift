import AppKit
import Foundation
import KernovaKit
import KernovaLogging
import KernovaSynchronization

/// Guest-side agent for files dragged between the VM display and the Mac,
/// talking to the host's `VsockDropService` on `KernovaVsockPort.drop`.
///
/// Independent of clipboard sharing. Files dropped on the display arrive as
/// `DropOffer`s, each one job, pulled representation by representation on a
/// dedicated worker queue and landed in the guest's Downloads folder with
/// Finder's own "Keep Both" naming, then revealed in a Finder window. Files
/// dragged out of the display leave through ``GuestDragOut``, whose offers the
/// endpoint serves when the host pulls them.
///
/// Connection state is confined to the main actor; the worker queue is what
/// the blocking pulls park on, so no pull ever holds the main thread.
final class VsockGuestDropAgent: Sendable {
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
    private let revealInFinder: @Sendable ([URL]) -> Void
    private let dragOutSystem: GuestDragOutSystem

    /// Opens one item's data connection to the host; tests hand over a
    /// socketpair in place of a real dial.
    private let dataDialer: @Sendable (UInt32) throws -> Int32

    /// What decides whether the reconnect loop dials and whether drags out are
    /// watched for; all default off with the client paused.
    private let enablement = Locked(Enablement())

    private struct Enablement: Sendable {
        /// What the host's `Hello` advertised: the reconnect loop only dials a
        /// host that has a drop listener, and drags are only offered to one
        /// that takes them.
        var host = HostDropCapabilities.unadvertised

        /// Whether the host's latest `PolicyUpdate` has drag and drop switched
        /// on: the host binds the drop ports only while the setting is on, so
        /// dialling before the first policy arrives buys a refused connect per
        /// retry interval.
        var enabledByPolicy = false

        var shouldDial: Bool { host.supportsDropFiles && enabledByPolicy }

        var watchesDrags: Bool { shouldDial && host.supportsDragOut }
    }

    /// Runs one drop job at a time, in offer order.
    ///
    /// Serial and separate from main: an inbound pull blocks its caller, and a
    /// drop has no pasteboard deadline to race, so one file streams at a time on
    /// a thread nothing else needs.
    private let jobQueue = DispatchQueue(
        label: "app.kernova.macosagent.drop-jobs", qos: .userInitiated)

    // MARK: - Main-actor state

    @MainActor private var liveChannel: VsockChannel?

    /// The current connection: what the host has offered, and every pull that
    /// lands it.
    @MainActor private var endpoint: ClipboardEndpoint?

    /// The readout of every drop the host has offered and this side has not
    /// finished, by generation.
    @MainActor private var jobs: [UInt64: ClipboardTransferOperation] = [:]

    /// The current connection's drags out of the guest.
    @MainActor private var dragOut: GuestDragOut?

    #if DEBUG
    /// Test seam, readable from any thread: reads on the main actor that owns it.
    var liveChannelForTesting: VsockChannel? { MainActorBridge.sync { liveChannel } }
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
    convenience init(stagingRoot: ProcessStagingRoot, reporter: ClipboardTransferReporter) {
        self.init(
            client: VsockGuestClient(port: KernovaVsockPort.drop, label: "drop"),
            reporter: reporter, stagingRoot: stagingRoot)
    }

    /// Designated init; tests inject a socketpair-backed client, a Downloads
    /// directory under a temp root, a staging root of their own, a
    /// `freeSpaceProvider` to simulate a full disk, a `revealInFinder` sink
    /// in place of opening a real Finder window, and a drag-out system of fakes
    /// in place of the guest's event stream and screen.
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
        stagingRoot: ProcessStagingRoot,
        freeSpaceProvider: ClipboardFileStaging.FreeSpaceProvider? = nil,
        dataDialer: @escaping @Sendable (UInt32) throws -> Int32 = {
            try VsockGuestDataDialer.connect(port: $0)
        },
        revealInFinder: @escaping @Sendable ([URL]) -> Void = { urls in
            DispatchQueue.main.async { NSWorkspace.shared.activateFileViewerSelecting(urls) }
        },
        dragOutSystem: GuestDragOutSystem = .live
    ) {
        self.client = client
        self.dataDialer = dataDialer
        self.reporter = reporter
        self.progressRevealDelay = progressRevealDelay
        self.progressIdleGap = progressIdleGap
        self.downloadsDirectory = downloadsDirectory
        self.revealInFinder = revealInFinder
        self.dragOutSystem = dragOutSystem
        self.staging = ClipboardFileStaging(
            label: "agent-drop", root: stagingRoot, receivingOn: .drop, as: .guest,
            freeSpaceProvider: freeSpaceProvider)
        // Default-paused: nothing dials until the host's `Hello` says it has a
        // drop listener.
        client.pause()
    }

    // MARK: - Lifecycle

    func start() {
        client.start { [weak self] channel in
            await self?.serve(channel: channel)
        }
        Self.logger.log(.notice, "Vsock drop agent started")
    }

    /// Records the host's drag-and-drop setting and matches the reconnect loop
    /// to it.
    func applyPolicy(enabled: Bool) {
        updateEnablement { $0.enabledByPolicy = enabled }
    }

    /// Records what the host takes over the drop channel and matches the
    /// reconnect loop and the drag watcher to it.
    ///
    /// Called whenever the control agent learns the host's capabilities — its
    /// `Hello`, and the clearing that precedes the next one — so a host with no
    /// drop listener is never redialled every retry interval.
    func applyHostCapabilities(_ capabilities: HostDropCapabilities) {
        updateEnablement { $0.host = capabilities }
    }

    private func updateEnablement(_ change: (inout Enablement) -> Void) {
        let shouldDial = enablement.withLock { enablement in
            change(&enablement)
            return enablement.shouldDial
        }
        if shouldDial {
            client.resume()
        } else {
            client.pause()
        }
        MainActorBridge.async { [weak self] in
            self?.reconcileDragWatching()
        }
    }

    /// Runs the drag watcher exactly while a connection is up and the host
    /// and its policy both allow drags out, reading the enablement as it
    /// stands now so hops landing out of order still settle on the latest.
    @MainActor
    private func reconcileDragWatching() {
        dragOut?.setWatching(enablement.withLock { $0.watchesDrags })
    }

    func stop() {
        client.stop()
        MainActorBridge.async { [weak self] in
            self?.teardownConnectionState()
        }
        Self.logger.log(.notice, "Vsock drop agent stopped")
    }

    /// Clears per-connection state.
    @MainActor
    private func teardownConnectionState() {
        dragOut?.stop()
        dragOut = nil
        // Unblocks any worker parked on a pull; it reads the dead connection
        // as a cancellation and ends its job.
        endpoint?.stop()
        for operation in jobs.values {
            // Retired, not finished: the transport measuring these is gone, so
            // there is nothing left to show finishing.
            operation.abandon()
        }
        endpoint = nil
        liveChannel = nil
        jobs.removeAll()
    }

    @MainActor
    private func teardownIfCurrent(_ channel: VsockChannel) {
        if liveChannel === channel { teardownConnectionState() }
    }

    // MARK: - Per-connection serve

    private func serve(channel: VsockChannel) async {
        let endpoint = await MainActor.run { () -> ClipboardEndpoint in
            let endpoint = ClipboardEndpoint(
                channel: channel,
                configuration: ClipboardEndpoint.Configuration(
                    role: .guest, kind: .drop, label: "drop", peerName: Self.dropSourceName,
                    // A drop lands in Downloads, never on a pasteboard, so no OS
                    // paste deadline bounds it and nothing is capped.
                    maxPasteBytes: { .max },
                    staging: self.staging,
                    progressRevealDelay: self.progressRevealDelay,
                    progressIdleGap: self.progressIdleGap,
                    dataLink: .dials(
                        port: KernovaVsockPort.dropData, connect: self.dataDialer)),
                reporter: self.reporter)
            self.liveChannel = channel
            self.endpoint = endpoint
            self.dragOut = GuestDragOut(peer: endpoint, system: self.dragOutSystem)
            endpoint.delegate = self
            endpoint.start()
            self.reconcileDragWatching()
            Self.logger.log(
                .notice,
                "Vsock drop connected to host (conn=\(endpoint.connectionTag, privacy: .public))")
            return endpoint
        }

        await endpoint.waitUntilEnded()
        await MainActor.run {
            self.teardownIfCurrent(channel)
        }
    }

    /// Takes on one drop gesture: opens its readout and queues its files behind
    /// whatever is already running.
    @MainActor
    private func takeOn(_ offer: ClipboardEndpoint.InboundOffer, on endpoint: ClipboardEndpoint) {
        let generation = offer.generation
        // The whole drop's totals are the floor, so the bar's denominator is
        // every dropped file rather than each in turn.
        let operation = ClipboardTransferOperation(
            gesture: .drop, direction: .inbound, peerName: Self.dropSourceName,
            expectedBytes: offer.reps.reduce(UInt64(0)) { $0 &+ $1.byteCount },
            expectedItems: offer.reps.count,
            revealDelay: progressRevealDelay, idleGap: progressIdleGap,
            onCancelRequested: { [weak endpoint] in
                // The tracker calls this outside its own lock, on whichever
                // thread noticed the click, so it hops before touching anything.
                MainActorBridge.async { endpoint?.cancelInbound(generation: generation) }
            },
            reporter: reporter)
        jobs[generation] = operation
        // The job holds `endpoint` strongly: its pulls are what a teardown wakes,
        // and a loop mid-file still has to read that wake and answer the host.
        jobQueue.async { [weak self] in
            self?.run(offer, operation: operation, on: endpoint)
        }
    }

    // MARK: - Job execution (worker queue)

    /// Pulls each of the drop's files in order and lands it in Downloads,
    /// carrying on past any the host turns out not to be able to read.
    private func run(
        _ offer: ClipboardEndpoint.InboundOffer, operation: ClipboardTransferOperation,
        on endpoint: ClipboardEndpoint
    ) {
        dispatchPrecondition(condition: .notOnQueue(.main))
        let generation = offer.generation
        var landed: [URL] = []
        var skipped = 0
        var outcome: JobOutcome = .completed

        for index in offer.reps.indices {
            // Asked before every pull and again before the file it delivers is
            // landed: a Cancel or a `DropRelease` retires the job's entry, and
            // between the two checks lies a whole transfer the user has already
            // called off — pulling into it would ask the host for bytes nothing
            // wants, and landing one would put a file in Downloads after the
            // cancel.
            guard endpoint.hasLiveInboundOffer(generation: generation) else {
                outcome = .cancelled
                break
            }
            switch endpoint.pull(generation: generation, repIndex: index, operation: operation) {
            case .delivered(let representation):
                if endpoint.hasLiveInboundOffer(generation: generation) {
                    do {
                        landed.append(try land(representation, named: offer.reps[index].filename))
                    } catch {
                        let failure = Self.classify(error)
                        Self.logger.log(
                            .error,
                            "Failed to save a dropped file into Downloads: \(error.localizedDescription, privacy: .public)"
                        )
                        outcome = .failed(failure.0, failure.1)
                    }
                } else {
                    Self.discard(representation)
                    outcome = .cancelled
                }
            case .aborted(let abort):
                // A retiring code is every route a drop is called off by — a
                // release, a Cancel on the readout, the channel going. The
                // channel's own end is why liveness cannot stand in for it: the
                // session cancels every awaiter before its end reaches this loop,
                // so the job's entry is still standing when the abort lands.
                if abort.isRetiring || !endpoint.hasLiveInboundOffer(generation: generation) {
                    outcome = .cancelled
                } else if abort.code == .readError {
                    // The host could not read this one item's source. That is the
                    // item's failure and not the batch's: everything else in the
                    // drop is still there to pull, and the side that made the
                    // gesture is the side that names what it left out.
                    skipped += 1
                    Self.logger.log(
                        .warning,
                        "Skipping dropped file \(index, privacy: .public) of gen=\(generation, privacy: .public): the host couldn't read it"
                    )
                } else {
                    Self.logger.log(
                        .warning,
                        "Dropped file \(index, privacy: .public) of gen=\(generation, privacy: .public) aborted (\(abort.rawCode, privacy: .public))"
                    )
                    outcome = .failed(
                        abort.code == .diskFull ? .dropDiskFull : .dropFailed, abort.message)
                }
            case .timedOut:
                outcome = .failed(.dropFailed, "The transfer stopped making progress")
            case .cancelled:
                outcome = .cancelled
            case .mainThreadUnavailable:
                // Unreachable: this loop runs on `jobQueue`, as the precondition
                // above asserts, and the refusal is the main thread's alone.
                outcome = .failed(.dropFailed, "The transfer could not be started")
            case .unavailable:
                // Unreachable: only a drag's promised item is refused this way,
                // and a drop promises nothing.
                outcome = .failed(.dropFailed, "The file could not be produced")
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
        send(completion: outcome, generation: generation, on: endpoint)
        MainActorBridge.async { [weak self] in
            // The offer goes with the job: a drop is landed in Downloads by this
            // loop and never served again, so nothing is left to pull from it.
            endpoint.retireInbound(generation: generation)
            // Identity-checked, not just keyed: generations restart at 1 with
            // every accepted channel, so a worker that outlived a teardown would
            // otherwise clear the *next* connection's job of the same number —
            // leaving it unreachable by a release or a Cancel.
            guard self?.jobs[generation] === operation else { return }
            self?.jobs[generation] = nil
        }
        Self.logger.log(
            .notice,
            "Drop job finished (gen=\(generation, privacy: .public), \(landed.count, privacy: .public) file(s) in Downloads, \(skipped, privacy: .public) skipped)"
        )
    }

    // MARK: - Landing files in Downloads

    /// Moves a delivered representation out of staging and into the Downloads
    /// folder, naming it the way Finder would.
    ///
    /// Staging and Downloads share the guest's data volume, so this is a rename.
    private func land(_ representation: ClipboardContent.Representation, named filename: String)
        throws -> URL
    {
        try StagedItemLanding.land(representation, inDirectory: downloadsDirectory, named: filename)
    }

    /// Throws away a file that arrived for a job the user had already called
    /// off, so the staging root does not hold it until the generation window
    /// reclaims it.
    private static func discard(_ representation: ClipboardContent.Representation) {
        guard let url = representation.fileURL else { return }
        try? FileManager.default.removeItem(at: url)
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
        completion: JobOutcome, generation: UInt64, on endpoint: ClipboardEndpoint
    ) {
        switch completion {
        case .completed:
            endpoint.sendDropComplete(generation: generation, outcome: .completed)
        case .cancelled:
            endpoint.sendDropComplete(generation: generation, outcome: .cancelled)
        case .failed(let code, let message):
            endpoint.sendDropComplete(
                generation: generation, outcome: .failed, code: code, message: message)
        }
    }
}

// MARK: - Endpoint delegate

extension VsockGuestDropAgent: ClipboardEndpointDelegate {
    func endpoint(
        _ endpoint: ClipboardEndpoint, didReceiveOffer offer: ClipboardEndpoint.InboundOffer
    ) {
        takeOn(offer, on: endpoint)
    }

    func endpoint(_ endpoint: ClipboardEndpoint, didReceiveDragTake generation: UInt64) {
        dragOut?.take(generation: generation)
    }

    func endpoint(
        _ endpoint: ClipboardEndpoint, didReceiveDragCatcher shown: Bool, generation: UInt64
    ) {
        dragOut?.setCatcherShown(shown, generation: generation)
    }

    func endpoint(_ endpoint: ClipboardEndpoint, didCompleteDrag generation: UInt64) {
        dragOut?.complete(generation: generation)
    }

    func endpointDidEnd(_ endpoint: ClipboardEndpoint) {
        // Nothing: this side's own reconnect loop settles the connection when
        // its `waitUntilEnded()` returns, and dials the next one.
    }
}
