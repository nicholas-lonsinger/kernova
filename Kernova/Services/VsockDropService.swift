import Foundation
import KernovaKit
import UniformTypeIdentifiers
import os

/// Streams files dropped on the VM display to the guest agent, which writes them
/// into the guest's Downloads folder.
///
/// One instance serves one accepted channel on `KernovaVsockPort.drop`. It is
/// send-only and rides the clipboard streaming engine unchanged: a drop is
/// announced as a `DropOffer` carrying metadata, the guest pulls each
/// representation with a `ClipboardRequest`, and the bytes cross on the same
/// `Begin`/`Chunk`/`End` path a paste uses.
///
/// Drops are **independent jobs**, not a supersession chain: dropping a second
/// batch while the first is still streaming leaves both running under their own
/// generations, because the user asked for both sets of files.
@MainActor
@Observable
final class VsockDropService {
    // MARK: - Observable state

    /// `true` between `start()` and `stop()`.
    private(set) var isConnected: Bool = false

    /// The drop currently being shown (most-significant in-flight session past
    /// the reveal delay), or `nil`.
    private(set) var transferProgress: ClipboardProgressSnapshot?

    // MARK: - Private state

    private let channel: VsockChannel
    private let label: String
    private let instanceID: UUID

    /// Log coordinate for this connection: generations and transfer ids restart
    /// with every accepted channel, and one instance serves exactly one.
    private let connectionTag = ClipboardConnectionTag.nextHost()

    private let progressCenter: ClipboardProgressCenter
    private let issueCenter: ClipboardIssueCenter

    /// The paste ceiling in force, recorded on any issue this service raises so
    /// every surface renders one VM's notices the same way.
    private let maxPasteBytes: @MainActor () -> Int

    /// Sizes a dropped folder's tree without reading it.
    ///
    /// Injected so a test can drop a folder without building one on disk, and so
    /// the walk can be driven synchronously.
    private let directoryByteCount: @Sendable (URL) -> Int

    /// Runs a payload-scaled folder walk off the main actor and calls back on it.
    ///
    /// A tree of any size would otherwise freeze the app for the length of the
    /// walk (docs/CLIPBOARD.md §8). Injected so a test can run it inline.
    private let runOffMainActor: (@escaping @Sendable () -> Void) -> Void

    @ObservationIgnored private var progress = ClipboardProgressTracker { _ in }

    private var sender: ClipboardStreamSender?
    private var consumeTask: Task<Void, Never>?

    /// Generation for the next drop; starts at 1 so 0 is the "no drop" sentinel.
    private var nextGeneration: UInt64 = 1

    /// Every drop still being served, keyed by its generation.
    private var jobs: [UInt64: DropJob] = [:]

    // `nonisolated` so the off-main consume loop can log; `Logger` is Sendable.
    nonisolated private static let logger = Logger(
        subsystem: "app.kernova", category: "VsockDropService")

    /// One drop gesture: the files it carries and the readout measuring them.
    private final class DropJob {
        let generation: UInt64
        let content: ClipboardContent
        let session: ClipboardProgressTracker.SessionToken
        /// Read from the sender's transfer queues to decide whether the job is
        /// still wanted; zeroed by a cancel, which aborts every transfer under it.
        let liveGeneration = AtomicGeneration()
        /// Whether the user (or a teardown) called this job off, so its silent
        /// end is not reported as a failure.
        var isCancelled = false

        init(
            generation: UInt64, content: ClipboardContent,
            session: ClipboardProgressTracker.SessionToken
        ) {
            self.generation = generation
            self.content = content
            self.session = session
            liveGeneration.set(generation)
        }
    }

    /// One dropped item's cheap metadata, gathered on the main actor before any
    /// payload-scaled work.
    private struct DropCandidate: Sendable {
        let url: URL
        let uti: String
        let filename: String
        /// A file's stat'd size; `nil` until a folder's walk fills it in.
        let byteCount: Int?
        let isDirectory: Bool
    }

    // MARK: - Init

    init(
        channel: VsockChannel, label: String, instanceID: UUID,
        maxPasteBytes: @escaping @MainActor () -> Int = { ClipboardPasteLimit.defaultBytes },
        progressRevealDelay: TimeInterval = ClipboardProgressTracker.defaultRevealDelay,
        progressIdleLinger: TimeInterval = ClipboardProgressTracker.defaultIdleLinger,
        directoryByteCount: @escaping @Sendable (URL) -> Int = {
            ClipboardArchive.estimatedByteCount(at: $0)
        },
        runOffMainActor: @escaping (@escaping @Sendable () -> Void) -> Void = { work in
            DispatchQueue.global(qos: .userInitiated).async(execute: work)
        },
        progressCenter: ClipboardProgressCenter = .shared,
        issueCenter: ClipboardIssueCenter = .shared
    ) {
        self.channel = channel
        self.label = label
        self.instanceID = instanceID
        self.maxPasteBytes = maxPasteBytes
        self.directoryByteCount = directoryByteCount
        self.runOffMainActor = runOffMainActor
        self.progressCenter = progressCenter
        self.issueCenter = issueCenter
        // Emissions hop to main on a serial (FIFO) queue, not an unordered
        // `Task { @MainActor }`: two snapshots arriving out of order would make
        // the progress bar jump backwards.
        progress = ClipboardProgressTracker(
            revealDelay: progressRevealDelay, idleLinger: progressIdleLinger
        ) { [weak self] snapshot in
            DispatchQueue.main.async {
                guard let self else { return }
                MainActor.assumeIsolated { self.publishProgress(snapshot) }
            }
        }
    }

    // MARK: - Lifecycle

    func start() {
        guard consumeTask == nil else { return }
        isConnected = true

        let sender = ClipboardStreamSender(channel: channel)
        self.sender = sender

        let channel = self.channel
        let label = self.label
        let connectionTag = self.connectionTag
        consumeTask = Task { [weak self] in
            await Self.consume(
                channel: channel, label: label, connectionTag: connectionTag, sender: sender,
                onControlFrame: { [weak self] frame in
                    // Fire-and-forget on the serial main queue, which preserves
                    // control-frame FIFO order; a per-frame Task would not.
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { self?.handleControlFrame(frame) }
                    }
                })
            // The channel is gone — settle here rather than waiting for whatever
            // replaces this service. `isConnected` is what the display reads to
            // decide whether it may take a drop, and the guest closes this
            // channel on every control reconnect (its client pauses until the
            // next `Hello`), so a service left standing would keep advertising a
            // drop it can no longer send.
            await MainActor.run { self?.settle() }
        }
        Self.logger.notice(
            "Vsock drop service started for '\(self.label, privacy: .public)' (conn=\(self.connectionTag, privacy: .public))"
        )
    }

    func stop() {
        consumeTask?.cancel()
        consumeTask = nil
        settle()
    }

    /// Tears the service down once its channel is over, whether the owner asked
    /// or the channel simply ended.
    ///
    /// Idempotent: the consume loop's own settle and an owner's `stop()` race by
    /// construction, and the first one through does the work.
    private func settle() {
        channel.close()
        guard isConnected else { return }
        isConnected = false
        sender?.cancelAll()
        sender = nil
        // A job still open when the channel goes is a drop whose files never
        // landed, and the gesture was made on this Mac — so it is owed an answer
        // here. One already called off is not: the user knows.
        let abandoned = jobs.values.filter { !$0.isCancelled }
        for job in abandoned { job.liveGeneration.set(0) }
        jobs.removeAll()
        if !abandoned.isEmpty {
            raiseIssue(
                .dropInterrupted(
                    fileCount: abandoned.reduce(0) { $0 + $1.content.representations.count }))
        }
        progress.clearAll()
        // Synchronously, not via the tracker's emission hop: a readout still
        // standing for a VM that has gone is the stuck indicator §13 forbids.
        publishProgress(nil)
        // Unconditional, unlike `publishProgress`'s change-guarded push: a stopped
        // VM's last snapshot would otherwise pin the status item's readout.
        progressCenter.progressChanged(from: self, nil)
        Self.logger.notice(
            "Vsock drop service stopped for '\(self.label, privacy: .public)' (conn=\(self.connectionTag, privacy: .public))"
        )
    }

    // MARK: - Progress and issues

    private func publishProgress(_ snapshot: ClipboardProgressSnapshot?) {
        // A stopped service shows nothing: emissions reach here through a queue
        // hop, so one dispatched just before teardown can land just after it.
        let next = isConnected ? snapshot : nil
        guard next != transferProgress else { return }
        transferProgress = next
        progressCenter.progressChanged(from: self, next)
    }

    private func raiseIssue(_ issue: ClipboardTransferIssue) {
        issueCenter.report(
            issue, instanceID: instanceID, vmName: label, pasteLimitBytes: maxPasteBytes())
    }

    // MARK: - Starting a drop

    /// Offers the dropped `urls` to the guest, reporting whether the drop was
    /// taken up.
    ///
    /// Returns as soon as the items' metadata has been read, so the drag session
    /// ends promptly: a folder's size walk and the offer itself follow off the
    /// main actor. `false` means nothing was offered — the channel is gone, or
    /// none of the items could be read.
    @discardableResult
    func startDrop(urls: [URL]) -> Bool {
        guard isConnected, sender != nil else { return false }
        var candidates: [DropCandidate] = []
        var unreadable = 0
        for url in urls {
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
                    DropCandidate(
                        url: url, uti: (values.contentType ?? .folder).identifier,
                        filename: url.lastPathComponent, byteCount: nil, isDirectory: true))
            } else if let type = values.contentType, let size = values.fileSize {
                candidates.append(
                    DropCandidate(
                        url: url, uti: type.identifier, filename: url.lastPathComponent,
                        byteCount: size, isDirectory: false))
            } else {
                unreadable += 1
            }
        }
        if unreadable > 0 {
            Self.logger.warning(
                "Skipped \(unreadable, privacy: .public) unreadable dropped item(s) for '\(self.label, privacy: .public)' (conn=\(self.connectionTag, privacy: .public))"
            )
        }
        guard !candidates.isEmpty else {
            // The gesture happened on this Mac and produced nothing, so the
            // silence has to be explained here.
            raiseIssue(.dropItemsUnreadable())
            return false
        }

        let generation = nextGeneration
        nextGeneration += 1
        let dropped = candidates
        guard dropped.contains(where: \.isDirectory) else {
            offer(generation: generation, reps: Self.representations(for: dropped, sizes: [:]))
            return true
        }
        // A folder's stat-walk estimate is payload-scaled, so it never runs on
        // the main actor. The offer follows once it lands.
        let folders = dropped.filter(\.isDirectory).map(\.url)
        let sizeOf = directoryByteCount
        runOffMainActor { [weak self] in
            var sizes: [URL: Int] = [:]
            for folder in folders { sizes[folder] = sizeOf(folder) }
            let measured = sizes
            DispatchQueue.main.async {
                guard let self else { return }
                MainActor.assumeIsolated {
                    guard self.isConnected else {
                        // The channel went away while the folder was being
                        // sized. The drop was accepted, so its disappearance is
                        // owed the same answer an interrupted transfer gets —
                        // there is no job yet for `settle()` to have reported.
                        self.raiseIssue(.dropInterrupted(fileCount: dropped.count))
                        return
                    }
                    self.offer(
                        generation: generation,
                        reps: Self.representations(for: dropped, sizes: measured))
                }
            }
        }
        return true
    }

    /// Builds one representation per dropped item, taking a folder's size from
    /// the completed walk.
    private static func representations(
        for candidates: [DropCandidate], sizes: [URL: Int]
    ) -> [ClipboardContent.Representation] {
        candidates.map { candidate in
            guard candidate.isDirectory else {
                return ClipboardContent.Representation(
                    uti: candidate.uti, fileURL: candidate.url,
                    byteCount: candidate.byteCount ?? 0, filename: candidate.filename)
            }
            return ClipboardContent.Representation(
                directorySourceURL: candidate.url, estimatedByteCount: sizes[candidate.url] ?? 0,
                filename: candidate.filename, uti: candidate.uti)
        }
    }

    /// Registers the job and announces it, opening the readout that spans every
    /// file in the drop.
    private func offer(generation: UInt64, reps: [ClipboardContent.Representation]) {
        // Cap to the 16-bit rep-index limit a transfer id can address.
        let capped = ClipboardContent(representations: reps).cappedToOfferLimit()
        if let originalCount = capped.truncatedFrom {
            Self.logger.warning(
                "Drop truncated from \(originalCount, privacy: .public) to \(ClipboardContent.maxOfferableRepresentations, privacy: .public) items (16-bit transfer-id limit)"
            )
        }
        let content = capped.content
        guard !content.representations.isEmpty else { return }

        // One session for the whole drop, declared up front, so the bar's
        // denominator is every dropped file rather than each in turn (§13).
        let units = content.representations.enumerated().map { index, rep in
            ClipboardProgressTracker.PlannedUnit(
                id: ClipboardTransferID.make(
                    generation: generation, repIndex: index, hostMinted: false),
                expectedBytes: UInt64(max(0, rep.byteCount)), name: rep.filename)
        }
        let session = progress.openSession(
            direction: .outbound, peerName: label, units: units,
            onCancelRequested: { [weak self] in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.cancelDrop(generation: generation) }
                }
            })

        var frame = Frame()
        frame.protocolVersion = 1
        frame.dropOffer = Kernova_V1_DropOffer.with {
            $0.generation = generation
            $0.repInfo = content.representations.map(\.offerRepresentationInfo)
        }
        do {
            try channel.send(frame)
        } catch {
            progress.closeSession(session, immediately: true)
            Self.logger.error(
                "Failed to offer a drop to '\(self.label, privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
            raiseIssue(.dropSendFailed())
            return
        }
        jobs[generation] = DropJob(generation: generation, content: content, session: session)
        Self.logger.notice(
            "Offered a drop to '\(self.label, privacy: .public)' (gen=\(generation, privacy: .public), conn=\(self.connectionTag, privacy: .public), \(content.representations.count, privacy: .public) item(s), \(content.totalByteCount, privacy: .public) bytes)"
        )
    }

    // MARK: - Cancelling

    /// Calls off the drop for `generation`: the guest keeps whatever already
    /// landed in Downloads and drops the rest.
    func cancelDrop(generation: UInt64) {
        guard let job = jobs[generation] else { return }
        job.isCancelled = true
        // Zeroed first, so a transfer between chunks sees the job is gone and
        // aborts itself rather than racing the explicit cancel below.
        job.liveGeneration.set(0)
        sender?.cancel(generation: generation)
        var frame = Frame()
        frame.protocolVersion = 1
        frame.dropRelease = Kernova_V1_DropRelease.with { $0.generation = generation }
        try? channel.send(frame)
        // Not `immediately`: the linger is what leaves the readout on screen at
        // the fraction it stopped on, so the cancel is visibly what happened.
        progress.closeSession(job.session)
        jobs[generation] = nil
        Self.logger.notice(
            "User cancelled the drop to '\(self.label, privacy: .public)' (gen=\(generation, privacy: .public), conn=\(self.connectionTag, privacy: .public))"
        )
    }

    // MARK: - Frame consumer

    /// Drains the channel, routing high-frequency stream frames off the main
    /// actor.
    nonisolated private static func consume(
        channel: VsockChannel,
        label: String,
        connectionTag: ClipboardConnectionTag,
        sender: ClipboardStreamSender,
        onControlFrame: @Sendable @escaping (Frame) -> Void
    ) async {
        do {
            for try await frame in channel.incoming where frame.protocolVersion == 1 {
                // `handleRequest` registers outbound transfers on the main actor,
                // so a sender-bound abort rides the same hop rather than being
                // handled here.
                ClipboardStreamRouting.route(
                    frame, role: .host, sender: sender, receiver: nil,
                    senderAbortDelivery: .viaControlFrame, onControlFrame: onControlFrame)
            }
            logger.info(
                "Vsock drop channel closed for '\(label, privacy: .public)' (conn=\(connectionTag, privacy: .public))"
            )
        } catch {
            logger.warning(
                "Vsock drop channel ended with error for '\(label, privacy: .public)' (conn=\(connectionTag, privacy: .public)): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func handleControlFrame(_ frame: Frame) {
        switch frame.payload {
        case .clipboardRequest(let request):
            handleRequest(request)
        case .dropComplete(let complete):
            handleDropComplete(complete)
        case .clipboardStreamAbort(let abort):
            // Only a sender-bound abort reaches here; see the routing in `consume`.
            sender?.handleAbort(transferID: abort.transferID)
        case .error(let error):
            Self.logger.warning(
                "Guest drop error for '\(self.label, privacy: .public)': \(error.code, privacy: .public) — \(error.message, privacy: .public)"
            )
        case .clipboardStreamBegin, .clipboardChunk, .clipboardStreamEnd, .clipboardStreamAck:
            // Routed off-main by the consume loop; never reaches here.
            break
        case .hello, .heartbeat, .policyUpdate, .logRecord, .clipboardOffer, .clipboardRelease,
            .dropOffer, .dropRelease:
            // Control-plane, clipboard and host→guest drop payloads belong
            // elsewhere; a peer sending them here crossed wires.
            Self.logger.warning(
                "Unexpected payload on the drop channel for '\(self.label, privacy: .public)' — wrong port; closing the channel"
            )
            channel.close()
        case .none:
            Self.logger.debug("Frame with no payload for '\(self.label, privacy: .public)'")
        }
    }

    // MARK: - Serving the guest's pulls

    private func handleRequest(_ request: Kernova_V1_ClipboardRequest) {
        guard let job = jobs[request.generation] else {
            Self.logger.debug(
                "Drop request for an unknown generation \(request.generation, privacy: .public) (conn=\(self.connectionTag, privacy: .public))"
            )
            // Abort every dropped request so the guest's parked pull wakes
            // immediately instead of stalling to its backstop timeout.
            sender?.rejectRequest(
                transferID: request.transferID, code: .requestStale,
                message: "No live drop for generation \(request.generation)")
            return
        }
        let repIndex = Int(request.transferID & 0xFFFF)
        guard repIndex < job.content.representations.count else {
            Self.logger.warning(
                "Drop request transfer_id \(request.transferID, privacy: .public) out of range for gen=\(request.generation, privacy: .public) (conn=\(self.connectionTag, privacy: .public))"
            )
            sender?.rejectRequest(
                transferID: request.transferID, code: .requestRange,
                message: "Item index \(repIndex) out of range")
            return
        }
        let representation = job.content.representations[repIndex]
        guard representation.uti == request.uti else {
            Self.logger.warning(
                "Drop request uti '\(request.uti, privacy: .public)' doesn't match offered item \(repIndex, privacy: .public) (conn=\(self.connectionTag, privacy: .public))"
            )
            sender?.rejectRequest(
                transferID: request.transferID, code: .requestUTI,
                message: "Requested UTI '\(request.uti)' does not match the dropped item")
            return
        }
        // Ahead of the session bookkeeping: with no sender nothing streams, so a
        // transfer announced here would never see a terminal and its readout
        // would stick on screen.
        guard let sender else { return }

        let xid = request.transferID
        let session = job.session
        let tracker = progress
        let live = job.liveGeneration
        tracker.unitBegan(
            session: session, id: xid, expectedBytes: UInt64(max(0, representation.byteCount)),
            name: representation.filename)
        sender.startTransfer(
            transferID: xid,
            generation: request.generation,
            representation: representation,
            maxAcceptByteCount: request.maxAcceptByteCount,
            // A drop always lands as a file in Downloads; nothing about it is
            // pasteboard-inline.
            isInline: false,
            isCurrent: { live.isCurrent($0) },
            onProgress: { sent, total in
                tracker.unitProgressed(
                    session: session, id: xid, bytesTransferred: UInt64(max(0, sent)),
                    totalBytes: UInt64(max(0, total)))
            },
            onComplete: { success in
                tracker.unitEnded(session: session, id: xid, succeeded: success)
            })
        Self.logger.debug(
            "Streaming dropped item \(repIndex, privacy: .public) to '\(self.label, privacy: .public)' (gen=\(request.generation, privacy: .public), conn=\(self.connectionTag, privacy: .public), \(representation.byteCount, privacy: .public) bytes offered)"
        )
    }

    // MARK: - The guest's verdict

    private func handleDropComplete(_ complete: Kernova_V1_DropComplete) {
        guard let job = jobs.removeValue(forKey: complete.generation) else { return }
        job.liveGeneration.set(0)
        switch complete.outcome {
        case .completed:
            progress.closeSession(job.session)
            Self.logger.notice(
                "Drop to '\(self.label, privacy: .public)' completed (gen=\(complete.generation, privacy: .public), conn=\(self.connectionTag, privacy: .public), \(job.content.representations.count, privacy: .public) item(s))"
            )
        case .cancelled:
            progress.closeSession(job.session)
            Self.logger.notice(
                "Drop to '\(self.label, privacy: .public)' cancelled (gen=\(complete.generation, privacy: .public), conn=\(self.connectionTag, privacy: .public))"
            )
        case .failed, .unspecified, .UNRECOGNIZED:
            progress.closeSession(job.session)
            // The code is matched, never the message: `message` is guest-supplied
            // text and the sentence the user reads is composed here.
            let code = ClipboardErrorCode(rawValue: complete.code)
            Self.logger.error(
                "Drop to '\(self.label, privacy: .public)' failed (gen=\(complete.generation, privacy: .public), conn=\(self.connectionTag, privacy: .public), code=\(complete.code, privacy: .public)): \(complete.message, privacy: .public)"
            )
            raiseIssue(.dropFailed(code: code))
        }
    }
}

// MARK: - Cancelling the shown transfer

extension VsockDropService: TransferCancelling {
    /// Routes a Cancel on the app-wide readout to whichever drop that readout is
    /// showing.
    func requestCancelOfShownOperation() {
        progress.requestCancelOfPublishedSession()
    }
}
