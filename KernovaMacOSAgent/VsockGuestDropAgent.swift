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
    private let progressTracker: ClipboardProgressTracker
    private let downloadsDirectory: URL
    private let staging: ClipboardFileStaging
    private let pullTimeout: TimeInterval
    private let revealInFinder: @Sendable ([URL]) -> Void

    /// Whether the host advertised `drop.files.v1`, so the reconnect loop only
    /// dials a host that has a drop listener.
    var hostSupportsDrop: @Sendable () -> Bool = { false }

    /// Bridges each blocking pull on the worker queue to the off-main stream
    /// receive.
    private let coordinator = LazyPullCoordinator()

    /// Runs one drop job at a time, in offer order.
    ///
    /// Serial and separate from main: `LazyPullCoordinator.pull` blocks its
    /// caller, and a drop has no pasteboard deadline to race, so one file streams
    /// at a time on a thread nothing else needs.
    private let jobQueue = DispatchQueue(
        label: "app.kernova.macosagent.drop-jobs", qos: .userInitiated)

    // MARK: - Main-queue state

    private var liveChannel: VsockChannel?
    private var receiver: ClipboardStreamReceiver?
    private var connectionTag = ClipboardConnectionTag.guestUnconnected

    /// Every job the host has offered and this side has not finished, by
    /// generation.
    private var jobs: [UInt64: DropJob] = [:]

    #if DEBUG
    /// Test seam.
    var liveChannelForTesting: VsockChannel? { liveChannel }
    #endif

    /// One drop gesture's files, and the transfer of it that is in flight.
    ///
    /// `@unchecked Sendable`: `lock` guards everything the worker queue and the
    /// main queue both touch.
    private final class DropJob: @unchecked Sendable {
        let generation: UInt64
        let reps: [Kernova_V1_ClipboardRepresentationInfo]
        let session: ClipboardProgressTracker.SessionToken

        private let lock = NSLock()
        private var cancelledStorage = false
        private var inFlightTransferID: UInt64?

        init(
            generation: UInt64, reps: [Kernova_V1_ClipboardRepresentationInfo],
            session: ClipboardProgressTracker.SessionToken
        ) {
            self.generation = generation
            self.reps = reps
            self.session = session
        }

        var isCancelled: Bool { lock.withLock { cancelledStorage } }

        /// Marks the job cancelled, returning the transfer to abort if one is in
        /// flight.
        ///
        /// Idempotent: a second cancel finds nothing in flight and returns `nil`.
        func cancel() -> UInt64? {
            lock.withLock {
                cancelledStorage = true
                defer { inFlightTransferID = nil }
                return inFlightTransferID
            }
        }

        /// Claims the job for one transfer, reporting `false` when a cancel has
        /// already landed and the transfer must not start.
        func beginTransfer(_ transferID: UInt64) -> Bool {
            lock.withLock {
                guard !cancelledStorage else { return false }
                inFlightTransferID = transferID
                return true
            }
        }

        func endTransfer() {
            lock.withLock { inFlightTransferID = nil }
        }
    }

    /// How one job ended.
    private enum JobOutcome {
        case completed
        case cancelled
        case failed(ClipboardErrorCode, String)
    }

    // MARK: - Init

    /// Production init — the real drop port and the guest user's Downloads
    /// folder.
    convenience init(progressTracker: ClipboardProgressTracker) {
        self.init(
            client: VsockGuestClient(port: KernovaVsockPort.drop, label: "drop"),
            progressTracker: progressTracker)
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
        progressTracker: ClipboardProgressTracker,
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
        self.progressTracker = progressTracker
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
        receiver?.cancelAll()
        // Unblock any worker parked on a pull (it returns cancelled).
        coordinator.failAll()
        receiver = nil
        liveChannel = nil
        for job in jobs.values {
            _ = job.cancel()
            // Immediate: the transport measuring these is gone, so there is
            // nothing left for the linger to show finishing.
            progressTracker.closeSession(job.session, immediately: true)
        }
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
        let connectionTag = ClipboardConnectionTag.nextGuest()
        // Built off-main (its callbacks hop themselves); only the published
        // reference is assigned on the main queue.
        let receiver = ClipboardStreamReceiver(
            channel: channel, staging: staging,
            onTransferTimed: { metrics in
                Self.logger.notice(
                    "Dropped file \(metrics.transferID, privacy: .public) (conn=\(connectionTag, privacy: .public)) received: \(metrics.logSummary, privacy: .public)"
                )
            },
            onComplete: { transferID, _ in
                Self.logger.warning(
                    "Unawaited dropped file \(transferID, privacy: .public) (conn=\(connectionTag, privacy: .public)) completed — dropped"
                )
            },
            onAbort: { info in
                Self.logger.debug(
                    "Unawaited dropped file \(info.transferID, privacy: .public) (conn=\(connectionTag, privacy: .public)) aborted (\(info.code, privacy: .public))"
                )
            })
        await MainActor.run {
            self.connectionTag = connectionTag
            self.liveChannel = channel
            self.receiver = receiver
        }
        Self.logger.notice(
            "Vsock drop connected to host (conn=\(connectionTag, privacy: .public))")

        do {
            for try await frame in channel.incoming where frame.protocolVersion == 1 {
                ClipboardStreamRouting.route(
                    frame, role: .guest, sender: nil, receiver: receiver,
                    senderAbortDelivery: .direct,
                    onControlFrame: { frame in
                        DispatchQueue.main.async { [weak self] in
                            self?.handleControlFrame(frame, on: channel)
                        }
                    })
            }
            Self.logger.notice(
                "Vsock drop channel closed by host (conn=\(connectionTag, privacy: .public))")
        } catch {
            Self.logger.warning(
                "Vsock drop channel ended with error (conn=\(connectionTag, privacy: .public)): \(error.localizedDescription, privacy: .public)"
            )
        }

        // Wake any worker blocked on a now-dead transfer immediately, off-main —
        // `teardownConnectionState` runs on main, which the worker does not hold
        // but the ordering keeps identical to the clipboard agent's.
        coordinator.failAll()
        await MainActor.run {
            self.teardownIfCurrent(channel)
        }
    }

    // MARK: - Frame handlers (main queue)

    private func handleControlFrame(_ frame: Frame, on channel: VsockChannel) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard liveChannel === channel else { return }
        switch frame.payload {
        case .dropOffer(let offer):
            handleDropOffer(offer, on: channel)
        case .dropRelease(let release):
            cancelJob(generation: release.generation)
        case .error(let error):
            Self.logger.warning(
                "Host drop error: \(error.code, privacy: .public) — \(error.message, privacy: .public)"
            )
        case .clipboardStreamBegin, .clipboardChunk, .clipboardStreamEnd, .clipboardStreamAck,
            .clipboardStreamAbort:
            // Routed off-main by the serve loop; never reaches here.
            break
        case .hello, .heartbeat, .policyUpdate, .logRecord, .clipboardOffer, .clipboardRequest,
            .clipboardRelease, .dropComplete, .none:
            Self.logger.warning("Unexpected payload on the drop channel — wrong port")
        }
    }

    /// Takes on one drop gesture: opens its readout and queues its files behind
    /// whatever is already running.
    private func handleDropOffer(_ offer: Kernova_V1_DropOffer, on channel: VsockChannel) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard jobs[offer.generation] == nil else {
            Self.logger.warning(
                "Duplicate drop offer for gen=\(offer.generation, privacy: .public) (conn=\(self.connectionTag, privacy: .public)) — ignored"
            )
            return
        }
        // Every field of the offer is host-supplied. Bound the count and each
        // declared size once, here at intake, so no capacity or progress
        // arithmetic downstream reasons about a value that can't be real.
        let bounded = ClipboardOfferBounds.bounded(offer.repInfo)
        if let truncatedFrom = bounded.truncatedFrom {
            Self.logger.warning(
                "Drop offer (gen=\(offer.generation, privacy: .public), conn=\(self.connectionTag, privacy: .public)) declared \(truncatedFrom, privacy: .public) items — truncated to \(bounded.reps.count, privacy: .public)"
            )
        }
        guard !bounded.reps.isEmpty else {
            send(
                completion: .failed(.dropFailed, "The drop carried no files"),
                generation: offer.generation, on: channel)
            return
        }

        let units = bounded.reps.enumerated().map { index, info in
            ClipboardProgressTracker.PlannedUnit(
                id: ClipboardTransferID.make(
                    generation: offer.generation, repIndex: index, hostMinted: false),
                expectedBytes: info.byteCount,
                name: info.filename.isEmpty ? nil : info.filename)
        }
        let generation = offer.generation
        let session = progressTracker.openSession(
            direction: .inbound, peerName: Self.dropSourceName, units: units,
            onCancelRequested: { [weak self] in
                DispatchQueue.main.async { self?.cancelJob(generation: generation) }
            })
        let job = DropJob(generation: generation, reps: bounded.reps, session: session)
        jobs[generation] = job
        Self.logger.notice(
            "Accepted a drop of \(bounded.reps.count, privacy: .public) item(s) (gen=\(generation, privacy: .public), conn=\(self.connectionTag, privacy: .public))"
        )
        jobQueue.async { [weak self] in
            self?.run(job: job, on: channel)
        }
    }

    /// Calls off the drop for `generation`, keeping what already landed.
    ///
    /// The same body serves a host `DropRelease` and a Cancel on this guest's own
    /// readout: both mean the user stopped it, and the files already written to
    /// Downloads are complete and stay — Finder's own cancel keeps them too.
    private func cancelJob(generation: UInt64) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let job = jobs[generation] else { return }
        guard let transferID = job.cancel() else { return }
        // Order matters: deregister the awaiter, stop the host producing bytes,
        // then wake the parked worker. Waking it first would let it start the
        // next file before the cancel is visible.
        receiver?.cancelAwait(transferID)
        sendStreamAbort(transferID: transferID)
        coordinator.abort(
            transferID,
            ClipboardStreamAbortInfo(
                transferID: transferID, code: "cancelled", message: "Cancelled by the user",
                neededBytes: nil, availableBytes: nil))
        Self.logger.notice(
            "Drop cancelled (gen=\(generation, privacy: .public), conn=\(self.connectionTag, privacy: .public))"
        )
    }

    /// Tells the host's sender to stop streaming a transfer this side has
    /// abandoned.
    private func sendStreamAbort(transferID: UInt64) {
        guard let channel = liveChannel else { return }
        var frame = Frame()
        frame.protocolVersion = 1
        frame.clipboardStreamAbort = .with {
            $0.transferID = transferID
            $0.code = "user.cancelled"
            $0.message = "Cancelled by the user"
        }
        try? channel.send(frame)
    }

    // MARK: - Job execution (worker queue)

    /// Pulls each of the job's files in order and lands it in Downloads.
    private func run(job: DropJob, on channel: VsockChannel) {
        dispatchPrecondition(condition: .notOnQueue(.main))
        var landed: [URL] = []
        var outcome: JobOutcome = .completed

        for (index, info) in job.reps.enumerated() {
            if job.isCancelled {
                outcome = .cancelled
                break
            }
            switch pull(index: index, info: info, job: job, on: channel) {
            case .success(let url):
                landed.append(url)
            case .cancelled:
                outcome = .cancelled
            case .failure(let code, let message):
                outcome = .failed(code, message)
            }
            if case .completed = outcome { continue }
            break
        }

        // The readout ends where it stopped: a cancelled or failed drop finishes
        // below 100 %, which is the whole of how those two read on screen.
        progressTracker.closeSession(job.session)
        if case .completed = outcome, !landed.isEmpty {
            revealInFinder(landed)
        }
        let generation = job.generation
        send(completion: outcome, generation: generation, on: channel)
        DispatchQueue.main.async { [weak self] in
            // Identity-checked, not just keyed: generations restart at 1 with
            // every accepted channel, so a worker that outlived a teardown would
            // otherwise clear the *next* connection's job of the same number —
            // leaving it unreachable by a release or a Cancel.
            guard self?.jobs[generation] === job else { return }
            self?.jobs[generation] = nil
        }
        Self.logger.notice(
            "Drop job finished (gen=\(generation, privacy: .public), \(landed.count, privacy: .public) file(s) in Downloads)"
        )
    }

    /// One representation's outcome.
    private enum PullOutcome {
        case success(URL)
        case cancelled
        case failure(ClipboardErrorCode, String)
    }

    /// Requests one representation, blocks until it lands, and moves it into
    /// Downloads.
    private func pull(
        index: Int, info: Kernova_V1_ClipboardRepresentationInfo, job: DropJob,
        on channel: VsockChannel
    ) -> PullOutcome {
        let byteCount = Int(clamping: info.byteCount)
        guard staging.hasCapacity(forByteCount: byteCount) else {
            Self.logger.warning(
                "Not enough disk space to receive dropped file '\(info.filename, privacy: .public)' (\(info.byteCount, privacy: .public) bytes)"
            )
            return .failure(
                .dropDiskFull, "Not enough disk space in the guest for \(info.byteCount) bytes")
        }
        // The guest is the receiver here, so it does not set the direction bit.
        let transferID = ClipboardTransferID.make(
            generation: job.generation, repIndex: index, hostMinted: false)
        guard job.beginTransfer(transferID) else { return .cancelled }
        defer { job.endTransfer() }

        let maxAccept =
            staging.availableCapacity().map { UInt64(clamping: $0) }
            ?? ClipboardStreamTuning.unlimitedAcceptByteCount
        let coordinator = self.coordinator
        let tracker = progressTracker
        let session = job.session
        guard let receiver = mainQueue({ self.receiver }) else { return .cancelled }
        receiver.awaitTransfer(
            transferID,
            // A folder's bytes are an archive of its tree, extracted as they
            // arrive. Directory-ness rides the offer this side already read, so
            // nothing on the wire has to repeat it.
            extractsDirectoryNamed: info.isDirectory ? info.filename : nil,
            advertisedByteCount: byteCount,
            onComplete: { rep in coordinator.deliver(transferID, rep) },
            onAbort: { abort in coordinator.abort(transferID, abort) },
            onProgress: { bytes, total in
                // Re-arms the inactivity backstop so a large still-streaming file
                // is never cut off mid-transfer.
                coordinator.heartbeat(transferID)
                tracker.unitProgressed(
                    session: session, id: transferID, bytesTransferred: UInt64(max(0, bytes)),
                    totalBytes: UInt64(max(0, total)))
            })
        tracker.unitBegan(
            session: session, id: transferID, expectedBytes: info.byteCount,
            name: info.filename.isEmpty ? nil : info.filename)

        let uti = info.uti
        let generation = job.generation
        let outcome = coordinator.pull(transferID: transferID, timeout: pullTimeout) {
            var request = Frame()
            request.protocolVersion = 1
            request.clipboardRequest = Kernova_V1_ClipboardRequest.with {
                $0.generation = generation
                $0.transferID = transferID
                $0.uti = uti
                $0.maxAcceptByteCount = maxAccept
            }
            do {
                try channel.send(request)
            } catch {
                // No request went out, so no reply will arrive — resolve the pull
                // now instead of blocking to the backstop timeout.
                receiver.cancelAwait(transferID)
                coordinator.abort(
                    transferID,
                    ClipboardStreamAbortInfo(
                        transferID: transferID, code: "send.failed",
                        message: "Failed to request the dropped file", neededBytes: nil,
                        availableBytes: nil))
            }
        }

        switch outcome {
        case .delivered(let representation):
            do {
                let url = try land(representation, named: info.filename)
                tracker.unitEnded(session: session, id: transferID, succeeded: true)
                return .success(url)
            } catch {
                tracker.unitEnded(session: session, id: transferID, succeeded: false)
                let failure = Self.classify(error)
                Self.logger.error(
                    "Failed to save a dropped file into Downloads: \(error.localizedDescription, privacy: .public)"
                )
                return .failure(failure.0, failure.1)
            }
        case .aborted(let abort):
            tracker.unitEnded(session: session, id: transferID, succeeded: false)
            if job.isCancelled { return .cancelled }
            Self.logger.warning(
                "Dropped file \(transferID, privacy: .public) aborted (\(abort.code, privacy: .public))"
            )
            return .failure(
                abort.code == "disk.full" ? .dropDiskFull : .dropFailed, abort.message)
        case .timedOut:
            receiver.cancelAwait(transferID)
            tracker.unitEnded(session: session, id: transferID, succeeded: false)
            sendStreamAbortFromWorker(transferID: transferID, on: channel)
            Self.logger.warning("Dropped file \(transferID, privacy: .public) timed out")
            return .failure(.dropFailed, "The transfer stopped making progress")
        case .cancelled:
            receiver.cancelAwait(transferID)
            tracker.unitEnded(session: session, id: transferID, succeeded: false)
            return .cancelled
        case .superseded:
            // A newer pull owns this id now; touch nothing keyed by it.
            tracker.unitEnded(session: session, id: transferID, succeeded: false)
            return .cancelled
        }
    }

    /// Sends a stall abort from the worker queue, where `liveChannel` is not
    /// readable.
    private func sendStreamAbortFromWorker(transferID: UInt64, on channel: VsockChannel) {
        var frame = Frame()
        frame.protocolVersion = 1
        frame.clipboardStreamAbort = .with {
            $0.transferID = transferID
            $0.code = "stall.timeout"
            $0.message = "Receiver gave up waiting for the dropped file"
        }
        try? channel.send(frame)
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

    private func send(completion: JobOutcome, generation: UInt64, on channel: VsockChannel) {
        var frame = Frame()
        frame.protocolVersion = 1
        frame.dropComplete = Kernova_V1_DropComplete.with {
            $0.generation = generation
            switch completion {
            case .completed:
                $0.outcome = .completed
            case .cancelled:
                $0.outcome = .cancelled
            case .failed(let code, let message):
                $0.outcome = .failed
                $0.code = code.rawValue
                $0.message = message
            }
        }
        try? channel.send(frame)
    }

    /// Reads main-queue-confined state from the worker queue.
    private func mainQueue<T>(_ body: () -> T) -> T {
        Thread.isMainThread ? body() : DispatchQueue.main.sync(execute: body)
    }
}
