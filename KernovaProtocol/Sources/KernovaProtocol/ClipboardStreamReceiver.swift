import CryptoKit
import Foundation

/// Reassembles streamed clipboard representations from a peer, choosing its sink
/// by representation role: an inline representation (text/RTF/inline image)
/// accumulates in memory; a file representation streams to a temp file under the
/// free-space guard, never resident whole.
///
/// One receiver drives all inbound transfers on a channel, keyed by
/// `transfer_id`. The owning service routes `ClipboardStreamBegin` /
/// `ClipboardChunk` / `ClipboardStreamEnd` / `ClipboardStreamAbort` frames here;
/// the receiver acks each chunk only **after** it is durably written (so credit
/// tracks the slowest stage) and verifies size + SHA-256 at End before
/// delivering. Per-transfer file I/O runs on a dedicated serial queue so the
/// owning actor is never blocked.
///
/// `@unchecked Sendable`: the transfer table is guarded by `lock`; each
/// transfer's bytes are touched only on its own serial queue.
public final class ClipboardStreamReceiver: @unchecked Sendable {
    private let channel: VsockChannel
    private let staging: ClipboardFileStaging
    private let windowBytes: Int
    private let stallTimeout: Duration

    /// Delivers a completed representation.
    ///
    /// Called off the owning actor, on the
    /// transfer's queue.
    private let onComplete: @Sendable (UInt64, ClipboardContent.Representation) -> Void

    /// Reports a transfer that failed (disk full, digest mismatch, peer abort).
    ///
    /// Called off the owning actor.
    private let onAbort: @Sendable (ClipboardStreamAbortInfo) -> Void

    private let lock = NSLock()
    private var transfers: [UInt64: InboundTransfer] = [:]

    /// - Parameters:
    ///   - channel: the vsock channel the transfer frames are read from.
    ///   - staging: provides temp-file sinks and the free-space guard.
    ///   - windowBytes: advertised credit window; sent in each ack.
    ///   - stallTimeout: how long a transfer waits for its next chunk before
    ///     aborting a silent sender. Tests inject a short value.
    ///   - onComplete: receives `(transferID, representation)` for each
    ///     successful transfer.
    ///   - onAbort: receives an `AbortInfo` for each failed transfer.
    public init(
        channel: VsockChannel,
        staging: ClipboardFileStaging,
        windowBytes: Int = ClipboardStreamTuning.defaultWindowBytes,
        stallTimeout: Duration = ClipboardStreamTuning.inboundStallTimeout,
        onComplete: @escaping @Sendable (UInt64, ClipboardContent.Representation) -> Void,
        onAbort: @escaping @Sendable (ClipboardStreamAbortInfo) -> Void
    ) {
        self.channel = channel
        self.staging = staging
        self.windowBytes = min(max(windowBytes, 1), ClipboardStreamTuning.maxWindowBytes)
        self.stallTimeout = stallTimeout
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
            totalBytes: Int(clamping: begin.totalBytes)
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
            if !transfer.isInline {
                // Up-front disk guard for a file rep — create no temp file when
                // the volume can't hold it.
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
                // Inline reps reassemble in RAM, so a peer-declared size needs a
                // hard ceiling — a file rep is unbounded, streamed to disk. [H1]
                guard transfer.totalBytes <= ClipboardStreamTuning.maxInlineBytes else {
                    self.fail(
                        transfer, code: "inline.too.large",
                        message: "Inline representation of \(transfer.totalBytes) bytes exceeds limit")
                    return
                }
                transfer.buffer = Data()
                transfer.buffer?.reserveCapacity(min(transfer.totalBytes, ClipboardStreamTuning.maxWindowBytes))
            }
            // Go-signal: tell the sender we're ready and advertise the window.
            self.sendAck(transfer)
            // Start the stall clock — a sender that never sends a chunk after
            // Begin must not pin this transfer's fd/partial forever. [H2]
            self.armStallTimer(transfer)
        }
    }

    /// Writes one chunk and acks it after the durable write.
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

            do {
                if transfer.isInline {
                    transfer.buffer?.append(chunk.data)
                } else {
                    try transfer.sink?.write(chunk.data)
                }
            } catch {
                self.fail(transfer, code: "write.error", message: "Chunk write failed: \(error.localizedDescription)")
                return
            }
            transfer.hasher.update(data: chunk.data)
            transfer.receivedBytes += chunk.data.count

            // Incremental disk guard for a file rep: re-check the remaining bytes
            // once per window so a volume filling mid-stream aborts cleanly.
            if !transfer.isInline {
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
            self.sendAck(transfer)
            // A chunk arrived — reset the stall clock. [H2]
            self.armStallTimer(transfer)
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

            let representation: ClipboardContent.Representation
            if transfer.isInline {
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
                representation = ClipboardContent.Representation(
                    uti: transfer.uti,
                    fileURL: url,
                    byteCount: transfer.receivedBytes,
                    sha256: digest,
                    filename: transfer.filename
                )
            }
            transfer.finished = true
            self.remove(transfer.transferID)
            self.onComplete(transfer.transferID, representation)
        }
    }

    /// Tears down an inbound transfer on a peer `ClipboardStreamAbort`.
    public func handleAbort(_ abort: Kernova_V1_ClipboardStreamAbort) {
        guard let transfer = transfer(abort.transferID) else { return }
        transfer.queue.async { [weak self] in
            guard let self, !transfer.finished else { return }
            transfer.stallTimer?.cancel()
            transfer.finished = true
            transfer.sink?.abort()
            self.remove(transfer.transferID)
            self.onAbort(
                ClipboardStreamAbortInfo(
                    transferID: abort.transferID, code: abort.code, message: abort.message,
                    neededBytes: nil, availableBytes: nil))
        }
    }

    /// Aborts every in-flight transfer for a superseded generation, deleting
    /// partial temp files.
    public func cancel(generation: UInt64) {
        let affected = lock.withLock { transfers.values.filter { $0.generation == generation } }
        for transfer in affected { teardown(transfer) }
    }

    /// Aborts every in-flight transfer (channel teardown / capability disable).
    public func cancelAll() {
        let all = lock.withLock { Array(transfers.values) }
        for transfer in all { teardown(transfer) }
    }

    // MARK: - Private

    private func transfer(_ id: UInt64) -> InboundTransfer? {
        lock.withLock { transfers[id] }
    }

    private func remove(_ id: UInt64) {
        lock.withLock { _ = transfers.removeValue(forKey: id) }
    }

    private func teardown(_ transfer: InboundTransfer) {
        transfer.queue.async { [weak self] in
            guard !transfer.finished else { return }
            transfer.stallTimer?.cancel()
            transfer.finished = true
            transfer.sink?.abort()
            self?.remove(transfer.transferID)
        }
    }

    /// (Re)arms the inbound stall timer: fails the transfer if no chunk arrives
    /// within `stallTimeout`.
    ///
    /// Called only from the transfer's serial queue, so cancelling and
    /// rescheduling here never races chunk processing; the work item's
    /// `!finished` guard makes a fire that loses the race to completion a no-op.
    /// [H2]
    private func armStallTimer(_ transfer: InboundTransfer) {
        transfer.stallTimer?.cancel()
        let timer = DispatchWorkItem { [weak self, weak transfer] in
            guard let self, let transfer, !transfer.finished else { return }
            self.fail(transfer, code: "stall.timeout", message: "Sender stopped sending")
        }
        transfer.stallTimer = timer
        transfer.queue.asyncAfter(deadline: .now() + stallTimeout.timeInterval, execute: timer)
    }

    /// Sends a cumulative ack for the transfer's current progress.
    private func sendAck(_ transfer: InboundTransfer) {
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
        onAbort(info)
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

// MARK: - Per-transfer state

/// Mutable state for one inbound transfer, touched only on `queue`.
private final class InboundTransfer: @unchecked Sendable {
    let transferID: UInt64
    let generation: UInt64
    let uti: String
    let filename: String
    let isInline: Bool
    let totalBytes: Int
    let queue: DispatchQueue

    var receivedBytes = 0
    var bytesSinceCheck = 0
    var hasher = SHA256()
    var buffer: Data?
    var sink: ClipboardFileStaging.Sink?
    var finished = false
    /// Pending inactivity timeout; rescheduled on each chunk, cancelled on
    /// finish.
    ///
    /// Touched only on `queue`.
    var stallTimer: DispatchWorkItem?

    init(
        transferID: UInt64, generation: UInt64, uti: String, filename: String, isInline: Bool,
        totalBytes: Int
    ) {
        self.transferID = transferID
        self.generation = generation
        self.uti = uti
        self.filename = filename
        self.isInline = isInline
        self.totalBytes = totalBytes
        self.queue = DispatchQueue(
            label: "app.kernova.clipboard.stream-recv.\(transferID)", qos: .userInitiated)
    }
}
