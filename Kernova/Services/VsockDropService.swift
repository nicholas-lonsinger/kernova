import Foundation
import KernovaKit
import UniformTypeIdentifiers
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
final class VsockDropService: VsockDataConnectionAccepting {
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

    /// Runs a payload-scaled folder walk off the main actor and calls back on it.
    ///
    /// A tree of any size would otherwise freeze the app for the length of the
    /// walk (docs/CLIPBOARD.md §8). Injected so a test can run it inline.
    private let runOffMainActor: (@escaping @Sendable () -> Void) -> Void

    // `nonisolated` so a log line can be written from any thread; `Logger` is
    // Sendable.
    nonisolated private static let logger = Logger(
        subsystem: "app.kernova", category: "VsockDropService")

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
    }

    // MARK: - Lifecycle

    func start() {
        guard !isConnected else { return }
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

    func stop() {
        settle()
    }

    /// Tears the service down once its channel is over, whether the owner asked
    /// or the channel simply ended.
    ///
    /// Idempotent: the consume loop's own settle and an owner's `stop()` race by
    /// construction, and the first one through does the work.
    private func settle() {
        endpoint.stop()
        guard isConnected else { return }
        isConnected = false
        Self.logger.notice(
            "Vsock drop service stopped for '\(self.label, privacy: .public)' (conn=\(self.connectionTag, privacy: .public))"
        )
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
    func reportUnreadableDrop() {
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
    @discardableResult
    func startDrop(urls: [URL]) -> Bool {
        guard isConnected, !urls.isEmpty else { return false }
        let dropped = urls
        let sizeOf = directoryByteCount
        runOffMainActor { [weak self] in
            let gathered = Self.gather(dropped, sizeOf: sizeOf)
            MainActorBridge.async {
                guard let self else { return }
                guard self.isConnected else {
                    // The channel went away while the items were being read. The
                    // drop was accepted, so its disappearance is owed the same
                    // answer an interrupted transfer gets — there is no job yet
                    // for `settle()` to have reported.
                    self.reportRefusal(.interrupted(fileCount: dropped.count))
                    return
                }
                guard !gathered.candidates.isEmpty else {
                    // The gesture happened on this Mac and produced nothing, so
                    // the silence has to be explained here.
                    self.reportRefusal(.itemsUnreadable)
                    return
                }
                self.offer(
                    Self.representations(for: gathered.candidates, sizes: gathered.sizes),
                    skipped: gathered.unreadable)
            }
        }
        return true
    }

    /// What one off-main pass over the dropped URLs produced.
    private struct GatheredDrop: Sendable {
        var candidates: [DropCandidate] = []
        /// A dropped folder's stat-walk estimate, by folder URL.
        var sizes: [URL: Int] = [:]
        /// How many of the dropped items could not be read at all.
        var unreadable = 0
    }

    /// Reads every dropped item's metadata, sizing any folder among them.
    ///
    /// `nonisolated`: each `resourceValues` call is a `stat(2)` and a folder's
    /// estimate walks its whole tree, so a drag of several hundred items — or one
    /// deep folder — would otherwise freeze the app for the length of the walk
    /// (docs/CLIPBOARD.md §8). The URLs are read off the drag pasteboard on the
    /// main actor, and the sandbox extension that arrives with them covers the
    /// process, so reading them from here needs nothing further.
    nonisolated private static func gather(
        _ urls: [URL], sizeOf: @Sendable (URL) -> Int
    ) -> GatheredDrop {
        var gathered = GatheredDrop()
        for url in urls {
            guard
                let values = try? url.resourceValues(forKeys: [
                    .contentTypeKey, .isDirectoryKey, .fileSizeKey,
                ])
            else {
                gathered.unreadable += 1
                continue
            }
            if values.isDirectory == true {
                gathered.candidates.append(
                    DropCandidate(
                        url: url, uti: (values.contentType ?? .folder).identifier,
                        filename: url.lastPathComponent, byteCount: nil, isDirectory: true))
                gathered.sizes[url] = sizeOf(url)
            } else if let type = values.contentType, let size = values.fileSize {
                gathered.candidates.append(
                    DropCandidate(
                        url: url, uti: type.identifier, filename: url.lastPathComponent,
                        byteCount: size, isDirectory: false))
            } else {
                gathered.unreadable += 1
            }
        }
        return gathered
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

    /// Announces the drop, opening the readout that spans every file in it, and
    /// says what the drag carried that this offer leaves out.
    ///
    /// The readout carries the Cancel the user reaches a drop through; it runs
    /// on the endpoint, so nothing here handles one.
    private func offer(_ reps: [ClipboardContent.Representation], skipped: Int) {
        let outcome = endpoint.offer(ClipboardContent(representations: reps))
        // "The rest were" sent is the whole point of the notice, and a failed
        // offer sent none of them — the readout the offer already failed carries
        // that news instead.
        guard skipped > 0, case .sent = outcome else { return }
        Self.logger.warning(
            "Skipped \(skipped, privacy: .public) unreadable dropped item(s) for '\(self.label, privacy: .public)' (conn=\(self.connectionTag, privacy: .public))"
        )
        // Queued behind the offer's own `markQueued`, which is what dates this
        // refusal *after* the drop's readout began: `ClipboardTransferReporter`
        // lets a completion clear a refusal older than the operation it ran
        // beside, and the rest of the batch arriving disproves nothing about the
        // items left out.
        MainActorBridge.async { [weak self] in
            guard let self else { return }
            self.reportRefusal(.itemsSkipped(note: Self.skippedNote(count: skipped)))
        }
    }

    /// The sentence a partly-unreadable drop shows.
    private static func skippedNote(count: Int) -> String {
        count == 1
            ? "One item couldn\u{2019}t be read, so it wasn\u{2019}t sent to the VM. The rest were."
            : "\(count) items couldn\u{2019}t be read, so they weren\u{2019}t sent to the VM. The rest were."
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
        settle()
    }
}
