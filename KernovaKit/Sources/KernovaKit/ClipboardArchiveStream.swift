import AppleArchive
import Foundation
import System

/// Why an extract was stopped by the consumer rather than by the archive.
enum ClipboardArchiveOutputRefusal: Equatable, Sendable {
    /// The staging volume no longer has room for the payload being written.
    case diskFull
    /// The payload outgrew the size the offer advertised for it.
    case overAdvertisedSize
}

/// Why a streamed archive stopped.
enum ClipboardArchiveStreamError: Error, Equatable {
    /// A seek or random-access operation on a purely sequential stream.
    ///
    /// AppleArchive drives both pipelines here with sequential reads and writes
    /// only; anything else means the codec wants a seekable stream, which the
    /// chunk transport cannot be.
    case unsupportedOperation
    /// Bytes were offered after the stream had already ended.
    case streamClosed
    /// The transfer was torn down — superseded, aborted, or the channel closed.
    case cancelled
    /// The consumer stopped the extract: what it was about to write is more than
    /// it agreed to take.
    case outputRefused(ClipboardArchiveOutputRefusal)
}

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
/// its work — after which further writes are accepted and dropped rather than
/// refused, since there is no longer anything they could break.
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
    /// Accepted and discarded once `complete()` has been called.
    ///
    /// - Throws: the failure that ended the pipe, or
    ///   ``ClipboardArchiveStreamError/streamClosed`` after `finish()`.
    func write(_ data: Data) throws {
        guard !data.isEmpty else { return }
        condition.lock()
        defer { condition.unlock() }
        while pendingBytes >= capacity, failure == nil, !finished {
            condition.wait()
        }
        if let failure { throw failure }
        guard !completed else { return }
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
    /// a parked writer wakes, and every write from here on is accepted and
    /// dropped instead of refused.
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

// MARK: - AppleArchive stream adapters

/// An AppleArchive stream that moves bytes in one direction only.
///
/// The defaults below are what keep each adapter to the single method it really
/// implements; everything else is a hard error, because a codec asking a chunk
/// transport to seek cannot be served.
///
/// `close()` deliberately does **not** end the pipe. AppleArchive surfaces an
/// encode failure only from the stream closes, so end of stream has to be
/// declared by the driver *after* every close has been checked — otherwise the
/// reader can see a clean end of stream for an archive whose final flush failed.
protocol ClipboardSequentialArchiveStream: ArchiveByteStreamProtocol, AnyObject {
    /// The pipe this adapter reads from or writes to.
    var pipe: ClipboardArchiveBytePipe { get }
}

extension ClipboardSequentialArchiveStream {
    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        throw ClipboardArchiveStreamError.unsupportedOperation
    }

    func write(from buffer: UnsafeRawBufferPointer) throws -> Int {
        throw ClipboardArchiveStreamError.unsupportedOperation
    }

    func read(into buffer: UnsafeMutableRawBufferPointer, atOffset offset: Int64) throws -> Int {
        throw ClipboardArchiveStreamError.unsupportedOperation
    }

    func write(from buffer: UnsafeRawBufferPointer, atOffset offset: Int64) throws -> Int {
        throw ClipboardArchiveStreamError.unsupportedOperation
    }

    func seek(toOffset offset: Int64, relativeTo origin: FileDescriptor.SeekOrigin) throws -> Int64 {
        throw ClipboardArchiveStreamError.unsupportedOperation
    }

    func close() throws {}

    func cancel() {
        pipe.fail(ClipboardArchiveStreamError.cancelled)
    }
}

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
}

/// A transparent stage that forwards to `upstream` and counts the bytes crossing
/// it.
///
/// Interposed between the encode/decode stage and the compression stage, so what
/// it counts is **uncompressed** archive bytes — the unit the offer's figure,
/// the paste ceiling and the free-space guard are all expressed in. Compressed
/// wire bytes answer none of those questions: compression can reach ~100:1 on
/// repetitive data, so a guard paced by them admits ~100× the payload it
/// thinks it does.
///
/// Every operation forwards, including the random-access ones: staying
/// transparent means an unexpected seek from the codec still works and only
/// makes the count approximate, instead of failing a transfer.
final class ClipboardArchiveCountingStream: ArchiveByteStreamProtocol, @unchecked Sendable {
    private let upstream: ArchiveByteStream
    /// Called once the running total has advanced by at least `pacingBytes`.
    ///
    /// Throwing from it stops the pipeline.
    private let onAdvance: ((Int) throws -> Void)?
    private let pacingBytes: Int

    private let lock = NSLock()
    private var total = 0
    private var reportedAt = 0

    /// Total bytes forwarded so far.
    var byteCount: Int { lock.withLock { total } }

    init(
        upstream: ArchiveByteStream, pacingBytes: Int = 1 << 20,
        onAdvance: ((Int) throws -> Void)? = nil
    ) {
        self.upstream = upstream
        self.pacingBytes = max(1, pacingBytes)
        self.onAdvance = onAdvance
    }

    private func advance(_ count: Int) throws {
        let due: Int? = lock.withLock {
            total += count
            guard total - reportedAt >= pacingBytes else { return nil }
            reportedAt = total
            return total
        }
        if let due { try onAdvance?(due) }
    }

    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        let count = try upstream.read(into: buffer)
        try advance(count)
        return count
    }

    func write(from buffer: UnsafeRawBufferPointer) throws -> Int {
        // Forward the whole buffer: a short write here would truncate the archive
        // exactly as one to the pipe would.
        var written = 0
        while written < buffer.count {
            let slice = UnsafeRawBufferPointer(rebasing: buffer[written...])
            let count = try upstream.write(from: slice)
            guard count > 0 else { throw ClipboardArchiveStreamError.streamClosed }
            written += count
        }
        try advance(written)
        return written
    }

    func read(into buffer: UnsafeMutableRawBufferPointer, atOffset offset: Int64) throws -> Int {
        try upstream.read(into: buffer, atOffset: offset)
    }

    func write(from buffer: UnsafeRawBufferPointer, atOffset offset: Int64) throws -> Int {
        try upstream.write(from: buffer, atOffset: offset)
    }

    func seek(toOffset offset: Int64, relativeTo origin: FileDescriptor.SeekOrigin) throws -> Int64 {
        try upstream.seek(toOffset: offset, relativeTo: origin)
    }

    func cancel() { upstream.cancel() }

    /// A no-op for the same reason the pipe adapters' is: the driver owns when
    /// the stack is torn down and in what order.
    func close() throws {}
}

// MARK: - Pipeline scaffolding

/// A lock-guarded counter shared between an archive pipeline's worker thread and
/// whoever reads its progress.
private final class ArchiveByteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0
    var value: Int {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// The consumer's own reason for stopping a pipeline, kept apart from whatever
/// the archive reports.
///
/// AppleArchive wraps an error thrown out of a stream callback in one of its
/// own, so the reason the *consumer* refused would otherwise reach the caller as
/// a generic archive failure — and a refusal has to be reported as what it is.
private final class ArchiveRefusalBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Error?
    var value: Error? {
        get { lock.withLock { stored } }
        set { lock.withLock { if stored == nil { stored = newValue } } }
    }
}

/// Collects the first failure raised while closing a stack of archive streams.
///
/// A close failure **is** a failed archive: AppleArchive reports a failed write
/// from `close()` and not from the write call, so swallowing one hands out a
/// silently truncated archive.
private struct ArchiveCloseTracker {
    private(set) var failure: Error?

    mutating func close(_ body: () throws -> Void) {
        do {
            try body()
        } catch {
            if failure == nil { failure = error }
        }
    }
}

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
        capacityBytes: Int = ClipboardStreamTuning.defaultWindowBytes
    ) {
        let pipe = ClipboardArchiveBytePipe(capacity: capacityBytes)
        self.pipe = pipe
        let outcome = self.outcome
        let counted = self.counted
        let queue = DispatchQueue(
            label: "app.kernova.clipboard.archive-encode.\(label)", qos: .userInitiated)
        queue.async {
            let failure = Self.encode(source, into: pipe, counted: counted)
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

    /// Runs the encode pipeline, returning the failure that ended it.
    ///
    /// Streams close in reverse creation order. The `defer`s belong to the `do`
    /// block, not to this function, so every close has already run and recorded
    /// itself by the time the result below is computed.
    private static func encode(
        _ source: ClipboardArchiveSource, into pipe: ClipboardArchiveBytePipe,
        counted: ArchiveByteCounter
    ) -> Error? {
        var closes = ArchiveCloseTracker()
        var failure: Error?
        do {
            guard
                let writeStream = ArchiveByteStream.customStream(
                    instance: ClipboardArchivePipeSink(pipe: pipe))
            else { throw ClipboardArchive.ArchiveError.openWriteStream }
            defer { closes.close { try writeStream.close() } }

            guard
                let compressStream = ArchiveByteStream.compressionStream(
                    using: .lz4, writingTo: writeStream)
            else { throw ClipboardArchive.ArchiveError.openCompressionStream }
            defer { closes.close { try compressStream.close() } }

            // Above the compressor, so what it sees is the uncompressed archive.
            // Unpaced, because the closure is a store and the count is read as a
            // live figure — the sender's ceiling is enforced against it, and a
            // paced snapshot would sit a whole quantum of payload behind.
            let counter = ClipboardArchiveCountingStream(
                upstream: compressStream, pacingBytes: 1
            ) { total in
                counted.value = total
            }
            guard let countedStream = ArchiveByteStream.customStream(instance: counter) else {
                throw ClipboardArchive.ArchiveError.openWriteStream
            }
            defer {
                closes.close { try countedStream.close() }
                counted.value = counter.byteCount
            }

            guard let encodeStream = ArchiveStream.encodeStream(writingTo: countedStream)
            else { throw ClipboardArchive.ArchiveError.openEncodeStream }
            defer { closes.close { try encodeStream.close() } }

            switch source {
            case .directory(let url):
                guard let keySet = ArchiveHeader.FieldKeySet(ClipboardArchive.fieldKeys)
                else { throw ClipboardArchive.ArchiveError.invalidFieldKeySet }
                try encodeStream.writeDirectoryContents(
                    archiveFrom: FilePath(url.path), keySet: keySet)
            case .file(let url, let name, let byteCount):
                try writeFileEntry(url, name: name, byteCount: byteCount, to: encodeStream)
            case .blob(let data, let name):
                try writeBlobEntry(data, name: name, to: encodeStream)
            }
        } catch {
            failure = error
        }
        // The pipe's own failure outranks a pipeline that returned normally: a
        // transport that died mid-archive can leave the encode looking
        // successful.
        return failure ?? closes.failure ?? pipe.failureError
    }

    /// The largest read issued against a file source, and the largest piece a
    /// blob is handed to the encoder in: 4 MiB.
    ///
    /// Big enough that the device, not the syscall, is the cost — kernel
    /// readahead overlaps the next block's I/O with this one's encode.
    private static let fileReadBlockSize = 4 * 1024 * 1024

    /// Writes one regular-file entry named `name` carrying exactly `byteCount`
    /// bytes of the file at `url`, with the attribute fields
    /// `writeDirectoryContents` gives an entry of the archive's key set.
    ///
    /// The file is opened and read here — the one place a single-file archive
    /// touches the volume — so the read policy is this method's: plain, cached
    /// reads in `fileReadBlockSize` blocks, the policy AppleArchive itself
    /// applies to a folder's entries.
    private static func writeFileEntry(
        _ url: URL, name: String, byteCount: Int, to encodeStream: ArchiveStream
    ) throws {
        let descriptor = Darwin.open(url.path, O_RDONLY)
        guard descriptor >= 0 else { throw ClipboardArchive.ArchiveError.sourceRead }
        defer { Darwin.close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG else {
            throw ClipboardArchive.ArchiveError.sourceRead
        }
        let header = ArchiveHeader()
        header.append(
            .uint(key: .init("TYP"), value: UInt64(ArchiveHeader.EntryType.regularFile.rawValue)))
        header.append(.string(key: .init("PAT"), value: name))
        header.append(.uint(key: .init("UID"), value: UInt64(status.st_uid)))
        header.append(.uint(key: .init("GID"), value: UInt64(status.st_gid)))
        header.append(.uint(key: .init("MOD"), value: UInt64(status.st_mode & 0o7777)))
        // Immutability stays behind: a Finder-locked source would otherwise
        // extract as a locked staging file that neither a move into its final
        // destination nor generation cleanup can touch.
        let flags = UInt64(status.st_flags & ~UInt32(UF_IMMUTABLE | SF_IMMUTABLE | UF_APPEND | SF_APPEND))
        header.append(.uint(key: .init("FLG"), value: flags))
        header.append(.timespec(key: .init("MTM"), value: status.st_mtimespec))
        // `CTM` is the entry's creation time (AADefs.h), not the inode change time.
        header.append(.timespec(key: .init("CTM"), value: status.st_birthtimespec))
        header.append(.blob(key: .init("DAT"), size: UInt64(byteCount)))
        try encodeStream.writeHeader(header)

        var remaining = byteCount
        let buffer = UnsafeMutableRawBufferPointer.allocate(
            byteCount: min(fileReadBlockSize, max(1, byteCount)), alignment: 16)
        defer { buffer.deallocate() }
        while remaining > 0 {
            let got = Darwin.read(descriptor, buffer.baseAddress, min(buffer.count, remaining))
            // Zero is the file ending before the byte count its offer declared;
            // negative is a read error. Both would leave the entry short of the
            // size its header declared.
            guard got > 0 else { throw ClipboardArchive.ArchiveError.sourceRead }
            try encodeStream.writeBlob(
                key: .init("DAT"), from: UnsafeRawBufferPointer(rebasing: buffer[..<got]))
            remaining -= got
        }
    }

    /// Writes one regular-file entry named `name` carrying `data`, with an
    /// owner-writable mode and the current time — resident bytes have no
    /// attributes of their own to preserve.
    private static func writeBlobEntry(_ data: Data, name: String, to encodeStream: ArchiveStream)
        throws
    {
        var now = timespec()
        clock_gettime(CLOCK_REALTIME, &now)
        let header = ArchiveHeader()
        header.append(
            .uint(key: .init("TYP"), value: UInt64(ArchiveHeader.EntryType.regularFile.rawValue)))
        header.append(.string(key: .init("PAT"), value: name))
        header.append(.uint(key: .init("MOD"), value: 0o644))
        header.append(.timespec(key: .init("MTM"), value: now))
        header.append(.timespec(key: .init("CTM"), value: now))
        header.append(.blob(key: .init("DAT"), size: UInt64(data.count)))
        try encodeStream.writeHeader(header)
        var offset = data.startIndex
        while offset < data.endIndex {
            let end = min(offset + fileReadBlockSize, data.endIndex)
            try data[offset..<end].withUnsafeBytes { piece in
                try encodeStream.writeBlob(key: .init("DAT"), from: piece)
            }
            offset = end
        }
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
    public var writeErrorCode: String { "extract.error" }

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
        capacityBytes: Int = ClipboardStreamTuning.defaultWindowBytes,
        pacingBytes: Int = ClipboardStreamTuning.defaultWindowBytes,
        onOutputAdvanced: (@Sendable (Int) throws -> Void)? = nil
    ) {
        self.destinationURL = destinationURL
        let pipe = ClipboardArchiveBytePipe(capacity: capacityBytes)
        self.pipe = pipe
        let outcome = self.outcome
        let counted = self.counted
        let refusal = self.refusal
        // Remember a refusal on the way out: the archive will rewrap it, and the
        // caller needs to know the volume filled or the payload outgrew its
        // offer, not merely that the extract failed.
        let guarded: (@Sendable (Int) throws -> Void)?
        if let onOutputAdvanced {
            guarded = { total in
                do {
                    try onOutputAdvanced(total)
                } catch {
                    refusal.value = error
                    throw error
                }
            }
        } else {
            guarded = nil
        }
        let queue = DispatchQueue(
            label: "app.kernova.clipboard.archive-extract.\(label)", qos: .userInitiated)
        queue.async {
            let failure = Self.extract(
                from: pipe, into: destinationURL, counted: counted, pacingBytes: pacingBytes,
                onOutputAdvanced: guarded)
            // Both endings wake a writer parked on a pipeline that has stopped
            // consuming, and differ in what a *later* write means: after a
            // failure it must be refused, but after a complete extract the
            // archive is already unpacked, so trailing bytes are dropped rather
            // than made to fail a good transfer. Dropping them loses no integrity
            // check — the receiver takes the digest over what arrives on the
            // wire, outside this sink.
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
    /// accepted and dropped, not refused.
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

    /// Runs the extract pipeline, returning the failure that ended it.
    ///
    /// Same close discipline, and same scoping, as the encode side: streams close
    /// in reverse creation order when the `do` block exits, so a close failure is
    /// recorded before the result below is computed.
    private static func extract(
        from pipe: ClipboardArchiveBytePipe, into destinationURL: URL, counted: ArchiveByteCounter,
        pacingBytes: Int, onOutputAdvanced: (@Sendable (Int) throws -> Void)?
    ) -> Error? {
        var closes = ArchiveCloseTracker()
        var failure: Error?
        do {
            guard
                let readStream = ArchiveByteStream.customStream(
                    instance: ClipboardArchivePipeSource(pipe: pipe))
            else { throw ClipboardArchive.ArchiveError.openReadStream }
            defer { closes.close { try readStream.close() } }

            guard
                let decompressStream = ArchiveByteStream.decompressionStream(
                    readingFrom: readStream)
            else { throw ClipboardArchive.ArchiveError.openDecompressionStream }
            defer { closes.close { try decompressStream.close() } }

            // Below the decompressor, so what it sees — and what the guard is
            // paced by — is the uncompressed payload about to be written.
            let counter = ClipboardArchiveCountingStream(
                upstream: decompressStream, pacingBytes: pacingBytes
            ) { total in
                counted.value = total
                try onOutputAdvanced?(total)
            }
            guard let countedStream = ArchiveByteStream.customStream(instance: counter) else {
                throw ClipboardArchive.ArchiveError.openReadStream
            }
            defer {
                closes.close { try countedStream.close() }
                counted.value = counter.byteCount
            }

            guard let decodeStream = ArchiveStream.decodeStream(readingFrom: countedStream)
            else { throw ClipboardArchive.ArchiveError.openDecodeStream }
            defer { closes.close { try decodeStream.close() } }

            // Ownership in the entries is the source's; the unprivileged
            // receiver cannot `chown` to another account, and a file owned by
            // one — `/etc/hosts`, another user's document — must still extract.
            guard
                let extractStream = ArchiveStream.extractStream(
                    extractingTo: FilePath(destinationURL.path), flags: .ignoreOperationNotPermitted)
            else { throw ClipboardArchive.ArchiveError.openExtractStream }
            defer { closes.close { try extractStream.close() } }

            _ = try ArchiveStream.process(readingFrom: decodeStream, writingTo: extractStream)
        } catch {
            failure = error
        }
        return failure ?? closes.failure
    }
}
