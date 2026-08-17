import CryptoKit
import Foundation
import os

/// Opens the extract sink for one archived transfer.
///
/// `onOutputAdvanced` is the receiver's output guard, consulted with the running
/// uncompressed total on the sink's own thread; a sink that stands in for
/// ``ClipboardArchiveExtractSink`` must still route it, since throwing from it is
/// how a transfer that outgrows its ceiling or its volume is stopped. Progress
/// in payload units is read off a ``ClipboardArchiveExtractSink`` directly, so
/// a stand-in reports wire bytes instead.
public typealias ClipboardSinkFactory =
    @Sendable (
        _ destinationURL: URL, _ label: String,
        _ onOutputAdvanced: @escaping @Sendable (Int) throws -> Void
    ) throws -> StagingSink

/// Reassembles streamed clipboard representations from a peer.
///
/// A raw payload — an inline representation at or below
/// `maxResidentInlineBytes`, the only kind a peer sends raw — accumulates in
/// memory. Everything else arrives as an archive
/// (`ClipboardStreamBegin.is_archive`) and streams into an extract pipeline
/// under the free-space guard, so the payload lands on disk as it arrives and
/// no archive is staged: a file becomes the archive's one entry, a folder — the
/// transfer having been primed as one by `awaitTransfer(_:extractsDirectoryNamed:…)`
/// — becomes the extracted tree, and an oversize inline representation is
/// mapped back at End and delivered as a resident `.inMemory` payload, so
/// inline content has no Kernova-imposed size cap.
///
/// One receiver drives all inbound transfers on a channel, keyed by
/// `transfer_id`: the owning service routes `ClipboardStreamBegin` /
/// `ClipboardChunk` / `ClipboardStreamEnd` / `ClipboardStreamAbort` frames here.
/// Acks cover only durably written bytes, and size + SHA-256 are verified at End
/// before anything is delivered. Per-transfer work runs on dedicated serial
/// queues — a receive lane, plus a write lane for an archived transfer — so
/// the owning actor is never blocked.
///
/// `@unchecked Sendable`: the transfer table is guarded by `lock`; each
/// transfer's state is partitioned between its two lanes (see
/// `InboundTransfer`), and the terminal transition is claimed once under the
/// transfer's own lock.
public final class ClipboardStreamReceiver: @unchecked Sendable {
    private typealias Transfer = InboundTransfer

    private static let logger = KernovaLogger(
        subsystem: "app.kernova", category: "ClipboardStreamReceiver")

    private let clock: any EngineClock
    private let channel: VsockChannel
    private let staging: ClipboardFileStaging

    private let makeSink: ClipboardSinkFactory
    private let windowBytes: Int
    private let ackQuantum: Int
    private let ackLatencyBound: TimeInterval
    private let stallTimeout: TimeInterval
    private let maxBacklogBytes: Int

    /// The most a raw inline payload may declare: a peer archives anything
    /// larger, and one that streams more raw than this is refused rather than
    /// let grow a RAM buffer without bound.
    private let maxResidentInlineBytes: Int

    /// Floor on what a streamed folder may extract whatever its offer advertised
    /// — the behavior under test when a suite shrinks it.
    private let minimumExtractAllowance: Int

    private let onComplete: @Sendable (UInt64, ClipboardContent.Representation) -> Void

    private let onAbort: @Sendable (ClipboardStreamAbortInfo) -> Void

    /// Fires just before `onComplete`, for a successful transfer only.
    private let onTransferTimed: (@Sendable (ClipboardTransferMetrics) -> Void)?

    private let lock = NSLock()
    private var transfers: [UInt64: Transfer] = [:]

    /// How many cancelled `transfer_id`s are remembered so a reply that races the
    /// cancellation can be named as ours rather than blamed on the peer.
    private static let maxRememberedCancellations = 64

    /// Ids this side cancelled whose reply has not arrived, newest last.
    ///
    /// Guarded by `lock`.
    private var cancelledTransfers: Set<UInt64> = []
    private var cancelledOrder: [UInt64] = []

    /// Off-actor delivery handlers registered per `transfer_id` by a lazy pull
    /// coordinator.
    ///
    /// When present for a transfer, the matching handler fires on one of the
    /// transfer's own lanes **instead of** the channel-wide
    /// `onComplete`/`onAbort`, so a main-blocked guest provider is woken without
    /// a main-thread hop. Guarded by `lock`; one-shot (removed when it fires).
    private var awaiters: [UInt64: Awaiter] = [:]

    /// Creates a receiver for one channel's inbound transfers.
    ///
    /// `onComplete`, `onAbort`, and `onTransferTimed` are called off the owning
    /// actor, on whichever lane finished the transfer.
    public init(
        clock: any EngineClock = makePlatformEngineClock(),
        channel: VsockChannel,
        staging: ClipboardFileStaging,
        windowBytes: Int = ClipboardStreamTuning.defaultWindowBytes,
        extractPipeBytes: Int = ClipboardStreamTuning.extractPipeBytes,
        extractPacingBytes: Int = ClipboardStreamTuning.extractPacingBytes,
        ackLatencyBound: TimeInterval = ClipboardStreamTuning.ackLatencyBound,
        stallTimeout: TimeInterval = ClipboardStreamTuning.inboundStallTimeout,
        maxResidentInlineBytes: Int = ClipboardStreamTuning.maxResidentInlineBytes,
        minimumExtractAllowance: Int = ClipboardStreamTuning.minimumExtractAllowance,
        sinkFactory: ClipboardSinkFactory? = nil,
        onTransferTimed: (@Sendable (ClipboardTransferMetrics) -> Void)? = nil,
        onComplete: @escaping @Sendable (UInt64, ClipboardContent.Representation) -> Void,
        onAbort: @escaping @Sendable (ClipboardStreamAbortInfo) -> Void
    ) {
        self.clock = clock
        self.channel = channel
        self.staging = staging
        let boundedWindow = min(max(windowBytes, 1), ClipboardStreamTuning.maxWindowBytes)
        self.windowBytes = boundedWindow
        // The extract pipe and the guard quantum are local sizing that never
        // rides the wire, so neither is clamped to `maxWindowBytes`.
        let extractCapacity = max(1, extractPipeBytes)
        let extractPacing = max(1, extractPacingBytes)
        self.makeSink =
            sinkFactory
            ?? { destinationURL, label, onOutputAdvanced in
                ClipboardArchiveExtractSink(
                    destinationURL: destinationURL, label: label,
                    capacityBytes: extractCapacity, pacingBytes: extractPacing,
                    onOutputAdvanced: onOutputAdvanced)
            }
        self.ackQuantum = ClipboardStreamTuning.ackQuantum(forWindowBytes: self.windowBytes)
        self.maxBacklogBytes = ClipboardStreamTuning.maxBacklogBytes(
            forWindowBytes: self.windowBytes)
        self.ackLatencyBound = ackLatencyBound
        self.stallTimeout = stallTimeout
        self.maxResidentInlineBytes = max(maxResidentInlineBytes, 0)
        self.minimumExtractAllowance = max(minimumExtractAllowance, 1)
        self.onTransferTimed = onTransferTimed
        self.onComplete = onComplete
        self.onAbort = onAbort
    }

    /// Begins an inbound transfer: free-space check, sink open, and the initial
    /// ack that tells the sender to go.
    public func handleBegin(_ begin: Kernova_V1_ClipboardStreamBegin) {
        // What the payload is expected to unpack to rides the offer, not the
        // wire: the side that registered this pull is the same side that sent
        // the `ClipboardRequest`, so it primes the expectation here rather than
        // the sender re-declaring it.
        let expectation = lock.withLock { () -> Transfer.Expectation? in
            guard let awaiter = awaiters[begin.transferID] else { return nil }
            return Transfer.Expectation(
                directoryName: awaiter.extractsDirectoryNamed,
                advertisedByteCount: awaiter.advertisedByteCount)
        }
        // A pull this side cancelled leaves no awaiter, so refuse its reply
        // rather than accept it as unsolicited and then blame the peer for the
        // first chunk. [cancelled-pull]
        if expectation == nil, wasCancelled(begin.transferID) {
            sendAbortFrame(
                begin.transferID, code: .requestCancelled,
                message: "The pull for this transfer was cancelled")
            return
        }
        let transfer = Transfer(
            transferID: begin.transferID,
            generation: begin.generation,
            uti: begin.uti,
            filename: begin.filename,
            isInline: begin.isInline,
            isArchive: begin.isArchive,
            // A raw payload's declared total is peer-supplied and never
            // cross-checked against the chunks that follow: bound it here, the
            // one place it enters, so the inline reserve below is handed a size
            // that can be reasoned about. An archive declares none — its wire
            // size is unknown until its last byte — and its output is bounded
            // by the expectation instead.
            declaredTotalBytes: begin.isArchive
                ? nil
                : Int(clamping: min(begin.totalBytes, ClipboardOfferBounds.maxDeclaredByteCount)),
            expectation: expectation,
            now: self.clock.now
        )
        // Ignore a duplicate transfer_id rather than overwrite an in-flight
        // transfer (which would orphan its open sink + partial temp file). [L4]
        let inserted = lock.withLock { () -> Bool in
            guard transfers[begin.transferID] == nil else { return false }
            transfers[begin.transferID] = transfer
            return true
        }
        guard inserted else {
            // The loser is dropped here and never reaches a terminal claim, so
            // close its signpost interval through the one path that does.
            _ = transfer.finishOnce()
            return
        }

        transfer.queue.async { [weak self] in
            guard let self else { return }
            // A supersession or peer abort can claim the terminal state in the
            // gap between the table insert above and this block. Bail rather
            // than open a sink nobody will close and start a stall timer that
            // outlives a transfer no longer reachable through the table. [L4]
            guard !transfer.isFinished else { return }
            if transfer.isArchive {
                guard self.openExtractSink(transfer) else { return }
            } else {
                // Raw is how a peer sends what fits in RAM, and nothing else:
                // refusing anything larger, or anything not inline, is what
                // bounds the buffer a misbehaving peer could otherwise grow
                // without limit — there is no staging file to spill it to. A
                // pull primed as a folder is refused too, so a peer claiming
                // `is_inline` cannot divert it into the RAM buffer and have a
                // folder's request answered with a file.
                guard transfer.isInline,
                    transfer.expectation?.directoryName == nil,
                    let declared = transfer.declaredTotalBytes,
                    declared <= self.maxResidentInlineBytes
                else {
                    self.fail(
                        transfer, code: .payloadUnsupported,
                        message: "A raw payload must be inline, fit in memory, and answer no folder pull")
                    return
                }
                // Reserve toward the declared size (capped) so the buffer grows
                // in one allocation rather than geometric reallocations off the
                // window size.
                transfer.buffer = Data()
                transfer.buffer?.reserveCapacity(
                    min(declared, ClipboardStreamTuning.maxInlineReserveBytes))
            }
            // Go-signal: tell the sender we're ready and advertise the window.
            self.sendAck(transfer, upTo: transfer.receivedBytes)
            // Start the stall clock — a sender that never sends a chunk after
            // Begin must not pin this transfer's fd/partial forever. [H2]
            self.startStallTimer(transfer)
        }
    }

    /// Opens the extract pipeline an archived transfer streams into, on the
    /// receive lane at Begin, reporting whether the transfer may proceed.
    ///
    /// The archive's wire size is unknown until its last byte, so the payload
    /// is bounded in the unit the offer stated — the tree or file it unpacks to
    /// — both up front, against the volume, and as it is written, against the
    /// ceiling and the room left for what the offer said remains.
    private func openExtractSink(_ transfer: Transfer) -> Bool {
        // An archive with no expectation is one nobody on this side asked for:
        // there is no name to unpack it under and no size to hold it to, so it
        // is refused before a byte is staged rather than extracted and dropped.
        guard let expectation = transfer.expectation else {
            fail(
                transfer, code: .payloadUnexpected,
                message: "No pull is awaiting this transfer")
            return false
        }
        let advertised = expectation.advertisedByteCount
        guard staging.hasCapacity(forByteCount: advertised) else {
            failDiskFull(transfer)
            return false
        }
        let ceiling = extractCeiling(
            forAdvertisedByteCount: advertised, isDirectory: expectation.directoryName != nil)
        let staging = self.staging
        do {
            let destination: URL
            if let name = expectation.directoryName {
                destination = try staging.reserveDirectory(
                    generation: transfer.generation, name: name)
            } else {
                destination = try staging.reserveScratchDirectory(generation: transfer.generation)
            }
            transfer.sink = try makeSink(destination, "\(transfer.transferID)") { written in
                // Paced by the payload being *written*, not by the archive
                // arriving: compression can reach ~100:1, so a guard clocked on
                // wire bytes would let ~100 MB land between checks and the
                // margin would never fire. Runs on the extract's own thread.
                guard written <= ceiling else {
                    throw ClipboardArchiveStreamError.outputRefused(.overAdvertisedSize)
                }
                // Re-check the room left for what the offer said remains, so a
                // volume another writer is filling stops the transfer early
                // rather than at the margin.
                guard staging.hasCapacity(forByteCount: max(0, advertised - written)) else {
                    throw ClipboardArchiveStreamError.outputRefused(.diskFull)
                }
            }
        } catch {
            fail(transfer, code: .stageError, message: "Cannot open the extract destination")
            return false
        }
        return true
    }

    /// Accepts one chunk: validated and hashed on the receive lane, then
    /// appended on the write lane, which acks the bytes it makes durable — or,
    /// for a RAM-resident inline rep, all of it on the receive lane.
    public func handleChunk(_ chunk: Kernova_V1_ClipboardChunk) {
        guard let transfer = transfer(chunk.transferID) else {
            return
        }
        transfer.queue.async { [weak self] in
            guard let self else { return }
            let interval =
                transfer.stageSignposts
                ? ClipboardSignposts.stages.beginInterval("inbound chunk", id: transfer.stageID) : nil
            defer {
                if let interval { ClipboardSignposts.stages.endInterval("inbound chunk", interval) }
            }
            guard !transfer.isFinished else { return }
            // End was already accepted: the byte counts are final and a
            // completion barrier may be queued behind the write backlog. Drop
            // the straggler rather than let it re-ack, gap, or overrun a
            // transfer that is on its way to delivery.
            guard !transfer.endReceived else { return }
            let offset = Int(clamping: chunk.offset)
            if offset < transfer.receivedBytes {
                self.reAck(transfer)
                return
            }
            guard offset == transfer.receivedBytes else {
                // Gap — the reliable stream should never reorder; treat as fatal.
                self.fail(
                    transfer, code: .offsetGap,
                    message: "Out-of-order chunk at \(offset), expected \(transfer.receivedBytes)")
                return
            }
            // A chunk carrying nothing advances no counter — not the byte
            // total, not the digest, not the extract's drop budget — while
            // still refreshing the stall clock and the lazy pull's inactivity
            // backstop below, so a stream of them holds a transfer open for
            // free past every bound there is. A sender emits none: it breaks
            // out of its read loop on an empty read, so a zero-byte transfer is
            // a Begin and an End with no chunk between them.
            guard !chunk.data.isEmpty else {
                self.fail(
                    transfer, code: .chunkEmpty, message: "Chunk carries no bytes")
                return
            }
            // Bound a single chunk — a frame can carry up to 128 MiB, but the
            // negotiated chunk is 64 KiB. [M3]
            guard chunk.data.count <= ClipboardStreamTuning.maxChunkBytes else {
                self.fail(
                    transfer, code: .chunkTooLarge,
                    message: "Chunk of \(chunk.data.count) bytes exceeds limit")
                return
            }
            // Reject a peer streaming past its declared total — bounds both the
            // inline RAM buffer and the file sink to it. [H1] A payload that
            // declares none is bounded by the backlog bound below, and its output
            // by the extract's own ceiling.
            if let declared = transfer.declaredTotalBytes,
                transfer.receivedBytes + chunk.data.count > declared
            {
                self.fail(
                    transfer, code: .sizeOverrun,
                    message: "Chunk exceeds declared total of \(declared)")
                return
            }

            let now = self.clock.now
            if transfer.firstChunkAt == nil { transfer.firstChunkAt = now }

            let writeQueue = transfer.writeQueue
            if let writeQueue {
                // Hand the bytes to the write lane and keep going. `Data` is
                // copy-on-write, so the hand-off retains the buffer rather than
                // copying it. This lane never blocks, so the credit window is
                // *enforced* here rather than trusted: a peer that ignores it
                // would otherwise queue chunks on a parked write lane until the
                // heap ran out.
                guard transfer.addBacklog(chunk.data.count) <= self.maxBacklogBytes else {
                    self.fail(
                        transfer, code: .flowOverrun,
                        message:
                            "Peer streamed more than \(self.maxBacklogBytes) bytes past its credit window"
                    )
                    return
                }
                let data = chunk.data
                writeQueue.async { [weak self] in
                    self?.performWrite(transfer, data)
                }
            } else {
                transfer.buffer?.append(chunk.data)
            }
            transfer.hasher.update(data: chunk.data)
            transfer.receivedBytes += chunk.data.count
            if writeQueue == nil {
                // RAM-resident: the append above *is* this transfer's durable
                // stage, so the ack schedule stays on this lane.
                self.ackIfDue(transfer, upTo: transfer.receivedBytes, now: now)
            }
            // A chunk arrived — reset the stall clock. [H2]
            transfer.lastChunkAt = now
            // Tell a parked lazy pull the transfer is alive so it re-arms its
            // inactivity backstop instead of timing out a slow-but-progressing
            // large transfer. [large-paste]
            // For an archive the wire count is compressed while every readout's
            // denominator is the offer's uncompressed figure, so report what the
            // extract has actually written instead — same unit, same scale.
            self.deliverProgress(
                transfer.transferID,
                bytesReceived: transfer.extractedByteCount ?? transfer.receivedBytes,
                totalBytes: transfer.declaredTotalBytes ?? 0)
        }
    }

    /// Verifies and commits a completed transfer.
    ///
    /// Size and SHA-256 are verified on the receive lane, which owns the hasher.
    /// A disk-streamed transfer then commits from a barrier on its write lane,
    /// so the staged file is whole before it is delivered.
    public func handleEnd(_ end: Kernova_V1_ClipboardStreamEnd) {
        guard let transfer = transfer(end.transferID) else { return }
        transfer.queue.async { [weak self] in
            guard let self else { return }
            guard !transfer.isFinished, !transfer.endReceived else { return }
            transfer.endReceived = true
            transfer.stallTimer?.cancel()
            let expected = Int(clamping: end.totalBytes)
            guard transfer.receivedBytes == expected else {
                self.fail(
                    transfer, code: .sizeMismatch,
                    message: "Got \(transfer.receivedBytes) bytes, expected \(expected)")
                return
            }
            let digest = Data(transfer.hasher.finalize())
            guard digest == end.sha256 else {
                self.fail(transfer, code: .digestMismatch, message: "SHA-256 mismatch at End")
                return
            }
            guard let writeQueue = transfer.writeQueue else {
                self.finishResident(transfer)
                return
            }
            // Completion barrier: enqueued behind every chunk of this transfer,
            // so it runs only once the whole backlog is durably written.
            writeQueue.async { [weak self] in
                guard let self, !transfer.isFinished else { return }
                self.finishStaged(transfer, wireByteCount: expected, digest: digest)
            }
        }
    }

    /// Completes a RAM-resident inline transfer, on the receive lane.
    private func finishResident(_ transfer: Transfer) {
        // Final ack: close the sender's cumulative credit ledger, since a tail
        // below one ack quantum was never acked mid-stream.
        if transfer.receivedBytes > transfer.ackedBytes {
            sendAck(transfer, upTo: transfer.receivedBytes)
        }
        deliver(
            transfer,
            ClipboardContent.Representation(
                uti: transfer.uti,
                source: .inMemory(transfer.buffer ?? Data()),
                filename: transfer.filename
            ),
            byteCount: transfer.receivedBytes, wireByteCount: transfer.receivedBytes)
    }

    /// Commits an archived transfer's extract — the tree or the one file its
    /// pipeline has been writing — and completes it, on the write lane behind
    /// the transfer's whole write backlog.
    private func finishStaged(_ transfer: Transfer, wireByteCount: Int, digest: Data) {
        // Final ack: every byte is durably written now, so this closes the
        // sender's cumulative credit ledger even if the tail sat below one
        // quantum.
        if transfer.writtenBytes > transfer.ackedBytes {
            sendAck(transfer, upTo: transfer.writtenBytes)
        }
        guard let sink = transfer.sink else {
            fail(transfer, code: .stageError, message: "Missing staging sink at End")
            return
        }
        // Committing is what drains the extract pipeline, so this is where a
        // truncated or corrupt archive surfaces — and it takes the partial
        // output with it.
        let destination: URL
        do {
            destination = try sink.commit()
        } catch {
            failSinkError(transfer, sink: sink, error: error)
            return
        }
        // `sha256` stays the wire digest throughout: it is the transfer's
        // integrity gate, already verified above.
        if transfer.expectation?.directoryName != nil {
            // The rep's bytes are the tree at `destination`, so its size is the
            // tree's, not the compressed count the wire carried — which can be
            // ~100× lower and disagrees with the uncompressed estimate the offer
            // advertised for the same folder.
            let treeByteCount = transfer.extractedByteCount ?? wireByteCount
            deliver(
                transfer,
                ClipboardContent.Representation(
                    uti: transfer.uti, fileURL: destination, byteCount: treeByteCount,
                    sha256: digest, filename: transfer.filename, isDirectory: true),
                byteCount: treeByteCount, wireByteCount: wireByteCount)
            return
        }
        // A file's archive holds exactly one regular-file entry, extracted into
        // a scratch directory of its own so it keeps its exact name. Anything
        // else — a tree, a link, nothing — is a payload that does not match
        // what the offer described, and the peer that produced it is not
        // trusted to have meant well.
        guard let file = Self.singleRegularFile(in: destination) else {
            try? FileManager.default.removeItem(at: destination)
            fail(
                transfer, code: .payloadInvalid,
                message: "The archive did not unpack to exactly one file")
            return
        }
        // A file's advertised size is exact and the sender writes exactly that
        // many bytes, so the ceiling's header allowance is not payload a peer
        // may spend: hold a file to its offer to the byte. An inline payload is
        // exempt — one resolved from a file that grew since its offer is
        // legitimately larger, and it is bounded by the ceiling instead.
        if !transfer.isInline, let advertised = transfer.expectation?.advertisedByteCount,
            file.byteCount != advertised
        {
            try? FileManager.default.removeItem(at: destination)
            fail(
                transfer, code: .sizeOverrun,
                message: "The file unpacked to \(file.byteCount) bytes, its offer said \(advertised)")
            return
        }
        let representation: ClipboardContent.Representation
        if transfer.isInline {
            // An oversize inline rep: serve its bytes back as a resident
            // `.inMemory` payload through a memory-mapped read, so the
            // pasteboard flavor is unchanged while Kernova's added RAM stays
            // near zero (CLIPBOARD.md §1/§2/§8). On Darwin a `.mappedIfSafe`
            // mapping stays valid after the staged file is unlinked by a later
            // generation sweep, so the mapped rep needs no lifetime tracking.
            let mapped: Data
            do {
                mapped = try Data(contentsOf: file.url, options: .mappedIfSafe)
            } catch {
                fail(
                    transfer, code: .mapError,
                    message: "Mapping the extracted inline file failed: \(error.localizedDescription)"
                )
                return
            }
            representation = ClipboardContent.Representation(
                uti: transfer.uti,
                source: .inMemory(mapped),
                filename: transfer.filename
            )
        } else {
            representation = ClipboardContent.Representation(
                uti: transfer.uti,
                fileURL: file.url,
                byteCount: file.byteCount,
                sha256: digest,
                filename: transfer.filename
            )
        }
        deliver(transfer, representation, byteCount: file.byteCount, wireByteCount: wireByteCount)
    }

    /// The one regular file directly inside `directory`, with its size, or `nil`
    /// when the directory holds anything else.
    private static func singleRegularFile(in directory: URL) -> (url: URL, byteCount: Int)? {
        guard
            let entries = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                options: []),
            entries.count == 1,
            let entry = entries.first,
            let values = try? entry.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
            values.isRegularFile == true
        else { return nil }
        return (entry, values.fileSize ?? 0)
    }

    /// Claims the terminal transition, reports timing, and delivers a completed
    /// representation.
    ///
    /// Called from whichever lane finished the transfer, always off the owning
    /// actor — the contract the delivery closures are written against.
    private func deliver(
        _ transfer: Transfer, _ representation: ClipboardContent.Representation,
        byteCount: Int, wireByteCount: Int
    ) {
        guard transfer.finishOnce() else { return }
        remove(transfer.transferID)
        if let onTransferTimed {
            let completedAt = clock.now
            onTransferTimed(
                ClipboardTransferMetrics(
                    transferID: transfer.transferID,
                    uti: transfer.uti,
                    byteCount: byteCount,
                    wireByteCount: wireByteCount,
                    duration: transfer.beganAt.seconds(to: completedAt),
                    detail: .inbound(
                        .init(
                            streamedToDisk: transfer.streamsToDisk,
                            streamingDuration: transfer.firstChunkAt.map {
                                $0.seconds(to: completedAt)
                            }))))
        }
        deliverComplete(transfer.transferID, representation)
    }

    /// Tears down an inbound transfer on a peer `ClipboardStreamAbort`, keyed
    /// purely on the bare `transfer_id` (see `ClipboardTransferID`).
    public func handleAbort(_ abort: Kernova_V1_ClipboardStreamAbort) {
        guard let transfer = transfer(abort.transferID) else {
            // No in-flight transfer for this id — the sender aborted *before*
            // Begin, or this is a duplicate abort. Still wake a lazy pull
            // awaiting it, which would otherwise park to its timeout.
            deliverAbort(
                ClipboardStreamAbortInfo(
                    transferID: abort.transferID, rawCode: abort.code, message: abort.message,
                    neededBytes: nil, availableBytes: nil))
            return
        }
        transfer.queue.async { [weak self] in
            guard let self, transfer.finishOnce() else { return }
            transfer.stallTimer?.cancel()
            self.abortSink(transfer)
            self.remove(transfer.transferID)
            self.deliverAbort(
                ClipboardStreamAbortInfo(
                    transferID: abort.transferID, rawCode: abort.code, message: abort.message,
                    neededBytes: nil, availableBytes: nil))
        }
    }

    /// Aborts every in-flight transfer for a superseded generation, deleting
    /// partial temp files, and wakes any lazy pull awaiting that generation.
    public func cancel(generation: UInt64) {
        let affected = lock.withLock {
            transfers.values.filter { $0.generation == generation }
        }
        for transfer in affected { teardown(transfer) }
        // Also wake awaiters whose transfer never produced a Begin, so a pull
        // blocked on a superseded generation resolves instead of parking to its
        // timeout.
        failAwaiters { Self.generation(ofTransferID: $0) == generation }
    }

    /// Aborts one in-flight transfer, deleting its partial temp file, and wakes a
    /// lazy pull awaiting it — the teardown for a single abandoned pull, leaving
    /// every sibling of the same generation streaming.
    public func cancel(transferID: UInt64) {
        if let transfer = lock.withLock({ transfers[transferID] }) { teardown(transfer) }
        failAwaiters { $0 == transferID }
    }

    /// Aborts every in-flight transfer (channel teardown / capability disable)
    /// and wakes every lazy pull awaiting this channel.
    public func cancelAll() {
        let all = lock.withLock { Array(transfers.values) }
        for transfer in all { teardown(transfer) }
        failAwaiters { _ in true }
    }

    /// Registers an off-actor delivery handler for a single transfer.
    ///
    /// Register before the `ClipboardRequest` is sent. The handler fires on one
    /// of the transfer's own lanes **in place of** the channel-wide
    /// `onComplete`/`onAbort`, and is one-shot — removed when it fires, or via
    /// `cancelAwait`.
    ///
    /// `extractsDirectoryNamed` primes the transfer: the archive is a folder's
    /// tree, extracted into a folder of that name as it streams, rather than a
    /// file's one entry. Directory-ness rides the `ClipboardOffer`, and this
    /// registration happens on the same side that read the offer and sent the
    /// request, so the stream layer never needs it on the wire.
    /// `advertisedByteCount` is that offer's `byte_count`, which the extract is
    /// then held to — nothing on the wire states an archive's unpacked size.
    ///
    /// One live registration per id: callers sharing a `transfer_id` share the
    /// pull that owns it (`LazyPullCoordinator`), so an overwrite here would be a
    /// second pull nobody asked for.
    public func awaitTransfer(
        _ transferID: UInt64,
        extractsDirectoryNamed: String? = nil,
        advertisedByteCount: Int = 0,
        onComplete: @escaping @Sendable (ClipboardContent.Representation) -> Void,
        onAbort: @escaping @Sendable (ClipboardStreamAbortInfo) -> Void,
        onProgress: (@Sendable (_ bytesReceived: Int, _ totalBytes: Int) -> Void)? = nil
    ) {
        let displaced: Bool = lock.withLock {
            // A transfer id is derivable from `(generation, repIndex, direction)`,
            // so a fresh pull reuses the id of one this side gave up on. Clearing
            // the cancellation record here is what keeps the retry from being
            // refused as that abandoned pull's late reply.
            cancelledTransfers.remove(transferID)
            cancelledOrder.removeAll { $0 == transferID }
            let prior = awaiters.updateValue(
                Awaiter(
                    extractsDirectoryNamed: extractsDirectoryNamed,
                    advertisedByteCount: max(0, advertisedByteCount),
                    onComplete: onComplete, onAbort: onAbort, onProgress: onProgress),
                forKey: transferID)
            return prior != nil
        }
        guard displaced else { return }
        Self.logger.fault(
            "Clipboard transfer \(transferID, privacy: .public) was awaited twice — the earlier awaiter is dropped"
        )
        assertionFailure("Clipboard transfer \(transferID) was awaited twice")
    }

    /// Deregisters a per-transfer delivery handler without firing it.
    public func cancelAwait(_ transferID: UInt64) {
        lock.withLock {
            guard awaiters.removeValue(forKey: transferID) != nil else { return }
            noteCancelled(transferID)
        }
    }

    // MARK: - Private

    private func transfer(_ id: UInt64) -> Transfer? {
        lock.withLock { transfers[id] }
    }

    /// Remembers that this side gave up on `transferID` before its reply arrived.
    ///
    /// A `Begin` can still be in flight for it, and without this the receiver
    /// cannot tell that reply apart from an unsolicited one — it would open a
    /// sink, ack the sender to start, and then blame the peer for the first
    /// chunk. Bounded and oldest-evicted: it only ever holds ids whose reply
    /// never arrived. Caller holds `lock`.
    private func noteCancelled(_ transferID: UInt64) {
        guard !cancelledTransfers.contains(transferID) else { return }
        cancelledTransfers.insert(transferID)
        cancelledOrder.append(transferID)
        while cancelledOrder.count > Self.maxRememberedCancellations {
            cancelledTransfers.remove(cancelledOrder.removeFirst())
        }
    }

    /// Reports, and clears, whether this side cancelled the pull for `transferID`.
    private func wasCancelled(_ transferID: UInt64) -> Bool {
        lock.withLock {
            guard cancelledTransfers.remove(transferID) != nil else { return false }
            cancelledOrder.removeAll { $0 == transferID }
            return true
        }
    }

    private func remove(_ id: UInt64) {
        lock.withLock { transfers[id] = nil }
    }

    private func deliverComplete(_ id: UInt64, _ representation: ClipboardContent.Representation) {
        let awaiter = lock.withLock { awaiters.removeValue(forKey: id) }
        if let awaiter {
            awaiter.onComplete(representation)
        } else {
            onComplete(id, representation)
        }
    }

    /// Notifies a registered per-transfer awaiter that a chunk was accepted off
    /// the wire.
    ///
    /// Peeks the awaiter without removing it — progress fires repeatedly, unlike
    /// the one-shot complete/abort delivery.
    private func deliverProgress(_ id: UInt64, bytesReceived: Int, totalBytes: Int) {
        let awaiter = lock.withLock { awaiters[id] }
        awaiter?.onProgress?(bytesReceived, totalBytes)
    }

    private func deliverAbort(_ info: ClipboardStreamAbortInfo) {
        let awaiter = lock.withLock { awaiters.removeValue(forKey: info.transferID) }
        if let awaiter {
            awaiter.onAbort(info)
        } else {
            onAbort(info)
        }
    }

    private func deliverAbortToAwaiterOnly(_ info: ClipboardStreamAbortInfo) {
        let awaiter = lock.withLock { awaiters.removeValue(forKey: info.transferID) }
        awaiter?.onAbort(info)
    }

    /// Fires (and removes) every registered awaiter whose `transfer_id` matches
    /// `predicate`, resolving a blocked pull with a cancellation.
    ///
    /// Covers awaiters whose transfer never produced a `Begin`, so they have no
    /// entry in `transfers` for `teardown` to reach. Idempotent with `teardown`'s
    /// own awaiter notification — whichever removes the awaiter first wins.
    private func failAwaiters(_ predicate: (UInt64) -> Bool) {
        let ids = lock.withLock { () -> [UInt64] in
            let matched = awaiters.keys.filter(predicate)
            for id in matched { noteCancelled(id) }
            return matched
        }
        for id in ids {
            deliverAbortToAwaiterOnly(
                ClipboardStreamAbortInfo(
                    transferID: id, code: .cancelled,
                    message: "Transfer superseded or channel closed",
                    neededBytes: nil, availableBytes: nil))
        }
    }

    private static func generation(ofTransferID id: UInt64) -> UInt64 {
        ClipboardTransferID.generation(of: id)
    }

    private func teardown(_ transfer: Transfer) {
        transfer.queue.async { [weak self] in
            guard let self, transfer.finishOnce() else { return }
            transfer.stallTimer?.cancel()
            self.abortSink(transfer)
            self.remove(transfer.transferID)
            // Wake a lazy pull blocked on this transfer; stay silent on the
            // channel-wide path so supersession isn't surfaced as a user-visible
            // abort the way a peer/disk failure is.
            self.deliverAbortToAwaiterOnly(
                ClipboardStreamAbortInfo(
                    transferID: transfer.transferID, code: .cancelled,
                    message: "Transfer superseded or channel closed",
                    neededBytes: nil, availableBytes: nil))
        }
    }

    /// Starts the per-transfer stall watchdog: one repeating timer that fails
    /// the transfer once no chunk has arrived within `stallTimeout`.
    ///
    /// The timer fires on the transfer's receive lane and compares against
    /// `lastChunkAt`, which each arriving chunk refreshes with a plain store; a
    /// tick that loses the race to completion is a no-op. [H2]
    private func startStallTimer(_ transfer: Transfer) {
        let timer = DispatchSource.makeTimerSource(queue: transfer.queue)
        timer.setEventHandler { [weak self, weak transfer] in
            guard let self, let transfer, !transfer.isFinished else { return }
            guard self.clock.seconds(since: transfer.lastChunkAt) >= self.stallTimeout else { return }
            self.fail(transfer, code: .stallTimeout, message: "Sender stopped sending")
        }
        // The timeout is a dead-sender backstop, not a precise deadline:
        // checking at `stallTimeout` cadence with a half-interval leeway detects
        // a stall within ~1–2.5× it (still well under the 120 s lazy-pull
        // backstop) and lets the OS coalesce the per-transfer wakeup for the
        // whole life of a long healthy transfer.
        let interval = stallTimeout
        timer.schedule(
            deadline: .now() + interval, repeating: interval,
            leeway: .milliseconds(Int(interval * 500)))
        transfer.stallTimer = timer
        timer.resume()
    }

    /// Appends one chunk on the transfer's write lane, then acks the bytes it
    /// just made durable.
    ///
    /// Runs strictly in stream order behind every earlier chunk of the same
    /// transfer, so `writtenBytes` is always a true durable *prefix* of the
    /// payload — which is what lets its ack carry credit.
    private func performWrite(_ transfer: Transfer, _ data: Data) {
        let interval =
            transfer.stageSignposts
            ? ClipboardSignposts.stages.beginInterval("staging write", id: transfer.stageID) : nil
        defer {
            if let interval { ClipboardSignposts.stages.endInterval("staging write", interval) }
        }
        // Paired with the receive lane's `addBacklog`, so the bound tracks bytes
        // still waiting to be written rather than bytes ever received.
        defer { transfer.drainBacklog(data.count) }
        guard !transfer.isFinished else { return }
        guard let sink = transfer.sink else {
            // Fail loudly rather than drop the bytes: the receive lane has
            // already folded them into `receivedBytes` and the digest, so a
            // silent skip would let End verify a payload the staging file never
            // received and commit a truncated result. [L3]
            fail(transfer, code: .stageError, message: "Missing staging sink for chunk")
            return
        }
        do {
            try sink.write(data)
        } catch {
            failSinkError(transfer, sink: sink, error: error)
            return
        }
        transfer.writtenBytes += data.count
        // No disk guard here: these are compressed bytes, and the sink's own
        // output guard paces the check by what is written to the volume, off
        // this lane, so nothing sits between the append and its ack.
        ackIfDue(transfer, upTo: transfer.writtenBytes, now: clock.now)
    }

    /// Sends a coalesced cumulative ack once a quantum of durably-written bytes
    /// has accumulated since the last one, or once that ack is older than the
    /// latency bound.
    ///
    /// The latency fallback keeps the gap between credit-opening acks inside the
    /// sender's fixed no-ack deadline when durable writes run slow. The tail
    /// below one quantum is acked at End.
    private func ackIfDue(
        _ transfer: Transfer, upTo count: Int, now: EngineInstant
    ) {
        guard
            count - transfer.ackedBytes >= ackQuantum
                || transfer.lastAckAt.seconds(to: now) >= ackLatencyBound
        else { return }
        sendAck(transfer, upTo: count)
    }

    /// Re-acks a duplicate chunk immediately — never coalesced, since a
    /// duplicate means the peer may be out of sync.
    ///
    /// On the disk path the ack is emitted from the write lane, ordered behind
    /// any pending appends, so it reports the same durably-written prefix every
    /// other ack does.
    private func reAck(_ transfer: Transfer) {
        guard let writeQueue = transfer.writeQueue else {
            sendAck(transfer, upTo: transfer.receivedBytes)
            return
        }
        writeQueue.async { [weak self] in
            guard let self, !transfer.isFinished else { return }
            self.sendAck(transfer, upTo: transfer.writtenBytes)
        }
    }

    private func sendAck(_ transfer: Transfer, upTo count: Int) {
        transfer.ackedBytes = count
        transfer.lastAckAt = clock.now
        send(
            .with {
                $0.protocolVersion = 1
                $0.clipboardStreamAck = .with {
                    $0.transferID = transfer.transferID
                    $0.bytesConsumed = UInt64(count)
                    $0.windowBytes = UInt64(windowBytes)
                }
            })
    }

    /// How much an extract may write for a payload the offer advertised at
    /// `advertisedByteCount`.
    ///
    /// Nothing on the wire states an archive's unpacked size, so the figure the
    /// paste ceiling and the free-space pre-flight were computed from is the
    /// only one to hold it to. A file's is exact, so its ceiling is that plus
    /// the one entry header's allowance. A folder's is a stat-walk estimate,
    /// and its allowance is generous on purpose: the archive adds a header per
    /// entry to the file bytes the estimate sums, and a tree can legitimately
    /// grow a little between the copy-time walk and the paste-time encode.
    /// Doubling covers header overhead for any tree whose file bytes dominate,
    /// and the floor covers one whose estimate is zero or tiny — a scaffold of
    /// empty files — while staying far below any paste ceiling.
    func extractCeiling(forAdvertisedByteCount advertisedByteCount: Int, isDirectory: Bool) -> Int {
        guard isDirectory else {
            return advertisedByteCount.saturatingAdding(ClipboardStreamTuning.fileExtractAllowance)
        }
        let doubled = advertisedByteCount.saturatingAdding(advertisedByteCount)
        return max(doubled, minimumExtractAllowance)
    }

    /// Fails a transfer whose sink rejected the bytes, naming the failure the way
    /// the sink does — and re-checking the volume first, because a write that
    /// failed on a full disk must read as `disk.full` rather than as a corrupt
    /// payload the user would only retry.
    private func failSinkError(_ transfer: Transfer, sink: StagingSink, error: Error) {
        if case ClipboardArchiveStreamError.outputRefused(let refusal) = error {
            switch refusal {
            case .diskFull:
                failDiskFull(transfer)
            case .overAdvertisedSize:
                fail(
                    transfer, code: .sizeOverrun,
                    message: "The payload unpacked to more than its offer advertised")
            }
            return
        }
        // The extract unpacked a whole archive and the peer kept streaming past
        // the tail a finished decoder leaves unread: more payload than the
        // archive it already completed, so it is named as the overrun it is
        // rather than as a failure of the extract, which succeeded.
        if case ClipboardArchiveStreamError.streamClosed = error {
            fail(
                transfer, code: .sizeOverrun,
                message: "The peer streamed past the end of a complete archive")
            return
        }
        guard staging.hasCapacity(forByteCount: 0) else {
            failDiskFull(transfer)
            return
        }
        fail(
            transfer, code: sink.writeErrorCode,
            message: "Writing the payload failed: \(error.localizedDescription)")
    }

    private func failDiskFull(_ transfer: Transfer) {
        let available = staging.availableCapacity().map { Int(clamping: $0) }
        sendAbortFrame(transfer.transferID, code: .diskFull, message: "Not enough disk space")
        finishFailed(
            transfer,
            info: ClipboardStreamAbortInfo(
                transferID: transfer.transferID, code: .diskFull,
                message: "Not enough disk space",
                // What the offer advertised is the honest "needed" figure for
                // an archive, exact for a file and an estimate for a folder.
                neededBytes: transfer.declaredTotalBytes
                    ?? transfer.expectation?.advertisedByteCount,
                availableBytes: available))
    }

    /// Fails a transfer from **either** lane: sends the abort frame and tears
    /// down whatever local state exists.
    private func fail(_ transfer: Transfer, code: ClipboardStreamAbortCode, message: String) {
        sendAbortFrame(transfer.transferID, code: code, message: message)
        finishFailed(
            transfer,
            info: ClipboardStreamAbortInfo(
                transferID: transfer.transferID, code: code, message: message,
                neededBytes: nil, availableBytes: nil))
    }

    private func finishFailed(_ transfer: Transfer, info: ClipboardStreamAbortInfo) {
        guard transfer.finishOnce() else { return }
        // Callable from either lane: each hop below lands on the lane that owns
        // the state it touches, and the abort is delivered without waiting on
        // either, so a blocked lazy pull wakes even while the write lane is
        // stuck in a slow write.
        transfer.queue.async { transfer.stallTimer?.cancel() }
        abortSink(transfer)
        remove(transfer.transferID)
        deliverAbort(info)
    }

    /// Closes and deletes the staging partial on the write lane, ordered behind
    /// any append still in flight.
    ///
    /// **An abort does not imply the partial is already gone** — it is deleted
    /// once the write lane drains, so a caller that needs the file gone must
    /// wait for that, not for the abort. A RAM-resident inline transfer has no
    /// sink and nothing to clean up.
    private func abortSink(_ transfer: Transfer) {
        guard let writeQueue = transfer.writeQueue else { return }
        // Wake the write lane first: a sink that consumes asynchronously parks it
        // inside `write`, and the teardown below would then sit in line behind
        // the very write it is aborting.
        transfer.sink?.cancel()
        writeQueue.async { transfer.sink?.abort() }
    }

    private func sendAbortFrame(_ transferID: UInt64, code: ClipboardStreamAbortCode, message: String) {
        send(.clipboardStreamAbort(transferID: transferID, code: code, message: message))
    }

    private func send(_ frame: Frame) {
        try? channel.writeFramed(VsockChannel.serializeFramed(frame))
    }

    #if DEBUG
    /// The stall watchdog's activity anchor for an in-flight transfer: when its
    /// last chunk arrived (or, before any chunk, when the transfer was
    /// accepted). `nil` for an unknown/finished transfer.
    ///
    /// Read on the transfer's receive lane, the anchor's isolation domain, so an
    /// assertion never races the repeating watchdog timer.
    func lastChunkAtForTesting(_ transferID: UInt64) -> EngineInstant? {
        guard let transfer = transfer(transferID) else { return nil }
        return transfer.queue.sync { transfer.lastChunkAt }
    }
    #endif
}

/// Why an inbound transfer failed, surfaced to the owning service.
public struct ClipboardStreamAbortInfo: Sendable, Equatable {
    /// Identifies the transfer that aborted.
    public let transferID: UInt64
    /// The abort reason, or `nil` for a code this build does not define.
    public let code: ClipboardStreamAbortCode?
    /// Exactly what the aborting side spelled, so a log line names an
    /// undefined code rather than losing it.
    public let rawCode: String
    /// Human-readable description of the failure.
    public let message: String
    /// Bytes the transfer needed, for a `disk.full` abort.
    public let neededBytes: Int?
    /// Bytes available on the staging volume, for a `disk.full` abort.
    public let availableBytes: Int?

    /// Whether the abort retires the transfer quietly instead of reporting a
    /// failure.
    ///
    /// An undefined code is never retiring: an abort spelled in a way this
    /// build cannot read is a failure to surface, not one to swallow.
    public var isRetiring: Bool {
        guard let code else { return false }
        return ClipboardStreamAbortCode.retiring.contains(code)
    }

    /// Creates abort info for a failure this side raised, whose code is known
    /// by construction.
    public init(
        transferID: UInt64, code: ClipboardStreamAbortCode, message: String, neededBytes: Int?,
        availableBytes: Int?
    ) {
        self.transferID = transferID
        self.code = code
        self.rawCode = code.rawValue
        self.message = message
        self.neededBytes = neededBytes
        self.availableBytes = availableBytes
    }

    /// Creates abort info from a peer's frame — the one construction that takes
    /// an arbitrary string, since the peer's spelling is untrusted.
    init(
        transferID: UInt64, rawCode: String, message: String, neededBytes: Int?,
        availableBytes: Int?
    ) {
        self.transferID = transferID
        self.code = ClipboardStreamAbortCode(rawValue: rawCode)
        self.rawCode = rawCode
        self.message = message
        self.neededBytes = neededBytes
        self.availableBytes = availableBytes
    }
}

/// Off-actor delivery handlers for a single awaited transfer.
private struct Awaiter {
    /// The folder name a streamed directory archive extracts into, or `nil` for
    /// an ordinary file/inline transfer.
    let extractsDirectoryNamed: String?
    /// The size the offer advertised — the figure the paste ceiling and the
    /// free-space pre-flight were computed from, and so the figure the extract
    /// is held to.
    let advertisedByteCount: Int
    let onComplete: @Sendable (ClipboardContent.Representation) -> Void
    let onAbort: @Sendable (ClipboardStreamAbortInfo) -> Void
    /// Fired (off the owning actor) on each accepted chunk with the cumulative
    /// `(bytesReceived, totalBytes)`. `nil` for the eager path.
    let onProgress: (@Sendable (_ bytesReceived: Int, _ totalBytes: Int) -> Void)?
}

// MARK: - Per-transfer state

/// Mutable state for one inbound transfer, partitioned between its lanes.
///
/// The **receive lane** (`queue`) owns the byte stream as it arrives —
/// validation, hashing, the stall anchor, progress. The **write lane**
/// (`writeQueue`, present only when the transfer streams to a staging file) owns
/// the sink and the ack schedule. Each field below names its owning lane, so
/// none needs a lock; the handful whose ownership *transfers* between lanes say
/// so in their own docs and rely on the hand-off being ordered by the `async`
/// that moves the work across. The one contended decision — which path reaches
/// the terminal state first — goes through `finishOnce()`.
private final class InboundTransfer: @unchecked Sendable {
    /// What the pull that requested this transfer expects it to unpack to.
    ///
    /// Set from the pull's own registration, never from the wire.
    struct Expectation {
        /// The folder name the archive extracts into, or `nil` when the payload
        /// is a file or inline rep.
        let directoryName: String?
        /// The size the offer advertised — exact for a file, a stat-walk
        /// estimate for a folder — which the extract is held to.
        let advertisedByteCount: Int
    }

    let transferID: UInt64
    let generation: UInt64
    let uti: String
    let filename: String
    let isInline: Bool
    /// Whether the payload is an archive to extract rather than raw bytes to
    /// buffer — the axis every sink decision branches on.
    let isArchive: Bool
    /// The size a raw payload declared; `nil` for an archive, whose wire size
    /// is unknown until its last byte.
    ///
    /// The one axis the size-dependent guards branch on, so none of them has to
    /// re-derive "unknown" from what kind of payload this is.
    let declaredTotalBytes: Int?
    /// The requesting pull's expectation, or `nil` for a transfer nobody on this
    /// side asked for.
    let expectation: Expectation?
    /// Receive lane: validation, hashing, the stall anchor, progress delivery.
    let queue: DispatchQueue
    /// Write lane: extract appends and the acks that open credit for them.
    ///
    /// `nil` for a raw payload, which has no sink and runs entirely on `queue`.
    let writeQueue: DispatchQueue?

    /// Uncompressed bytes the extract has written, or `nil` for a raw payload
    /// — the progress figure in the offer's own unit.
    var extractedByteCount: Int? {
        (sink as? ClipboardArchiveExtractSink)?.uncompressedByteCount
    }

    /// Whether this transfer streams through the extract pipeline instead of a
    /// RAM buffer.
    var streamsToDisk: Bool { writeQueue != nil }

    /// When `handleBegin` created this transfer.
    let beganAt: EngineInstant
    /// When the first chunk arrived.
    ///
    /// Written on `queue`; frozen once End is accepted, so the write lane's
    /// completion barrier — ordered after that — reads the final value.
    var firstChunkAt: EngineInstant?

    /// Receive lane: bytes accepted off the wire — validated, hashed, and
    /// either buffered or handed to the write lane.
    var receivedBytes = 0
    /// Write lane: bytes appended to the sink, the durable prefix every ack
    /// reports.
    ///
    /// Trails `receivedBytes` by at most one credit window, because the sender
    /// may not run further ahead than the last acked (i.e. written) byte count.
    var writtenBytes = 0
    /// Bytes covered by the last ack sent — the ack-coalescing byte watermark.
    ///
    /// Owned by whichever lane acks this transfer: the write lane for a staged
    /// rep, the receive lane for a RAM-resident one. The go-signal at Begin
    /// writes it from the receive lane before the first chunk is handed over, so
    /// the write lane's first read is ordered after it.
    var ackedBytes = 0
    /// When the last ack was sent — the ack-coalescing time watermark, checked
    /// against `ackLatencyBound` on each durably-written chunk.
    ///
    /// Same lane ownership as `ackedBytes`.
    var lastAckAt: EngineInstant
    /// Receive lane: running SHA-256 over the accepted bytes.
    var hasher = SHA256()
    /// Receive lane: RAM reassembly buffer for a resident inline rep.
    var buffer: Data?
    /// The staging sink for a disk-streamed rep.
    ///
    /// Opened on the receive lane at Begin, before any chunk is handed over;
    /// touched only on the write lane from then on.
    var sink: StagingSink?
    /// Receive lane: whether End has been accepted, after which no further
    /// chunk may change the byte counts.
    var endReceived = false
    /// Receive lane: when the last chunk *arrived* (seeded at acceptance) — the
    /// stall watchdog's activity anchor, which backstops a dead sender.
    var lastChunkAt: EngineInstant
    /// Receive lane: the per-transfer stall watchdog, a repeating timer on
    /// `queue` that checks `lastChunkAt` — started once per transfer, cancelled
    /// on finish, never re-armed per chunk.
    var stallTimer: DispatchSourceTimer?

    /// Bytes handed to the write lane that it has not finished writing — the
    /// receive lane's view of how far ahead the peer is running.
    ///
    /// The one counter both lanes touch, so it carries its own lock rather than
    /// belonging to either.
    private let backlogLock = NSLock()
    private var backlogBytes = 0

    /// Records `count` bytes as handed over, returning the new backlog.
    func addBacklog(_ count: Int) -> Int {
        backlogLock.withLock {
            backlogBytes += count
            return backlogBytes
        }
    }

    /// Records `count` bytes as written, releasing their share of the backlog.
    func drainBacklog(_ count: Int) {
        backlogLock.withLock { backlogBytes -= count }
    }

    /// The whole-transfer signpost interval, ended by whichever lane claims the
    /// terminal transition.
    let signpostInterval: OSSignpostIntervalState
    /// Whether the per-chunk stage intervals are worth emitting, read once when
    /// the transfer is announced rather than on each of its chunks.
    let stageSignposts: Bool
    /// Identifies this transfer's stage intervals. Without it they would all
    /// share `OSSignpostID.exclusive`, which only holds for intervals that
    /// never overlap — and two transfers on their own queues do.
    let stageID: OSSignpostID

    private let finishLock = NSLock()
    private var finished = false

    /// Whether the transfer has reached its terminal state (delivered or
    /// aborted).
    ///
    /// Safe to read from either lane.
    var isFinished: Bool { finishLock.withLock { finished } }

    /// Claims the terminal transition, returning `true` to exactly one caller.
    ///
    /// Completion, a failed append, a mid-stream disk-full, supersession, a peer
    /// abort, and a stalled sender all race for it; the winner tears the transfer
    /// down and every loser becomes a no-op.
    /// It is also where the whole-transfer signpost interval is closed: routing
    /// the end through the single exactly-once claim is what stops the racing
    /// terminal paths from double-ending it.
    func finishOnce() -> Bool {
        let claimed = finishLock.withLock { () -> Bool in
            if finished { return false }
            finished = true
            return true
        }
        if claimed {
            ClipboardSignposts.transfers.endInterval("Clipboard receive", signpostInterval)
        }
        return claimed
    }

    init(
        transferID: UInt64, generation: UInt64, uti: String, filename: String, isInline: Bool,
        isArchive: Bool, declaredTotalBytes: Int?, expectation: Expectation?, now: EngineInstant
    ) {
        self.transferID = transferID
        self.generation = generation
        self.uti = uti
        self.filename = filename
        self.isInline = isInline
        self.isArchive = isArchive
        self.declaredTotalBytes = declaredTotalBytes
        self.expectation = expectation
        self.beganAt = now
        self.lastAckAt = now
        self.lastChunkAt = now
        self.signpostInterval = ClipboardSignposts.transfers.beginInterval(
            "Clipboard receive", id: ClipboardSignposts.transfers.makeSignpostID())
        self.stageSignposts = ClipboardSignposts.stages.isEnabled
        self.stageID = ClipboardSignposts.stages.makeSignpostID()
        self.queue = DispatchQueue(
            label: "app.kernova.clipboard.stream-recv.\(transferID)", qos: .userInitiated)
        // An archive always takes the write lane: its sink is the extract
        // pipeline, so a peer claiming `is_inline` must not divert it into the
        // RAM buffer, where nothing would ever unpack it.
        self.writeQueue =
            isArchive
            ? DispatchQueue(
                label: "app.kernova.clipboard.stream-recv.write.\(transferID)", qos: .userInitiated)
            : nil
    }
}
