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
    /// any depth, and then removed from staging. Only `destination` itself is
    /// named by path: its folder is never opened, so access to `destination`
    /// alone is enough.
    ///
    /// A copy that fails part-way removes what it created at `destination`
    /// outright — Kernova's own unfinished output, never an item the user had
    /// — and leaves the staged item for the caller.
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
            source, at: destination, from: ClipboardArchiveLocalVolume(), to: ClipboardArchiveLocalVolume())
    }

    /// ``land(_:at:)`` for the staged item at `source`, read and removed
    /// through `staging` and created and renamed through `target`.
    static func land<Staging: ClipboardArchiveWritableVolume, Target: ClipboardArchiveWritableVolume>(
        _ source: URL, at destination: URL, from staging: Staging, to target: Target
    ) throws {
        do {
            try target.rename(
                Array(source.path.utf8), in: AT_FDCWD, to: Array(destination.path.utf8), in: AT_FDCWD)
            return
        } catch Errno.improperLink, Errno.notSupported {
            // Copied below.
        } catch {
            throw posixError(error)
        }
        do {
            try TreeMaterializer.materialize(.newItem(destination.path), on: target) { materializer in
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
