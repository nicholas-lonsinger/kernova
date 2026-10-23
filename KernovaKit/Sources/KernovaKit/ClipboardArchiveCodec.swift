import AppleArchive
import Foundation
import KernovaSynchronization
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
/// `close()` does **nothing**. AppleArchive surfaces an encode failure only
/// from the stream closes, so end of stream has to be declared by the driver
/// *after* every close has been checked — otherwise a consumer can see a clean
/// end of stream for an archive whose final flush failed.
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
final class ClipboardArchivePayloadSink: ClipboardSequentialArchiveStream {
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
final class ClipboardArchivePayloadSource: ClipboardSequentialArchiveStream {
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
final class ClipboardArchiveCountingStream: ArchiveByteStreamProtocol {
    private let upstream: ArchiveByteStream
    /// Called once the running total has advanced by at least `pacingBytes`.
    ///
    /// Throwing from it stops the pipeline.
    private let onAdvance: ((Int) throws -> Void)?
    private let pacingBytes: Int

    private struct State {
        var total = 0
        var reportedAt = 0

        /// Adds `count` to the total, returning the new total when at least
        /// `pacingBytes` have accumulated since the last one returned.
        mutating func advance(by count: Int, pacingBytes: Int) -> Int? {
            total += count
            guard total - reportedAt >= pacingBytes else { return nil }
            reportedAt = total
            return total
        }
    }

    /// AppleArchive's worker thread advances it, and the caller's thread reads
    /// it after the codec returns, with no ordering documented between them.
    private let state = Locked(State())

    /// Total bytes forwarded so far.
    var byteCount: Int { state.withLock { $0.total } }

    init(
        upstream: ArchiveByteStream, pacingBytes: Int = 1 << 20,
        onAdvance: ((Int) throws -> Void)? = nil
    ) {
        self.upstream = upstream
        self.pacingBytes = max(1, pacingBytes)
        self.onAdvance = onAdvance
    }

    private func advance(_ count: Int) throws {
        let due = state.withLock { $0.advance(by: count, pacingBytes: pacingBytes) }
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

/// The consumer's own reason for stopping a pipeline, kept apart from whatever
/// the archive reports.
///
/// AppleArchive wraps an error thrown out of a stream callback in one of its
/// own, so the reason the *consumer* refused would otherwise reach the caller as
/// a generic archive failure — and a refusal has to be reported as what it is.
final class ArchiveRefusalBox: Sendable {
    private let first = Locked<(any Error)?>(nil)

    /// The first refusal recorded, if any.
    var recorded: (any Error)? { first.withLock { $0 } }

    /// Records `error`, unless a refusal was already recorded.
    func record(_ error: any Error) {
        first.withLock { first in
            if first == nil { first = error }
        }
    }

    /// Wraps `body` so the reason it throws for survives being rewrapped.
    func guarding(_ body: (@Sendable (Int) throws -> Void)?) -> (@Sendable (Int) throws -> Void)? {
        guard let body else { return nil }
        return { total in
            do {
                try body(total)
            } catch {
                self.record(error)
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
    /// - Returns: the failure that ended the encode — a
    ///   ``ClipboardSourceReadFailure`` naming the entry, relative to the
    ///   source, when the source could not be read — or `nil` when the whole
    ///   archive was written and every stream closed cleanly.
    static func encode<Sink: ArchiveByteStreamProtocol & AnyObject>(
        _ source: ClipboardArchiveSource, into sink: Sink,
        counted: Locked<Int>, pacingBytes: Int = 1,
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
                counted.withLock { $0 = total }
                try onOutputAdvanced?(total)
            }
            guard let countedStream = ArchiveByteStream.customStream(instance: counter) else {
                throw ClipboardArchive.ArchiveError.openWriteStream
            }
            defer {
                closes.close { try countedStream.close() }
                let total = counter.byteCount
                counted.withLock { $0 = total }
            }

            guard let encodeStream = ArchiveStream.encodeStream(writingTo: countedStream)
            else { throw ClipboardArchive.ArchiveError.openEncodeStream }
            defer { closes.close { try encodeStream.close() } }

            switch source {
            case .directory(let url):
                try writeTree(at: url.path, to: encodeStream)
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
        counted: Locked<Int>, pacingBytes: Int,
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
                counted.withLock { $0 = total }
                try onOutputAdvanced?(total)
            }
            guard let countedStream = ArchiveByteStream.customStream(instance: counter) else {
                throw ClipboardArchive.ArchiveError.openReadStream
            }
            defer {
                closes.close { try countedStream.close() }
                let total = counter.byteCount
                counted.withLock { $0 = total }
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
    /// bytes of the file at `url`.
    ///
    /// - Throws: ``ClipboardSourceReadFailure`` naming the file itself (an empty
    ///   path) when it cannot be opened, is not a regular file, or ends before
    ///   `byteCount`.
    static func writeFileEntry(
        _ url: URL, name: String, byteCount: Int, to encodeStream: ArchiveStream
    ) throws {
        let file = try OpenedRegularFile(path: url.path, itemPath: "")
        defer { file.close() }
        try writeRegularFileEntry(file, name: name, byteCount: byteCount, to: encodeStream)
    }

    /// Writes the tree rooted at `root` — the root's own entry, with an empty
    /// `PAT`, then every entry beneath it, each directory ahead of its contents
    /// — with the fields of ``ClipboardArchive/fieldKeys``.
    ///
    /// Walked here rather than by `writeDirectoryContents`, which reports a file
    /// it cannot open only as `ArchiveError.ioError` and archives a directory it
    /// cannot list as an empty one, raising nothing
    /// (docs/research/2026-10-22-applearchive-folder-encoder-read-failures.md).
    ///
    /// - Throws: ``ClipboardSourceReadFailure`` naming the first entry, relative
    ///   to `root`, that could not be described, listed, or read. The walk stops
    ///   there: nothing is skipped.
    static func writeTree(at root: String, to encodeStream: ArchiveStream) throws {
        guard let keySet = ArchiveHeader.FieldKeySet(ClipboardArchive.fieldKeys) else {
            assertionFailure("ClipboardArchive.fieldKeys does not parse")
            throw ClipboardArchive.ArchiveError.invalidFieldKeySet
        }
        try writeTreeEntry(root: root, itemPath: "", keySet: keySet, to: encodeStream)
    }

    /// Writes the entry at `itemPath` under `root` and, for a directory,
    /// everything beneath it.
    private static func writeTreeEntry(
        root: String, itemPath: String, keySet: ArchiveHeader.FieldKeySet,
        to encodeStream: ArchiveStream
    ) throws {
        let path = itemPath.isEmpty ? root : "\(root)/\(itemPath)"
        var status = stat()
        guard lstat(path, &status) == 0 else {
            throw ClipboardSourceReadFailure(itemPath: itemPath, reason: .posix(errno))
        }
        if (status.st_mode & S_IFMT) == S_IFREG {
            // Header and bytes both come from the one descriptor, so the entry
            // describes exactly the file it carries.
            let file = try OpenedRegularFile(path: path, itemPath: itemPath)
            defer { file.close() }
            try writeRegularFileEntry(
                file, name: itemPath, byteCount: Int(file.status.st_size), to: encodeStream)
            return
        }
        guard
            let header = ArchiveHeader(
                keySet: keySet, directory: FilePath(root), path: FilePath(itemPath), flags: [])
        else { throw ClipboardSourceReadFailure(itemPath: itemPath, reason: .unknown) }
        try encodeStream.writeHeader(header)
        guard (status.st_mode & S_IFMT) == S_IFDIR else { return }
        for name in try childNames(of: path, itemPath: itemPath) {
            try writeTreeEntry(
                root: root, itemPath: itemPath.isEmpty ? name : "\(itemPath)/\(name)",
                keySet: keySet, to: encodeStream)
        }
    }

    /// The names in the directory at `path`, sorted so the archive's order is
    /// the tree's and not the volume's.
    private static func childNames(of path: String, itemPath: String) throws -> [String] {
        guard let directory = opendir(path) else {
            throw ClipboardSourceReadFailure(itemPath: itemPath, reason: .posix(errno))
        }
        defer { closedir(directory) }
        var names: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(directory) else {
                // `readdir` returns NULL both at the end and on an error, telling
                // them apart only by `errno`.
                if errno != 0 {
                    throw ClipboardSourceReadFailure(itemPath: itemPath, reason: .posix(errno))
                }
                break
            }
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                String(decoding: raw.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self)
            }
            if name != "." && name != ".." { names.append(name) }
        }
        return names.sorted()
    }

    /// A regular file opened for reading, with the status of the descriptor
    /// that will be read.
    private struct OpenedRegularFile {
        let descriptor: Int32
        let status: stat
        /// What a failure reading it names.
        let itemPath: String

        /// Opens the file at `path`, refusing anything that is not a regular
        /// file by the time it is open.
        init(path: String, itemPath: String) throws {
            let descriptor = Darwin.open(path, O_RDONLY | O_NOFOLLOW)
            guard descriptor >= 0 else {
                throw ClipboardSourceReadFailure(itemPath: itemPath, reason: .posix(errno))
            }
            var status = stat()
            guard fstat(descriptor, &status) == 0 else {
                let code = errno
                Darwin.close(descriptor)
                throw ClipboardSourceReadFailure(itemPath: itemPath, reason: .posix(code))
            }
            guard (status.st_mode & S_IFMT) == S_IFREG else {
                Darwin.close(descriptor)
                throw ClipboardSourceReadFailure(itemPath: itemPath, reason: .posix(EFTYPE))
            }
            self.descriptor = descriptor
            self.status = status
            self.itemPath = itemPath
        }

        func close() { Darwin.close(descriptor) }
    }

    /// Writes one regular-file entry named `name` carrying exactly `byteCount`
    /// bytes of `file`, with the attribute fields of ``ClipboardArchive/fieldKeys``
    /// in the order `writeDirectoryContents` gives them.
    ///
    /// The read policy is this method's: plain, cached reads in
    /// `fileReadBlockSize` blocks, the policy AppleArchive itself applies.
    private static func writeRegularFileEntry(
        _ file: OpenedRegularFile, name: String, byteCount: Int, to encodeStream: ArchiveStream
    ) throws {
        let status = file.status
        let header = ArchiveHeader()
        header.append(
            .uint(key: .init("TYP"), value: UInt64(ArchiveHeader.EntryType.regularFile.rawValue)))
        header.append(.string(key: .init("PAT"), value: name))
        header.append(.uint(key: .init("UID"), value: UInt64(status.st_uid)))
        header.append(.uint(key: .init("GID"), value: UInt64(status.st_gid)))
        header.append(.uint(key: .init("MOD"), value: UInt64(status.st_mode & 0o7777)))
        header.append(.uint(key: .init("FLG"), value: UInt64(status.st_flags)))
        // `CTM` is the entry's creation time (AADefs.h), not the inode change time.
        header.append(.timespec(key: .init("CTM"), value: status.st_birthtimespec))
        header.append(.timespec(key: .init("MTM"), value: status.st_mtimespec))
        header.append(.blob(key: .init("DAT"), size: UInt64(byteCount)))
        try encodeStream.writeHeader(header)

        var remaining = byteCount
        let buffer = UnsafeMutableRawBufferPointer.allocate(
            byteCount: min(fileReadBlockSize, max(1, byteCount)), alignment: 16)
        defer { buffer.deallocate() }
        while remaining > 0 {
            let got = Darwin.read(file.descriptor, buffer.baseAddress, min(buffer.count, remaining))
            // Zero is the file ending before the byte count its header declared;
            // negative is a read error. Both would leave the entry short.
            guard got > 0 else {
                throw ClipboardSourceReadFailure(
                    itemPath: file.itemPath, reason: got == 0 ? .endedEarly : .posix(errno))
            }
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
    /// tree — taking out the generation sweep with it, and every later reclaim of
    /// the process root that holds it. The peer chooses
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
