import Darwin
import Foundation
import KernovaFileTree
import System

/// Removes staged content outright: a file, a symlink (never its target), or
/// a directory tree of any depth and any mode, through ``TreeRemoval``.
///
/// `FileManager.removeItem` and `removefile(3)` remove nothing from a tree
/// whose paths run past `PATH_MAX` or that holds a directory its owner cannot
/// write (docs/research/2026-10-23-applearchive-extract-semantics.md, finding
/// 12), and `REMOVEFILE_ALLOW_LONG_PATHS` changes the process's working
/// directory, which its man page says makes it not thread safe.
///
/// For app-internal files only: a file the user can see goes to the Trash.
public enum StagedItemRemoval {
    /// Removes the item at `url`.
    ///
    /// - Throws: the `Errno` of the first call that failed —
    ///   `.noSuchFileOrDirectory` when nothing is at `url` — or, when a
    ///   directory was moved out from under the removal, a failure naming no
    ///   reason. What was removed before it stays removed.
    public static func remove(at url: URL) throws {
        try remove(at: url, on: POSIXTreeFileSystem())
    }

    /// ``remove(at:)`` against `fileSystem`.
    static func remove<FileSystem: MutableTreeFileSystem>(at url: URL, on fileSystem: FileSystem) throws {
        do {
            try TreeRemoval.remove(Array(url.path.utf8), in: AT_FDCWD, on: fileSystem)
        } catch let error as TreeFileSystemError {
            throw Errno(rawValue: error.code)
        } catch DirectoryCursorFailure.system(let error) {
            throw Errno(rawValue: error.code)
        }
    }
}
