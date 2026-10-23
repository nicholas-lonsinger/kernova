import AppleArchive
import Darwin
import Foundation
import System

// MARK: - Volume

/// The file-system calls the archive encoder makes, each naming an entry by
/// one name relative to an open directory — never by a full path, so no call
/// meets `PATH_MAX` however deep the tree — and every name as the volume's
/// raw bytes, which on SMB, NFS and exFAT need not be UTF-8.
///
/// `AT_FDCWD` with an absolute path names a source's own root.
protocol ClipboardArchiveVolume {
    /// The status of `name` in `directory`, not following a symlink.
    func status(of name: [UInt8], in directory: Int32) throws(Errno) -> stat
    /// The status of an open descriptor.
    func status(of descriptor: Int32) throws(Errno) -> stat
    /// Opens the directory `name` in `directory`, refusing a symlink.
    func openDirectory(_ name: [UInt8], in directory: Int32) throws(Errno) -> Int32
    /// Opens `name` in `directory` for reading, refusing a symlink and never
    /// waiting for a writer — opening a FIFO returns at once.
    func openFile(_ name: [UInt8], in directory: Int32) throws(Errno) -> Int32
    /// The names in an open directory, `.` and `..` left out, in no order.
    func names(in directory: Int32) throws(Errno) -> [[UInt8]]
    /// The target of the symlink `name` in `directory`.
    func linkTarget(of name: [UInt8], in directory: Int32) throws(Errno) -> [UInt8]
    /// Reads up to `buffer.count` bytes, returning `0` at the end of the file.
    func read(_ descriptor: Int32, into buffer: UnsafeMutableRawBufferPointer) throws(Errno) -> Int
    func close(_ descriptor: Int32)
}

/// The volumes this Mac mounts, through the `*at` system calls.
struct ClipboardArchiveLocalVolume: ClipboardArchiveVolume {
    func status(of name: [UInt8], in directory: Int32) throws(Errno) -> stat {
        var status = stat()
        try Self.check(Self.withName(name) { fstatat(directory, $0, &status, AT_SYMLINK_NOFOLLOW) })
        return status
    }

    func status(of descriptor: Int32) throws(Errno) -> stat {
        var status = stat()
        try Self.check(fstat(descriptor, &status))
        return status
    }

    func openDirectory(_ name: [UInt8], in directory: Int32) throws(Errno) -> Int32 {
        try Self.check(
            Self.withName(name) {
                openat(directory, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            })
    }

    func openFile(_ name: [UInt8], in directory: Int32) throws(Errno) -> Int32 {
        // `O_NONBLOCK` is ignored by a regular file's reads; what it changes is
        // that a FIFO swapped in after the status was taken opens at once, for
        // the caller's own type check to refuse, rather than parking the
        // encode until something writes to it.
        try Self.check(
            Self.withName(name) {
                openat(directory, $0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            })
    }

    func names(in directory: Int32) throws(Errno) -> [[UInt8]] {
        // `closedir` closes the descriptor `fdopendir` was handed, and the
        // caller still owns `directory`.
        let listing = try Self.check(dup(directory))
        guard let stream = fdopendir(listing) else {
            let code = errno
            Darwin.close(listing)
            throw Errno(rawValue: code)
        }
        defer { closedir(stream) }
        var names: [[UInt8]] = []
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                // `readdir` returns NULL both at the end and on an error, telling
                // them apart only by `errno`.
                if errno != 0 { throw Errno(rawValue: errno) }
                return names
            }
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                Array(raw.prefix(Int(entry.pointee.d_namlen)))
            }
            if name != [0x2E] && name != [0x2E, 0x2E] { names.append(name) }
        }
    }

    func linkTarget(of name: [UInt8], in directory: Int32) throws(Errno) -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: Int(PATH_MAX) + 1)
        let count = try Self.check(
            Self.withName(name) { name in
                buffer.withUnsafeMutableBytes { raw in
                    readlinkat(directory, name, raw.baseAddress, raw.count)
                }
            })
        guard count < buffer.count else { throw Errno.fileNameTooLong }
        return Array(buffer[..<count])
    }

    func read(_ descriptor: Int32, into buffer: UnsafeMutableRawBufferPointer) throws(Errno) -> Int {
        try Self.check(Darwin.read(descriptor, buffer.baseAddress, buffer.count))
    }

    func close(_ descriptor: Int32) { Darwin.close(descriptor) }

    private static func withName<R>(_ name: [UInt8], _ body: (UnsafePointer<CChar>) -> R) -> R {
        body(name.map { CChar(bitPattern: $0) } + [0])
    }

    @discardableResult
    private static func check<Result: BinaryInteger>(_ result: Result) throws(Errno) -> Result {
        guard result >= 0 else { throw Errno(rawValue: errno) }
        return result
    }
}

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
    /// - Throws: ``ClipboardSourceReadFailure`` naming the entry when its type
    ///   has no archive entry type or its path and link target outgrow a
    ///   header; ``ClipboardArchive/ArchiveError/unproducibleFieldKey`` for a
    ///   key in ``ClipboardArchive/fieldKeys`` this type has no value for — a
    ///   programming error, raised loudly rather than left out of every entry.
    func make() throws -> ArchiveHeader {
        let format = status.st_mode & S_IFMT
        guard let type = Self.entryType(format) else {
            throw ClipboardSourceReadFailure(
                itemPath: ClipboardArchiveCodec.displayPath(path), reason: .posix(EFTYPE))
        }
        guard ArchiveHeaderEncoding.fits(stringBytes: path.count + (linkTarget?.count ?? 0)) else {
            throw ClipboardSourceReadFailure(
                itemPath: ClipboardArchiveCodec.displayPath(path), reason: .posix(ENAMETOOLONG))
        }
        var encoding = ArchiveHeaderEncoding()
        for name in Self.keyNames {
            let key = ArchiveHeader.FieldKey(name)
            switch name {
            case "TYP": encoding.append(.uint(key: key, value: UInt64(type.rawValue)))
            case "PAT": encoding.append(string: path, key: key)
            case "LNK": if let linkTarget { encoding.append(string: linkTarget, key: key) }
            case "DEV":
                if format == S_IFCHR || format == S_IFBLK {
                    encoding.append(
                        .uint(key: key, value: UInt64(UInt32(bitPattern: status.st_rdev))))
                }
            case "UID": encoding.append(.uint(key: key, value: UInt64(status.st_uid)))
            case "GID": encoding.append(.uint(key: key, value: UInt64(status.st_gid)))
            case "MOD": encoding.append(.uint(key: key, value: UInt64(status.st_mode & 0o7777)))
            case "FLG": encoding.append(.uint(key: key, value: UInt64(status.st_flags)))
            // `CTM` is the entry's creation time (AADefs.h), not the inode
            // change time; a volume that keeps none reports it as zero, and
            // AppleArchive's own headers then leave the field out.
            case "CTM":
                let birth = status.st_birthtimespec
                if birth.tv_sec != 0 || birth.tv_nsec != 0 {
                    encoding.append(.timespec(key: key, value: birth))
                }
            case "MTM": encoding.append(.timespec(key: key, value: status.st_mtimespec))
            case "DAT":
                if format == S_IFREG {
                    encoding.append(.blob(key: key, size: UInt64(byteCount ?? Int(status.st_size))))
                }
            default:
                assertionFailure("ClipboardArchive.fieldKeys names \(name), which no entry produces")
                throw ClipboardArchive.ArchiveError.unproducibleFieldKey
            }
        }
        guard let header = encoding.make() else {
            throw ClipboardSourceReadFailure(
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

/// A header built field by field, whose string fields can carry bytes that are
/// not UTF-8 — `ArchiveHeader.Field.string` takes a `String`, which cannot
/// hold them.
///
/// Such a field goes in as a same-length placeholder whose bytes are then
/// replaced in the header's encoding: appending a field appends its encoding,
/// and a string field's encoding ends with the string's bytes.
private struct ArchiveHeaderEncoding {
    /// A header's encoding is at most `UInt16.max` bytes, and every field but
    /// the strings encodes in under this many together; `ArchiveHeader`
    /// traps on a field that would overflow it.
    private static let nonStringFieldBound = 256
    private let header = ArchiveHeader()
    private var patches: [(range: Range<Int>, bytes: [UInt8])] = []

    /// Whether string fields carrying `byteCount` bytes in all fit a header.
    static func fits(stringBytes byteCount: Int) -> Bool {
        nonStringFieldBound + byteCount <= Int(UInt16.max)
    }

    func append(_ field: ArchiveHeader.Field) {
        header.append(field)
    }

    /// Appends a string field carrying `bytes` exactly; the caller has
    /// checked that every string ``fits(stringBytes:)``.
    mutating func append(string bytes: [UInt8], key: ArchiveHeader.FieldKey) {
        let decoded = String(decoding: bytes, as: UTF8.self)
        guard Array(decoded.utf8) != bytes else {
            header.append(.string(key: key, value: decoded))
            return
        }
        header.append(.string(key: key, value: String(repeating: "_", count: bytes.count)))
        let end = header.withAAEncodedData { $0.count }
        patches.append((end - bytes.count..<end, bytes))
    }

    /// The header, or `nil` when its patched encoding does not parse.
    func make() -> ArchiveHeader? {
        guard !patches.isEmpty else { return header }
        var encoded = header.withAAEncodedData { Array($0) }
        for patch in patches { encoded.replaceSubrange(patch.range, with: patch.bytes) }
        return encoded.withUnsafeBufferPointer { ArchiveHeader(withAAEncodedData: $0) }
    }
}

// MARK: - Walk

extension ClipboardArchiveCodec {
    /// An entry path as a ``ClipboardSourceReadFailure`` names it: decoded for
    /// display, a byte that is not UTF-8 shown as U+FFFD.
    static func displayPath(_ path: [UInt8]) -> String {
        String(decoding: path, as: UTF8.self)
    }

    /// Writes one regular-file entry named `name` carrying exactly `byteCount`
    /// bytes of the file at `url`.
    ///
    /// - Throws: ``ClipboardSourceReadFailure`` naming the file itself (an empty
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
    /// The walk holds one directory open at a time, reaching a parent again
    /// through its child's `..` and confirming it is the directory it left, so
    /// neither depth nor path length bounds the tree it can archive.
    ///
    /// - Throws: ``ClipboardSourceReadFailure`` naming the first entry, relative
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
        guard var directory = try walk.writeEntry(Array(root.utf8), in: AT_FDCWD, path: [])
        else { return }
        defer { volume.close(directory.descriptor) }
        // Every directory between the root and `directory`, closed.
        var ancestors: [TreeDirectory] = []
        while true {
            if let name = directory.pending.popLast() {
                let path = directory.path.isEmpty ? name : directory.path + [0x2F] + name
                guard let child = try walk.writeEntry(name, in: directory.descriptor, path: path)
                else { continue }
                let left = directory.descriptor
                ancestors.append(directory)
                directory = child
                volume.close(left)
            } else if var parent = ancestors.popLast() {
                parent.descriptor = try walk.reopen(parent, from: directory)
                let left = directory.descriptor
                directory = parent
                volume.close(left)
            } else {
                return
            }
        }
    }

    /// A directory whose entry is written and whose contents are not yet.
    struct TreeDirectory {
        /// Open while this is the directory being walked; stale once it is an
        /// ancestor.
        var descriptor: Int32
        let device: dev_t
        let inode: ino_t
        let path: [UInt8]
        /// The names still to write, the next one last.
        var pending: [[UInt8]]
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
        func writeEntry(_ name: [UInt8], in directory: Int32, path: [UInt8]) throws -> TreeDirectory? {
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
                    try encodeStream.writeHeader(
                        ClipboardArchiveEntryHeader(path: path, status: opened).make())
                    let names = try attempt(path) { () throws(Errno) in
                        try volume.names(in: descriptor)
                    }
                    guard !names.isEmpty else {
                        volume.close(descriptor)
                        return nil
                    }
                    return TreeDirectory(
                        descriptor: descriptor, device: opened.st_dev, inode: opened.st_ino,
                        path: path,
                        pending: names.sorted { $1.lexicographicallyPrecedes($0) })
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

        /// Opens `parent` again through `child`'s `..`.
        ///
        /// - Throws: ``ClipboardSourceReadFailure`` naming `parent`, with no
        ///   reason, when `..` is no longer the directory the walk left.
        func reopen(_ parent: TreeDirectory, from child: TreeDirectory) throws -> Int32 {
            let descriptor = try attempt(parent.path) { () throws(Errno) in
                try volume.openDirectory([0x2E, 0x2E], in: child.descriptor)
            }
            do {
                let status = try attempt(parent.path) { () throws(Errno) in
                    try volume.status(of: descriptor)
                }
                guard status.st_dev == parent.device, status.st_ino == parent.inode else {
                    throw ClipboardSourceReadFailure(
                        itemPath: ClipboardArchiveCodec.displayPath(parent.path), reason: .unknown)
                }
                return descriptor
            } catch {
                volume.close(descriptor)
                throw error
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
        /// - Throws: ``ClipboardSourceReadFailure`` naming `failurePath` when
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
                throw ClipboardSourceReadFailure(
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
                    throw ClipboardSourceReadFailure(
                        itemPath: ClipboardArchiveCodec.displayPath(failurePath), reason: .endedEarly)
                }
                try encodeStream.writeBlob(
                    key: .init("DAT"), from: UnsafeRawBufferPointer(rebasing: buffer[..<got]))
                remaining -= got
            }
        }

        private func attempt<Result>(
            _ path: [UInt8], _ body: () throws(Errno) -> Result
        ) throws(ClipboardSourceReadFailure) -> Result {
            do {
                return try body()
            } catch {
                throw ClipboardSourceReadFailure(
                    itemPath: ClipboardArchiveCodec.displayPath(path), reason: .posix(error.rawValue))
            }
        }
    }
}
