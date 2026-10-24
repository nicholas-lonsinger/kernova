import Darwin
import Foundation
import System

/// The file-system calls the archive encoder makes, each naming an entry by
/// one name relative to an open directory — never by a full path, so no call
/// meets `PATH_MAX` however deep the tree — and every name as the volume's
/// raw bytes, which on SMB, NFS and exFAT need not be UTF-8.
///
/// `AT_FDCWD` with an absolute path names a tree's own root.
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

/// What an attribute call acts on: an open descriptor, or a name in an open
/// directory, never followed when it is a symlink.
enum ClipboardArchiveEntryTarget {
    case descriptor(Int32)
    case name([UInt8], in: Int32)
}

/// The attributes one `setattrlist` call applies; each is applied only when
/// present.
struct ClipboardArchiveSettableAttributes {
    var creation: timespec?
    var modification: timespec?
    /// Permission and set-id bits, `0o7777` at most.
    var mode: mode_t?
    var flags: UInt32?

    var isEmpty: Bool { creation == nil && modification == nil && mode == nil && flags == nil }
}

/// The file-system calls the archive extractor and the staged-tree remover
/// make, with the same naming rules as ``ClipboardArchiveVolume``.
protocol ClipboardArchiveWritableVolume: ClipboardArchiveVolume {
    /// Creates the directory `name` in `directory`, searchable and writable
    /// by its owner alone until its own mode is applied.
    func makeDirectory(_ name: [UInt8], in directory: Int32) throws(Errno)
    /// Creates the regular file `name` in `directory` — failing when anything
    /// already has the name — and opens it for writing around the page cache.
    func createFile(_ name: [UInt8], in directory: Int32) throws(Errno) -> Int32
    /// Writes up to `buffer.count` bytes, returning how many were written.
    func write(_ descriptor: Int32, from buffer: UnsafeRawBufferPointer) throws(Errno) -> Int
    /// Closes a descriptor that was written through, reporting the write
    /// failure the system deferred to the close.
    func closeWritten(_ descriptor: Int32) throws(Errno)
    /// Creates the symlink `name` in `directory` pointing at `target`.
    func makeSymlink(_ name: [UInt8], to target: [UInt8], in directory: Int32) throws(Errno)
    /// Creates the FIFO `name` in `directory` without opening it.
    func makeFIFO(_ name: [UInt8], in directory: Int32) throws(Errno)
    /// Creates the device or socket node `name` in `directory`, `type` one of
    /// `S_IFCHR`, `S_IFBLK` and `S_IFSOCK`.
    func makeNode(_ name: [UInt8], type: mode_t, device: dev_t, in directory: Int32) throws(Errno)
    /// Sets the group of `target`, leaving its owner as it is.
    func setGroup(_ group: gid_t, of target: ClipboardArchiveEntryTarget) throws(Errno)
    /// Applies `attributes` to `target`.
    func setAttributes(
        _ attributes: ClipboardArchiveSettableAttributes, of target: ClipboardArchiveEntryTarget
    ) throws(Errno)
    /// Removes `name` from `directory` — an empty directory when
    /// `isDirectory`, otherwise anything else, a symlink itself rather than
    /// its target.
    func remove(_ name: [UInt8], in directory: Int32, isDirectory: Bool) throws(Errno)
}

/// The volumes this Mac mounts, through the `*at` system calls.
struct ClipboardArchiveLocalVolume: ClipboardArchiveWritableVolume, Sendable {
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

    // MARK: - Writes

    func makeDirectory(_ name: [UInt8], in directory: Int32) throws(Errno) {
        try Self.check(Self.withName(name) { mkdirat(directory, $0, S_IRWXU) })
    }

    func createFile(_ name: [UInt8], in directory: Int32) throws(Errno) -> Int32 {
        let descriptor = try Self.check(
            Self.withName(name) {
                openat(
                    directory, $0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                    S_IRUSR | S_IWUSR)
            })
        // Around the page cache, so a multi-GB arrival does not evict what the
        // rest of the system has cached.
        _ = fcntl(descriptor, F_NOCACHE, 1)
        return descriptor
    }

    func write(_ descriptor: Int32, from buffer: UnsafeRawBufferPointer) throws(Errno) -> Int {
        while true {
            let written = Darwin.write(descriptor, buffer.baseAddress, buffer.count)
            if written >= 0 { return written }
            guard errno == EINTR else { throw Errno(rawValue: errno) }
        }
    }

    func closeWritten(_ descriptor: Int32) throws(Errno) {
        try Self.check(Darwin.close(descriptor))
    }

    func makeSymlink(_ name: [UInt8], to target: [UInt8], in directory: Int32) throws(Errno) {
        try Self.check(
            Self.withName(target) { target in
                Self.withName(name) { symlinkat(target, directory, $0) }
            })
    }

    func makeFIFO(_ name: [UInt8], in directory: Int32) throws(Errno) {
        // The guest agent's macOS 12 floor has no FIFO call that takes a
        // directory descriptor, and a full path would bring back the
        // `PATH_MAX` bound everything else here avoids.
        guard #available(macOS 13, *) else { throw Errno.notSupported }
        try Self.check(Self.withName(name) { mkfifoat(directory, $0, S_IRUSR | S_IWUSR) })
    }

    func makeNode(_ name: [UInt8], type: mode_t, device: dev_t, in directory: Int32) throws(Errno) {
        guard #available(macOS 13, *) else { throw Errno.notSupported }
        try Self.check(
            Self.withName(name) { mknodat(directory, $0, type | S_IRUSR | S_IWUSR, device) })
    }

    func setGroup(_ group: gid_t, of target: ClipboardArchiveEntryTarget) throws(Errno) {
        // The owner `-1` leaves it as it is.
        let owner = uid_t.max
        switch target {
        case .descriptor(let descriptor):
            try Self.check(fchown(descriptor, owner, group))
        case .name(let name, let directory):
            try Self.check(
                Self.withName(name) { fchownat(directory, $0, owner, group, AT_SYMLINK_NOFOLLOW) })
        }
    }

    func setAttributes(
        _ attributes: ClipboardArchiveSettableAttributes, of target: ClipboardArchiveEntryTarget
    ) throws(Errno) {
        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        // The buffer holds the attributes in the order of their bits, each
        // with its own size and no length word ahead of them (setattrlist(2)).
        var buffer: [UInt8] = []
        if var creation = attributes.creation {
            list.commonattr |= attrgroup_t(ATTR_CMN_CRTIME)
            withUnsafeBytes(of: &creation) { buffer.append(contentsOf: $0) }
        }
        if var modification = attributes.modification {
            list.commonattr |= attrgroup_t(ATTR_CMN_MODTIME)
            withUnsafeBytes(of: &modification) { buffer.append(contentsOf: $0) }
        }
        if let mode = attributes.mode {
            list.commonattr |= attrgroup_t(ATTR_CMN_ACCESSMASK)
            var mask = UInt32(mode)
            withUnsafeBytes(of: &mask) { buffer.append(contentsOf: $0) }
        }
        if var flags = attributes.flags {
            list.commonattr |= attrgroup_t(ATTR_CMN_FLAGS)
            withUnsafeBytes(of: &flags) { buffer.append(contentsOf: $0) }
        }
        guard list.commonattr != 0 else { return }
        let result = buffer.withUnsafeMutableBytes { raw in
            switch target {
            case .descriptor(let descriptor):
                fsetattrlist(descriptor, &list, raw.baseAddress, raw.count, 0)
            case .name(let name, let directory):
                Self.withName(name) {
                    setattrlistat(directory, $0, &list, raw.baseAddress, raw.count, UInt32(FSOPT_NOFOLLOW))
                }
            }
        }
        try Self.check(result)
    }

    func remove(_ name: [UInt8], in directory: Int32, isDirectory: Bool) throws(Errno) {
        try Self.check(
            Self.withName(name) { unlinkat(directory, $0, isDirectory ? AT_REMOVEDIR : 0) })
    }

    // MARK: - Private

    private static func withName<R>(_ name: [UInt8], _ body: (UnsafePointer<CChar>) -> R) -> R {
        body(name.map { CChar(bitPattern: $0) } + [0])
    }

    @discardableResult
    private static func check<Result: BinaryInteger>(_ result: Result) throws(Errno) -> Result {
        guard result >= 0 else { throw Errno(rawValue: errno) }
        return result
    }
}
