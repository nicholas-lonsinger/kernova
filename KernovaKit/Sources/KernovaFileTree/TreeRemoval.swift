#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(ucrt)
import ucrt
#endif

/// Removes an entry outright: a file, a symlink (never its target), or a
/// directory tree of any depth and any mode.
///
/// The tree is walked through descriptors on a ``DirectoryCursor``, each
/// directory made searchable and writable by its owner before it is emptied,
/// so neither a path past `PATH_MAX` nor a directory its owner cannot write
/// stops it.
public enum TreeRemoval {
    /// The owner's read, write and search bits, `S_IRWXU`.
    private static let ownerAll: UInt32 = 0o700

    /// Removes `name` in `directory`.
    ///
    /// - Throws: the ``TreeFileSystemError`` of the first call that failed, or
    ///   a ``DirectoryCursorFailure`` when the walk could not climb back. What
    ///   was removed before it stays removed.
    public static func remove<FileSystem: MutableTreeFileSystem>(
        _ name: [UInt8], in directory: Int32, on fileSystem: FileSystem
    ) throws {
        _ = try remove(name, in: directory, on: fileSystem, whileItIs: { _ in true })
    }

    /// Removes `name` in `directory` only while it is the entry `isTarget`
    /// accepts the status of: asked of the entry the name holds before
    /// anything changes, of a directory once it is open and before it is
    /// emptied through that descriptor, and of the name again before it is
    /// unlinked.
    ///
    /// - Returns: whether it removed the entry; `false` when the name held
    ///   another one at any of those checks, which is left as it is.
    /// - Throws: as ``remove(_:in:on:)``.
    public static func remove<FileSystem: MutableTreeFileSystem>(
        _ name: [UInt8], in directory: Int32, on fileSystem: FileSystem,
        whileItIs isTarget: (FileStatus) -> Bool
    ) throws -> Bool {
        let status = try fileSystem.status(of: name, in: directory)
        guard isTarget(status) else { return false }
        if status.kind == .directory {
            guard try empty(name, status: status, in: directory, on: fileSystem, whileItIs: isTarget) else {
                return false
            }
            guard isTarget(try fileSystem.status(of: name, in: directory)) else { return false }
        }
        try fileSystem.remove(name, in: directory, isDirectory: status.kind == .directory)
        return true
    }

    /// A directory being emptied: its name in its parent, and the names in it
    /// still to remove.
    private struct Frame {
        let name: [UInt8]
        var pending: [[UInt8]]
    }

    /// Removes everything inside the directory `name` in `directory`, whose
    /// status is `status`, once the directory open is one `isTarget` accepts.
    ///
    /// - Returns: whether it was; `false` when it was not, and nothing changed
    ///   inside it.
    private static func empty<FileSystem: MutableTreeFileSystem>(
        _ name: [UInt8], status: FileStatus, in directory: Int32, on fileSystem: FileSystem,
        whileItIs isTarget: (FileStatus) -> Bool
    ) throws -> Bool {
        guard let top = try open(name, status: status, in: directory, on: fileSystem) else { return true }
        guard isTarget(top.status) else {
            fileSystem.close(top.descriptor)
            return false
        }
        var cursor = DirectoryCursor(
            fileSystem: fileSystem, descriptor: top.descriptor, status: top.status,
            frame: Frame(name: name, pending: top.names))
        while true {
            if let name = cursor.frame.pending.popLast() {
                let entry = try fileSystem.status(of: name, in: cursor.descriptor)
                guard entry.kind == .directory else {
                    try fileSystem.remove(name, in: cursor.descriptor, isDirectory: false)
                    continue
                }
                guard let child = try open(name, status: entry, in: cursor.descriptor, on: fileSystem)
                else {
                    try fileSystem.remove(name, in: cursor.descriptor, isDirectory: true)
                    continue
                }
                cursor.descend(
                    into: child.descriptor, status: child.status,
                    frame: Frame(name: name, pending: child.names))
            } else if !cursor.isAtTop {
                let left = try cursor.ascend()
                try fileSystem.remove(left.name, in: cursor.descriptor, isDirectory: true)
            } else {
                return true
            }
        }
    }

    /// Opens the directory `name` in `directory`, whose status is `status`,
    /// made searchable and writable by its owner through its descriptor. Only
    /// a directory the caller cannot open is changed by name first, so a
    /// caller the system lets open anything changes nothing by name.
    ///
    /// - Returns: the directory, open, with the names in it; `nil` when it is
    ///   empty, closed.
    private static func open<FileSystem: MutableTreeFileSystem>(
        _ name: [UInt8], status: FileStatus, in directory: Int32, on fileSystem: FileSystem
    ) throws(TreeFileSystemError) -> (descriptor: Int32, status: FileStatus, names: [[UInt8]])? {
        let descriptor: Int32
        do { descriptor = try fileSystem.openDirectory(name, in: directory) } catch {
            guard error.code == EACCES, status.permissions & ownerAll != ownerAll else { throw error }
            try fileSystem.setMode(status.permissions | ownerAll, of: name, in: directory)
            descriptor = try fileSystem.openDirectory(name, in: directory)
        }
        do {
            let opened = try fileSystem.status(of: descriptor)
            if opened.permissions & ownerAll != ownerAll {
                try fileSystem.setAttributes(
                    TreeEntryAttributes(permissions: opened.permissions | ownerAll), of: .descriptor(descriptor))
            }
            let names = try fileSystem.names(in: descriptor)
            guard !names.isEmpty else {
                fileSystem.close(descriptor)
                return nil
            }
            return (descriptor, opened, names)
        } catch {
            fileSystem.close(descriptor)
            throw error
        }
    }
}
