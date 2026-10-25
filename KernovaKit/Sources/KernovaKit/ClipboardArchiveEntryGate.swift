import AppleArchive
import Darwin
import System

/// The archive stream an extract is fed through, deciding each entry before
/// AppleArchive's extract sees any of it: an entry that is not a regular file,
/// directory or symlink is left out, and one the extract is known not to
/// create stops it, recorded as a ``ClipboardItemFailure`` naming the entry.
///
/// AppleArchive reports neither refusal by name. An entry whose `PAT` is
/// 1,024 bytes or more reaches no filter at all and is skipped without a
/// trace; a shorter one past `PATH_MAX`, or one APFS refuses for not being
/// UTF-8, fails only as `close()`'s pathless `ioError`, the rest of the
/// archive extracted
/// (docs/research/2026-10-23-applearchive-extract-semantics.md, findings 1–3).
final class ClipboardArchiveEntryGate: ArchiveStreamProtocol {
    private let extractStream: ArchiveStream
    /// The byte length of the resolved path the extract writes under.
    private let destinationByteCount: Int
    private let refusals: ArchiveRefusalBox
    /// Whether the blobs arriving belong to an entry left out. `process` hands
    /// a stream one entry at a time, so they are its blobs alone.
    private var skipping = false

    /// - Parameters:
    ///   - extractStream: where each admitted entry goes.
    ///   - destination: the resolved path `extractStream` extracts under.
    ///   - refusals: receives the failure an entry is refused with.
    init(feeding extractStream: ArchiveStream, under destination: String, refusals: ArchiveRefusalBox) {
        self.extractStream = extractStream
        destinationByteCount = destination.utf8.count
        self.refusals = refusals
    }

    /// The entry types a file or a folder is made of.
    ///
    /// Creating any other kind of node can stall the extract: once AppleArchive
    /// has made a FIFO, the extract never returns
    /// (docs/research/2026-10-22-applearchive-folder-encoder-read-failures.md).
    private static let landedEntryTypes = Set(
        [ArchiveHeader.EntryType.regularFile, .directory, .link].map { UInt64($0.rawValue) })

    /// The `errno` an entry at `path` is refused with, or `nil` when the
    /// extract can create it under a destination of `destinationByteCount`
    /// bytes.
    static func refusal(of path: [UInt8], under destinationByteCount: Int) -> Int32? {
        // The entry's absolute path, NUL included, must fit `PATH_MAX`.
        if !path.isEmpty, destinationByteCount + 1 + path.count >= Int(PATH_MAX) { return ENAMETOOLONG }
        // APFS stores only UTF-8 names (finding 3).
        if Array(String(decoding: path, as: UTF8.self).utf8) != path { return EILSEQ }
        return nil
    }

    func writeHeader(_ header: ArchiveHeader) throws {
        guard let fields = ClipboardArchiveEntryFields(header) else {
            throw ClipboardArchive.ArchiveError.unreadableEntryHeader
        }
        guard let type = fields.type, Self.landedEntryTypes.contains(type) else {
            skipping = true
            return
        }
        skipping = false
        let path = fields.path ?? []
        if let code = Self.refusal(of: path, under: destinationByteCount) {
            let failure = ClipboardItemFailure(
                itemPath: ClipboardArchiveCodec.displayPath(path), reason: .posix(code))
            refusals.record(failure)
            throw failure
        }
        try extractStream.writeHeader(header)
    }

    func writeBlob(key: ArchiveHeader.FieldKey, from buffer: UnsafeRawBufferPointer) throws {
        guard !skipping else { return }
        try extractStream.writeBlob(key: key, from: buffer)
    }

    func readHeader() throws -> ArchiveHeader? {
        throw ClipboardArchiveStreamError.unsupportedOperation
    }

    func readBlob(key: ArchiveHeader.FieldKey, into buffer: UnsafeMutableRawBufferPointer) throws {
        throw ClipboardArchiveStreamError.unsupportedOperation
    }

    func cancel() { extractStream.cancel() }

    /// A no-op: the driver closes the extract stream, and reports its failure.
    func close() throws {}
}
