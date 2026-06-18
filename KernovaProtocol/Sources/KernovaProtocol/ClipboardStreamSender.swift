import CryptoKit
import Foundation

/// Streams one clipboard representation at a time to a peer in reply to a
/// `ClipboardRequest`, with windowed flow control and a streaming SHA-256.
///
/// One sender drives all outbound transfers on a channel, keyed by
/// `transfer_id`. Each transfer runs on its own serial queue so a transfer
/// blocked on credit never head-of-line-blocks another. File sources are read
/// 64 KiB at a time with `F_NOCACHE` (never loaded whole); in-memory sources are
/// sliced. The bytes' SHA-256 is computed incrementally and sent in
/// `ClipboardStreamEnd`.
///
/// The owning service routes inbound `ClipboardStreamAck` / `ClipboardStreamAbort`
/// frames here via `handleAck` / `handleAbort`, and cancels transfers on
/// supersession or teardown via `cancel(generation:)` / `cancelAll()`.
///
/// `@unchecked Sendable`: per-transfer state is guarded by each transfer's
/// `NSCondition`; the transfer table is guarded by `lock`.
///
/// RATIONALE: synchronous `FileHandle.read(upToCount:)` on a dedicated GCD queue
/// (not a Swift-concurrency cooperative thread) is the DTS-sanctioned fallback
/// to `DispatchIO`; `F_NOCACHE` recovers the page-cache-friendliness DTS prefers
/// for streaming large files. This keeps the windowed-flow-control loop simple
/// and synchronous while never blocking a cooperative thread.
public final class ClipboardStreamSender: @unchecked Sendable {
    private let channel: VsockChannel
    private let chunkSize: Int
    private let windowBytes: Int
    private let noAckTimeout: Duration

    private let lock = NSLock()
    private var transfers: [UInt64: OutboundTransfer] = [:]

    /// - Parameters:
    ///   - channel: the wire to write frames on (`writeFramed` is thread-safe).
    ///   - chunkSize: per-chunk payload size; defaults to 64 KiB. Tests inject a
    ///     small size to exercise multi-chunk paths.
    ///   - windowBytes: in-flight credit window; clamped up to at least one
    ///     chunk so a transfer can always make progress.
    ///   - noAckTimeout: how long a transfer waits for credit to advance before
    ///     aborting a hung peer. Defaults to 10 s.
    public init(
        channel: VsockChannel,
        chunkSize: Int = ClipboardStreamTuning.defaultChunkPayloadSize,
        windowBytes: Int = ClipboardStreamTuning.defaultWindowBytes,
        noAckTimeout: Duration = .seconds(10)
    ) {
        self.channel = channel
        self.chunkSize = max(1, chunkSize)
        self.windowBytes = max(windowBytes, max(1, chunkSize))
        self.noAckTimeout = noAckTimeout
    }

    /// Begins streaming `representation` in reply to a request.
    ///
    /// Sends `ClipboardStreamBegin`, then chunks under the credit window, then
    /// `ClipboardStreamEnd`. Refuses up front (with `Abort{disk.full}`) when the
    /// requester's `maxAcceptByteCount` can't hold the payload. Calls
    /// `isCurrent(generation)` between chunks and aborts (`Abort{superseded}`)
    /// once the offer is no longer current.
    ///
    /// - Parameters:
    ///   - transferID: identifies this transfer across its frames.
    ///   - generation: the offer generation `representation` belongs to.
    ///   - representation: the clipboard representation to stream.
    ///   - maxAcceptByteCount: the requester's payload ceiling; a larger
    ///     payload is refused with `Abort{disk.full}`.
    ///   - isInline: whether the receiver should reassemble in memory; mirrored
    ///     into `ClipboardStreamBegin.is_inline`.
    ///   - isCurrent: supersession check, evaluated off the caller's actor
    ///     between chunks. Must be safe to call from the transfer queue.
    public func startTransfer(
        transferID: UInt64,
        generation: UInt64,
        representation: ClipboardContent.Representation,
        maxAcceptByteCount: UInt64,
        isInline: Bool,
        isCurrent: @escaping @Sendable (UInt64) -> Bool
    ) {
        let transfer = OutboundTransfer(
            transferID: transferID, generation: generation, windowBytes: windowBytes)
        // Ignore a duplicate transfer_id rather than overwrite an in-flight
        // transfer (which would orphan its open reader). [L4]
        let inserted = lock.withLock { () -> Bool in
            guard transfers[transferID] == nil else { return false }
            transfers[transferID] = transfer
            return true
        }
        guard inserted else { return }

        transfer.queue.async { [weak self] in
            self?.run(
                transfer: transfer,
                representation: representation,
                maxAcceptByteCount: maxAcceptByteCount,
                isInline: isInline,
                isCurrent: isCurrent
            )
        }
    }

    /// Advances a transfer's credit from an inbound `ClipboardStreamAck`.
    ///
    /// `bytesConsumed` is cumulative, so a lost or reordered ack is self-healing
    /// — credit only ever moves forward (`max`).
    public func handleAck(transferID: UInt64, bytesConsumed: UInt64, windowBytes: UInt64) {
        guard let transfer = transfer(transferID) else { return }
        transfer.condition.lock()
        transfer.ackedBytes = max(transfer.ackedBytes, Int(clamping: bytesConsumed))
        if windowBytes > 0 {
            transfer.windowBytes = min(Int(clamping: windowBytes), ClipboardStreamTuning.maxWindowBytes)
        }
        transfer.started = true
        transfer.condition.signal()
        transfer.condition.unlock()
    }

    /// Stops a transfer in response to an inbound `ClipboardStreamAbort`.
    ///
    /// The owning service is responsible for surfacing the abort to the user;
    /// this only tears down the sending loop and does **not** echo an abort back
    /// to the peer (it already aborted).
    public func handleAbort(transferID: UInt64) {
        guard let transfer = transfer(transferID) else { return }
        transfer.markAborted(.peer)
    }

    /// Aborts every in-flight transfer for a superseded offer generation,
    /// notifying the peer so it discards its partial state.
    public func cancel(generation: UInt64) {
        let affected = lock.withLock { transfers.values.filter { $0.generation == generation } }
        for transfer in affected { transfer.markAborted(.superseded) }
    }

    /// Aborts every in-flight transfer (channel teardown / capability disable),
    /// best-effort notifying each peer.
    public func cancelAll() {
        let all = lock.withLock { Array(transfers.values) }
        for transfer in all { transfer.markAborted(.superseded) }
    }

    // MARK: - Private

    private func transfer(_ id: UInt64) -> OutboundTransfer? {
        lock.withLock { transfers[id] }
    }

    private func remove(_ id: UInt64) {
        lock.withLock { _ = transfers.removeValue(forKey: id) }
    }

    private func run(
        transfer: OutboundTransfer,
        representation: ClipboardContent.Representation,
        maxAcceptByteCount: UInt64,
        isInline: Bool,
        isCurrent: @escaping @Sendable (UInt64) -> Bool
    ) {
        defer { remove(transfer.transferID) }

        let totalBytes = representation.byteCount

        // The requester advertised its free-space ceiling; refuse a transfer it
        // can't accept rather than stream bytes that will be dropped.
        // `unlimitedAcceptByteCount` (UInt64.max) means the requester could not
        // measure its free space; any other value — including 0 — is a real
        // ceiling. [M2]
        if maxAcceptByteCount != ClipboardStreamTuning.unlimitedAcceptByteCount
            && UInt64(totalBytes) > maxAcceptByteCount
        {
            sendAbort(transfer: transfer, code: "disk.full", message: "Requester cannot accept \(totalBytes) bytes")
            return
        }

        // Open the source.
        let reader: ChunkReader
        switch representation.source {
        case .inMemory(let data):
            reader = InMemoryChunkReader(data: data)
        case .file(let url, _, _):
            guard let fileReader = FileChunkReader(url: url) else {
                sendAbort(transfer: transfer, code: "read.error", message: "Cannot open source file")
                return
            }
            reader = fileReader
        case .pendingRemote:
            // The sender is only ever handed materialized reps we offered; a
            // not-yet-pulled placeholder has no bytes to stream.
            assertionFailure("Cannot stream a pending-remote representation")
            sendAbort(
                transfer: transfer, code: "read.error",
                message: "Cannot stream a pending-remote representation")
            return
        }
        defer { reader.close() }

        guard
            send(
                .with {
                    $0.protocolVersion = 1
                    $0.clipboardStreamBegin = .with {
                        $0.generation = transfer.generation
                        $0.transferID = transfer.transferID
                        $0.uti = representation.uti
                        $0.totalBytes = UInt64(totalBytes)
                        $0.filename = representation.filename
                        $0.isInline = isInline
                    }
                })
        else { return }  // channel dead — nothing more to do

        var hasher = SHA256()
        var offset = 0
        while offset < totalBytes {
            let nextChunkSize = min(chunkSize, totalBytes - offset)

            // Wait for the go-signal (first ack) and then for credit, bounded by
            // the no-ack deadline; bail on abort.
            let outcome = transfer.awaitCredit(
                offset: offset, chunkSize: nextChunkSize, timeout: noAckTimeout)
            switch outcome {
            case .aborted(let reason):
                // A local supersede/cancel notifies the peer; an inbound abort
                // (the peer already gave up) does not echo back.
                if reason == .superseded {
                    sendAbort(transfer: transfer, code: "superseded", message: "Offer superseded")
                }
                return
            case .timedOut:
                sendAbort(transfer: transfer, code: "ack.timeout", message: "Peer stopped acknowledging")
                return
            case .proceed:
                break
            }

            // Supersession: a newer local copy retired this offer.
            guard isCurrent(transfer.generation) else {
                transfer.markAborted(.superseded)
                sendAbort(transfer: transfer, code: "superseded", message: "Offer superseded")
                return
            }

            guard let chunk = reader.read(upTo: nextChunkSize), !chunk.isEmpty else {
                sendAbort(transfer: transfer, code: "read.error", message: "Source read failed at offset \(offset)")
                return
            }
            hasher.update(data: chunk)

            guard
                send(
                    .with {
                        $0.protocolVersion = 1
                        $0.clipboardChunk = .with {
                            $0.transferID = transfer.transferID
                            $0.offset = UInt64(offset)
                            $0.data = chunk
                        }
                    })
            else { return }  // channel dead
            offset += chunk.count
        }

        let digest = Data(hasher.finalize())
        _ = send(
            .with {
                $0.protocolVersion = 1
                $0.clipboardStreamEnd = .with {
                    $0.transferID = transfer.transferID
                    $0.totalBytes = UInt64(totalBytes)
                    $0.sha256 = digest
                }
            })
    }

    /// Writes a frame; returns `false` if the channel is dead (the transfer
    /// should give up — no abort frame can be sent on a dead channel).
    @discardableResult
    private func send(_ frame: Frame) -> Bool {
        do {
            try channel.writeFramed(VsockChannel.serializeFramed(frame))
            return true
        } catch {
            return false
        }
    }

    private func sendAbort(transfer: OutboundTransfer, code: String, message: String) {
        _ = send(
            .with {
                $0.protocolVersion = 1
                $0.clipboardStreamAbort = .with {
                    $0.transferID = transfer.transferID
                    $0.code = code
                    $0.message = message
                }
            })
    }
}

// MARK: - Per-transfer state

/// Mutable state for one outbound transfer, guarded by `condition`.
private final class OutboundTransfer: @unchecked Sendable {
    let transferID: UInt64
    let generation: UInt64
    let queue: DispatchQueue
    let condition = NSCondition()

    /// Cumulative bytes the receiver has acknowledged.
    var ackedBytes = 0
    /// Effective credit window: seeded with the sender's configured window, then
    /// updated to the receiver's advertised window by each ack.
    var windowBytes: Int
    /// Set once the first ack (the go-signal) arrives.
    var started = false
    /// Set on inbound abort / supersession / teardown.
    var aborted = false
    /// Why the transfer was aborted (decides whether to notify the peer).
    var abortReason: AbortReason?

    /// Why an outbound transfer stopped early.
    enum AbortReason {
        /// The peer aborted; don't echo an abort back.
        case peer
        /// A newer local copy / teardown retired this offer; notify the peer.
        case superseded
    }

    init(transferID: UInt64, generation: UInt64, windowBytes: Int) {
        self.transferID = transferID
        self.generation = generation
        self.windowBytes = windowBytes
        self.queue = DispatchQueue(
            label: "app.kernova.clipboard.stream-send.\(transferID)", qos: .userInitiated)
    }

    enum CreditOutcome { case proceed, aborted(AbortReason?), timedOut }

    /// Blocks until there is credit for a `chunkSize` chunk at `offset`, the
    /// transfer is aborted, or the no-ack deadline elapses without progress.
    func awaitCredit(offset: Int, chunkSize: Int, timeout: Duration) -> CreditOutcome {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date(timeIntervalSinceNow: timeout.timeInterval)
        while true {
            if aborted { return .aborted(abortReason) }
            // Honor the receiver-advertised window (updated by acks under this
            // lock), never the sender's own constant. [L1]
            let effectiveWindow = max(windowBytes, chunkSize)
            let inFlight = offset - ackedBytes
            if started && inFlight + chunkSize <= effectiveWindow { return .proceed }
            if !condition.wait(until: deadline) {
                // Re-check under the lock: a signal that fires exactly at the
                // deadline still counts as progress.
                if aborted { return .aborted(abortReason) }
                let inFlightNow = offset - ackedBytes
                if started && inFlightNow + chunkSize <= max(windowBytes, chunkSize) { return .proceed }
                return .timedOut
            }
        }
    }

    func markAborted(_ reason: AbortReason) {
        condition.lock()
        if !aborted {
            aborted = true
            abortReason = reason
        }
        condition.signal()
        condition.unlock()
    }
}

// MARK: - Chunk readers

/// Reads a source sequentially in chunks. `read(upTo:)` returns `nil` on error.
private protocol ChunkReader {
    func read(upTo count: Int) -> Data?
    func close()
}

private final class InMemoryChunkReader: ChunkReader {
    private let data: Data
    private var offset: Int
    init(data: Data) {
        self.data = data
        self.offset = data.startIndex
    }
    func read(upTo count: Int) -> Data? {
        let end = min(offset + count, data.endIndex)
        guard offset < end else { return Data() }
        let slice = data[offset..<end]
        offset = end
        return Data(slice)
    }
    func close() {}
}

private final class FileChunkReader: ChunkReader {
    private let handle: FileHandle
    init?(url: URL) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        _ = fcntl(handle.fileDescriptor, F_NOCACHE, 1)
        self.handle = handle
    }
    func read(upTo count: Int) -> Data? {
        do {
            return try handle.read(upToCount: count) ?? Data()
        } catch {
            return nil
        }
    }
    func close() {
        try? handle.close()
    }
}
