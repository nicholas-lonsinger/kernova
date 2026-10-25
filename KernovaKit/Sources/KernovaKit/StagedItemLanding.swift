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
    /// inode and its depth does not matter. Onto another volume — or one that
    /// cannot rename without replacing — the item is copied there as the
    /// receiver's extract creates an arriving tree, through descriptors and to
    /// any depth, and then removed from staging. An attribute the destination
    /// cannot hold is left out of the copy. Only `destination` itself is named
    /// by path: its folder is never opened, so access to `destination` alone
    /// is enough.
    ///
    /// A copy that fails part-way moves what it created at `destination` to
    /// the Trash — the user may have put something into it meanwhile — or,
    /// when that fails, leaves it there; either way the staged item is left
    /// for the caller.
    ///
    /// - Throws: `CocoaError(.fileNoSuchFile)` for a representation with no
    ///   staged file; otherwise a `POSIXError` with the `errno` of the call
    ///   that failed — `EEXIST` when something is at `destination` — or, for a
    ///   copy that failed naming none, its ``ClipboardItemFailure``.
    public static func land(
        _ representation: ClipboardContent.Representation, at destination: URL
    ) throws {
        guard let source = representation.fileURL else { throw CocoaError(.fileNoSuchFile) }
        try land(
            source, at: destination, from: ClipboardArchiveLocalVolume(), to: ClipboardArchiveLocalVolume(),
            trash: { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) })
    }

    /// ``land(_:at:)`` for the staged item at `source`, read and removed
    /// through `staging`, created and renamed through `target`, and an
    /// unfinished copy moved to the Trash through `trash`.
    static func land<Staging: ClipboardArchiveWritableVolume, Target: ClipboardArchiveWritableVolume>(
        _ source: URL, at destination: URL, from staging: Staging, to target: Target,
        trash: (URL) throws -> Void
    ) throws {
        do {
            guard try !rename(source, to: destination, from: staging, to: target) else { return }
        } catch {
            throw posixError(error)
        }
        do {
            try TreeMaterializer.materialize(
                newItemAt: destination.path, on: target,
                unfinished: { path in
                    do {
                        try trash(URL(fileURLWithPath: path))
                    } catch {
                        logger.log(
                            .error,
                            "Could not move an unfinished copy to the Trash: \(String(describing: error), privacy: .public)"
                        )
                    }
                }
            ) { materializer in
                try ClipboardArchiveCodec.walkTree(at: source.path, into: materializer, on: staging)
            }
        } catch {
            throw posixError(error)
        }
        // The item has landed, so a staged copy that stays is staging's to
        // reclaim, not a failed landing.
        do {
            try StagedItemRemoval.remove(at: source, on: staging)
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
    private static func rename<Staging: ClipboardArchiveWritableVolume, Target: ClipboardArchiveWritableVolume>(
        _ source: URL, to destination: URL, from staging: Staging, to target: Target
    ) throws(Errno) -> Bool {
        let sourcePath = Array(source.path.utf8)
        let destinationPath = Array(destination.path.utf8)
        let status = try staging.status(of: sourcePath, in: AT_FDCWD)
        let mode = status.st_mode & 0o7777
        let unwritable = (status.st_mode & S_IFMT) == S_IFDIR && mode & S_IWUSR == 0
        if unwritable {
            try staging.setAttributes(
                ClipboardArchiveAttributes(mode: mode | S_IWUSR), of: .name(sourcePath, in: AT_FDCWD))
        }
        do {
            try target.rename(sourcePath, in: AT_FDCWD, to: destinationPath, in: AT_FDCWD)
        } catch {
            let copies = error == .improperLink || error == .notSupported
            if unwritable {
                do {
                    try staging.setAttributes(
                        ClipboardArchiveAttributes(mode: mode), of: .name(sourcePath, in: AT_FDCWD))
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
                try target.setAttributes(
                    ClipboardArchiveAttributes(mode: mode), of: .name(destinationPath, in: AT_FDCWD))
            } catch {
                logger.log(
                    .error,
                    "A landed folder kept its owner's write permission: \(String(describing: error), privacy: .public)")
            }
        }
        return true
    }

    /// `error` as a `POSIXError` when it carries an `errno`.
    private static func posixError(_ error: any Error) -> any Error {
        var code: Int32?
        if let errno = error as? Errno {
            code = errno.rawValue
        } else if let failure = error as? ClipboardItemFailure, case .posix(let errno) = failure.reason {
            code = errno
        }
        return code.flatMap(POSIXErrorCode.init(rawValue:)).map { POSIXError($0) } ?? error
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
