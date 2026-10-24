import Darwin
import Foundation
import System

/// Removes staged content outright: a file, a symlink (never its target), or
/// a directory tree of any depth and any mode.
///
/// `FileManager.removeItem` and `removefile(3)` remove nothing from a tree
/// whose paths run past `PATH_MAX` or that holds a directory its owner cannot
/// write (docs/research/2026-10-23-applearchive-extract-semantics.md, finding
/// 12), and `REMOVEFILE_ALLOW_LONG_PATHS` changes the process's working
/// directory, which its man page says makes it not thread safe.
/// This walks the tree through descriptors on a ``DirectoryCursor`` instead,
/// making each directory searchable and writable by its owner before
/// emptying it.
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
        try remove(at: url, on: ClipboardArchiveLocalVolume())
    }

    /// ``remove(at:)`` against `volume`.
    static func remove<Volume: ClipboardArchiveWritableVolume>(at url: URL, on volume: Volume) throws {
        let root = Array(url.path.utf8)
        let status = try volume.status(of: root, in: AT_FDCWD)
        guard (status.st_mode & S_IFMT) == S_IFDIR else {
            try volume.remove(root, in: AT_FDCWD, isDirectory: false)
            return
        }
        try empty(root, status: status, on: volume)
        try volume.remove(root, in: AT_FDCWD, isDirectory: true)
    }

    /// A directory being emptied: its name in its parent, and the names in it
    /// still to remove.
    private struct Frame {
        let name: [UInt8]
        var pending: [[UInt8]]
    }

    /// Removes everything inside the directory `root`, whose status is
    /// `status`.
    private static func empty<Volume: ClipboardArchiveWritableVolume>(
        _ root: [UInt8], status: stat, on volume: Volume
    ) throws {
        guard let top = try open(root, status: status, in: AT_FDCWD, on: volume) else { return }
        var cursor = DirectoryCursor(
            volume: volume, descriptor: top.descriptor, status: top.status,
            frame: Frame(name: root, pending: top.names))
        while true {
            if let name = cursor.frame.pending.popLast() {
                let entry = try volume.status(of: name, in: cursor.descriptor)
                guard (entry.st_mode & S_IFMT) == S_IFDIR else {
                    try volume.remove(name, in: cursor.descriptor, isDirectory: false)
                    continue
                }
                guard let child = try open(name, status: entry, in: cursor.descriptor, on: volume)
                else {
                    try volume.remove(name, in: cursor.descriptor, isDirectory: true)
                    continue
                }
                cursor.descend(
                    into: child.descriptor, status: child.status,
                    frame: Frame(name: name, pending: child.names))
            } else if !cursor.isAtTop {
                let left: Frame
                do {
                    left = try cursor.ascend()
                } catch DirectoryCursorFailure.system(let errno) {
                    throw errno
                }
                try volume.remove(left.name, in: cursor.descriptor, isDirectory: true)
            } else {
                return
            }
        }
    }

    /// Opens the directory `name` in `directory`, whose status is `status`,
    /// first making it searchable and writable by its owner.
    ///
    /// - Returns: the directory, open, with the names in it; `nil` when it is
    ///   empty, closed.
    private static func open<Volume: ClipboardArchiveWritableVolume>(
        _ name: [UInt8], status: stat, in directory: Int32, on volume: Volume
    ) throws(Errno) -> (descriptor: Int32, status: stat, names: [[UInt8]])? {
        let mode = status.st_mode & 0o7777
        if mode & S_IRWXU != S_IRWXU {
            try volume.setAttribute(.mode(mode | S_IRWXU), of: .name(name, in: directory))
        }
        let descriptor = try volume.openDirectory(name, in: directory)
        do {
            let opened = try volume.status(of: descriptor)
            let names = try volume.names(in: descriptor)
            guard !names.isEmpty else {
                volume.close(descriptor)
                return nil
            }
            return (descriptor, opened, names)
        } catch {
            volume.close(descriptor)
            throw error
        }
    }
}
