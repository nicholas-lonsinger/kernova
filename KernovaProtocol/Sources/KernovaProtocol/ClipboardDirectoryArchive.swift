import AppleArchive
import Foundation
import System

/// In-process directory archiving for clipboard folder transfers.
///
/// A copied folder rides the same `.file` streaming path as a plain file by
/// first being packed into a single AppleArchive (`.aar`, LZFSE) of the tree;
/// the receiver unpacks it back into a real directory. Archiving is in-process
/// via Apple's `AppleArchive` framework — never shelling out to `ditto`/`tar`/
/// `zip` — so the app stays Mac App Store-sandbox-safe.
///
/// The canonical fidelity key set preserves type, path, symlink target, device
/// id, data, ownership, permissions, flags, timestamps, and a per-entry
/// SHA-256. Symlinks are stored, not followed, and AppleArchive confines
/// extraction beneath the destination directory (a `../` entry can't escape).
/// No logging — callers (host service / guest agent) log at their own
/// subsystem, matching the other log-free `KernovaProtocol` stream/staging
/// types.
public enum ClipboardDirectoryArchive {
    /// A stream in the archive pipeline could not be opened, or the field-key
    /// set failed to parse.
    ///
    /// All of these are "should never happen" given a writable destination and
    /// the compile-time key string — surfaced as throwing cases rather than
    /// force-unwrapped so a caller can fail the transfer gracefully instead of
    /// crashing an end user.
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
    private static let fieldKeys = "TYP,PAT,LNK,DEV,DAT,UID,GID,MOD,FLG,MTM,CTM,SH2"

    /// Packs the directory tree at `directoryURL` into a single LZFSE-compressed
    /// `.aar` at `archiveURL`.
    ///
    /// Archives the directory's *contents* (entries are stored relative to
    /// `directoryURL`), so extraction reconstitutes the tree under a fresh
    /// destination without embedding the source's name — the folder name rides
    /// separately in the representation's `filename`. On any throw the partial
    /// archive is removed so a half-written `.aar` is never streamed.
    ///
    /// - Throws: ``ArchiveError`` if a pipeline stream can't be opened, or any
    ///   error AppleArchive raises while walking/reading the tree.
    public static func archive(directoryAt directoryURL: URL, to archiveURL: URL) throws {
        do {
            // Streams are closed in reverse creation order on scope exit (encode
            // flushes its trailer, then compression, then the file) — including
            // when `writeDirectoryContents` throws, so the partial is closed
            // before the catch removes it.
            guard
                let writeStream = ArchiveByteStream.fileStream(
                    path: FilePath(archiveURL.path),
                    mode: .writeOnly,
                    options: [.create],
                    permissions: FilePermissions(rawValue: 0o644))
            else { throw ArchiveError.openWriteStream }
            defer { try? writeStream.close() }

            guard
                let compressStream = ArchiveByteStream.compressionStream(
                    using: .lzfse, writingTo: writeStream)
            else { throw ArchiveError.openCompressionStream }
            defer { try? compressStream.close() }

            guard let encodeStream = ArchiveStream.encodeStream(writingTo: compressStream)
            else { throw ArchiveError.openEncodeStream }
            defer { try? encodeStream.close() }

            guard let keySet = ArchiveHeader.FieldKeySet(fieldKeys)
            else { throw ArchiveError.invalidFieldKeySet }

            try encodeStream.writeDirectoryContents(
                archiveFrom: FilePath(directoryURL.path), keySet: keySet)
        } catch {
            try? FileManager.default.removeItem(at: archiveURL)
            throw error
        }
    }

    /// Extracts the LZFSE `.aar` at `archiveURL` into `directoryURL`, which must
    /// already exist (the caller reserves it under the staging root).
    ///
    /// On any throw the destination directory is removed so a partially-
    /// extracted tree never reaches the pasteboard.
    ///
    /// - Throws: ``ArchiveError`` if a pipeline stream can't be opened, or any
    ///   error AppleArchive raises while decoding/extracting.
    public static func extract(archiveAt archiveURL: URL, to directoryURL: URL) throws {
        do {
            guard
                let readStream = ArchiveByteStream.fileStream(
                    path: FilePath(archiveURL.path),
                    mode: .readOnly,
                    options: [],
                    permissions: FilePermissions(rawValue: 0o644))
            else { throw ArchiveError.openReadStream }
            defer { try? readStream.close() }

            guard
                let decompressStream = ArchiveByteStream.decompressionStream(
                    readingFrom: readStream)
            else { throw ArchiveError.openDecompressionStream }
            defer { try? decompressStream.close() }

            guard let decodeStream = ArchiveStream.decodeStream(readingFrom: decompressStream)
            else { throw ArchiveError.openDecodeStream }
            defer { try? decodeStream.close() }

            guard
                let extractStream = ArchiveStream.extractStream(
                    extractingTo: FilePath(directoryURL.path))
            else { throw ArchiveError.openExtractStream }
            defer { try? extractStream.close() }

            _ = try ArchiveStream.process(readingFrom: decodeStream, writingTo: extractStream)
        } catch {
            try? FileManager.default.removeItem(at: directoryURL)
            throw error
        }
    }
}

extension ClipboardDirectoryArchive {
    /// UTI for a directory representation (a folder or OS package).
    ///
    /// Equals `UTType.folder.identifier`; kept as a literal so the package needn't
    /// import `UniformTypeIdentifiers`.
    public static let directoryUTI = "public.folder"

    /// Archives the directory at `directoryURL` into a single `.aar` staged under
    /// `staging`/`generation` and returns a file representation describing it, or
    /// `nil` if the archive has no readable size.
    ///
    /// The folder name (not the `.aar`) rides in `filename`, the UTI is
    /// `directoryUTI`, and `isDirectory` is set, so the receiver extracts it back
    /// into a real folder. Shared by the host intake and the guest agent — both
    /// import `KernovaProtocol` — so the archive/UTI/sizing rules live in one
    /// place and can't drift between the two ends. Throws the underlying archive
    /// error so the caller can log it at its own subsystem (this package stays
    /// log-free).
    public static func archivedRepresentation(
        ofDirectoryAt directoryURL: URL, named folderName: String,
        into staging: ClipboardFileStaging, generation: UInt64
    ) throws -> ClipboardContent.Representation? {
        let archiveURL = try staging.reserveURL(
            generation: generation, filename: folderName + ".aar")
        try archive(directoryAt: directoryURL, to: archiveURL)
        guard
            let size = try? archiveURL.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0
        else { return nil }
        return ClipboardContent.Representation(
            uti: directoryUTI, fileURL: archiveURL, byteCount: size, filename: folderName,
            isDirectory: true)
    }

    /// Extracts a directory representation's staged `.aar` into a real folder
    /// under `staging`/`generation`, returning the folder URL, or `nil` if the
    /// rep isn't a directory, its archive URL is missing, the volume lacks room,
    /// or extraction fails.
    ///
    /// The free-space check is a best-effort **floor**: `representation.byteCount`
    /// is the LZFSE-compressed archive size, while extraction writes the larger
    /// uncompressed tree — so a volume that passes the check can still fill
    /// mid-extract. That's handled, not guaranteed away: `extract` deletes the
    /// partial tree on a throw and this returns `nil`, the same graceful outcome
    /// as a failed file stage.
    public static func extractedDirectoryURL(
        for representation: ClipboardContent.Representation,
        into staging: ClipboardFileStaging, generation: UInt64
    ) -> URL? {
        guard representation.isDirectory, let archiveURL = representation.fileURL,
            staging.hasCapacity(forByteCount: representation.byteCount),
            let directory = try? staging.reserveDirectory(
                generation: generation, name: representation.filename)
        else { return nil }
        do {
            try extract(archiveAt: archiveURL, to: directory)
            return directory
        } catch {
            return nil
        }
    }
}
