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

    // MARK: - Private state

    private let label: String

    /// This connection's engine, frame routing and control-frame delivery.
    nonisolated private let session: ClipboardStreamSession

    /// The drops offered to the guest, and the transfers answering its pulls.
    private let outbound: ClipboardOutboundOffers

    /// Log coordinate for this connection: generations and transfer ids restart
    /// with every accepted channel, and one instance serves exactly one.
    nonisolated private var connectionTag: ClipboardConnectionTag { session.connectionTag }

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
        }
    ) {
        self.label = label
        self.reporter = reporter
        self.directoryByteCount = directoryByteCount
        self.runOffMainActor = runOffMainActor
        let session = ClipboardStreamSession(
            channel: channel, role: .host, kind: .drop, label: label)
        self.session = session
        self.outbound = ClipboardOutboundOffers(
            session: session, reporter: reporter, peerName: label,
            progressRevealDelay: progressRevealDelay, progressIdleGap: progressIdleGap)
    }

    // MARK: - Lifecycle

    func start() {
        guard !isConnected else { return }
        isConnected = true
        session.start(
            handleControlFrame: { [weak self] frame in self?.handleControlFrame(frame) },
            onEnded: { [weak self] in
                // The channel is gone — settle here rather than waiting for
                // whatever replaces this service. `isConnected` is what the
                // display reads to decide whether it may take a drop, and the
                // guest closes this channel on every control reconnect (its
                // client pauses until the next `Hello`), so a service left
                // standing would keep advertising a drop it can no longer send.
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.settle() } }
            })
        Self.logger.notice(
            "Vsock drop service started for '\(self.label, privacy: .public)' (conn=\(self.connectionTag, privacy: .public))"
        )
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
        session.stop()
        guard isConnected else { return }
        isConnected = false
        outbound.endSession()
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
        guard isConnected, session.sender != nil else { return false }
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
            reportRefusal(.itemsUnreadable)
            return false
        }

        let dropped = candidates
        guard dropped.contains(where: \.isDirectory) else {
            offer(Self.representations(for: dropped, sizes: [:]))
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
                        self.reportRefusal(.interrupted(fileCount: dropped.count))
                        return
                    }
                    self.offer(Self.representations(for: dropped, sizes: measured))
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

    /// Announces the drop, opening the readout that spans every file in it.
    private func offer(_ reps: [ClipboardContent.Representation]) {
        outbound.offer(ClipboardContent(representations: reps))
    }

    // MARK: - Cancelling

    /// Calls off the drop for `generation`: the guest keeps whatever already
    /// landed in Downloads and drops the rest.
    func cancelDrop(generation: UInt64) {
        outbound.cancel(generation: generation)
    }

    // MARK: - Frame consumer

    /// Handles the control frames the consume loop dispatches to the main actor.
    private func handleControlFrame(_ frame: Frame) {
        switch frame.payload {
        case .clipboardRequest(let request):
            outbound.handleRequest(request)
        case .dropComplete(let complete):
            outbound.handleDropComplete(complete)
        case .clipboardStreamAbort(let abort):
            // Only a sender-bound abort reaches here; see `ClipboardStreamRouting`.
            session.sender?.handleAbort(transferID: abort.transferID)
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
            session.channel.close()
        case .none:
            Self.logger.debug("Frame with no payload for '\(self.label, privacy: .public)'")
        }
    }
}
