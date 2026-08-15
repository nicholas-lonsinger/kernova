import Foundation

/// Shared parameters for archived clipboard transfers — every file, folder and
/// oversize inline payload, which cross the wire as an AppleArchive (LZ4).
///
/// The archive itself is never materialized: ``ClipboardArchiveReader`` encodes
/// the source straight onto the wire and ``ClipboardArchiveExtractSink``
/// extracts the arriving bytes straight into the destination. Archiving must
/// stay in-process via Apple's `AppleArchive` framework — never shelling out to
/// `ditto`/`tar`/`zip`, which the App Sandbox blocks. This type never logs;
/// callers log at their own subsystem.
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
