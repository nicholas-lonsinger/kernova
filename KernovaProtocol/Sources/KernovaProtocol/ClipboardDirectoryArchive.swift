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
