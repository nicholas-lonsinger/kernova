import AppleArchive
import Darwin
import Foundation
import System

// MARK: - Entry headers

/// One archive entry's header, its fields those of ``ClipboardArchive/fieldKeys``
/// in that order, each taken from the entry's status.
struct ClipboardArchiveEntryHeader {
    /// The entry's path in the archive, raw bytes and `/`-separated; empty for
    /// a source's own root.
    let path: [UInt8]
    let status: stat
    /// A symlink's target.
    var linkTarget: [UInt8]? = nil
    /// The byte count a regular file's entry declares.
    var byteCount: Int? = nil

    /// The header.
    ///
    /// - Throws: ``ClipboardItemFailure`` naming the entry when its type
    ///   has no archive entry type or its path and link target outgrow a
    ///   header; ``ClipboardArchive/ArchiveError/unproducibleFieldKey`` for a
    ///   key in ``ClipboardArchive/fieldKeys`` this type has no value for — a
    ///   programming error, raised loudly rather than left out of every entry.
    func make() throws -> ArchiveHeader {
        let format = status.st_mode & S_IFMT
        guard let type = Self.entryType(format) else {
            throw ClipboardItemFailure(
                itemPath: ClipboardArchiveCodec.displayPath(path), reason: .posix(EFTYPE))
        }
        guard ClipboardArchiveHeaderBuilder.fits(stringBytes: path.count + (linkTarget?.count ?? 0))
        else {
            throw ClipboardItemFailure(
                itemPath: ClipboardArchiveCodec.displayPath(path), reason: .posix(ENAMETOOLONG))
        }
        guard let builder = ClipboardArchiveHeaderBuilder() else {
            throw ClipboardItemFailure(
                itemPath: ClipboardArchiveCodec.displayPath(path), reason: .unknown)
        }
        for key in Self.keyNames {
            switch key {
            case "TYP": builder.append(uint: UInt64(type.rawValue), key: key)
            case "PAT": builder.append(string: path, key: key)
            case "LNK": if let linkTarget { builder.append(string: linkTarget, key: key) }
            case "DEV":
                if format == S_IFCHR || format == S_IFBLK {
                    builder.append(uint: UInt64(UInt32(bitPattern: status.st_rdev)), key: key)
                }
            case "UID": builder.append(uint: UInt64(status.st_uid), key: key)
            case "GID": builder.append(uint: UInt64(status.st_gid), key: key)
            case "MOD": builder.append(uint: UInt64(status.st_mode & 0o7777), key: key)
            case "FLG": builder.append(uint: UInt64(status.st_flags), key: key)
            // `CTM` is the entry's creation time (AADefs.h), not the inode
            // change time; a volume that keeps none reports it as zero, and
            // AppleArchive's own headers then leave the field out.
            case "CTM":
                let birth = status.st_birthtimespec
                if birth.tv_sec != 0 || birth.tv_nsec != 0 {
                    builder.append(timespec: birth, key: key)
                }
            case "MTM": builder.append(timespec: status.st_mtimespec, key: key)
            case "DAT":
                if format == S_IFREG {
                    builder.append(blobSize: UInt64(byteCount ?? Int(status.st_size)), key: key)
                }
            default:
                assertionFailure("ClipboardArchive.fieldKeys names \(key), which no entry produces")
                throw ClipboardArchive.ArchiveError.unproducibleFieldKey
            }
        }
        guard let header = builder.make() else {
            throw ClipboardItemFailure(
                itemPath: ClipboardArchiveCodec.displayPath(path), reason: .unknown)
        }
        return header
    }

    private static let keyNames = ClipboardArchive.fieldKeys.split(separator: ",").map(String.init)

    private static func entryType(_ format: mode_t) -> ArchiveHeader.EntryType? {
        switch format {
        case S_IFREG: .regularFile
        case S_IFDIR: .directory
        case S_IFLNK: .link
        case S_IFIFO: .fifo
        case S_IFCHR: .characterSpecial
        case S_IFBLK: .blockSpecial
        case S_IFSOCK: .socket
        default: nil
        }
    }
}

// MARK: - Walk

extension ClipboardArchiveCodec {
    /// An entry path as a ``ClipboardItemFailure`` names it: decoded for
    /// display, a byte that is not UTF-8 shown as U+FFFD.
    static func displayPath(_ path: [UInt8]) -> String {
        String(decoding: path, as: UTF8.self)
    }

    /// Writes one regular-file entry named `name` carrying exactly `byteCount`
    /// bytes of the file at `url`.
    ///
    /// - Throws: ``ClipboardItemFailure`` naming the file itself (an empty
    ///   path) when it cannot be opened, is not a regular file, or ends before
    ///   `byteCount`.
    static func writeFileEntry(
        _ url: URL, name: String, byteCount: Int, to encodeStream: ArchiveStream
    ) throws {
        let walk = TreeWalk(volume: ClipboardArchiveLocalVolume(), encodeStream: encodeStream)
        try walk.writeRegularFile(
            Array(url.path.utf8), in: AT_FDCWD, path: Array(name.utf8), failurePath: [],
            byteCount: byteCount)
    }

    /// Writes the tree rooted at `root` — the root's own entry, with an empty
    /// `PAT`, then every entry beneath it, each directory ahead of its contents
    /// and siblings in byte order — with the fields of
    /// ``ClipboardArchive/fieldKeys``.
    ///
    /// Walked here rather than by `writeDirectoryContents`, which reports a file
    /// it cannot open only as `ArchiveError.ioError` and archives a directory it
    /// cannot list as an empty one, raising nothing
    /// (docs/research/2026-10-22-applearchive-folder-encoder-read-failures.md).
    ///
    /// The walk moves through the tree on a ``DirectoryCursor``, so neither
    /// depth nor path length bounds the tree it can archive.
    ///
    /// - Throws: ``ClipboardItemFailure`` naming the first entry, relative
    ///   to `root`, that could not be described, listed, or read — or, with no
    ///   reason, the directory that was no longer where the walk left it. The
    ///   walk stops there: nothing is skipped.
    static func writeTree(at root: String, to encodeStream: ArchiveStream) throws {
        try writeTree(at: root, to: encodeStream, on: ClipboardArchiveLocalVolume())
    }

    /// ``writeTree(at:to:)`` against `volume`.
    static func writeTree<Volume: ClipboardArchiveVolume>(
        at root: String, to encodeStream: ArchiveStream, on volume: Volume
    ) throws {
        let walk = TreeWalk(volume: volume, encodeStream: encodeStream)
        guard let top = try walk.writeEntry(Array(root.utf8), in: AT_FDCWD, path: []) else { return }
        var cursor = DirectoryCursor(
            volume: volume, descriptor: top.descriptor, status: top.status, frame: top.directory)
        while true {
            if let name = cursor.frame.pending.popLast() {
                let parentPath = cursor.frame.path
                let path = parentPath.isEmpty ? name : parentPath + [0x2F] + name
                guard let child = try walk.writeEntry(name, in: cursor.descriptor, path: path)
                else { continue }
                cursor.descend(into: child.descriptor, status: child.status, frame: child.directory)
            } else if let parent = cursor.parentFrame {
                do {
                    _ = try cursor.ascend()
                } catch let failure as DirectoryCursorFailure {
                    throw failure.naming(parent.path)
                }
            } else {
                return
            }
        }
    }

    /// A directory whose entry is written and whose contents are not yet.
    struct TreeDirectory {
        let path: [UInt8]
        /// The names still to write, the next one last.
        var pending: [[UInt8]]
    }

    /// A directory ``TreeWalk/writeEntry(_:in:path:)`` opened to walk into.
    struct OpenedTreeDirectory {
        let descriptor: Int32
        let status: stat
        let directory: TreeDirectory
    }

    /// One walk's writes, against one volume and one encode stream.
    struct TreeWalk<Volume: ClipboardArchiveVolume> {
        let volume: Volume
        let encodeStream: ArchiveStream

        /// Writes the entry `name` in `directory`, at `path` in the archive.
        ///
        /// - Returns: for a directory holding anything, that directory, open;
        ///   otherwise `nil`, with the entry — and for an empty directory,
        ///   everything in it — written.
        func writeEntry(_ name: [UInt8], in directory: Int32, path: [UInt8]) throws
            -> OpenedTreeDirectory?
        {
            let status = try attempt(path) { () throws(Errno) in
                try volume.status(of: name, in: directory)
            }
            switch status.st_mode & S_IFMT {
            case S_IFREG:
                try writeRegularFile(name, in: directory, path: path, failurePath: path, byteCount: nil)
                return nil
            case S_IFDIR:
                let descriptor = try attempt(path) { () throws(Errno) in
                    try volume.openDirectory(name, in: directory)
                }
                do {
                    let opened = try attempt(path) { () throws(Errno) in
                        try volume.status(of: descriptor)
                    }
                    try encodeStream.writeHeader(ClipboardArchiveEntryHeader(path: path, status: opened).make())
                    let names = try attempt(path) { () throws(Errno) in
                        try volume.names(in: descriptor)
                    }
                    guard !names.isEmpty else {
                        volume.close(descriptor)
                        return nil
                    }
                    return OpenedTreeDirectory(
                        descriptor: descriptor, status: opened,
                        directory: TreeDirectory(
                            path: path, pending: names.sorted { $1.lexicographicallyPrecedes($0) }))
                } catch {
                    volume.close(descriptor)
                    throw error
                }
            case S_IFLNK:
                let target = try attempt(path) { () throws(Errno) in
                    try volume.linkTarget(of: name, in: directory)
                }
                try encodeStream.writeHeader(
                    ClipboardArchiveEntryHeader(path: path, status: status, linkTarget: target).make())
                return nil
            default:
                // A FIFO, device or socket is an entry, never a read.
                try encodeStream.writeHeader(ClipboardArchiveEntryHeader(path: path, status: status).make())
                return nil
            }
        }

        /// Writes the regular file `name` in `directory` as the entry `path`,
        /// carrying `byteCount` bytes, or its size when `nil`.
        ///
        /// Header and bytes both come from the one descriptor, so the entry
        /// describes exactly the file it carries. The read policy is plain,
        /// cached reads in `fileReadBlockSize` blocks, the policy AppleArchive
        /// itself applies.
        ///
        /// - Throws: ``ClipboardItemFailure`` naming `failurePath` when
        ///   the file cannot be opened, is not a regular file by the time it is
        ///   open, or ends before the byte count its header declared.
        func writeRegularFile(
            _ name: [UInt8], in directory: Int32, path: [UInt8], failurePath: [UInt8],
            byteCount: Int?
        ) throws {
            let descriptor = try attempt(failurePath) { () throws(Errno) in
                try volume.openFile(name, in: directory)
            }
            defer { volume.close(descriptor) }
            let status = try attempt(failurePath) { () throws(Errno) in
                try volume.status(of: descriptor)
            }
            guard (status.st_mode & S_IFMT) == S_IFREG else {
                throw ClipboardItemFailure(
                    itemPath: ClipboardArchiveCodec.displayPath(failurePath), reason: .posix(EFTYPE))
            }
            let byteCount = byteCount ?? Int(status.st_size)
            try encodeStream.writeHeader(
                ClipboardArchiveEntryHeader(path: path, status: status, byteCount: byteCount).make())

            var remaining = byteCount
            let buffer = UnsafeMutableRawBufferPointer.allocate(
                byteCount: min(ClipboardArchiveCodec.fileReadBlockSize, max(1, byteCount)), alignment: 16)
            defer { buffer.deallocate() }
            while remaining > 0 {
                let got = try attempt(failurePath) { () throws(Errno) in
                    try volume.read(
                        descriptor,
                        into: UnsafeMutableRawBufferPointer(
                            rebasing: buffer[..<min(buffer.count, remaining)]))
                }
                // The file ending before the byte count its header declared
                // would leave the entry short.
                guard got > 0 else {
                    throw ClipboardItemFailure(
                        itemPath: ClipboardArchiveCodec.displayPath(failurePath), reason: .endedEarly)
                }
                try encodeStream.writeBlob(
                    key: .init("DAT"), from: UnsafeRawBufferPointer(rebasing: buffer[..<got]))
                remaining -= got
            }
        }

        private func attempt<Result>(
            _ path: [UInt8], _ body: () throws(Errno) -> Result
        ) throws(ClipboardItemFailure) -> Result {
            do {
                return try body()
            } catch {
                throw ClipboardItemFailure(
                    itemPath: ClipboardArchiveCodec.displayPath(path), reason: .posix(error.rawValue))
            }
        }
    }
}
