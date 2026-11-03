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
        let status = try fileSystem.status(of: name, in: directory)
        guard status.kind == .directory else {
            try fileSystem.remove(name, in: directory, isDirectory: false)
            return
        }
        try empty(name, status: status, in: directory, on: fileSystem)
        try fileSystem.remove(name, in: directory, isDirectory: true)
    }

    /// A directory being emptied: its name in its parent, and the names in it
    /// still to remove.
    private struct Frame {
        let name: [UInt8]
        var pending: [[UInt8]]
    }

    /// Removes everything inside the directory `name` in `directory`, whose
    /// status is `status`.
    private static func empty<FileSystem: MutableTreeFileSystem>(
        _ name: [UInt8], status: FileStatus, in directory: Int32, on fileSystem: FileSystem
    ) throws {
        guard let top = try open(name, status: status, in: directory, on: fileSystem) else { return }
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
                return
            }
        }
    }

    /// Opens the directory `name` in `directory`, whose status is `status`,
    /// first making it searchable and writable by its owner.
    ///
    /// - Returns: the directory, open, with the names in it; `nil` when it is
    ///   empty, closed.
    private static func open<FileSystem: MutableTreeFileSystem>(
        _ name: [UInt8], status: FileStatus, in directory: Int32, on fileSystem: FileSystem
    ) throws(TreeFileSystemError) -> (descriptor: Int32, status: FileStatus, names: [[UInt8]])? {
        let mode = status.permissions
        if mode & ownerAll != ownerAll {
            try fileSystem.setMode(mode | ownerAll, of: name, in: directory)
        }
        let descriptor = try fileSystem.openDirectory(name, in: directory)
        do {
            let opened = try fileSystem.status(of: descriptor)
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
