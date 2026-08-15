import CryptoKit
import Foundation

/// Streams one clipboard representation at a time to a peer in reply to a
/// `ClipboardRequest`, with windowed flow control and a streaming SHA-256.
///
/// A small inline representation streams raw; every other representation — a
/// file, a folder, an oversize inline payload — is encoded onto the wire as an
/// LZ4 AppleArchive as it streams (`ClipboardStreamBegin.is_archive`), so the
/// receiver's disk sink is one extract pipeline whatever the payload.
///
/// Each transfer runs on its own serial queue, so a transfer blocked on credit
/// never head-of-line-blocks another and a source that parks the flow-control
/// loop never blocks a Swift-concurrency cooperative thread. Per-transfer state
/// is guarded by each transfer's `NSCondition`; the transfer table is guarded
/// by `lock`.
public final class ClipboardStreamSender: @unchecked Sendable {
    private let channel: VsockChannel
    private let chunkSize: Int
    private let windowBytes: Int
    private let noAckTimeout: TimeInterval
    private let maxResidentInlineBytes: Int

    private let archiveSource: ClipboardArchiveSourceFactory

    private let lock = NSLock()
    private var transfers: [UInt64: OutboundTransfer] = [:]

    /// - Parameters:
    ///   - channel: the wire to write frames on (`writeFramed` is thread-safe).
    ///   - chunkSize: per-chunk payload size; defaults to 64 KiB.
    ///   - windowBytes: in-flight credit window; clamped up to at least one
    ///     chunk so a transfer can always make progress.
    ///   - noAckTimeout: how long a transfer waits for credit to advance before
    ///     aborting a hung peer.
    ///   - maxResidentInlineBytes: the largest inline payload streamed raw; a
    ///     larger one is archived so the receiver never has to hold it whole.
    public convenience init(
        channel: VsockChannel,
        chunkSize: Int = ClipboardStreamTuning.defaultChunkPayloadSize,
        windowBytes: Int = ClipboardStreamTuning.defaultWindowBytes,
        noAckTimeout: TimeInterval = 10,
        maxResidentInlineBytes: Int = ClipboardStreamTuning.maxResidentInlineBytes
    ) {
        self.init(
            channel: channel, chunkSize: chunkSize, windowBytes: windowBytes,
            noAckTimeout: noAckTimeout, maxResidentInlineBytes: maxResidentInlineBytes,
            archiveSource: { source, label, capacity in
                ArchiveChunkReader(source: source, label: label, capacityBytes: capacity)
            })
    }

    /// Creates a sender whose archived transfers read through `archiveSource`.
    ///
    /// A test stands in a source that parks, which is the only way to exercise
    /// an abort landing while the transfer thread is inside a read.
    init(
        channel: VsockChannel,
        chunkSize: Int = ClipboardStreamTuning.defaultChunkPayloadSize,
        windowBytes: Int = ClipboardStreamTuning.defaultWindowBytes,
        noAckTimeout: TimeInterval = 10,
        maxResidentInlineBytes: Int = ClipboardStreamTuning.maxResidentInlineBytes,
        archiveSource: @escaping ClipboardArchiveSourceFactory
    ) {
        self.channel = channel
        self.chunkSize = max(1, chunkSize)
        self.windowBytes = max(windowBytes, max(1, chunkSize))
        self.noAckTimeout = noAckTimeout
        self.maxResidentInlineBytes = max(0, maxResidentInlineBytes)
        self.archiveSource = archiveSource
    }

    /// Begins streaming `representation` in reply to a request.
    ///
    /// Refuses up front with `Abort{disk.full}` when the requester's
    /// `maxAcceptByteCount` can't hold the payload, and aborts with
    /// `Abort{superseded}` once `isCurrent(generation)` goes false.
    ///
    /// An inline representation at or below `maxResidentInlineBytes` streams
    /// raw and declares its size. Everything else is archived onto the wire —
    /// a folder as its tree, a file or an oversize inline payload as a
    /// one-entry archive — and its compressed size isn't known until its last
    /// byte, so the `ClipboardStreamBegin` declares `total_bytes = 0` and the
    /// `ClipboardStreamEnd` carries the true count. The requester's
    /// `maxAcceptByteCount` is measured against the payload the archive expands
    /// to, not the bytes on the wire: refused up front against the size the
    /// offer advertised, and enforced cumulatively as the archive is produced,
    /// since a folder's advertised size is an estimate.
    ///
    /// - Parameters:
    ///   - transferID: identifies this transfer across its frames.
    ///   - generation: the offer generation `representation` belongs to.
    ///   - representation: the clipboard representation to stream; a
    ///     file-backed or folder source must stay readable for the whole
    ///     transfer.
    ///   - maxAcceptByteCount: the requester's payload ceiling.
    ///   - isInline: whether the receiver should deliver the payload as
    ///     pasteboard bytes; mirrored into `ClipboardStreamBegin.is_inline`.
    ///   - isCurrent: supersession check, evaluated off the caller's actor
    ///     between chunks. Must be safe to call from the transfer queue.
    ///   - onProgress: fired off the caller's actor after each chunk is handed to
    ///     the socket, carrying the cumulative `(bytesSent, totalBytes)` in the
    ///     unit the offer advertised. An archived transfer reports `0` for the
    ///     total — the progress tracker keeps the offer's figure.
    ///   - onComplete: fired off the caller's actor exactly once when the transfer
    ///     ends, with `success` true only when all bytes were streamed.
    public func startTransfer(
        transferID: UInt64,
        generation: UInt64,
        representation: ClipboardContent.Representation,
        maxAcceptByteCount: UInt64,
        isInline: Bool,
        isCurrent: @escaping @Sendable (UInt64) -> Bool,
        onProgress: (@Sendable (_ bytesSent: Int, _ totalBytes: Int) -> Void)? = nil,
        onComplete: (@Sendable (_ success: Bool) -> Void)? = nil
    ) {
        let transfer = OutboundTransfer(
            transferID: transferID, generation: generation, windowBytes: windowBytes)
        // Ignore a duplicate transfer_id rather than overwrite an in-flight
        // transfer, which would orphan its open reader.
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
                isCurrent: isCurrent,
                onProgress: onProgress,
                onComplete: onComplete
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
    /// Tears down the sending loop only: it does **not** echo an abort back to
    /// the peer, which already aborted, nor surface it to the user.
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

    /// Rejects a `ClipboardRequest` we won't start a transfer for, sending a
    /// `ClipboardStreamAbort` so the requester's parked pull wakes immediately
    /// off-main instead of stalling to its `lazyPullTimeout` backstop.
    ///
    /// No `OutboundTransfer` is ever registered — the request is dropped before
    /// any transfer exists.
    public func rejectRequest(transferID: UInt64, code: String, message: String) {
        sendAbort(transferID: transferID, code: code, message: message)
    }

    // MARK: - Private

    private func transfer(_ id: UInt64) -> OutboundTransfer? {
        lock.withLock { transfers[id] }
    }

    private func remove(_ id: UInt64) {
        lock.withLock { transfers[id] = nil }
    }

    private func run(
        transfer: OutboundTransfer,
        representation: ClipboardContent.Representation,
        maxAcceptByteCount: UInt64,
        isInline: Bool,
        isCurrent: @escaping @Sendable (UInt64) -> Bool,
        onProgress: (@Sendable (_ bytesSent: Int, _ totalBytes: Int) -> Void)?,
        onComplete: (@Sendable (_ success: Bool) -> Void)?
    ) {
        // `onComplete` must fire on every exit path so the owner can clear any
        // progress UI; it runs *after* `remove` (defers run LIFO).
        var didComplete = false
        defer { onComplete?(didComplete) }
        defer { remove(transfer.transferID) }

        // The payload in the unit the offer advertised it in — exact for a file
        // or inline rep, the stat-walk estimate for a folder.
        let advertisedByteCount = representation.byteCount

        // Refuse a transfer the requester can't accept rather than stream bytes
        // that will be dropped. Any ceiling other than `unlimitedAcceptByteCount`
        // — including 0 — is a real one.
        if maxAcceptByteCount != ClipboardStreamTuning.unlimitedAcceptByteCount
            && UInt64(advertisedByteCount) > maxAcceptByteCount
        {
            sendAbort(
                transfer: transfer, code: "disk.full",
                message: "Requester cannot accept \(advertisedByteCount) bytes")
            return
        }

        // Opening an archive source starts the encode, and resolving an inline
        // file reads it, so check for a retirement that landed between
        // registration and here before paying for a payload nobody is waiting
        // on. `stream` re-checks before anything is announced.
        let retirement = transfer.retirement()
        if retirement.retired {
            notifyPeerOfRetirement(transfer, reason: retirement.reason)
            return
        }

        // What crosses the wire: raw bytes for an inline payload the receiver
        // can hold resident, an archive for everything else.
        enum Payload {
            case raw(Data)
            case archived(ClipboardArchiveSource)
        }
        let payload: Payload
        switch representation.source {
        case .inMemory(let data) where isInline && data.count <= maxResidentInlineBytes:
            payload = .raw(data)
        case .file(let url, let byteCount, _) where isInline && byteCount <= maxResidentInlineBytes:
            // An inline payload is resident bytes on both ends, so resolve the
            // file to bytes here — bounded by the threshold the receiver holds
            // it resident under — rather than stream it raw from disk. A file
            // that grew past the threshold since the offer's stat is archived,
            // as any oversize inline payload is.
            guard let data = try? Data(contentsOf: url) else {
                sendAbort(transfer: transfer, code: "read.error", message: "Cannot read source file")
                return
            }
            payload =
                data.count <= maxResidentInlineBytes
                ? .raw(data) : .archived(.blob(data, name: Self.entryName(for: representation)))
        case .pendingRemote:
            // The sender is only ever handed materialized reps we offered; a
            // not-yet-pulled placeholder has no bytes to stream.
            assertionFailure("Cannot stream a pending-remote representation")
            sendAbort(
                transfer: transfer, code: "read.error",
                message: "Cannot stream a pending-remote representation")
            return
        case .inMemory(let data):
            payload = .archived(.blob(data, name: Self.entryName(for: representation)))
        case .file(let url, let byteCount, _):
            payload = .archived(
                .file(url, name: Self.entryName(for: representation), byteCount: byteCount))
        case .directory(let url, _):
            payload = .archived(.directory(url))
        }
        let reader: ChunkReader
        let declaredByteCount: Int?
        switch payload {
        case .raw(let data):
            reader = InMemoryChunkReader(data: data)
            declaredByteCount = data.count
        case .archived(let source):
            reader = openArchive(source, transfer)
            declaredByteCount = nil
        }
        // Covers every exit below — abort, supersession, credit timeout, a dead
        // channel — by closing the source, which for an archive unblocks the
        // encode pipeline so its worker unwinds instead of parking in a
        // callback that has no timeout.
        defer { reader.close() }

        didComplete = stream(
            transfer: transfer, reader: reader, declaredByteCount: declaredByteCount,
            uti: representation.uti, filename: representation.filename, isInline: isInline,
            maxAcceptByteCount: maxAcceptByteCount, isCurrent: isCurrent, onProgress: onProgress)
    }

    /// The archive entry name for a one-entry payload: the representation's
    /// filename, which is what the receiver's extract will name the file.
    private static func entryName(for representation: ClipboardContent.Representation) -> String {
        FinderStyleUniquing.sanitizedComponent(
            representation.filename.isEmpty ? "data" : representation.filename)
    }

    /// Opens the archive source for a transfer and routes the transfer's
    /// retirement into it.
    ///
    /// An archive source parks the transfer thread inside `read` when the
    /// encoder has produced nothing yet, and no abort path signals the
    /// transfer's own condition into *that* wait. Without the hook a stalled
    /// encode outlives every abort, supersession and channel teardown — and,
    /// because a transfer id is derivable, silently swallows the peer's retry as
    /// a duplicate.
    private func openArchive(
        _ source: ClipboardArchiveSource, _ transfer: OutboundTransfer
    ) -> CancellableChunkReader {
        let reader = archiveSource(source, "\(transfer.transferID)", windowBytes)
        if transfer.setAbortHook({ [weak reader] in reader?.close() }) {
            reader.close()
        }
        return reader
    }

    /// Announces a transfer and streams its source to the peer under the credit
    /// window, returning whether every byte was handed to the socket.
    ///
    /// `declaredByteCount` is `nil` for an archived payload, whose size is only
    /// known once it has been produced. Such a transfer announces
    /// `total_bytes = 0` (unknown), runs until its source reports the end, and
    /// reports the true count in its `ClipboardStreamEnd`.
    private func stream(
        transfer: OutboundTransfer,
        reader: ChunkReader,
        declaredByteCount: Int?,
        uti: String,
        filename: String,
        isInline: Bool,
        maxAcceptByteCount: UInt64,
        isCurrent: @escaping @Sendable (UInt64) -> Bool,
        onProgress: (@Sendable (_ bytesSent: Int, _ totalBytes: Int) -> Void)?
    ) -> Bool {
        // Retirement is checked per chunk in the loop below, which a zero-byte
        // payload never enters — so check once here, before anything is
        // announced. Every transfer then honors an abort or supersession that
        // landed between `startTransfer` registering it and this queue reaching
        // it, whatever its size (docs/CLIPBOARD.md §9).
        let retirement = transfer.retirement()
        if retirement.retired {
            notifyPeerOfRetirement(transfer, reason: retirement.reason)
            return false
        }
        guard isCurrent(transfer.generation) else {
            transfer.markAborted(.superseded)
            notifyPeerOfRetirement(transfer, reason: .superseded)
            return false
        }

        guard
            send(
                .with {
                    $0.protocolVersion = 1
                    $0.clipboardStreamBegin = .with {
                        $0.generation = transfer.generation
                        $0.transferID = transfer.transferID
                        $0.uti = uti
                        $0.totalBytes = UInt64(declaredByteCount ?? 0)
                        $0.filename = filename
                        $0.isInline = isInline
                        $0.isArchive = declaredByteCount == nil
                    }
                })
        else { return false }  // channel dead — nothing more to do

        var hasher = SHA256()
        var offset = 0
        while declaredByteCount.map({ offset < $0 }) ?? true {
            let nextChunkSize = declaredByteCount.map { min(chunkSize, $0 - offset) } ?? chunkSize

            // Read before asking for credit, and ask for exactly what came back.
            // A source that produces bytes as it goes — an archive encoded onto
            // the wire — only reveals its end by returning nothing, and its
            // tail is usually shorter than a chunk. Reserving a whole chunk's
            // credit for either would park the sender on credit for bytes it is
            // never going to send, which nothing else can then unblock.
            guard var chunk = reader.read(upTo: nextChunkSize) else {
                // A retirement is what woke this read when it was parked, so it
                // is the peer's news rather than a source failure.
                let retirement = transfer.retirement()
                if retirement.retired {
                    notifyPeerOfRetirement(transfer, reason: retirement.reason)
                    return false
                }
                sendAbort(transfer: transfer, code: "read.error", message: "Source read failed at offset \(offset)")
                return false
            }
            // Fill the chunk: a partial read otherwise puts one frame on the wire
            // per dribble from the source. A reader that satisfies the whole
            // request pays nothing here — the loop body never runs.
            while !chunk.isEmpty, chunk.count < nextChunkSize {
                guard let more = reader.read(upTo: nextChunkSize - chunk.count) else {
                    sendAbort(
                        transfer: transfer, code: "read.error",
                        message: "Source read failed at offset \(offset + chunk.count)")
                    return false
                }
                if more.isEmpty { break }
                chunk.append(more)
            }
            if chunk.isEmpty {
                // A declared payload that runs dry early is a failed read; an
                // undeclared one has simply reached its end.
                guard declaredByteCount == nil else {
                    sendAbort(
                        transfer: transfer, code: "read.error",
                        message: "Source read failed at offset \(offset)")
                    return false
                }
                break
            }

            // Wait for the go-signal (first ack) and then for credit, bounded by
            // the no-ack deadline; bail on abort.
            let outcome = transfer.awaitCredit(
                offset: offset, chunkSize: chunk.count, timeout: noAckTimeout)
            switch outcome {
            case .aborted(let reason):
                notifyPeerOfRetirement(transfer, reason: reason)
                return false
            case .timedOut:
                sendAbort(transfer: transfer, code: "ack.timeout", message: "Peer stopped acknowledging")
                return false
            case .proceed:
                break
            }

            // Supersession: a newer local copy retired this offer.
            guard isCurrent(transfer.generation) else {
                transfer.markAborted(.superseded)
                notifyPeerOfRetirement(transfer, reason: .superseded)
                return false
            }

            // The requester's ceiling, enforced as bytes are produced. A declared
            // payload was already refused up front, so this only ever fires for a
            // stream whose size wasn't knowable then — and it is measured in the
            // unit the ceiling is stated in: the payload the requester will
            // write, not the archive on the wire, which compression can make
            // ~100× smaller. A source whose wire bytes are its payload reports
            // no offer-unit count.
            let producedBytes = reader.offerUnitProgress ?? (offset + chunk.count)
            if maxAcceptByteCount != ClipboardStreamTuning.unlimitedAcceptByteCount,
                UInt64(producedBytes) > maxAcceptByteCount
            {
                sendAbort(
                    transfer: transfer, code: "disk.full",
                    message:
                        "Requester cannot accept more than \(maxAcceptByteCount) bytes; the payload has produced \(producedBytes)"
                )
                return false
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
            else { return false }  // channel dead
            offset += chunk.count
            // Report bytes handed to the socket (not yet acked) so the owner can
            // surface outbound progress. A `0` total leaves the tracker on the
            // expectation the unit was opened with — the offer's figure — so the
            // numerator has to be in that unit too, which for an archive is what
            // the source has encoded, not what the wire has carried.
            onProgress?(reader.offerUnitProgress ?? offset, declaredByteCount ?? 0)
        }

        let digest = Data(hasher.finalize())
        _ = send(
            .with {
                $0.protocolVersion = 1
                $0.clipboardStreamEnd = .with {
                    $0.transferID = transfer.transferID
                    $0.totalBytes = UInt64(offset)
                    $0.sha256 = digest
                }
            })
        // All bytes were streamed; a failed End-send still counts as success —
        // delivery is then the receiver's stall concern, not a send failure.
        return true
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
        sendAbort(transferID: transfer.transferID, code: code, message: message)
    }

    /// Tells the peer about a retirement when it is the peer's news.
    ///
    /// A local supersede/cancel is; an inbound abort is not, since the peer
    /// already gave up. The single place that decision is made, shared by the
    /// pre-Begin check and the chunk loop.
    private func notifyPeerOfRetirement(
        _ transfer: OutboundTransfer, reason: OutboundTransfer.AbortReason?
    ) {
        guard reason == .superseded else { return }
        sendAbort(transfer: transfer, code: "superseded", message: "Offer superseded")
    }

    /// Writes a `ClipboardStreamAbort` for `transferID`.
    private func sendAbort(transferID: UInt64, code: String, message: String) {
        _ = send(
            .with {
                $0.protocolVersion = 1
                $0.clipboardStreamAbort = .with {
                    $0.transferID = transferID
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
    /// Wakes a source parked outside `awaitCredit`, run once retirement is
    /// claimed.
    ///
    /// Idempotent by contract, so a duplicate abort is harmless.
    var abortHook: (@Sendable () -> Void)?
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

    /// Whether the transfer has already been retired, and why.
    ///
    /// `awaitCredit`'s abort check without the wait, for the payload-independent
    /// check that runs before the chunk loop.
    ///
    /// Reads under `condition`, the lock `markAborted` writes under, so a
    /// retirement racing this read resolves one way or the other rather than
    /// tearing.
    func retirement() -> (retired: Bool, reason: AbortReason?) {
        condition.lock()
        defer { condition.unlock() }
        return (aborted, abortReason)
    }

    /// Blocks until there is credit for a `chunkSize` chunk at `offset`, the
    /// transfer is aborted, or the no-ack deadline elapses without progress.
    func awaitCredit(offset: Int, chunkSize: Int, timeout: TimeInterval) -> CreditOutcome {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date(timeIntervalSinceNow: timeout)
        while true {
            if aborted { return .aborted(abortReason) }
            // Honor the receiver-advertised window (updated by acks under this
            // lock), never the sender's own constant.
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
        let hook = abortHook
        condition.signal()
        condition.unlock()
        // Outside the lock: the hook takes the source's own lock, and nothing
        // should hold two.
        hook?()
    }

    /// Registers the retirement hook, reporting whether retirement already
    /// happened — in which case the caller runs it itself, since `markAborted`
    /// has been and gone.
    func setAbortHook(_ hook: @escaping @Sendable () -> Void) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        abortHook = hook
        return aborted
    }
}

// MARK: - Chunk readers

/// Reads a source sequentially in chunks.
///
/// `read(upTo:)` returns `nil` on error and an empty `Data` at the end of the
/// source — which is the end of the payload for a source whose size was never
/// declared, and a short read for one that was.
///
/// `close()` must be safe to call from another thread while a read is in
/// flight, and must make that read return: it is how an abort reaches a source
/// that parks.
protocol ChunkReader: AnyObject {
    func read(upTo count: Int) -> Data?
    func close()
    /// Bytes of the *payload the offer described* produced so far, when the
    /// source can say — an archive's wire bytes are compressed and so are in a
    /// different unit from every readout's denominator. `nil` leaves the caller
    /// to report wire bytes.
    var offerUnitProgress: Int? { get }
}

extension ChunkReader {
    /// A source whose wire bytes *are* the payload needs no translation.
    var offerUnitProgress: Int? { nil }
}

/// A `ChunkReader` whose `close()` is safe to call from another thread while a
/// `read(upTo:)` is parked on it, and whose reads and closes may therefore be
/// interleaved across threads.
///
/// A source that produces its bytes on its own schedule parks its caller inside
/// `read(upTo:)`, and nothing else can reach that park — so retirement runs
/// `close()` from whichever thread claimed it. Conforming is the promise that
/// this is sound; `ChunkReader` alone does not carry it, and a reader backed by
/// an unguarded cursor cannot make it.
protocol CancellableChunkReader: ChunkReader, Sendable {}

/// Opens the archive source for an archived transfer.
///
/// The result is cancellable because an archive's encode runs ahead of the
/// transport and parks the transfer thread, which only `close()` can release.
typealias ClipboardArchiveSourceFactory =
    @Sendable (
        _ source: ClipboardArchiveSource, _ label: String, _ capacityBytes: Int
    ) -> CancellableChunkReader

final class InMemoryChunkReader: ChunkReader {
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
        // Returning the slice avoids a per-chunk 64 KiB alloc+copy; it aliases
        // `data`, which this reader retains for the whole transfer anyway. The
        // slice has a non-zero `startIndex`, which every consumer here handles.
        return slice
    }
    func close() {}
}

/// Reads a payload as archive bytes produced on demand, so nothing larger than
/// the credit window is ever held and no archive lands on disk.
///
/// The empty result that ends the stream is reached only once the encode
/// pipeline has closed cleanly; a failure anywhere in it surfaces as `nil`, the
/// transfer's `read.error` abort.
final class ArchiveChunkReader: CancellableChunkReader {
    private let reader: ClipboardArchiveReader

    init(source: ClipboardArchiveSource, label: String, capacityBytes: Int) {
        reader = ClipboardArchiveReader(source: source, label: label, capacityBytes: capacityBytes)
    }

    func read(upTo count: Int) -> Data? {
        try? reader.read(upTo: count)
    }

    /// Uncompressed archive bytes, which is the unit the offer's figure is in —
    /// the compressed wire count would read as a stalled transfer.
    var offerUnitProgress: Int? { reader.uncompressedByteCount }

    func close() {
        reader.cancel()
    }
}
