import Foundation
import KernovaKit
import os

/// Streams files dropped on the VM display to the guest agent, which writes them
/// into the guest's Downloads folder.
///
/// One instance serves one accepted channel on `KernovaVsockPort.drop`, and the
/// drop is send-only: that channel carries the `DropOffer` announcing the items
/// and the guest's `DropComplete` closing the batch, never a payload byte. The
/// guest pulls each item on a vsock data connection of its own, dialled to the
/// drop data port and opened with a `ClipboardTransferRequest` — the transfer
/// engine a paste runs on.
///
/// Drops are **independent jobs**, not a supersession chain: dropping a second
/// batch while the first is still streaming leaves both running under their own
/// generations, because the user asked for both sets of files.
@MainActor
@Observable
final class VsockDropService: VsockFeatureService, VsockDataConnectionAccepting {
    // MARK: - Observable state

    /// `true` between `start()` and `stop()`.
    private(set) var isConnected: Bool = false

    // MARK: - Private state

    private let label: String

    /// This connection: the drops offered to the guest, and the transfers
    /// answering its pulls.
    ///
    /// `nonisolated` so an accepted data connection can be forwarded from the
    /// listener's queue.
    nonisolated private let endpoint: ClipboardEndpoint

    /// Log coordinate for this connection: generations and transfer ids restart
    /// with every accepted channel, and one instance serves exactly one.
    nonisolated private var connectionTag: ClipboardConnectionTag { endpoint.connectionTag }

    /// This VM's transfer report, which every surface renders. Shared with the
    /// VM's clipboard service, so one readout covers both.
    private let reporter: ClipboardTransferReporter

    /// Sizes a dropped folder's tree without reading it.
    ///
    /// Injected so a test can drop a folder without building one on disk, and so
    /// the walk can be driven synchronously.
    private let directoryByteCount: @Sendable (URL) -> Int

    /// Where each live drop's promised files were staged, by offer generation.
    ///
    /// A drag of file promises writes its bytes into a directory of its own
    /// before the offer goes out, and the guest can pull them minutes later, so
    /// the directory is held until that drop settles rather than freed when the
    /// drag ends.
    private var stagedDirectories: [UInt64: URL] = [:]

    /// Runs a payload-scaled folder walk off the main actor and calls back on it.
    ///
    /// A tree of any size would otherwise freeze the app for the length of the
    /// walk (docs/CLIPBOARD.md §8). Injected so a test can run it inline.
    private let runOffMainActor: (@escaping @Sendable () -> Void) -> Void

    // `nonisolated` so a log line can be written from any thread; `Logger` is
    // Sendable.
    nonisolated private static let logger = Logger(
        subsystem: "app.kernova", category: "VsockDropService")

    // MARK: - Settle contract

    /// Notified once when the channel dies on its own, never on an
    /// owner-requested `stop()`.
    @ObservationIgnored var onChannelLost: (@MainActor () -> Void)?

    /// Latches the first settle, whichever reached it, so the teardown is
    /// terminal rather than merely idempotent: `isConnected` alone would let a
    /// `start()` after a settle reopen the endpoint over an already-closed
    /// channel, whose immediate end reaches the owner as a channel loss it
    /// never had a live connection for.
    @ObservationIgnored private var hasStopped = false

    // MARK: - Init

    init(
        channel: VsockChannel, label: String, reporter: ClipboardTransferReporter,
        progressRevealDelay: TimeInterval = ClipboardTransferOperation.defaultRevealDelay,
        progressIdleGap: TimeInterval = ClipboardTransferOperation.defaultIdleGap,
        directoryByteCount: @escaping @Sendable (URL) -> Int = {
            ClipboardArchive.estimatedByteCount(at: $0)
        },
        runOffMainActor: @escaping (@escaping @Sendable () -> Void) -> Void = { work in
            DispatchQueue.global(qos: .userInitiated).async(execute: work)
        },
        scheduleDropDeadline:
            @escaping @Sendable (
                TimeInterval, @escaping @MainActor @Sendable () -> Void
            ) -> Void = ClipboardOutboundOffers.scheduleOnMainQueue
    ) {
        self.label = label
        self.reporter = reporter
        self.directoryByteCount = directoryByteCount
        self.runOffMainActor = runOffMainActor
        self.endpoint = ClipboardEndpoint(
            channel: channel,
            configuration: ClipboardEndpoint.Configuration(
                role: .host, kind: .drop, label: label, peerName: label,
                dropClaimSchedule: scheduleDropDeadline,
                progressRevealDelay: progressRevealDelay, progressIdleGap: progressIdleGap),
            reporter: reporter)
        endpoint.delegate = self
        endpoint.onDropSettled = { [weak self] generation in
            self?.releaseStagedFiles(for: generation)
        }
    }

    // MARK: - Lifecycle

    func start() {
        guard !isConnected, !hasStopped else { return }
        isConnected = true
        endpoint.start()
        Self.logger.notice(
            "Vsock drop service started for '\(self.label, privacy: .public)' (conn=\(self.connectionTag, privacy: .public))"
        )
    }

    /// Takes over one item's data connection, accepted on the drop data port,
    /// from whatever thread the listener hands it over on.
    ///
    /// Takes ownership of `fd` on every path.
    nonisolated func acceptDataConnection(fd: Int32) {
        endpoint.acceptDataConnection(fd: fd)
    }

    /// Tears the service down at the owner's request.
    ///
    /// The owner is not called back — it already knows.
    func stop() {
        settle(reason: .ownerRequested)
    }

    /// Tears the service down once its channel is over, whether the owner asked
    /// or the channel simply ended.
    ///
    /// Idempotent and terminal: the consume loop's own settle and an owner's
    /// `stop()` race by construction, the `hasStopped` latch lets the first one
    /// through do the work, and it keeps a later `start()` from reopening.
    /// `isConnected` is what a service settled before it ever connected skips
    /// the notification and the log line on.
    private func settle(reason: VsockSettleReason) {
        guard !hasStopped else { return }
        hasStopped = true
        endpoint.stop()
        guard isConnected else { return }
        isConnected = false
        Self.logger.notice(
            "Vsock drop service stopped for '\(self.label, privacy: .public)' (conn=\(self.connectionTag, privacy: .public))"
        )
        // Last, so the owner observes fully-settled state from inside the
        // callback.
        if case .channelLost = reason {
            onChannelLost?()
        }
    }

    // MARK: - Refusals

    /// Reports a refusal no operation is measuring — a drop that never got as far
    /// as opening one.
    private func reportRefusal(_ failure: ClipboardTransferFailure) {
        reporter.finish(
            ClipboardTransferFinish(
                gesture: .drop, outcome: .failed(failure), peerName: label))
    }

    /// Reports a drag this side took that produced no file to send, for a caller
    /// that resolved the drag's items itself — a file promise the source failed
    /// to write.
    ///
    /// Announced as a gesture of its own: this drag never reaches
    /// ``startDrop(urls:)``, so nothing else tells the reporter it happened.
    func reportUnreadableDrop() {
        reporter.gestureBegan()
        reportRefusal(.itemsUnreadable)
    }

    // MARK: - Starting a drop

    /// Offers the dropped `urls` to the guest, reporting whether the drop was
    /// taken on.
    ///
    /// Returns as soon as the drag's URL list has been taken, so the drag session
    /// ends promptly: reading each item's metadata and sizing a dropped folder
    /// are both `stat(2)`-scaled and run off the main actor, with the offer
    /// following once they land. `false` means nothing will be offered — the
    /// channel is gone, or the drag carried nothing. A drag whose items all turn
    /// out to be unreadable is answered by the report instead, since only the
    /// off-main pass can know.
    ///
    /// `stagedIn` is the directory a promise drag wrote `urls` into. A drop taken
    /// on owns it from here and frees it when that drop settles; a drop refused
    /// (`false`) leaves it to the caller, who still holds the only reference.
    @discardableResult
    func startDrop(urls: [URL], stagedIn stagingDirectory: URL? = nil) -> Bool {
        guard isConnected, !urls.isEmpty else { return false }
        // Announced the moment the drag is taken, so this one's verdict is its
        // own however it ends: a drag that turns out to carry nothing sendable,
        // or whose offer never gets away, opens no operation to announce it, and
        // its refusal would otherwise collapse into the identical one the last
        // drag left standing (`ClipboardTransferReporter.gestureBegan`).
        reporter.gestureBegan()
        let dropped = urls
        let sizeOf = directoryByteCount
        runOffMainActor { [weak self] in
            let intake = ClipboardPasteboardReader.resolve(filesAt: dropped, sizeOf: sizeOf)
            MainActorBridge.async {
                // Every path from here either registers the staged files against
                // an offer generation or frees them: nothing else holds a
                // reference to them once the drag is over.
                guard let self else {
                    stagingDirectory.map(DropPromiseStaging.release)
                    return
                }
                guard self.isConnected else {
                    // The channel went away while the items were being read. The
                    // drop was accepted, so its disappearance is owed the same
                    // answer an interrupted transfer gets — there is no job yet
                    // for `settle()` to have reported.
                    stagingDirectory.map(DropPromiseStaging.release)
                    self.reportRefusal(.interrupted(fileCount: dropped.count))
                    return
                }
                guard !intake.representations.isEmpty else {
                    // The gesture happened on this Mac and produced nothing, so
                    // the silence has to be explained here.
                    stagingDirectory.map(DropPromiseStaging.release)
                    self.reportRefusal(.itemsUnreadable)
                    return
                }
                self.offer(
                    intake.representations, skipped: intake.skipped, stagedIn: stagingDirectory)
            }
        }
        return true
    }

    /// Announces the drop, opening the readout that spans every file in it, and
    /// says what the drag carried that this offer leaves out.
    ///
    /// The readout carries the Cancel the user reaches a drop through; it runs
    /// on the endpoint, so nothing here handles one.
    ///
    /// `skipped` is handed to the offer rather than announced here: one gesture
    /// ends once (docs/CLIPBOARD.md §13), and the drop's terminal counts these
    /// alongside whatever fails once the guest asks — so an interim refusal
    /// naming only this stage would reach the user as a second notice carrying
    /// a smaller number than the verdict that follows it.
    private func offer(
        _ reps: [ClipboardContent.Representation], skipped: Int, stagedIn stagingDirectory: URL?
    ) {
        let outcome = endpoint.offer(
            ClipboardContent(representations: reps), skippedBeforeOffer: skipped)
        guard case .sent(let generation) = outcome else {
            // Nothing was registered for the guest to pull from, so no settle is
            // coming for these files — and with the offer itself lost there is
            // no rest of the batch for the skipped items to be missing from.
            stagingDirectory.map(DropPromiseStaging.release)
            return
        }
        if let stagingDirectory { stagedDirectories[generation] = stagingDirectory }
        guard skipped > 0 else { return }
        Self.logger.warning(
            "Skipped \(skipped, privacy: .public) unreadable dropped item(s) for '\(self.label, privacy: .public)' (conn=\(self.connectionTag, privacy: .public))"
        )
    }

    /// Frees the files one settled drop's promises were staged into.
    private func releaseStagedFiles(for generation: UInt64) {
        guard let directory = stagedDirectories.removeValue(forKey: generation) else { return }
        DropPromiseStaging.release(directory)
    }
}

// MARK: - Endpoint delegate

extension VsockDropService: ClipboardEndpointDelegate {
    /// Settles here rather than waiting for whatever replaces this service.
    ///
    /// `isConnected` is what the display reads to decide whether it may take a
    /// drop, and the guest closes this channel on every control reconnect (its
    /// client pauses until the next `Hello`), so a service left standing would
    /// keep advertising a drop it can no longer send.
    func endpointDidEnd(_ endpoint: ClipboardEndpoint) {
        settle(reason: .channelLost)
    }
}
