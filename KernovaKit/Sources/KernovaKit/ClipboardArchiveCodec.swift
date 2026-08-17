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
    /// only; anything else means the codec wants a seekable stream, which a
    /// socket cannot be.
    case unsupportedOperation
    /// Bytes were offered after the stream had already ended.
    case streamClosed
    /// The transfer was torn down — superseded, aborted, or the connection
    /// closed.
    case cancelled
    /// The consumer stopped the extract: what it was about to write is more than
    /// it agreed to take.
    case outputRefused(ClipboardArchiveOutputRefusal)
}

// MARK: - Stream adapters

/// An AppleArchive stream that moves bytes in one direction only.
///
/// The defaults below are what keep each adapter to the single method it really
/// implements; everything else is a hard error, because a codec asking a
/// sequential transport to seek cannot be served.
///
/// `close()` deliberately does **nothing**. AppleArchive surfaces an encode
/// failure only from the stream closes, so end of stream has to be declared by
/// the driver *after* every close has been checked — otherwise a consumer can
/// see a clean end of stream for an archive whose final flush failed.
protocol ClipboardSequentialArchiveStream: ArchiveByteStreamProtocol, AnyObject {}

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

    func cancel() {}
}

/// Write-only adapter handing every encoded byte straight to a data connection.
final class ClipboardArchivePayloadSink: ClipboardSequentialArchiveStream, @unchecked Sendable {
    private let writer: ClipboardPayloadWriter

    init(writer: ClipboardPayloadWriter) {
        self.writer = writer
    }

    func write(from buffer: UnsafeRawBufferPointer) throws -> Int {
        try writer.write(buffer)
        return buffer.count
    }
}

/// Read-only adapter pulling archive bytes straight off a data connection.
final class ClipboardArchivePayloadSource: ClipboardSequentialArchiveStream, @unchecked Sendable {
    private let reader: ClipboardPayloadReader

    init(reader: ClipboardPayloadReader) {
        self.reader = reader
    }

    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        try reader.read(into: buffer)
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
        // Forward the whole buffer: a short write here would truncate the
        // archive exactly as one to the transport would.
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

    /// A no-op for the same reason the sequential adapters' is: the driver owns
    /// when the stack is torn down and in what order.
    func close() throws {}
}

// MARK: - Pipeline scaffolding

/// A lock-guarded counter shared between an archive pipeline and whoever reads
/// its progress.
final class ArchiveByteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0

    /// The running total.
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
final class ArchiveRefusalBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Error?

    /// The first refusal recorded, if any.
    var value: Error? {
        get { lock.withLock { stored } }
        set { lock.withLock { if stored == nil { stored = newValue } } }
    }

    /// Wraps `body` so the reason it throws for survives being rewrapped.
    func guarding(_ body: (@Sendable (Int) throws -> Void)?) -> (@Sendable (Int) throws -> Void)? {
        guard let body else { return nil }
        return { total in
            do {
                try body(total)
            } catch {
                self.value = error
                throw error
            }
        }
    }
}

/// Collects the first failure raised while closing a stack of archive streams.
///
/// A close failure **is** a failed archive: AppleArchive reports a failed write
/// from `close()` and not from the write call, so swallowing one hands out a
/// silently truncated archive.
struct ArchiveCloseTracker {
    private(set) var failure: Error?

    mutating func close(_ body: () throws -> Void) {
        do {
            try body()
        } catch {
            if failure == nil { failure = error }
        }
    }
}

// MARK: - Codec

/// The AppleArchive (LZ4) pipeline both directions of a clipboard transfer run,
/// with no archive ever landing on disk at either end.
///
/// Encoding drives a source — a folder's tree, one file, or resident bytes —
/// into a byte sink; extracting drives a byte source straight into a
/// destination directory. Neither side seeks, so a socket-backed stream is
/// admissible on both
/// (docs/research/2026-08-14-applearchive-uniform-transfer-container.md).
///
/// Never drive either from the main actor: both park on whatever the transport
/// is doing, and AppleArchive's callbacks have no timeout of their own.
enum ClipboardArchiveCodec {
    /// The largest read issued against a file source, and the largest piece a
    /// blob is handed to the encoder in: 4 MiB.
    ///
    /// Big enough that the device, not the syscall, is the cost — kernel
    /// readahead overlaps the next block's I/O with this one's encode.
    static let fileReadBlockSize = 4 * 1024 * 1024

    /// Encodes `source` into `sink`.
    ///
    /// Streams close in reverse creation order. The `defer`s belong to the `do`
    /// block, not to this function, so every close has already run and recorded
    /// itself by the time the result below is computed.
    ///
    /// - Parameters:
    ///   - source: what to encode.
    ///   - sink: where the compressed archive bytes go.
    ///   - counted: receives the running **uncompressed** total, the unit every
    ///     ceiling and readout is stated in.
    ///   - pacingBytes: how much accumulates between `onOutputAdvanced` calls.
    ///     `1` reports every write, which is what an unpaced ceiling needs.
    ///   - onOutputAdvanced: consulted with the running uncompressed total;
    ///     throwing from it stops the encode.
    /// - Returns: the failure that ended the encode, or `nil` when the whole
    ///   archive was written and every stream closed cleanly.
    static func encode<Sink: ArchiveByteStreamProtocol & AnyObject>(
        _ source: ClipboardArchiveSource, into sink: Sink,
        counted: ArchiveByteCounter, pacingBytes: Int = 1,
        onOutputAdvanced: (@Sendable (Int) throws -> Void)? = nil
    ) -> Error? {
        var closes = ArchiveCloseTracker()
        var failure: Error?
        do {
            guard let writeStream = ArchiveByteStream.customStream(instance: sink)
            else { throw ClipboardArchive.ArchiveError.openWriteStream }
            defer { closes.close { try writeStream.close() } }

            guard
                let compressStream = ArchiveByteStream.compressionStream(
                    using: .lz4, writingTo: writeStream)
            else { throw ClipboardArchive.ArchiveError.openCompressionStream }
            defer { closes.close { try compressStream.close() } }

            // Above the compressor, so what it sees is the uncompressed archive
            // — the unit the requester's ceiling and the progress readout are
            // both stated in.
            let counter = ClipboardArchiveCountingStream(
                upstream: compressStream, pacingBytes: pacingBytes
            ) { total in
                counted.value = total
                try onOutputAdvanced?(total)
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
        return failure ?? closes.failure
    }

    /// Extracts the archive `source` carries into `destinationURL`.
    ///
    /// Same close discipline, and same scoping, as the encode side.
    ///
    /// - Parameters:
    ///   - source: the arriving archive bytes.
    ///   - destinationURL: an existing empty directory to extract into. A
    ///     stopped extract leaves partial output behind for the caller to
    ///     remove.
    ///   - counted: receives the running **uncompressed** total.
    ///   - pacingBytes: output granularity at which `onOutputAdvanced` is
    ///     consulted, and so how far the extract can overrun a ceiling before
    ///     the next check catches it.
    ///   - onOutputAdvanced: the output guard; throwing from it stops the
    ///     extract.
    /// - Returns: the failure that ended the extract, or `nil` when the whole
    ///   archive was unpacked and every stream closed cleanly.
    static func extract<Source: ArchiveByteStreamProtocol & AnyObject>(
        from source: Source, into destinationURL: URL,
        counted: ArchiveByteCounter, pacingBytes: Int,
        onOutputAdvanced: (@Sendable (Int) throws -> Void)?
    ) -> Error? {
        var closes = ArchiveCloseTracker()
        var failure: Error?
        do {
            guard let readStream = ArchiveByteStream.customStream(instance: source)
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
                    extractingTo: FilePath(destinationURL.path),
                    selectUsing: clearImmutability, flags: .ignoreOperationNotPermitted)
            else { throw ClipboardArchive.ArchiveError.openExtractStream }
            defer { closes.close { try extractStream.close() } }

            _ = try ArchiveStream.process(readingFrom: decodeStream, writingTo: extractStream)
        } catch {
            failure = error
        }
        return failure ?? closes.failure
    }

    /// Writes one regular-file entry named `name` carrying exactly `byteCount`
    /// bytes of the file at `url`, with the attribute fields
    /// `writeDirectoryContents` gives an entry of the archive's key set.
    ///
    /// The file is opened and read here — the one place a single-file archive
    /// touches the volume — so the read policy is this method's: plain, cached
    /// reads in `fileReadBlockSize` blocks, the policy AppleArchive itself
    /// applies to a folder's entries.
    static func writeFileEntry(
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
        header.append(.uint(key: .init("FLG"), value: UInt64(status.st_flags)))
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
    static func writeBlobEntry(_ data: Data, name: String, to encodeStream: ArchiveStream) throws {
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

    /// Clears the immutable and append-only bits from each entry's flags as the
    /// extract applies them.
    ///
    /// Either bit blocks `unlink` on the entry *and* on every directory above
    /// it, so one locked entry makes `removeItem` fail for the whole extracted
    /// tree — taking out the generation sweep with it, and, since
    /// `ClipboardFileStaging.reclaimAll` is a single `removeItem` on the shared
    /// staging parent, every later reclaim of that parent too. The peer chooses
    /// what an entry's `FLG` carries, so the receiver is the only place the
    /// guarantee can hold; the sender writes the source's flags unaltered.
    ///
    /// Cleared here rather than off a walk of the finished tree because an
    /// extract that stops part-way removes its output immediately, leaving no
    /// point at which a walk could run.
    private static func clearImmutability(
        _: ArchiveHeader.EntryMessage, _: FilePath, _ data: ArchiveHeader.EntryFilterData?
    ) -> ArchiveHeader.EntryMessageStatus {
        if case .entryAttributes(let attributes)? = data, let flags = attributes.flg {
            attributes.flg =
                flags & ~UInt32(UF_IMMUTABLE | SF_IMMUTABLE | UF_APPEND | SF_APPEND)
        }
        return .ok
    }
}
