import Foundation

/// Shared parameters for archived clipboard transfers — every file, folder and
/// oversize inline payload, which cross the wire as an AppleArchive (LZ4).
///
/// A transfer never materializes the archive: ``ClipboardTransferSender``
/// encodes the source straight onto its data connection and
/// ``ClipboardTransferReceiver`` extracts the arriving bytes straight into the
/// destination. Archiving must stay in-process via Apple's `AppleArchive`
/// framework — never shelling out to `ditto`/`tar`/`zip`, which the App Sandbox
/// blocks. This type never logs; callers log at their own subsystem.
public enum ClipboardArchive {
    /// A stream in the archive pipeline could not be opened, the field-key set
    /// failed to parse, or a source could not be described as an entry.
    public enum ArchiveError: Error {
        case openWriteStream
        case openCompressionStream
        case openEncodeStream
        case openReadStream
        case openDecompressionStream
        case openDecodeStream
        case openExtractStream
        case invalidFieldKeySet
        /// A file source could not be opened, or ended before the byte count
        /// its offer declared.
        case sourceRead
    }

    /// The archive's fidelity key set — what a file or folder round trip
    /// preserves.
    ///
    /// AppleArchive writes a per-entry digest (`SH2`) into the entry *header*, so
    /// carrying one makes the encoder read and hash each file in full before its
    /// first payload byte can leave; the transfer's wire-level SHA-256
    /// (CLIPBOARD.md §7) is the integrity check.
    ///
    /// Extended attributes (`XAT`) are omitted: CLIPBOARD.md §6's accepted gap,
    /// which this key set is the one place to close.
    static let fieldKeys = "TYP,PAT,LNK,DEV,DAT,UID,GID,MOD,FLG,MTM,CTM"
}

extension ClipboardArchive {
    /// UTI for a directory representation (a folder or OS package).
    public static let directoryUTI = "public.folder"

    /// Upper bound on how many entries the estimate walk visits before stopping,
    /// so a pathological tree (or a symlink cycle — the estimate's enumerator
    /// follows links) can't spin unbounded.
    private static let estimateEntryCap = 500_000

    /// A stat-walk size estimate (sum of regular-file sizes) for a source folder.
    ///
    /// The directory rep's offer `byte_count`, which the receiver's paste cap and
    /// free-space preflight gate on. It describes the *uncompressed* tree — what
    /// a streamed extract actually writes — while the compressed archive's size is
    /// unknown until the last byte has been encoded.
    public static func estimatedByteCount(at root: URL) -> Int {
        guard
            let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [])
        else { return 0 }
        var total = 0
        var count = 0
        while let url = enumerator.nextObject() as? URL {
            count += 1
            if count > estimateEntryCap { break }
            if let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                values.isRegularFile == true
            {
                total &+= values.fileSize ?? 0
            }
        }
        return total
    }
}

// MARK: - Whole-archive round trip

extension ClipboardArchive {
    /// The whole archive for `source`, held in memory.
    ///
    /// The shape a transfer deliberately never uses — it streams the archive
    /// past both ends without ever holding one — so this is for a caller that
    /// needs the archive as a value: a fixture describing what a peer puts on
    /// the wire, or a check of what arrived. Never call it on a payload whose
    /// size is not known to be small.
    public static func archiveBytes(of source: ClipboardArchiveSource) throws -> Data {
        let sink = ClipboardArchiveDataSink()
        if let failure = ClipboardArchiveCodec.encode(
            source, into: sink, counted: ArchiveByteCounter())
        {
            throw failure
        }
        return sink.bytes
    }

    /// Extracts a whole in-memory archive into `destinationURL`, which must be
    /// an existing empty directory.
    ///
    /// - Throws: whatever the extract reports for a truncated or corrupt
    ///   archive. Partial output is left for the caller to remove.
    public static func extract(_ bytes: Data, into destinationURL: URL) throws {
        if let failure = ClipboardArchiveCodec.extract(
            from: ClipboardArchiveDataSource(bytes: bytes), into: destinationURL,
            counted: ArchiveByteCounter(), pacingBytes: ClipboardStreamTuning.extractPacingBytes,
            onOutputAdvanced: nil)
        {
            throw failure
        }
    }
}

/// Collects every encoded byte into one buffer.
private final class ClipboardArchiveDataSink: ClipboardSequentialArchiveStream, @unchecked Sendable {
    private let lock = NSLock()
    private var collected = Data()

    var bytes: Data { lock.withLock { collected } }

    func write(from buffer: UnsafeRawBufferPointer) throws -> Int {
        lock.withLock { collected.append(contentsOf: buffer) }
        return buffer.count
    }
}

/// Hands one buffer's bytes to the decoder in reads.
private final class ClipboardArchiveDataSource: ClipboardSequentialArchiveStream,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let bytes: Data
    private var offset = 0

    init(bytes: Data) {
        self.bytes = bytes
    }

    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        guard let destination = buffer.baseAddress else { return 0 }
        return lock.withLock {
            let take = min(buffer.count, bytes.count - offset)
            guard take > 0 else { return 0 }
            let start = bytes.index(bytes.startIndex, offsetBy: offset)
            bytes[start..<bytes.index(start, offsetBy: take)].withUnsafeBytes { raw in
                guard let source = raw.baseAddress else { return }
                destination.copyMemory(from: source, byteCount: take)
            }
            offset += take
            return take
        }
    }
}

/// What an archived transfer encodes.
public enum ClipboardArchiveSource: Sendable {
    /// A folder, archived as its tree with entries relative to it, so the
    /// folder's own name is not embedded.
    case directory(URL)
    /// One file, archived as a single regular-file entry named `name` carrying
    /// exactly `byteCount` bytes — the size its offer declared, so a file that
    /// grew since is sent as that prefix and one that shrank fails the read.
    case file(URL, name: String, byteCount: Int)
    /// Resident bytes, archived as a single regular-file entry named `name`.
    case blob(Data, name: String)
}
