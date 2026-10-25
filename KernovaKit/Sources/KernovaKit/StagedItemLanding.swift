import Darwin
import Foundation
import KernovaLogging
import System

/// Moves an item a pull delivered out of staging to where the user wanted it.
///
/// A pull lands only in staging, and its receiver deletes its extract
/// destination on failure, so it is never pointed at a user's folder: staging
/// then moving is how a received file or folder reaches one.
public enum StagedItemLanding {
    private static let logger = KernovaLogger(subsystem: "app.kernova", category: "StagedItemLanding")

    /// Moves `representation`'s staged file or folder to exactly `destination`,
    /// never replacing an existing item.
    ///
    /// Where the volume can, the move is one rename, so the item keeps its
    /// inode. Onto another volume — or one that cannot rename without
    /// replacing — the item is copied there and then removed from staging.
    ///
    /// - Throws: `CocoaError(.fileNoSuchFile)` for a representation with no
    ///   staged file; a `POSIXError` with the `errno` of a rename that failed
    ///   for another reason — `EEXIST` when something is at `destination`; or
    ///   the copy's error.
    public static func land(
        _ representation: ClipboardContent.Representation, at destination: URL
    ) throws {
        guard let source = representation.fileURL else { throw CocoaError(.fileNoSuchFile) }
        try land(source, at: destination, on: ClipboardArchiveLocalVolume())
    }

    /// ``land(_:at:)`` for the staged item at `source`, renamed and removed
    /// through `volume`.
    static func land<Volume: ClipboardArchiveWritableVolume>(
        _ source: URL, at destination: URL, on volume: Volume
    ) throws {
        do {
            guard try !rename(source, to: destination, on: volume) else { return }
        } catch {
            throw POSIXErrorCode(rawValue: error.rawValue).map { POSIXError($0) } ?? error
        }
        try FileManager.default.copyItem(at: source, to: destination)
        // The item has landed, so a staged copy that stays is staging's to
        // reclaim, not a failed landing. `FileManager` removes nothing from a
        // tree holding a folder its owner cannot write
        // (docs/research/2026-10-23-applearchive-extract-semantics.md,
        // finding 12).
        do {
            try StagedItemRemoval.remove(at: source, on: volume)
        } catch {
            logger.log(
                .warning,
                "Could not remove a landed item from staging: \(String(describing: error), privacy: .public)")
        }
    }

    /// Renames the staged item at `source` to `destination`, returning
    /// `false`, with the staged item as it was, when the volume cannot.
    ///
    /// Moving a directory to another parent writes its `..`, so it needs
    /// write permission on the directory itself (`rename(2)`, `EACCES`). A
    /// staged directory whose own mode withholds that from its owner is made
    /// writable for the rename, and given its own mode back after, wherever
    /// it then is.
    private static func rename<Volume: ClipboardArchiveWritableVolume>(
        _ source: URL, to destination: URL, on volume: Volume
    ) throws(Errno) -> Bool {
        let sourcePath = Array(source.path.utf8)
        let destinationPath = Array(destination.path.utf8)
        let status = try volume.status(of: sourcePath, in: AT_FDCWD)
        let mode = status.st_mode & 0o7777
        let unwritable = (status.st_mode & S_IFMT) == S_IFDIR && mode & S_IWUSR == 0
        if unwritable {
            try volume.setMode(mode | S_IWUSR, of: sourcePath, in: AT_FDCWD)
        }
        do {
            try volume.rename(sourcePath, in: AT_FDCWD, to: destinationPath, in: AT_FDCWD)
        } catch {
            let copies = error == .improperLink || error == .notSupported
            if unwritable {
                do {
                    try volume.setMode(mode, of: sourcePath, in: AT_FDCWD)
                } catch let restore {
                    // A copy would carry the added write permission.
                    if copies { throw restore }
                    logger.log(
                        .error,
                        "A staged folder kept its owner's write permission: \(String(describing: restore), privacy: .public)"
                    )
                }
            }
            if copies { return false }
            throw error
        }
        if unwritable {
            do {
                try volume.setMode(mode, of: destinationPath, in: AT_FDCWD)
            } catch {
                logger.log(
                    .error,
                    "A landed folder kept its owner's write permission: \(String(describing: error), privacy: .public)")
            }
        }
        return true
    }

    /// Moves `representation`'s staged file or folder into `directory` under
    /// `filename` — sanitized to one path component, and counted up Finder's
    /// "Keep Both" way when the name is taken — returning where it landed.
    ///
    /// An empty `filename` keeps the staged item's own name. `directory` is
    /// created if it does not exist.
    public static func land(
        _ representation: ClipboardContent.Representation, inDirectory directory: URL,
        named filename: String
    ) throws -> URL {
        guard let source = representation.fileURL else { throw CocoaError(.fileNoSuchFile) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = NameUniquing.uniqueDestination(
            in: directory, filename: filename.isEmpty ? source.lastPathComponent : filename)
        try land(representation, at: destination)
        return destination
    }
}
