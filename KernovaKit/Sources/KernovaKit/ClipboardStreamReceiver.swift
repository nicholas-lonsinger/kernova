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
/// verifies size + SHA-256 at End before delivering. Per-transfer file I/O runs on a
/// dedicated serial queue so the owning actor is never blocked.
///
/// `@unchecked Sendable`: the transfer table is guarded by `lock`; each
/// transfer's bytes are touched only on its own serial queue.
public final class ClipboardStreamReceiver: @unchecked Sendable {
    private let channel: VsockChannel
    private let staging: ClipboardFileStaging
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
    /// Called off the owning actor, on the
    /// transfer's queue.
    private let onComplete: @Sendable (UInt64, ClipboardContent.Representation) -> Void

    /// Reports a transfer that failed (disk full, digest mismatch, peer abort).
    ///
    /// Called off the owning actor.
    private let onAbort: @Sendable (ClipboardStreamAbortInfo) -> Void

    /// Reports timing telemetry for each successfully completed transfer, so
    /// the owning service can surface a per-transfer throughput log line
    /// (the real-vsock baseline #377 calls for).
    ///
    /// Called off the owning actor, on the transfer's queue, just before
    /// delivery. `nil` disables the (already negligible) capture.
    private let onTransferTimed: (@Sendable (ClipboardTransferMetrics) -> Void)?

    private let lock = NSLock()
    private var transfers: [UInt64: InboundTransfer] = [:]

    /// Off-actor delivery handlers registered per `transfer_id` by a lazy pull
    /// coordinator.
    ///
    /// When present for a transfer, the matching handler is fired on the
    /// transfer's serial queue **instead of** the channel-wide
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
        onTransferTimed: (@Sendable (ClipboardTransferMetrics) -> Void)? = nil,
        onComplete: @escaping @Sendable (UInt64, ClipboardContent.Representation) -> Void,
        onAbort: @escaping @Sendable (ClipboardStreamAbortInfo) -> Void
    ) {
        self.channel = channel
        self.staging = staging
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
                    transfer.sink = try self.staging.makeSink(
                        generation: transfer.generation, filename: transfer.filename)
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
            self.sendAck(transfer)
            // Start the stall clock — a sender that never sends a chunk after
            // Begin must not pin this transfer's fd/partial forever. [H2]
            self.startStallTimer(transfer)
        }
    }

    /// Writes one chunk; a cumulative ack follows once a quantum of
    /// durably-written bytes has accumulated (#377).
    public func handleChunk(_ chunk: Kernova_V1_ClipboardChunk) {
        guard let transfer = transfer(chunk.transferID) else {
            // Orphan chunk for an unknown/aborted transfer — ignore.
            return
        }
        transfer.queue.async { [weak self] in
            guard let self else { return }
            guard !transfer.finished else { return }
            let offset = Int(clamping: chunk.offset)
            if offset < transfer.receivedBytes {
                // Duplicate (already written) — re-ack and drop.
                self.sendAck(transfer)
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

            if transfer.firstChunkAt == nil { transfer.firstChunkAt = ContinuousClock.now }

            do {
                if transfer.streamsToDisk {
                    try transfer.sink?.write(chunk.data)
                } else {
                    transfer.buffer?.append(chunk.data)
                }
            } catch {
                self.fail(transfer, code: "write.error", message: "Chunk write failed: \(error.localizedDescription)")
                return
            }
            transfer.hasher.update(data: chunk.data)
            transfer.receivedBytes += chunk.data.count

            // Incremental disk guard for any disk-streamed rep (a file rep or a
            // spilled large inline): re-check the remaining bytes once per window
            // so a volume filling mid-stream aborts cleanly.
            if transfer.streamsToDisk {
                transfer.bytesSinceCheck += chunk.data.count
                if transfer.bytesSinceCheck >= self.windowBytes {
                    transfer.bytesSinceCheck = 0
                    let remaining = transfer.totalBytes - transfer.receivedBytes
                    if remaining > 0 && !self.staging.hasCapacity(forByteCount: remaining) {
                        self.failDiskFull(transfer)
                        return
                    }
                }
            }
            // Coalesced cumulative ack (#377): ack once at least a quantum of
            // durably-written bytes has accumulated since the last ack — or
            // once the last ack is older than the latency bound, so slow
            // durable writes fall back to timely per-chunk acks instead of
            // stretching the gap between credit-opening acks past the sender's
            // fixed no-ack deadline. The tail below one quantum is acked at
            // End.
            let now = ContinuousClock.now
            if transfer.receivedBytes - transfer.ackedBytes >= self.ackQuantum
                || transfer.lastAckAt.duration(to: now) >= self.ackLatencyBound
            {
                self.sendAck(transfer)
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
    public func handleEnd(_ end: Kernova_V1_ClipboardStreamEnd) {
        guard let transfer = transfer(end.transferID) else { return }
        transfer.queue.async { [weak self] in
            guard let self else { return }
            guard !transfer.finished else { return }
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
            // Final ack: a tail below one ack quantum was never acked mid-stream
            // (#377) — close the sender's cumulative credit ledger at End.
            if transfer.receivedBytes > transfer.ackedBytes {
                self.sendAck(transfer)
            }

            let representation: ClipboardContent.Representation
            if !transfer.streamsToDisk {
                // Small inline rep: reassembled in RAM.
                representation = ClipboardContent.Representation(
                    uti: transfer.uti,
                    source: .inMemory(transfer.buffer ?? Data()),
                    filename: transfer.filename
                )
            } else {
                guard let sink = transfer.sink else {
                    self.fail(transfer, code: "stage.error", message: "Missing staging sink at End")
                    return
                }
                let url: URL
                do {
                    url = try sink.commit()
                } catch {
                    self.fail(
                        transfer, code: "commit.error",
                        message: "Finalizing staged file failed: \(error.localizedDescription)")
                    return
                }
                if transfer.isInline {
                    // A large inline rep spilled to disk: serve its bytes back as a
                    // resident `.inMemory` payload through a memory-mapped read. The
                    // pasteboard flavor is unchanged (inline image data, full
                    // fidelity), while Kernova's added RAM stays near zero — the
                    // bytes page in on demand and the OS can evict them under
                    // pressure (CLIPBOARD.md §1/§2/§8). The mmap is taken here on the
                    // transfer's queue, never on the owning actor.
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
                        self.fail(
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
                        byteCount: transfer.receivedBytes,
                        sha256: digest,
                        filename: transfer.filename
                    )
                }
            }
            transfer.finished = true
            self.remove(transfer.transferID)
            if let onTransferTimed = self.onTransferTimed {
                let completedAt = ContinuousClock.now
                onTransferTimed(
                    ClipboardTransferMetrics(
                        transferID: transfer.transferID,
                        uti: transfer.uti,
                        byteCount: transfer.receivedBytes,
                        streamedToDisk: transfer.streamsToDisk,
                        duration: transfer.beganAt.duration(to: completedAt),
                        streamingDuration: transfer.firstChunkAt.map {
                            $0.duration(to: completedAt)
                        }))
            }
            self.deliverComplete(transfer.transferID, representation)
        }
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
            guard let self, !transfer.finished else { return }
            transfer.stallTimer?.cancel()
            transfer.finished = true
            transfer.sink?.abort()
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
    /// When the transfer completes or aborts, the matching handler fires on the
    /// transfer's serial queue (off the owning actor) **in place of** the
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
    /// progress (a chunk was durably written), so a parked lazy pull can re-arm
    /// its inactivity backstop and the owner can surface byte progress.
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
            guard let self, !transfer.finished else { return }
            transfer.stallTimer?.cancel()
            transfer.finished = true
            transfer.sink?.abort()
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
    /// The timer fires on the transfer's serial queue and compares against
    /// `lastChunkAt`, which each durably-written chunk refreshes with a plain
    /// store — replacing a per-chunk `DispatchWorkItem` cancel+alloc+`asyncAfter`
    /// re-arm, pure per-chunk enqueue overhead on the hot path (#377). The
    /// handler's `!finished` guard makes a tick that loses the race to
    /// completion a no-op. [H2]
    private func startStallTimer(_ transfer: InboundTransfer) {
        let timer = DispatchSource.makeTimerSource(queue: transfer.queue)
        timer.setEventHandler { [weak self, weak transfer] in
            guard let self, let transfer, !transfer.finished else { return }
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

    /// Sends a cumulative ack for the transfer's current progress and advances
    /// the coalescing watermarks (`ackedBytes`/`lastAckAt`) to match.
    private func sendAck(_ transfer: InboundTransfer) {
        transfer.ackedBytes = transfer.receivedBytes
        transfer.lastAckAt = .now
        send(
            .with {
                $0.protocolVersion = 1
                $0.clipboardStreamAck = .with {
                    $0.transferID = transfer.transferID
                    $0.bytesConsumed = UInt64(transfer.receivedBytes)
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

    private func fail(_ transfer: InboundTransfer, code: String, message: String) {
        sendAbortFrame(transfer.transferID, code: code, message: message)
        finishFailed(
            transfer,
            info: ClipboardStreamAbortInfo(
                transferID: transfer.transferID, code: code, message: message,
                neededBytes: nil, availableBytes: nil))
    }

    private func finishFailed(_ transfer: InboundTransfer, info: ClipboardStreamAbortInfo) {
        guard !transfer.finished else { return }
        transfer.stallTimer?.cancel()
        transfer.finished = true
        transfer.sink?.abort()
        remove(transfer.transferID)
        deliverAbort(info)
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
    /// last chunk was durably written (or, before any chunk, when the transfer
    /// was accepted). `nil` for an unknown/finished transfer.
    ///
    /// Read on the transfer's queue, the anchor's isolation domain — the
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
    /// Fired (off the owning actor) on each durably-written chunk, carrying the
    /// cumulative `(bytesReceived, totalBytes)`, so a blocked lazy pull can re-arm
    /// its inactivity backstop and the owner can surface transfer progress. `nil`
    /// for the eager path.
    let onProgress: (@Sendable (_ bytesReceived: Int, _ totalBytes: Int) -> Void)?
}

// MARK: - Per-transfer state

/// Mutable state for one inbound transfer, touched only on `queue`.
private final class InboundTransfer: @unchecked Sendable {
    let transferID: UInt64
    let generation: UInt64
    let uti: String
    let filename: String
    let isInline: Bool
    let totalBytes: Int
    let maxResidentInlineBytes: Int
    let queue: DispatchQueue

    /// Whether this transfer streams to a staging file instead of a RAM buffer:
    /// every file rep, plus an inline rep past `maxResidentInlineBytes` (which is
    /// mmapped back at End so there is no inline size cap).
    ///
    /// Stable — derived from the immutable `isInline`/`totalBytes`.
    var streamsToDisk: Bool {
        !isInline || totalBytes > maxResidentInlineBytes
    }

    /// When `handleBegin` created this transfer; anchors the total duration
    /// reported in `ClipboardTransferMetrics`.
    let beganAt = ContinuousClock.now
    /// When the first chunk arrived; separates the go-signal/source-open ramp
    /// from steady-state streaming in the reported metrics.
    ///
    /// Touched only on `queue`.
    var firstChunkAt: ContinuousClock.Instant?

    var receivedBytes = 0
    /// Bytes covered by the last ack sent — the ack-coalescing byte watermark.
    ///
    /// Touched only on `queue`.
    var ackedBytes = 0
    /// When the last ack was sent — the ack-coalescing time watermark, checked
    /// against `ackLatencyBound` on each durably-written chunk.
    ///
    /// Touched only on `queue`.
    var lastAckAt = ContinuousClock.now
    var bytesSinceCheck = 0
    var hasher = SHA256()
    var buffer: Data?
    var sink: ClipboardFileStaging.Sink?
    var finished = false
    /// When the last chunk was durably written (seeded at acceptance, before
    /// any chunk) — the stall watchdog's activity anchor.
    ///
    /// Touched only on `queue`.
    var lastChunkAt = ContinuousClock.now
    /// Per-transfer stall watchdog: a repeating timer on `queue` that checks
    /// `lastChunkAt` — started once per transfer, cancelled on finish, never
    /// re-armed per chunk.
    ///
    /// Touched only on `queue`.
    var stallTimer: DispatchSourceTimer?

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
        self.maxResidentInlineBytes = maxResidentInlineBytes
        self.queue = DispatchQueue(
            label: "app.kernova.clipboard.stream-recv.\(transferID)", qos: .userInitiated)
    }
}
