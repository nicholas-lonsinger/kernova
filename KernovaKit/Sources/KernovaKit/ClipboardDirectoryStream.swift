import AppleArchive
import Foundation
import System

/// Why a streamed directory archive stopped.
public enum ClipboardArchiveStreamError: Error, Equatable {
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
/// Either side ends the pipe — `finish()` for a clean end of stream, `fail(_:)`
/// to abandon it — and both endings wake the other side at once, which is what
/// lets an abort unwind an archive pipeline parked in a callback that has no
/// timeout of its own.
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
        guard let base = buffer.baseAddress, !buffer.isEmpty else { return 0 }
        condition.lock()
        defer { condition.unlock() }
        while pendingBytes == 0, failure == nil, !finished {
            condition.wait()
        }
        if let failure { throw failure }
        guard pendingBytes > 0 else { return 0 }
        var copied = 0
        while copied < buffer.count, let head = chunks.first {
            let take = min(head.count - headOffset, buffer.count - copied)
            head.withUnsafeBytes { raw in
                guard let source = raw.baseAddress else { return }
                base.advanced(by: copied).copyMemory(
                    from: source.advanced(by: headOffset), byteCount: take)
            }
            copied += take
            headOffset += take
            if headOffset == head.count {
                chunks.removeFirst()
                headOffset = 0
            }
        }
        pendingBytes -= copied
        condition.broadcast()
        return copied
    }

    /// Removes up to `count` bytes, parking while the pipe is empty.
    ///
    /// Returns an empty `Data` at end of stream.
    ///
    /// - Throws: the failure that ended the pipe.
    func read(upTo count: Int) throws -> Data {
        guard count > 0 else { return Data() }
        condition.lock()
        defer { condition.unlock() }
        while pendingBytes == 0, failure == nil, !finished {
            condition.wait()
        }
        if let failure { throw failure }
        guard pendingBytes > 0 else { return Data() }
        var result = Data()
        result.reserveCapacity(min(count, pendingBytes))
        while result.count < count, let head = chunks.first {
            let take = min(head.count - headOffset, count - result.count)
            let start = head.index(head.startIndex, offsetBy: headOffset)
            result.append(head[start..<head.index(start, offsetBy: take)])
            headOffset += take
            if headOffset == head.count {
                chunks.removeFirst()
                headOffset = 0
            }
        }
        pendingBytes -= result.count
        condition.broadcast()
        return result
    }

    /// Ends the stream cleanly: the reader drains what is left and then sees end
    /// of stream.
    func finish() {
        condition.lock()
        finished = true
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

/// Write-only sequential `ArchiveByteStreamProtocol` handing every encoded byte
/// to a ``ClipboardArchiveBytePipe``.
///
/// `write` accepts the **whole** buffer before returning `buffer.count`:
/// AppleArchive never re-offers a tail a short write left behind, so a partial
/// accept silently truncates the archive. The pipe's write is all-or-nothing,
/// which is what makes that hold.
///
/// `close()` deliberately does **not** end the pipe. AppleArchive surfaces an
/// encode failure only from the stream closes, so end of stream has to be
/// declared by the driver *after* every close has been checked — otherwise the
/// reader can see a clean end of stream for an archive whose final flush failed.
final class ClipboardArchivePipeSink: ArchiveByteStreamProtocol, @unchecked Sendable {
    private let pipe: ClipboardArchiveBytePipe

    init(pipe: ClipboardArchiveBytePipe) {
        self.pipe = pipe
    }

    func write(from buffer: UnsafeRawBufferPointer) throws -> Int {
        try pipe.write(buffer)
        return buffer.count
    }

    func close() throws {}

    func cancel() {
        pipe.fail(ClipboardArchiveStreamError.cancelled)
    }

    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
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
}

/// Read-only sequential `ArchiveByteStreamProtocol` pulling archive bytes out of
/// a ``ClipboardArchiveBytePipe``.
///
/// `close()` is a no-op for the same reason as the sink's: the pipe's ends are
/// declared by the driver, not by the codec tearing its streams down.
final class ClipboardArchivePipeSource: ArchiveByteStreamProtocol, @unchecked Sendable {
    private let pipe: ClipboardArchiveBytePipe

    init(pipe: ClipboardArchiveBytePipe) {
        self.pipe = pipe
    }

    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        try pipe.read(into: buffer)
    }

    func close() throws {}

    func cancel() {
        pipe.fail(ClipboardArchiveStreamError.cancelled)
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
}

// MARK: - Pipeline outcome

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

/// Streams a source directory as LZFSE archive bytes, with no archive ever
/// landing on disk.
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
public final class ClipboardDirectoryArchiveReader: @unchecked Sendable {
    private let pipe: ClipboardArchiveBytePipe
    private let outcome = ClipboardArchivePipelineOutcome()

    /// Starts archiving `directoryURL` immediately.
    ///
    /// - Parameters:
    ///   - directoryURL: the source folder; its entries are stored relative to
    ///     it, so the folder's own name is not embedded.
    ///   - label: distinguishes this transfer's worker queue in a stack trace.
    ///   - capacityBytes: how far the encoder may run ahead of the transport.
    public init(
        directoryURL: URL, label: String,
        capacityBytes: Int = ClipboardStreamTuning.defaultWindowBytes
    ) {
        let pipe = ClipboardArchiveBytePipe(capacity: capacityBytes)
        self.pipe = pipe
        let outcome = self.outcome
        let queue = DispatchQueue(
            label: "app.kernova.clipboard.archive-encode.\(label)", qos: .userInitiated)
        queue.async {
            let failure = Self.encode(directoryAt: directoryURL, into: pipe)
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
    /// Idempotent, and safe to call from any thread — including after the archive
    /// has already been read to its end.
    public func cancel() {
        pipe.fail(ClipboardArchiveStreamError.cancelled)
    }

    /// Runs the encode pipeline, returning the failure that ended it.
    ///
    /// Streams close in reverse creation order, and a close failure **is** a
    /// failed archive: AppleArchive reports a failed write from `close()` and not
    /// from `writeDirectoryContents`, so swallowing one hands out a silently
    /// truncated archive.
    private static func encode(directoryAt directoryURL: URL, into pipe: ClipboardArchiveBytePipe)
        -> Error?
    {
        var closeFailure: Error?
        var failure: Error?
        func recordClose(_ close: () throws -> Void) {
            do {
                try close()
            } catch {
                if closeFailure == nil { closeFailure = error }
            }
        }
        do {
            guard
                let writeStream = ArchiveByteStream.customStream(
                    instance: ClipboardArchivePipeSink(pipe: pipe))
            else { throw ClipboardDirectoryArchive.ArchiveError.openWriteStream }
            defer { recordClose { try writeStream.close() } }

            guard
                let compressStream = ArchiveByteStream.compressionStream(
                    using: .lzfse, writingTo: writeStream)
            else { throw ClipboardDirectoryArchive.ArchiveError.openCompressionStream }
            defer { recordClose { try compressStream.close() } }

            guard let encodeStream = ArchiveStream.encodeStream(writingTo: compressStream)
            else { throw ClipboardDirectoryArchive.ArchiveError.openEncodeStream }
            defer { recordClose { try encodeStream.close() } }

            guard let keySet = ArchiveHeader.FieldKeySet(ClipboardDirectoryArchive.fieldKeys)
            else { throw ClipboardDirectoryArchive.ArchiveError.invalidFieldKeySet }

            try encodeStream.writeDirectoryContents(
                archiveFrom: FilePath(directoryURL.path), keySet: keySet)
        } catch {
            failure = error
        }
        // The pipe's own failure outranks a pipeline that returned normally: a
        // transport that died mid-archive can leave `writeDirectoryContents`
        // looking successful.
        return failure ?? closeFailure ?? pipe.failureError
    }
}

// MARK: - Consumer

/// A `StagingSink` that extracts a directory archive **as it arrives**, rather
/// than spooling the archive and unpacking it afterwards.
///
/// Bytes written here feed an AppleArchive extract pipeline running on its own
/// queue, which writes the tree straight into `destinationURL`. `write` parks
/// while the pipeline is more than a window behind, so the receiver's ack — sent
/// once `write` returns — follows extraction rather than arrival, and memory
/// stays bounded however large the tree is.
///
/// A streamed extract has always written part of the destination tree by the time
/// anything can be verified, so **every** failure path removes it: `commit()`
/// deletes the tree when the pipeline failed, and `abort()` deletes it outright.
public final class ClipboardDirectoryExtractSink: StagingSink, @unchecked Sendable {
    /// The folder the tree is extracted into — the URL a paste is served.
    public let destinationURL: URL

    private let pipe: ClipboardArchiveBytePipe
    private let outcome = ClipboardArchivePipelineOutcome()
    private let terminalLock = NSLock()
    private var terminal = false

    /// Opens the extract pipeline, which begins consuming as soon as bytes are
    /// written.
    ///
    /// - Parameters:
    ///   - destinationURL: an existing empty directory to extract into.
    ///   - label: distinguishes this transfer's worker queue in a stack trace.
    ///   - capacityBytes: how far arriving bytes may run ahead of extraction.
    public init(
        destinationURL: URL, label: String,
        capacityBytes: Int = ClipboardStreamTuning.defaultWindowBytes
    ) {
        self.destinationURL = destinationURL
        let pipe = ClipboardArchiveBytePipe(capacity: capacityBytes)
        self.pipe = pipe
        let outcome = self.outcome
        let queue = DispatchQueue(
            label: "app.kernova.clipboard.archive-extract.\(label)", qos: .userInitiated)
        queue.async {
            let failure = Self.extract(from: pipe, into: destinationURL)
            // Wake a writer parked on a pipeline that has stopped consuming,
            // rather than let it block until the transfer's own watchdog fires.
            pipe.fail(failure ?? ClipboardArchiveStreamError.streamClosed)
            outcome.complete(failure)
        }
    }

    /// Hands `data` to the extract pipeline, parking while it is a window behind.
    ///
    /// - Throws: whatever failed the pipeline, so the transfer aborts on the
    ///   receiver's own write lane instead of running to completion over a tree
    ///   that was never written.
    public func write(_ data: Data) throws {
        try pipe.write(data)
    }

    /// Ends the stream, waits for the pipeline to drain, and returns the
    /// extracted folder.
    ///
    /// - Throws: whatever failed the pipeline — a truncated or corrupt archive, or
    ///   the volume filling mid-extract. The partial tree is removed first.
    @discardableResult
    public func commit() throws -> URL {
        guard claimTerminal() else { return destinationURL }
        pipe.finish()
        if let failure = outcome.wait() {
            try? FileManager.default.removeItem(at: destinationURL)
            throw failure
        }
        return destinationURL
    }

    /// Wakes a writer parked in `write(_:)` and stops the pipeline, without
    /// waiting for it to unwind.
    ///
    /// Idempotent, and safe from any thread. The tree is removed by `abort()`,
    /// which can then run on the woken lane rather than queue behind it.
    public func cancel() {
        pipe.fail(ClipboardArchiveStreamError.cancelled)
    }

    /// Tears the pipeline down and removes the partial tree.
    ///
    /// Idempotent, and a no-op once `commit()` has succeeded.
    public func abort() {
        guard claimTerminal() else { return }
        pipe.fail(ClipboardArchiveStreamError.cancelled)
        _ = outcome.wait()
        try? FileManager.default.removeItem(at: destinationURL)
    }

    private func claimTerminal() -> Bool {
        terminalLock.withLock {
            if terminal { return false }
            terminal = true
            return true
        }
    }

    /// Runs the extract pipeline, returning the failure that ended it.
    ///
    /// Same close discipline as the encode side: streams close in reverse
    /// creation order and a close failure is a failed extract.
    private static func extract(from pipe: ClipboardArchiveBytePipe, into destinationURL: URL)
        -> Error?
    {
        var closeFailure: Error?
        var failure: Error?
        func recordClose(_ close: () throws -> Void) {
            do {
                try close()
            } catch {
                if closeFailure == nil { closeFailure = error }
            }
        }
        do {
            guard
                let readStream = ArchiveByteStream.customStream(
                    instance: ClipboardArchivePipeSource(pipe: pipe))
            else { throw ClipboardDirectoryArchive.ArchiveError.openReadStream }
            defer { recordClose { try readStream.close() } }

            guard
                let decompressStream = ArchiveByteStream.decompressionStream(
                    readingFrom: readStream)
            else { throw ClipboardDirectoryArchive.ArchiveError.openDecompressionStream }
            defer { recordClose { try decompressStream.close() } }

            guard let decodeStream = ArchiveStream.decodeStream(readingFrom: decompressStream)
            else { throw ClipboardDirectoryArchive.ArchiveError.openDecodeStream }
            defer { recordClose { try decodeStream.close() } }

            guard
                let extractStream = ArchiveStream.extractStream(
                    extractingTo: FilePath(destinationURL.path))
            else { throw ClipboardDirectoryArchive.ArchiveError.openExtractStream }
            defer { recordClose { try extractStream.close() } }

            _ = try ArchiveStream.process(readingFrom: decodeStream, writingTo: extractStream)
        } catch {
            failure = error
        }
        return failure ?? closeFailure
    }
}
