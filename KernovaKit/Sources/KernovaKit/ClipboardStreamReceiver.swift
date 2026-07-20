import CryptoKit
import Foundation

/// Reassembles streamed clipboard representations from a peer, choosing its sink
/// by representation role and size: a small inline representation (text/RTF/
/// inline image) accumulates in memory; a file representation — and a large
/// inline one past `maxResidentInlineBytes` — streams to a temp file under the
/// free-space guard, never resident whole.
///
/// A spilled inline rep is mmapped back at End and delivered as a resident
/// `.inMemory` payload, so residency stays an implementation detail and inline
/// content has no Kernova-imposed size cap.
///
/// One receiver drives all inbound transfers on a channel, keyed by
/// `transfer_id`. The owning service routes `ClipboardStreamBegin` /
/// `ClipboardChunk` / `ClipboardStreamEnd` / `ClipboardStreamAbort` frames here;
/// the receiver acks only **durably written** bytes (so credit tracks the
/// slowest stage), coalesced to one cumulative ack per quarter-window
/// (`ClipboardStreamTuning.ackQuantum(forWindowBytes:)`, #377) with a
/// 1 s latency bound so slow writes fall back to per-chunk acks — the
/// go-signal, duplicate re-ack, and final ack at End stay unconditional — and
/// verifies size + SHA-256 at End before delivering. Per-transfer work runs on
/// dedicated serial queues so the owning actor is never blocked.
///
/// ## Two lanes per disk-streamed transfer (#615)
/// A transfer that streams to a staging file runs on **two** serial queues, so
/// the staging `write(2)` no longer sits between a chunk's arrival and the
/// credit-opening ack that unblocks the sender:
///
/// - the **receive lane** (`queue`) validates each chunk, updates the running
///   SHA-256, refreshes the stall anchor, and reports progress;
/// - the **write lane** (`writeQueue`) appends to the sink and then acks the
///   bytes it just made durable.
///
/// The lanes overlap — chunk *n+1* is validated and hashed while chunk *n* is
/// still being written — which is what removes the receiver's serialization
/// from the sender's credit loop. Because an ack still reports `writtenBytes`,
/// the sender's window bounds the un-written backlog (`receivedBytes -
/// writtenBytes` can never exceed one window), so a slow volume throttles the
/// sender instead of growing receiver RAM. A RAM-resident inline rep has no
/// sink and no write lane: it stays entirely on the receive lane, with the ack
/// schedule it always had.
///
/// `@unchecked Sendable`: the transfer table is guarded by `lock`; each
/// transfer's state is partitioned between its two lanes (see
/// `InboundTransfer`), and the terminal transition is claimed once under the
/// transfer's own lock.
public final class ClipboardStreamReceiver: @unchecked Sendable {
    /// Opens the append-only staging sink for one disk-streamed transfer.
    public typealias SinkFactory =
        @Sendable (_ generation: UInt64, _ filename: String) throws ->
        StagingSink

    private let channel: VsockChannel
    private let staging: ClipboardFileStaging

    /// Opens the staging sink for a disk-streamed transfer.
    ///
    /// Defaults to `ClipboardFileStaging.makeSink(generation:filename:)`;
    /// injected in tests to substitute a sink that parks or fails a write,
    /// which is the only way to hold the write lane's backlog open long enough
    /// to assert on it.
    private let makeSink: SinkFactory
    private let windowBytes: Int
    /// Durably-written bytes that must accumulate since the last ack before the
    /// next cumulative ack is sent — see
    /// `ClipboardStreamTuning.ackQuantum(forWindowBytes:)`.
    private let ackQuantum: Int
    /// Oldest the last ack may grow before the next durably-written chunk
    /// forces a fresh ack regardless of the byte quantum, so slow writes fall
    /// back to timely per-chunk acking instead of starving the sender's no-ack
    /// deadline — see `ClipboardStreamTuning.ackLatencyBound`.
    private let ackLatencyBound: Duration
    private let stallTimeout: Duration

    /// Inline payloads at/below this size reassemble in RAM; larger ones spill to
    /// the staging file and are mmapped back (so there is no inline size cap).
    ///
    /// Injectable so tests exercise the spill path without moving 256 MiB.
    private let maxResidentInlineBytes: Int

    /// Delivers a completed representation.
    ///
    /// Called off the owning actor, on whichever of the transfer's lanes
    /// finished it — its write lane for a staged rep, its receive lane for a
    /// RAM-resident one.
    private let onComplete: @Sendable (UInt64, ClipboardContent.Representation) -> Void

    /// Reports a transfer that failed (disk full, digest mismatch, peer abort).
    ///
    /// Called off the owning actor.
    private let onAbort: @Sendable (ClipboardStreamAbortInfo) -> Void

    /// Reports timing telemetry for each successfully completed transfer, so
    /// the owning service can surface a per-transfer throughput log line
    /// (the real-vsock baseline #377 calls for).
    ///
    /// Called off the owning actor, on the same lane as `onComplete` and just
    /// before it. `nil` disables the (already negligible) capture.
    private let onTransferTimed: (@Sendable (ClipboardTransferMetrics) -> Void)?

    private let lock = NSLock()
    private var transfers: [UInt64: InboundTransfer] = [:]

    /// Off-actor delivery handlers registered per `transfer_id` by a lazy pull
    /// coordinator.
    ///
    /// When present for a transfer, the matching handler is fired on one of the
    /// transfer's own lanes **instead of** the channel-wide
    /// `onComplete`/`onAbort` — the lazy guest provider blocks the agent's main
    /// thread and must be woken without a main-thread hop, which the channel-wide
    /// closures perform. Guarded by `lock`; one-shot (removed when it fires).
    private var awaiters: [UInt64: Awaiter] = [:]

    /// - Parameters:
    ///   - channel: the vsock channel the transfer frames are read from.
    ///   - staging: provides temp-file sinks and the free-space guard.
    ///   - windowBytes: advertised credit window; sent in each ack.
    ///   - ackLatencyBound: oldest the last ack may grow before the next
    ///     durably-written chunk forces a fresh ack regardless of the byte
    ///     quantum. Tests inject `.zero` (per-chunk acks) or a huge value
    ///     (pure byte-quantum schedules).
    ///   - stallTimeout: how long a transfer waits for its next chunk before
    ///     aborting a silent sender. Tests inject a short value.
    ///   - maxResidentInlineBytes: inline-rep RAM-residency spill threshold;
    ///     larger inline reps stream to disk and are mmapped back. Tests inject a
    ///     tiny value to exercise the spill path.
    ///   - sinkFactory: opens each disk-streamed transfer's staging sink;
    ///     defaults to `staging.makeSink(generation:filename:)`. Tests inject a
    ///     sink that parks or fails a write to drive the write lane's
    ///     backpressure and error paths.
    ///   - onTransferTimed: receives timing telemetry for each successful
    ///     transfer (fired on the transfer's queue, just before `onComplete`);
    ///     `nil` skips the reporting.
    ///   - onComplete: receives `(transferID, representation)` for each
    ///     successful transfer.
    ///   - onAbort: receives an `AbortInfo` for each failed transfer.
    public init(
        channel: VsockChannel,
        staging: ClipboardFileStaging,
        windowBytes: Int = ClipboardStreamTuning.defaultWindowBytes,
        ackLatencyBound: Duration = ClipboardStreamTuning.ackLatencyBound,
        stallTimeout: Duration = ClipboardStreamTuning.inboundStallTimeout,
        maxResidentInlineBytes: Int = ClipboardStreamTuning.maxResidentInlineBytes,
        sinkFactory: SinkFactory? = nil,
        onTransferTimed: (@Sendable (ClipboardTransferMetrics) -> Void)? = nil,
        onComplete: @escaping @Sendable (UInt64, ClipboardContent.Representation) -> Void,
        onAbort: @escaping @Sendable (ClipboardStreamAbortInfo) -> Void
    ) {
        self.channel = channel
        self.staging = staging
        self.makeSink =
            sinkFactory
            ?? { generation, filename in
                try staging.makeSink(generation: generation, filename: filename)
            }
        self.windowBytes = min(max(windowBytes, 1), ClipboardStreamTuning.maxWindowBytes)
        self.ackQuantum = ClipboardStreamTuning.ackQuantum(forWindowBytes: self.windowBytes)
        self.ackLatencyBound = ackLatencyBound
        self.stallTimeout = stallTimeout
        self.maxResidentInlineBytes = max(maxResidentInlineBytes, 0)
        self.onTransferTimed = onTransferTimed
        self.onComplete = onComplete
        self.onAbort = onAbort
    }

    /// Begins an inbound transfer.
    ///
    /// Performs the up-front free-space check for a
    /// file representation, opens the sink, and sends the initial ack (the
    /// go-signal). A disk-full check fails the transfer in-band before any temp
    /// file is created.
    public func handleBegin(_ begin: Kernova_V1_ClipboardStreamBegin) {
        let transfer = InboundTransfer(
            transferID: begin.transferID,
            generation: begin.generation,
            uti: begin.uti,
            filename: begin.filename,
            isInline: begin.isInline,
            totalBytes: Int(clamping: begin.totalBytes),
            maxResidentInlineBytes: maxResidentInlineBytes
        )
        // Ignore a duplicate transfer_id rather than overwrite an in-flight
        // transfer (which would orphan its open sink + partial temp file). [L4]
        let inserted = lock.withLock { () -> Bool in
            guard transfers[begin.transferID] == nil else { return false }
            transfers[begin.transferID] = transfer
            return true
        }
        guard inserted else { return }

        transfer.queue.async { [weak self] in
            guard let self else { return }
            // The transfer becomes visible in the table above *before* this
            // block is enqueued, so a supersession or peer abort racing that
            // gap can claim the terminal state and run first. Bail rather than
            // open a sink nobody will ever close: the sink's owner (the write
            // lane) would then be reading `sink` concurrently with this lane
            // assigning it, and the stall timer started below would outlive a
            // transfer no longer reachable through the table. [L4]
            guard !transfer.isFinished else { return }
            if transfer.streamsToDisk {
                // A file rep always streams to disk; an inline rep past the RAM-
                // residency threshold spills to disk too and is mmapped back at
                // End — so residency never decides whether the paste succeeds and
                // there is no inline size cap (CLIPBOARD.md §1). The disk
                // free-space guard, not a heap ceiling, bounds a misbehaving
                // peer's declared size: create no temp file when it can't fit. [H1]
                guard self.staging.hasCapacity(forByteCount: transfer.totalBytes) else {
                    self.failDiskFull(transfer)
                    return
                }
                do {
                    // Opened here, before the first chunk is handed to the
                    // write lane, so that lane's reads are ordered after this
                    // assignment and it can own the sink from then on.
                    transfer.sink = try self.makeSink(transfer.generation, transfer.filename)
                } catch {
                    self.fail(transfer, code: "stage.error", message: "Cannot open staging file")
                    return
                }
            } else {
                // A small inline rep reassembles in RAM, matching native (the
                // consuming app holds the bytes in RAM too). Reserve toward the
                // declared size (capped) so a large inline rep grows in one
                // allocation rather than geometric reallocations off the 2 MiB
                // window.
                transfer.buffer = Data()
                transfer.buffer?.reserveCapacity(
                    min(transfer.totalBytes, ClipboardStreamTuning.maxInlineReserveBytes))
            }
            // Go-signal: tell the sender we're ready and advertise the window.
            // Sent from this lane even for a disk-streamed transfer (whose
            // later acks come from the write lane) — it precedes every chunk
            // hand-off, so the write lane's first read of the ack watermarks is
            // ordered after it.
            self.sendAck(transfer, upTo: transfer.receivedBytes)
            // Start the stall clock — a sender that never sends a chunk after
            // Begin must not pin this transfer's fd/partial forever. [H2]
            self.startStallTimer(transfer)
        }
    }

    /// Accepts one chunk: validated and hashed here on the receive lane, then
    /// appended on the write lane, which acks the bytes it makes durable
    /// (#615).
    ///
    /// A RAM-resident inline rep does all of it on this lane.
    public func handleChunk(_ chunk: Kernova_V1_ClipboardChunk) {
        guard let transfer = transfer(chunk.transferID) else {
            // Orphan chunk for an unknown/aborted transfer — ignore.
            return
        }
        transfer.queue.async { [weak self] in
            guard let self else { return }
            guard !transfer.isFinished else { return }
            // End was already accepted: the byte counts are final and a
            // completion barrier may be queued behind the write backlog. Drop
            // the straggler rather than let it re-ack, gap, or overrun a
            // transfer that is on its way to delivery. (Before the write lane
            // existed, the serial queue closed this window on its own — End
            // finished the transfer before the next chunk could be dequeued.)
            guard !transfer.endReceived else { return }
            let offset = Int(clamping: chunk.offset)
            if offset < transfer.receivedBytes {
                // Duplicate (already accepted) — re-ack and drop.
                self.reAck(transfer)
                return
            }
            guard offset == transfer.receivedBytes else {
                // Gap — the reliable stream should never reorder; treat as fatal.
                self.fail(
                    transfer, code: "offset.gap",
                    message: "Out-of-order chunk at \(offset), expected \(transfer.receivedBytes)")
                return
            }
            // Bound a single chunk — a frame can carry up to 128 MiB, but the
            // negotiated chunk is 64 KiB. [M3]
            guard chunk.data.count <= ClipboardStreamTuning.maxChunkBytes else {
                self.fail(
                    transfer, code: "chunk.too.large",
                    message: "Chunk of \(chunk.data.count) bytes exceeds limit")
                return
            }
            // Reject a peer streaming past its declared total — bounds both the
            // inline RAM buffer and the file sink to total_bytes. [H1]
            guard transfer.receivedBytes + chunk.data.count <= transfer.totalBytes else {
                self.fail(
                    transfer, code: "size.overrun",
                    message: "Chunk exceeds declared total of \(transfer.totalBytes)")
                return
            }

            let now = ContinuousClock.now
            if transfer.firstChunkAt == nil { transfer.firstChunkAt = now }

            let writeQueue = transfer.writeQueue
            if let writeQueue {
                // Hand the bytes to the write lane and keep going: the append —
                // and the credit-opening ack that follows it — no longer sit
                // between this chunk and the next one (#615). `Data` is
                // copy-on-write, so the hand-off retains the buffer rather than
                // copying it, and the sender's credit window bounds how far
                // this backlog can run ahead of the writes.
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
            // large transfer, and carry the cumulative byte counts for progress
            // surfacing. [large-paste]
            self.deliverProgress(
                transfer.transferID,
                bytesReceived: transfer.receivedBytes,
                totalBytes: transfer.totalBytes)
        }
    }

    /// Verifies and commits a completed transfer.
    ///
    /// Size and SHA-256 are verified here on the receive lane, which owns the
    /// hasher and has therefore already folded in every accepted chunk. A
    /// disk-streamed transfer then commits from a barrier on its write lane, so
    /// the staged file is whole before it is delivered (#615).
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
                    transfer, code: "size.mismatch",
                    message: "Got \(transfer.receivedBytes) bytes, expected \(expected)")
                return
            }
            let digest = Data(transfer.hasher.finalize())
            guard digest == end.sha256 else {
                self.fail(transfer, code: "digest.mismatch", message: "SHA-256 mismatch at End")
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
                self.finishStaged(transfer, byteCount: expected, digest: digest)
            }
        }
    }

    /// Completes a RAM-resident inline transfer, on the receive lane.
    private func finishResident(_ transfer: InboundTransfer) {
        // Final ack: a tail below one ack quantum was never acked mid-stream
        // (#377) — close the sender's cumulative credit ledger at End.
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
            byteCount: transfer.receivedBytes)
    }

    /// Commits a disk-streamed transfer's staging file and completes it, on the
    /// write lane behind the transfer's whole write backlog.
    private func finishStaged(_ transfer: InboundTransfer, byteCount: Int, digest: Data) {
        // Final ack: every byte is durably written now, so this closes the
        // sender's cumulative credit ledger even if the tail sat below one
        // quantum (#377).
        if transfer.writtenBytes > transfer.ackedBytes {
            sendAck(transfer, upTo: transfer.writtenBytes)
        }
        guard let sink = transfer.sink else {
            fail(transfer, code: "stage.error", message: "Missing staging sink at End")
            return
        }
        let url: URL
        do {
            url = try sink.commit()
        } catch {
            fail(
                transfer, code: "commit.error",
                message: "Finalizing staged file failed: \(error.localizedDescription)")
            return
        }
        // The SHA-256 covers the bytes that *arrived*; nothing so far covers
        // the bytes that reached the volume. Before the write lane existed
        // those were one act on one lane and the digest spanned both; now the
        // staging write sits outside what the digest can see, so confirm the
        // committed file is the size the verified payload was. One `stat` per
        // transfer restores end-to-end coverage of the write path — without it
        // a staging file short of its payload would satisfy every check the
        // receiver performs (CLIPBOARD.md §7). [L3]
        let stagedSize = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size]
        if let stagedSize = (stagedSize as? NSNumber)?.intValue, stagedSize != byteCount {
            // Committed, so `Sink.abort()` is already a no-op — drop the
            // truncated file here rather than leave it for generation rotation.
            try? FileManager.default.removeItem(at: url)
            fail(
                transfer, code: "write.short",
                message: "Staged file is \(stagedSize) bytes, expected \(byteCount)")
            return
        }
        let representation: ClipboardContent.Representation
        if transfer.isInline {
            // A large inline rep spilled to disk: serve its bytes back as a
            // resident `.inMemory` payload through a memory-mapped read. The
            // pasteboard flavor is unchanged (inline image data, full
            // fidelity), while Kernova's added RAM stays near zero — the
            // bytes page in on demand and the OS can evict them under
            // pressure (CLIPBOARD.md §1/§2/§8). The mmap is taken here on the
            // write lane, never on the owning actor.
            //
            // RATIONALE: the mapping outlives the staging generation. The
            // staged file rides the receiver's 3-generation retention, and on
            // Darwin a file mapped with `.mappedIfSafe` stays valid after the
            // directory is later swept (unlinking does not drop an open
            // mapping), so the mapped rep needs no separate lifetime tracking.
            let mapped: Data
            do {
                mapped = try Data(contentsOf: url, options: .mappedIfSafe)
            } catch {
                fail(
                    transfer, code: "map.error",
                    message: "Mapping staged inline file failed: \(error.localizedDescription)")
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
                fileURL: url,
                byteCount: byteCount,
                sha256: digest,
                filename: transfer.filename
            )
        }
        deliver(transfer, representation, byteCount: byteCount)
    }

    /// Claims the terminal transition, reports timing, and delivers a completed
    /// representation.
    ///
    /// Called from whichever lane finished the transfer — the receive lane for
    /// a RAM-resident rep, the write lane's completion barrier for a staged
    /// one. Both are off the owning actor, which is the contract the delivery
    /// closures are written against.
    private func deliver(
        _ transfer: InboundTransfer, _ representation: ClipboardContent.Representation,
        byteCount: Int
    ) {
        guard transfer.finishOnce() else { return }
        remove(transfer.transferID)
        if let onTransferTimed {
            let completedAt = ContinuousClock.now
            onTransferTimed(
                ClipboardTransferMetrics(
                    transferID: transfer.transferID,
                    uti: transfer.uti,
                    byteCount: byteCount,
                    streamedToDisk: transfer.streamsToDisk,
                    duration: transfer.beganAt.duration(to: completedAt),
                    streamingDuration: transfer.firstChunkAt.map {
                        $0.duration(to: completedAt)
                    }))
        }
        deliverComplete(transfer.transferID, representation)
    }

    /// Tears down an inbound transfer on a peer `ClipboardStreamAbort`.
    ///
    /// RATIONALE: teardown is keyed purely on the bare `transfer_id` — see
    /// `ClipboardTransferID`'s doc for why a straggler abort for a
    /// since-reused id (#499) is bounded-benign rather than a hazard here.
    public func handleAbort(_ abort: Kernova_V1_ClipboardStreamAbort) {
        guard let transfer = transfer(abort.transferID) else {
            // No in-flight transfer for this id — the sender aborted *before*
            // Begin (e.g. a pre-Begin `disk.full` refusal in ClipboardStreamSender),
            // or this is a duplicate abort. Still wake a lazy pull awaiting this
            // transfer, which would otherwise park to its timeout.
            deliverAbort(
                ClipboardStreamAbortInfo(
                    transferID: abort.transferID, code: abort.code, message: abort.message,
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
                    transferID: abort.transferID, code: abort.code, message: abort.message,
                    neededBytes: nil, availableBytes: nil))
        }
    }

    /// Aborts every in-flight transfer for a superseded generation, deleting
    /// partial temp files, and wakes any lazy pull awaiting that generation.
    public func cancel(generation: UInt64) {
        let affected = lock.withLock { transfers.values.filter { $0.generation == generation } }
        for transfer in affected { teardown(transfer) }
        // Also wake awaiters whose transfer never produced a Begin (no entry in
        // `transfers`), so a pull blocked on a superseded/released generation
        // resolves instead of parking to its timeout.
        failAwaiters { Self.generation(ofTransferID: $0) == generation }
    }

    /// Aborts every in-flight transfer (channel teardown / capability disable)
    /// and wakes every lazy pull awaiting this channel.
    public func cancelAll() {
        let all = lock.withLock { Array(transfers.values) }
        for transfer in all { teardown(transfer) }
        failAwaiters { _ in true }
    }

    /// Consumer-requested cancel of one lazy pull (#464 — e.g. Finder's cancel
    /// button, relayed through the File Provider extension to the owner).
    ///
    /// Unlike `cancel(generation:)`/`cancelAll()` (silent teardown on
    /// supersession — the channel-wide path never surfaced those as a user-visible
    /// abort), this is a *consumer* asking to stop, so it also tells the sender to
    /// give up the remaining bytes via a `ClipboardStreamAbort` frame — the same
    /// wire message `fail(_:code:message:)` sends on a genuine receive failure.
    /// Idempotent: a transfer already finished, or an unknown `transferID`, is a
    /// harmless no-op (the abort frame is still sent best-effort; a stale/finished
    /// transfer_id on the sender side is itself a no-op there).
    public func cancel(transferID: UInt64) {
        sendAbortFrame(transferID, code: "cancelled", message: "Fetch cancelled by consumer")
        if let transfer = transfer(transferID) {
            teardown(transfer)
        } else {
            failAwaiters { $0 == transferID }
        }
    }

    /// Registers an off-actor delivery handler for a single transfer.
    ///
    /// Called by `LazyPullCoordinator` before the `ClipboardRequest` is sent.
    /// When the transfer completes or aborts, the matching handler fires on one
    /// of the transfer's own lanes (off the owning actor) **in place of** the
    /// channel-wide `onComplete`/`onAbort`, so the main-blocked guest provider is
    /// woken without a main-thread hop. One-shot: the handler is removed when it
    /// fires (or via `cancelAwait`).
    public func awaitTransfer(
        _ transferID: UInt64,
        onComplete: @escaping @Sendable (ClipboardContent.Representation) -> Void,
        onAbort: @escaping @Sendable (ClipboardStreamAbortInfo) -> Void,
        onProgress: (@Sendable (_ bytesReceived: Int, _ totalBytes: Int) -> Void)? = nil
    ) {
        lock.withLock {
            awaiters[transferID] = Awaiter(
                onComplete: onComplete, onAbort: onAbort, onProgress: onProgress)
        }
    }

    /// Deregisters a per-transfer delivery handler without firing it.
    public func cancelAwait(_ transferID: UInt64) {
        lock.withLock { awaiters[transferID] = nil }
    }

    // MARK: - Private

    private func transfer(_ id: UInt64) -> InboundTransfer? {
        lock.withLock { transfers[id] }
    }

    private func remove(_ id: UInt64) {
        lock.withLock { transfers[id] = nil }
    }

    /// Delivers a completed representation to a registered per-transfer awaiter,
    /// or the channel-wide `onComplete` when none is registered.
    private func deliverComplete(_ id: UInt64, _ representation: ClipboardContent.Representation) {
        let awaiter = lock.withLock { awaiters.removeValue(forKey: id) }
        if let awaiter {
            awaiter.onComplete(representation)
        } else {
            onComplete(id, representation)
        }
    }

    /// Notifies a registered per-transfer awaiter that the transfer made
    /// progress (a chunk was accepted off the wire), so a parked lazy pull can
    /// re-arm its inactivity backstop and the owner can surface byte progress.
    ///
    /// Peeks the awaiter without removing it — progress fires repeatedly, unlike
    /// the one-shot complete/abort delivery. A transfer with no registered
    /// awaiter (the eager channel-wide path) has nothing to notify.
    private func deliverProgress(_ id: UInt64, bytesReceived: Int, totalBytes: Int) {
        let awaiter = lock.withLock { awaiters[id] }
        awaiter?.onProgress?(bytesReceived, totalBytes)
    }

    /// Delivers a failure to a registered per-transfer awaiter, or the
    /// channel-wide `onAbort` when none is registered.
    private func deliverAbort(_ info: ClipboardStreamAbortInfo) {
        let awaiter = lock.withLock { awaiters.removeValue(forKey: info.transferID) }
        if let awaiter {
            awaiter.onAbort(info)
        } else {
            onAbort(info)
        }
    }

    /// Notifies a registered per-transfer awaiter of a teardown/supersession
    /// without firing the channel-wide `onAbort`.
    ///
    /// Supersession and channel teardown are silent on the channel-wide path
    /// (the eager flow does not surface them), but a lazy pull blocked on the
    /// cancelled transfer must still be unblocked.
    private func deliverAbortToAwaiterOnly(_ info: ClipboardStreamAbortInfo) {
        let awaiter = lock.withLock { awaiters.removeValue(forKey: info.transferID) }
        awaiter?.onAbort(info)
    }

    /// Fires (and removes) every registered awaiter whose `transfer_id` matches
    /// `predicate`, resolving a blocked pull with a cancellation.
    ///
    /// Covers awaiters whose transfer never produced a `Begin`, so they have no
    /// entry in `transfers` for `teardown` to reach. One-shot and idempotent with
    /// `teardown`'s own awaiter notification — whichever removes the awaiter first
    /// wins; the other is a no-op.
    private func failAwaiters(_ predicate: (UInt64) -> Bool) {
        let ids = lock.withLock { awaiters.keys.filter(predicate) }
        for id in ids {
            deliverAbortToAwaiterOnly(
                ClipboardStreamAbortInfo(
                    transferID: id, code: "cancelled",
                    message: "Transfer superseded or channel closed",
                    neededBytes: nil, availableBytes: nil))
        }
    }

    /// The generation encoded in a `transfer_id`, ignoring the direction bit and
    /// honoring both the legacy and child (folder-tree) layouts.
    private static func generation(ofTransferID id: UInt64) -> UInt64 {
        ClipboardTransferID.generation(of: id)
    }

    private func teardown(_ transfer: InboundTransfer) {
        transfer.queue.async { [weak self] in
            guard let self, transfer.finishOnce() else { return }
            transfer.stallTimer?.cancel()
            self.abortSink(transfer)
            self.remove(transfer.transferID)
            // Wake a lazy pull blocked on this transfer; stay silent on the
            // channel-wide path so supersession/teardown isn't surfaced as a
            // user-visible abort the way a peer/disk failure is.
            self.deliverAbortToAwaiterOnly(
                ClipboardStreamAbortInfo(
                    transferID: transfer.transferID, code: "cancelled",
                    message: "Transfer superseded or channel closed",
                    neededBytes: nil, availableBytes: nil))
        }
    }

    /// Starts the per-transfer stall watchdog: one repeating timer that fails
    /// the transfer once no chunk has arrived within `stallTimeout`.
    ///
    /// The timer fires on the transfer's receive lane and compares against
    /// `lastChunkAt`, which each arriving chunk refreshes with a plain
    /// store — replacing a per-chunk `DispatchWorkItem` cancel+alloc+`asyncAfter`
    /// re-arm, pure per-chunk enqueue overhead on the hot path (#377). The
    /// handler's `!finished` guard makes a tick that loses the race to
    /// completion a no-op. [H2]
    private func startStallTimer(_ transfer: InboundTransfer) {
        let timer = DispatchSource.makeTimerSource(queue: transfer.queue)
        timer.setEventHandler { [weak self, weak transfer] in
            guard let self, let transfer, !transfer.isFinished else { return }
            guard transfer.lastChunkAt.duration(to: .now) >= self.stallTimeout else { return }
            self.fail(transfer, code: "stall.timeout", message: "Sender stopped sending")
        }
        // RATIONALE: checking at `stallTimeout` cadence with a half-interval
        // leeway detects a stall within ~1–2.5× `stallTimeout`, not exactly at
        // it — deliberate: the timeout is a dead-sender backstop (well under
        // the 120 s lazy-pull backstop even at 2.5×), not a precise deadline,
        // and the coarse cadence + generous leeway let the OS coalesce the
        // per-transfer wakeup instead of firing it on-schedule for the whole
        // life of a long healthy transfer.
        let interval = stallTimeout.timeInterval
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
    /// payload — which is what lets the ack it sends carry credit.
    private func performWrite(_ transfer: InboundTransfer, _ data: Data) {
        guard !transfer.isFinished else { return }
        guard let sink = transfer.sink else {
            // Unreachable while Begin opens the sink before the first chunk is
            // handed over. Fail loudly anyway rather than drop the bytes: the
            // receive lane has already folded them into `receivedBytes` and the
            // digest, so a silent skip would let End verify a payload the
            // staging file never received and commit a truncated result. [L3]
            fail(transfer, code: "stage.error", message: "Missing staging sink for chunk")
            return
        }
        do {
            try sink.write(data)
        } catch {
            fail(
                transfer, code: "write.error",
                message: "Chunk write failed: \(error.localizedDescription)")
            return
        }
        transfer.writtenBytes += data.count

        // Incremental disk guard: re-check the remaining bytes once per window
        // so a volume filling mid-stream aborts cleanly. Keyed on written bytes
        // because writes, not arrivals, are what consume the volume.
        transfer.bytesSinceCheck += data.count
        if transfer.bytesSinceCheck >= windowBytes {
            transfer.bytesSinceCheck = 0
            let remaining = transfer.totalBytes - transfer.writtenBytes
            if remaining > 0 && !staging.hasCapacity(forByteCount: remaining) {
                failDiskFull(transfer)
                return
            }
        }
        ackIfDue(transfer, upTo: transfer.writtenBytes, now: .now)
    }

    /// Sends a coalesced cumulative ack once a quantum of durably-written bytes
    /// has accumulated since the last one, or once that ack is older than the
    /// latency bound (#377).
    ///
    /// The latency fallback restores timely per-chunk acking exactly when
    /// durable writes run slow, so the gap between credit-opening acks can't
    /// stretch past the sender's fixed no-ack deadline. The tail below one
    /// quantum is acked at End.
    private func ackIfDue(
        _ transfer: InboundTransfer, upTo count: Int, now: ContinuousClock.Instant
    ) {
        guard
            count - transfer.ackedBytes >= ackQuantum
                || transfer.lastAckAt.duration(to: now) >= ackLatencyBound
        else { return }
        sendAck(transfer, upTo: count)
    }

    /// Re-acks a duplicate chunk immediately — never coalesced, since a
    /// duplicate means the peer may be out of sync.
    ///
    /// On the disk path the ack is emitted from the write lane, ordered behind
    /// any pending appends, so it reports the same durably-written prefix every
    /// other ack does rather than racing the write lane's watermarks.
    private func reAck(_ transfer: InboundTransfer) {
        guard let writeQueue = transfer.writeQueue else {
            sendAck(transfer, upTo: transfer.receivedBytes)
            return
        }
        writeQueue.async { [weak self] in
            guard let self, !transfer.isFinished else { return }
            self.sendAck(transfer, upTo: transfer.writtenBytes)
        }
    }

    /// Sends a cumulative ack covering `count` durably-written bytes and
    /// advances the coalescing watermarks (`ackedBytes`/`lastAckAt`) to match.
    private func sendAck(_ transfer: InboundTransfer, upTo count: Int) {
        transfer.ackedBytes = count
        transfer.lastAckAt = .now
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

    private func failDiskFull(_ transfer: InboundTransfer) {
        let available = staging.availableCapacity().map { Int(clamping: $0) }
        sendAbortFrame(transfer.transferID, code: "disk.full", message: "Not enough disk space")
        finishFailed(
            transfer,
            info: ClipboardStreamAbortInfo(
                transferID: transfer.transferID, code: "disk.full",
                message: "Not enough disk space",
                neededBytes: transfer.totalBytes, availableBytes: available))
    }

    /// Fails a transfer from **either** lane: sends the abort frame and tears
    /// down whatever local state exists.
    private func fail(_ transfer: InboundTransfer, code: String, message: String) {
        sendAbortFrame(transfer.transferID, code: code, message: message)
        finishFailed(
            transfer,
            info: ClipboardStreamAbortInfo(
                transferID: transfer.transferID, code: code, message: message,
                neededBytes: nil, availableBytes: nil))
    }

    private func finishFailed(_ transfer: InboundTransfer, info: ClipboardStreamAbortInfo) {
        guard transfer.finishOnce() else { return }
        // Each hop lands on the lane that owns the state it touches, so this is
        // callable from the write lane (a failed append, a volume that filled
        // mid-stream) as well as the receive lane. The abort itself is
        // delivered here, without waiting on either hop, so a blocked lazy pull
        // wakes immediately even when the write lane is stuck in a slow write.
        transfer.queue.async { transfer.stallTimer?.cancel() }
        abortSink(transfer)
        remove(transfer.transferID)
        deliverAbort(info)
    }

    /// Closes and deletes the staging partial on the write lane — the sink's
    /// owning lane — so the cleanup is ordered behind any append still in
    /// flight.
    ///
    /// Pending appends behind it see the claimed terminal state and bail.
    ///
    /// The abort is delivered without waiting for this hop, so **an abort does
    /// not imply the partial is already gone** — it is deleted once the write
    /// lane drains. That ordering is deliberate: doing it inline would make the
    /// aborting lane block on the sink's lock behind an in-flight `write(2)`,
    /// which is exactly the stall this file exists to avoid, and it would not
    /// delete the file any sooner (the same write has to finish either way).
    /// A caller that needs the file gone must wait for it, not for the abort.
    ///
    /// A RAM-resident inline transfer has neither a sink nor a write lane, so
    /// there is nothing to clean up.
    private func abortSink(_ transfer: InboundTransfer) {
        guard let writeQueue = transfer.writeQueue else { return }
        writeQueue.async { transfer.sink?.abort() }
    }

    private func sendAbortFrame(_ transferID: UInt64, code: String, message: String) {
        send(
            .with {
                $0.protocolVersion = 1
                $0.clipboardStreamAbort = .with {
                    $0.transferID = transferID
                    $0.code = code
                    $0.message = message
                }
            })
    }

    private func send(_ frame: Frame) {
        try? channel.writeFramed(VsockChannel.serializeFramed(frame))
    }

    #if DEBUG
    /// The stall watchdog's activity anchor for an in-flight transfer: when its
    /// last chunk arrived (or, before any chunk, when the transfer was
    /// accepted). `nil` for an unknown/finished transfer.
    ///
    /// Read on the transfer's receive lane, the anchor's isolation domain — the
    /// deterministic seam for asserting a chunk advances the anchor without
    /// racing the repeating watchdog timer.
    func lastChunkAtForTesting(_ transferID: UInt64) -> ContinuousClock.Instant? {
        guard let transfer = transfer(transferID) else { return nil }
        return transfer.queue.sync { transfer.lastChunkAt }
    }
    #endif
}

/// Timing telemetry for one successfully completed inbound transfer,
/// surfaced by the owning service as a `.notice` console log line so a real
/// host↔guest vsock throughput baseline can be read out of Console.app /
/// `log stream` without a special build (#377 — the tuning constants were
/// set from first principles; no measured baseline existed).
///
/// Successful transfers only — a failed transfer reports through
/// `ClipboardStreamAbortInfo` instead.
public struct ClipboardTransferMetrics: Sendable, Equatable {
    /// Identifies the transfer these metrics describe.
    public let transferID: UInt64
    /// UTI of the transferred representation.
    public let uti: String
    /// Total payload bytes received and digest-verified.
    public let byteCount: Int
    /// Whether the payload streamed to a staging file (vs. reassembling in RAM).
    public let streamedToDisk: Bool
    /// Begin processed → digest verified and committed.
    public let duration: Duration
    /// First chunk arrival → digest verified and committed — excludes the
    /// go-signal round-trip and the sender's source-open ramp from the
    /// steady-state streaming figure. `nil` for a zero-byte transfer, which
    /// never carries a chunk.
    public let streamingDuration: Duration?

    /// One-line human-readable rendering for the throughput log line, e.g.
    /// `"10485760 bytes (public.data) in 0.052 s — 192.3 MiB/s (disk, streamed 0.049 s)"`.
    ///
    /// The headline rate uses the total duration (the honest end-to-end
    /// figure); the trailing streaming time lets a reader separate per-transfer
    /// setup cost from steady-state throughput when comparing configurations.
    public var logSummary: String {
        let seconds = duration.timeInterval
        let rate = seconds > 0 ? Double(byteCount) / 1_048_576 / seconds : 0
        var detail = streamedToDisk ? "disk" : "memory"
        if let streamingDuration {
            detail += String(format: ", streamed %.3f s", streamingDuration.timeInterval)
        }
        return String(
            format: "%ld bytes (%@) in %.3f s — %.1f MiB/s (%@)",
            byteCount, uti, seconds, rate, detail)
    }
}

/// Why an inbound transfer failed, surfaced to the owning service.
public struct ClipboardStreamAbortInfo: Sendable, Equatable {
    /// Identifies the transfer that aborted.
    public let transferID: UInt64
    /// Machine-readable abort reason (e.g. `disk.full`, `superseded`).
    public let code: String
    /// Human-readable description of the failure.
    public let message: String
    /// Bytes the transfer needed, for a `disk.full` abort.
    public let neededBytes: Int?
    /// Bytes available on the staging volume, for a `disk.full` abort.
    public let availableBytes: Int?

    /// Creates abort info describing why an inbound transfer failed.
    public init(
        transferID: UInt64, code: String, message: String, neededBytes: Int?, availableBytes: Int?
    ) {
        self.transferID = transferID
        self.code = code
        self.message = message
        self.neededBytes = neededBytes
        self.availableBytes = availableBytes
    }
}

/// Off-actor delivery handlers for a single awaited transfer.
private struct Awaiter {
    let onComplete: @Sendable (ClipboardContent.Representation) -> Void
    let onAbort: @Sendable (ClipboardStreamAbortInfo) -> Void
    /// Fired (off the owning actor) on each accepted chunk, carrying the
    /// cumulative `(bytesReceived, totalBytes)`, so a blocked lazy pull can re-arm
    /// its inactivity backstop and the owner can surface transfer progress. `nil`
    /// for the eager path.
    let onProgress: (@Sendable (_ bytesReceived: Int, _ totalBytes: Int) -> Void)?
}

// MARK: - Per-transfer state

/// Mutable state for one inbound transfer, partitioned between its lanes.
///
/// The **receive lane** (`queue`) owns the byte stream as it arrives —
/// validation, hashing, the stall anchor, progress. The **write lane**
/// (`writeQueue`, present only when the transfer streams to a staging file)
/// owns the sink and the ack schedule (#615). Each field below names its owning
/// lane, so none needs a lock; the handful whose ownership *transfers* between
/// lanes (`sink` and the ack watermarks at Begin, `firstChunkAt` at End) say so
/// in their own docs and rely on the hand-off being ordered by the very
/// `async` that moves the work across. The one genuinely contended decision —
/// which path reaches the terminal state first — goes through `finishOnce()`.
private final class InboundTransfer: @unchecked Sendable {
    let transferID: UInt64
    let generation: UInt64
    let uti: String
    let filename: String
    let isInline: Bool
    let totalBytes: Int
    /// Receive lane: validation, hashing, the stall anchor, progress delivery.
    let queue: DispatchQueue
    /// Write lane: staging appends and the acks that open credit for them.
    ///
    /// `nil` for a RAM-resident inline rep, which has no sink and runs entirely
    /// on `queue`.
    let writeQueue: DispatchQueue?

    /// Whether this transfer streams to a staging file instead of a RAM buffer:
    /// every file rep, plus an inline rep past `maxResidentInlineBytes` (which is
    /// mmapped back at End so there is no inline size cap).
    ///
    /// Reads back the write lane's existence rather than re-deriving the rule —
    /// the lane is created for exactly the transfers that get a sink.
    var streamsToDisk: Bool { writeQueue != nil }

    /// When `handleBegin` created this transfer; anchors the total duration
    /// reported in `ClipboardTransferMetrics`.
    let beganAt = ContinuousClock.now
    /// When the first chunk arrived; separates the go-signal/source-open ramp
    /// from steady-state streaming in the reported metrics.
    ///
    /// Written on `queue`; frozen once End is accepted, so the write lane's
    /// completion barrier — ordered after that — reads the final value.
    var firstChunkAt: ContinuousClock.Instant?

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
    /// writes it from the receive lane before the first chunk is ever handed
    /// over, so the write lane's first read is ordered after it.
    var ackedBytes = 0
    /// When the last ack was sent — the ack-coalescing time watermark, checked
    /// against `ackLatencyBound` on each durably-written chunk.
    ///
    /// Same lane ownership as `ackedBytes`.
    var lastAckAt = ContinuousClock.now
    /// Write lane: bytes written since the last free-space re-check.
    var bytesSinceCheck = 0
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
    /// Receive lane: when the last chunk *arrived* (seeded at acceptance,
    /// before any chunk) — the stall watchdog's activity anchor, which
    /// backstops a dead sender.
    var lastChunkAt = ContinuousClock.now
    /// Receive lane: the per-transfer stall watchdog, a repeating timer on
    /// `queue` that checks `lastChunkAt` — started once per transfer, cancelled
    /// on finish, never re-armed per chunk.
    var stallTimer: DispatchSourceTimer?

    private let finishLock = NSLock()
    private var finished = false

    /// Whether the transfer has reached its terminal state (delivered or
    /// aborted).
    ///
    /// Safe to read from either lane.
    var isFinished: Bool { finishLock.withLock { finished } }

    /// Claims the terminal transition, returning `true` to exactly one caller.
    ///
    /// Completion (write lane, behind the backlog), a failed append or a
    /// mid-stream disk-full (write lane), and supersession, peer abort or a
    /// stalled sender (receive lane) all race for it; the winner tears the
    /// transfer down and every loser becomes a no-op.
    func finishOnce() -> Bool {
        finishLock.withLock {
            if finished { return false }
            finished = true
            return true
        }
    }

    init(
        transferID: UInt64, generation: UInt64, uti: String, filename: String, isInline: Bool,
        totalBytes: Int, maxResidentInlineBytes: Int
    ) {
        self.transferID = transferID
        self.generation = generation
        self.uti = uti
        self.filename = filename
        self.isInline = isInline
        self.totalBytes = totalBytes
        self.queue = DispatchQueue(
            label: "app.kernova.clipboard.stream-recv.\(transferID)", qos: .userInitiated)
        // A file rep always streams to disk; an inline rep past the RAM-
        // residency threshold spills to disk too. Both get a write lane; a
        // resident inline rep gets none, and `streamsToDisk` reads that back.
        self.writeQueue =
            (!isInline || totalBytes > maxResidentInlineBytes)
            ? DispatchQueue(
                label: "app.kernova.clipboard.stream-recv.write.\(transferID)", qos: .userInitiated)
            : nil
    }
}
