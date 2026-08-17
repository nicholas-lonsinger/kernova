import AppleArchive
import Foundation
import System
import os

// MARK: - Byte pipe

/// A bounded, blocking byte pipe between an AppleArchive stream callback and the
/// chunk transport.
///
/// One side appends bytes and parks while at least `capacity` of them are still
/// undelivered; the other drains them and parks while it is empty. That parking
/// *is* the flow control: on the sending side the encoder runs no further ahead
/// than the credit window allows, and on the receiving side an ack is only sent
/// once the extract pipeline has taken the bytes.
///
/// Three endings wake the other side at once, which is what lets an abort unwind
/// an archive pipeline parked in a callback that has no timeout of its own:
/// `finish()` declares a clean end of stream from the writing side, `fail(_:)`
/// abandons the pipe, and `complete()` reports that the reading side has finished
/// its work — after which one capacity's worth of further writes is accepted and
/// dropped rather than refused, since a straggling tail can break nothing, and
/// anything past that is refused.
///
/// `@unchecked Sendable`: every field is guarded by `condition`.
final class ClipboardArchiveBytePipe: @unchecked Sendable {
    private let condition = NSCondition()
    private let capacity: Int

    private var chunks: [Data] = []
    /// Bytes of `chunks.first` already handed out.
    private var headOffset = 0
    private var pendingBytes = 0
    private var finished = false
    /// Whether the reader finished its work successfully, so a later write has
    /// nothing left to feed.
    ///
    /// Implies `finished`.
    private var completed = false
    /// Bytes written since `complete()` and discarded, which `capacity` bounds.
    private var droppedBytes = 0
    private var failure: Error?

    /// - Parameter capacity: how many undelivered bytes park the writer. A single
    ///   write larger than this still goes through whole — parking a writer whose
    ///   buffer can never fit would deadlock the pipeline — so the peak held is
    ///   `capacity` plus one callback's buffer.
    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    /// Appends `data`, parking while the pipe is at capacity.
    ///
    /// Discarded once `complete()` has been called, up to `capacity` bytes in
    /// total; past that the writer is feeding a reader that finished long ago
    /// and is refused.
    ///
    /// - Throws: the failure that ended the pipe, or
    ///   ``ClipboardArchiveStreamError/streamClosed`` after `finish()` and past
    ///   the drop bound.
    func write(_ data: Data) throws {
        guard !data.isEmpty else { return }
        condition.lock()
        defer { condition.unlock() }
        while pendingBytes >= capacity, failure == nil, !finished {
            condition.wait()
        }
        if let failure { throw failure }
        if completed {
            // The tail a completed reader legitimately leaves unread is the
            // codec's own trailer — bytes, not a window's worth — so a peer
            // still streaming this far past a finished extract is sending
            // payload that no longer has anywhere to go. Counting cumulatively
            // keeps every write past the bound refused, not just the one that
            // crossed it.
            droppedBytes += data.count
            guard droppedBytes <= capacity else {
                throw ClipboardArchiveStreamError.streamClosed
            }
            return
        }
        guard !finished else { throw ClipboardArchiveStreamError.streamClosed }
        chunks.append(data)
        pendingBytes += data.count
        condition.broadcast()
    }

    /// Appends the bytes of a raw buffer, parking while the pipe is at capacity.
    func write(_ buffer: UnsafeRawBufferPointer) throws {
        guard !buffer.isEmpty else { return }
        try write(Data(buffer))
    }

    /// Fills `buffer` with as much as is available, parking while the pipe is
    /// empty.
    ///
    /// Returns 0 at end of stream.
    ///
    /// - Throws: the failure that ended the pipe.
    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        guard let destination = buffer.baseAddress else { return 0 }
        var copied = 0
        return try drain(upTo: buffer.count) { run in
            guard let source = run.baseAddress else { return }
            destination.advanced(by: copied).copyMemory(from: source, byteCount: run.count)
            copied += run.count
        }
    }

    /// Removes up to `count` bytes, parking while the pipe is empty.
    ///
    /// Returns an empty `Data` at end of stream.
    ///
    /// - Throws: the failure that ended the pipe.
    func read(upTo count: Int) throws -> Data {
        var result = Data()
        result.reserveCapacity(count)
        _ = try drain(upTo: count) { run in
            guard let source = run.baseAddress else { return }
            result.append(source.assumingMemoryBound(to: UInt8.self), count: run.count)
        }
        return result
    }

    /// Hands each contiguous run of up to `count` buffered bytes to `consume`,
    /// parking while the pipe is empty.
    ///
    /// The one place the chunk-consumption arithmetic lives: an off-by-one here
    /// silently corrupts archive bytes, so both readers share it and differ only
    /// in where they put the run.
    ///
    /// - Returns: bytes drained; 0 means end of stream.
    private func drain(upTo count: Int, into consume: (UnsafeRawBufferPointer) -> Void) throws
        -> Int
    {
        guard count > 0 else { return 0 }
        condition.lock()
        defer { condition.unlock() }
        while pendingBytes == 0, failure == nil, !finished {
            condition.wait()
        }
        if let failure { throw failure }
        guard pendingBytes > 0 else { return 0 }
        var drained = 0
        while drained < count, let head = chunks.first {
            let take = min(head.count - headOffset, count - drained)
            head.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                consume(UnsafeRawBufferPointer(start: base.advanced(by: headOffset), count: take))
            }
            drained += take
            headOffset += take
            if headOffset == head.count {
                chunks.removeFirst()
                headOffset = 0
            }
        }
        pendingBytes -= drained
        condition.broadcast()
        return drained
    }

    /// Ends the stream cleanly: the reader drains what is left and then sees end
    /// of stream.
    func finish() {
        condition.lock()
        finished = true
        condition.broadcast()
        condition.unlock()
    }

    /// Ends the stream from the *reading* side, which has finished successfully:
    /// a parked writer wakes, and the next `capacity` bytes written are dropped
    /// instead of refused.
    ///
    /// Distinct from `fail(_:)`, which reports that the pipeline gave up and so
    /// must keep refusing writes.
    func complete() {
        condition.lock()
        completed = true
        finished = true
        chunks.removeAll()
        headOffset = 0
        pendingBytes = 0
        condition.broadcast()
        condition.unlock()
    }

    /// Abandons the stream: both sides wake and throw `error`, and the buffered
    /// bytes are dropped.
    ///
    /// The first failure wins, so a late duplicate abort is harmless.
    func fail(_ error: Error) {
        condition.lock()
        if failure == nil { failure = error }
        finished = true
        chunks.removeAll()
        headOffset = 0
        pendingBytes = 0
        condition.broadcast()
        condition.unlock()
    }

    /// The failure that ended the pipe, if any.
    var failureError: Error? {
        condition.lock()
        defer { condition.unlock() }
        return failure
    }
}

// MARK: - Pipe stream adapters

/// Write-only adapter handing every encoded byte to the pipe.
///
/// `write` accepts the **whole** buffer before returning `buffer.count`:
/// AppleArchive never re-offers a tail a short write left behind, so a partial
/// accept silently truncates the archive. The pipe's write is all-or-nothing,
/// which is what makes that hold.
final class ClipboardArchivePipeSink: ClipboardSequentialArchiveStream, @unchecked Sendable {
    let pipe: ClipboardArchiveBytePipe

    init(pipe: ClipboardArchiveBytePipe) {
        self.pipe = pipe
    }

    func write(from buffer: UnsafeRawBufferPointer) throws -> Int {
        try pipe.write(buffer)
        return buffer.count
    }

    func cancel() {
        pipe.fail(ClipboardArchiveStreamError.cancelled)
    }
}

/// Read-only adapter pulling archive bytes out of the pipe.
final class ClipboardArchivePipeSource: ClipboardSequentialArchiveStream, @unchecked Sendable {
    let pipe: ClipboardArchiveBytePipe

    init(pipe: ClipboardArchiveBytePipe) {
        self.pipe = pipe
    }

    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        try pipe.read(into: buffer)
    }

    func cancel() {
        pipe.fail(ClipboardArchiveStreamError.cancelled)
    }
}

// MARK: - Pipeline scaffolding

/// The terminal state of one archive pipeline, published by its worker and
/// awaited by whoever tears the transfer down.
///
/// `wait()` is idempotent, so a `commit()` that already collected the outcome
/// and a later `abort()` both resolve.
private final class ClipboardArchivePipelineOutcome: @unchecked Sendable {
    private let condition = NSCondition()
    private var done = false
    private var error: Error?

    func complete(_ error: Error?) {
        condition.lock()
        if !done {
            done = true
            self.error = error
        }
        condition.broadcast()
        condition.unlock()
    }

    /// Blocks until the pipeline's worker has exited; returns its failure, if any.
    func wait() -> Error? {
        condition.lock()
        defer { condition.unlock() }
        while !done { condition.wait() }
        return error
    }
}

// MARK: - Producer

/// Streams a payload — a folder's tree, one file, or resident bytes — as LZ4
/// archive bytes, with no archive ever landing on disk.
///
/// The AppleArchive encode pipeline runs on its own queue and pushes into a
/// bounded pipe; the caller pulls chunks off the other end with `read(upTo:)`,
/// which parks it until bytes are available. Never drive this from the main
/// actor: both ends park, and AppleArchive's callbacks have no timeout.
///
/// An empty result from `read(upTo:)` is end of archive, and is reached **only**
/// when the whole pipeline — including every stream close, which is where
/// AppleArchive surfaces a failed write — succeeded. Any failure surfaces as a
/// throw instead, so a truncated archive can never be mistaken for a complete
/// one.
public final class ClipboardArchiveReader: @unchecked Sendable {
    private let pipe: ClipboardArchiveBytePipe
    private let outcome = ClipboardArchivePipelineOutcome()
    /// Counts uncompressed archive bytes, so a caller reporting progress has a
    /// figure in the same unit as the offer's figure.
    private let counted = ArchiveByteCounter()

    /// Uncompressed archive bytes encoded so far.
    ///
    /// The honest progress numerator: compressed wire bytes are in a different
    /// unit from the figure every readout's denominator comes from.
    public var uncompressedByteCount: Int { counted.value }

    /// Starts archiving `source` immediately.
    ///
    /// - Parameters:
    ///   - source: what to encode.
    ///   - label: distinguishes this transfer's worker queue in a stack trace.
    ///   - capacityBytes: how far the encoder may run ahead of the transport.
    public init(
        source: ClipboardArchiveSource, label: String,
        capacityBytes: Int = ClipboardStreamTuning.encodePipeBytes
    ) {
        let pipe = ClipboardArchiveBytePipe(capacity: capacityBytes)
        self.pipe = pipe
        let outcome = self.outcome
        let counted = self.counted
        let queue = DispatchQueue(
            label: "app.kernova.clipboard.archive-encode.\(label)", qos: .userInitiated)
        queue.async {
            // Begun and ended inside this block, so the interval never crosses a
            // thread: it is the encode worker's whole lifetime, which is what a
            // trace compares against the transport's own intervals.
            let interval = ClipboardSignposts.stages.beginInterval(
                "archive encode", id: ClipboardSignposts.stages.makeSignpostID())
            defer { ClipboardSignposts.stages.endInterval("archive encode", interval) }
            // The pipe's own failure outranks a pipeline that returned normally:
            // a transport that died mid-archive can leave the encode looking
            // successful.
            let failure =
                ClipboardArchiveCodec.encode(
                    source, into: ClipboardArchivePipeSink(pipe: pipe), counted: counted)
                ?? pipe.failureError
            // Declare the end of stream only after every close has been checked,
            // so the reader's end of stream means "complete and flushed".
            if let failure {
                pipe.fail(failure)
            } else {
                pipe.finish()
            }
            outcome.complete(failure)
        }
    }

    /// Pulls up to `count` archive bytes, parking until some are available.
    ///
    /// Returns an empty `Data` once the whole archive has been handed over.
    ///
    /// - Throws: whatever failed the encode pipeline or the transport.
    public func read(upTo count: Int) throws -> Data {
        try pipe.read(upTo: count)
    }

    /// Abandons the archive, unblocking the encode pipeline so its worker unwinds.
    ///
    /// Idempotent, and safe to call from any thread — including from an abort
    /// while another thread is parked in `read(upTo:)`, which is what makes that
    /// park cancellable.
    public func cancel() {
        pipe.fail(ClipboardArchiveStreamError.cancelled)
    }
}

// MARK: - Consumer

/// A `StagingSink` that extracts an archive **as it arrives**, rather than
/// spooling the archive and unpacking it afterwards.
///
/// Bytes written here feed an AppleArchive extract pipeline running on its own
/// queue, which writes the payload — a folder's tree, or a file's one entry —
/// straight into `destinationURL`. `write` parks while the pipeline is more than
/// a window behind, so the receiver's ack — sent once `write` returns — follows
/// extraction rather than arrival, and memory stays bounded however large the
/// payload is.
///
/// A streamed extract has always written part of the destination by the time
/// anything can be verified, so **every** failure path removes it: `commit()`
/// deletes the destination when the pipeline failed, and `abort()` deletes it
/// outright.
public final class ClipboardArchiveExtractSink: StagingSink, @unchecked Sendable {
    /// The directory the archive is extracted into.
    public let destinationURL: URL

    /// Which of the two mutually exclusive endings a caller claimed.
    private enum Terminal {
        case committed
        case aborted
    }

    private let pipe: ClipboardArchiveBytePipe
    private let outcome = ClipboardArchivePipelineOutcome()
    private let terminalLock = NSLock()
    private var terminal: Terminal?
    /// Set when this side stopped the extract, so the reason survives
    /// AppleArchive rewrapping it.
    private let refusal = ArchiveRefusalBox()
    /// Uncompressed archive bytes consumed — what the extract has written, near
    /// enough for a guard and a readout, and in the same unit as the offer's
    /// figure.
    private let counted = ArchiveByteCounter()

    /// Uncompressed archive bytes extracted so far.
    public var uncompressedByteCount: Int { counted.value }

    /// An extract failure names the extract, not a disk write.
    public var writeErrorCode: ClipboardStreamAbortCode { .extractError }

    /// Opens the extract pipeline, which begins consuming as soon as bytes are
    /// written.
    ///
    /// - Parameters:
    ///   - destinationURL: an existing empty directory to extract into.
    ///   - label: distinguishes this transfer's worker queue in a stack trace.
    ///   - capacityBytes: how far arriving bytes may run ahead of extraction.
    ///   - pacingBytes: how much output accumulates between `onOutputAdvanced`
    ///     calls.
    ///   - onOutputAdvanced: consulted with the running uncompressed total;
    ///     throwing from it stops the extract and removes the output. Runs on
    ///     the pipeline's own thread, so it must not touch a lane's state.
    public init(
        destinationURL: URL, label: String,
        capacityBytes: Int = ClipboardStreamTuning.extractPipeBytes,
        pacingBytes: Int = ClipboardStreamTuning.extractPacingBytes,
        onOutputAdvanced: (@Sendable (Int) throws -> Void)? = nil
    ) {
        self.destinationURL = destinationURL
        let pipe = ClipboardArchiveBytePipe(capacity: capacityBytes)
        self.pipe = pipe
        let outcome = self.outcome
        let counted = self.counted
        // Remember a refusal on the way out: the archive will rewrap it, and the
        // caller needs to know the volume filled or the payload outgrew its
        // offer, not merely that the extract failed.
        let guarded = refusal.guarding(onOutputAdvanced)
        let queue = DispatchQueue(
            label: "app.kernova.clipboard.archive-extract.\(label)", qos: .userInitiated)
        queue.async {
            let failure = ClipboardArchiveCodec.extract(
                from: ClipboardArchivePipeSource(pipe: pipe), into: destinationURL,
                counted: counted, pacingBytes: pacingBytes, onOutputAdvanced: guarded)
            // Both endings wake a writer parked on a pipeline that has stopped
            // consuming, and differ in what a *later* write means: after a
            // failure it must be refused, but after a complete extract the
            // archive is already unpacked, so a trailing tail is dropped rather
            // than made to fail a good transfer — bounded by the pipe's capacity,
            // since a peer streaming past that is holding the transfer open
            // rather than finishing one. Dropping the tail loses no integrity
            // check: the receiver takes the digest over what arrives on the wire,
            // outside this sink.
            if let failure {
                pipe.fail(failure)
            } else {
                pipe.complete()
            }
            outcome.complete(failure)
        }
    }

    /// Hands `data` to the extract pipeline, parking while it is a window behind.
    ///
    /// Bytes offered after the pipeline has unpacked the whole archive are
    /// dropped rather than refused, up to one window of them; past that the
    /// write is refused, so a peer cannot keep a finished transfer alive by
    /// streaming into it.
    ///
    /// - Throws: whatever failed the pipeline, so the transfer aborts on the
    ///   receiver's own write lane instead of running to completion over output
    ///   that was never written.
    public func write(_ data: Data) throws {
        do {
            try pipe.write(data)
        } catch {
            throw refusal.value ?? error
        }
    }

    /// Ends the stream, waits for the pipeline to drain, and returns the
    /// destination directory.
    ///
    /// Idempotent: a repeat commit reports the same outcome the first one did.
    ///
    /// - Throws: whatever failed the pipeline — a truncated or corrupt archive, or
    ///   the volume filling mid-extract. The partial output is removed first.
    ///   ``ClipboardArchiveStreamError/cancelled`` when `abort()` got there
    ///   first, since the directory this would otherwise name has been deleted.
    @discardableResult
    public func commit() throws -> URL {
        if let claimed = claimTerminal(.committed) {
            guard claimed == .committed else { throw ClipboardArchiveStreamError.cancelled }
            // Re-read the latched outcome rather than assume success: a first
            // commit that failed took the output with it, so handing back its
            // URL would name a directory that is gone.
            if let failure = outcome.wait() { throw refusal.value ?? failure }
            return destinationURL
        }
        pipe.finish()
        if let failure = outcome.wait() {
            try? FileManager.default.removeItem(at: destinationURL)
            throw refusal.value ?? failure
        }
        return destinationURL
    }

    /// Wakes a writer parked in `write(_:)` and stops the pipeline, without
    /// waiting for it to unwind.
    ///
    /// Idempotent, and safe from any thread. The output is removed by `abort()`,
    /// which can then run on the woken lane rather than queue behind it.
    public func cancel() {
        pipe.fail(ClipboardArchiveStreamError.cancelled)
    }

    /// Tears the pipeline down and removes the partial output.
    ///
    /// Idempotent, and a no-op once `commit()` has succeeded.
    public func abort() {
        guard claimTerminal(.aborted) == nil else { return }
        pipe.fail(ClipboardArchiveStreamError.cancelled)
        _ = outcome.wait()
        try? FileManager.default.removeItem(at: destinationURL)
    }

    /// Claims the terminal transition for `kind`, or reports which one was
    /// already claimed.
    ///
    /// The two endings are mutually exclusive rather than merely once-only:
    /// `abort()` deletes the output `commit()` would hand back, so a `commit()`
    /// that lost the race must not read as success.
    private func claimTerminal(_ kind: Terminal) -> Terminal? {
        terminalLock.withLock {
            if let terminal { return terminal }
            terminal = kind
            return nil
        }
    }
}
