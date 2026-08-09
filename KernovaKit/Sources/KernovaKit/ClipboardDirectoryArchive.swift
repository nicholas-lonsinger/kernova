import Foundation

/// Shared parameters for clipboard folder transfers, which cross the wire as an
/// AppleArchive (LZFSE) of the tree.
///
/// The archive itself is never materialized: ``ClipboardDirectoryArchiveReader``
/// encodes the source tree straight onto the wire and
/// ``ClipboardDirectoryExtractSink`` extracts the arriving bytes straight into
/// the destination tree. Archiving must stay in-process via Apple's
/// `AppleArchive` framework — never shelling out to `ditto`/`tar`/`zip`, which
/// the App Sandbox blocks. This type never logs; callers log at their own
/// subsystem.
public enum ClipboardDirectoryArchive {
    /// A stream in the archive pipeline could not be opened, or the field-key
    /// set failed to parse.
    public enum ArchiveError: Error {
        case openWriteStream
        case openCompressionStream
        case openEncodeStream
        case openReadStream
        case openDecompressionStream
        case openDecodeStream
        case openExtractStream
        case invalidFieldKeySet
    }

    /// Fidelity key set: type, path, link target, device id, data, uid, gid,
    /// permissions, flags, mtime, ctime, and per-entry SHA-256.
    ///
    /// RATIONALE: extended attributes (`XAT`) are deliberately omitted — the
    /// plain-file streaming path cannot carry them, and a folder carrying them
    /// alone would break CLIPBOARD.md §6's uniform xattr gap.
    static let fieldKeys = "TYP,PAT,LNK,DEV,DAT,UID,GID,MOD,FLG,MTM,CTM,SH2"
}

extension ClipboardDirectoryArchive {
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
