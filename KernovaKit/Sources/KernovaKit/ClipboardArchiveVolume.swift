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

/// The attributes one `setattrlist` call applies, so a target refusing any of
/// them refuses the call.
struct ClipboardArchiveAttributes: Sendable {
    var creation: timespec?
    var modification: timespec?
    var flags: UInt32?
    /// Permission and set-id bits, `0o7777` at most.
    var mode: mode_t?

    init(
        creation: timespec? = nil, modification: timespec? = nil, flags: UInt32? = nil, mode: mode_t? = nil
    ) {
        self.creation = creation
        self.modification = modification
        self.flags = flags
        self.mode = mode
    }

    var isEmpty: Bool { creation == nil && modification == nil && flags == nil && mode == nil }

    /// Each attribute on its own, so a target refusing one refuses no other.
    var separated: [ClipboardArchiveAttributes] {
        [
            creation.map { ClipboardArchiveAttributes(creation: $0) },
            modification.map { ClipboardArchiveAttributes(modification: $0) },
            flags.map { ClipboardArchiveAttributes(flags: $0) },
            mode.map { ClipboardArchiveAttributes(mode: $0) },
        ].compactMap { $0 }
    }
}

/// The file-system calls the archive extractor, the staged-tree remover and
/// a staged item's landing make, with the same naming rules as
/// ``ClipboardArchiveVolume``, from any number of threads at once.
protocol ClipboardArchiveWritableVolume: ClipboardArchiveVolume, Sendable {
    /// Creates the directory `name` in `directory`, searchable and writable
    /// by its owner alone until its own mode is applied.
    func makeDirectory(_ name: [UInt8], in directory: Int32) throws(Errno)
    /// Creates the regular file `name` in `directory` — failing when anything
    /// already has the name — and opens it for writing around the page cache.
    func createFile(_ name: [UInt8], in directory: Int32) throws(Errno) -> Int32
    /// Writes up to `buffer.count` bytes at `offset`, returning how many were
    /// written.
    func write(_ descriptor: Int32, from buffer: UnsafeRawBufferPointer, at offset: Int64) throws(Errno) -> Int
    /// Sets the size of the open file `descriptor`, what it grows by reading
    /// as zeros.
    func setSize(of descriptor: Int32, to size: Int64) throws(Errno)
    /// The size, and alignment, of the holes the volume holding `descriptor`
    /// makes, or `nil` when it reports none.
    func holeSize(of descriptor: Int32) -> Int?
    /// Frees the blocks of `length` bytes at `offset` in the open file
    /// `descriptor`, which then read as zeros; both are multiples of
    /// ``holeSize(of:)``, and the range lies inside the file.
    func punchHole(in descriptor: Int32, at offset: Int64, length: Int64) throws(Errno)
    /// Closes a descriptor that was written through, reporting the write
    /// failure the system deferred to the close.
    func closeWritten(_ descriptor: Int32) throws(Errno)
    /// Creates the symlink `name` in `directory` pointing at `target`.
    func makeSymlink(_ name: [UInt8], to target: [UInt8], in directory: Int32) throws(Errno)
    /// Sets the group of `target`, leaving its owner as it is.
    func setGroup(_ group: gid_t, of target: ClipboardArchiveEntryTarget) throws(Errno)
    /// Applies `attributes` to `target` in one call.
    func setAttributes(_ attributes: ClipboardArchiveAttributes, of target: ClipboardArchiveEntryTarget)
        throws(Errno)
    /// Removes `name` from `directory` — an empty directory when
    /// `isDirectory`, otherwise anything else, a symlink itself rather than
    /// its target.
    func remove(_ name: [UInt8], in directory: Int32, isDirectory: Bool) throws(Errno)
    /// Renames `name` in `directory` to `newName` in `newDirectory`, failing
    /// when anything already has the new name — `EXDEV` when the two are on
    /// different volumes, `ENOTSUP` when the volume cannot rename without
    /// replacing.
    func rename(_ name: [UInt8], in directory: Int32, to newName: [UInt8], in newDirectory: Int32)
        throws(Errno)
}

/// The volumes this Mac mounts, through the `*at` system calls.
struct ClipboardArchiveLocalVolume: ClipboardArchiveWritableVolume {
    func status(of name: [UInt8], in directory: Int32) throws(Errno) -> stat {
        var status = stat()
        try Self.call(name) { fstatat(directory, $0, &status, AT_SYMLINK_NOFOLLOW) }
        return status
    }

    func status(of descriptor: Int32) throws(Errno) -> stat {
        var status = stat()
        try Self.check(fstat(descriptor, &status))
        return status
    }

    func openDirectory(_ name: [UInt8], in directory: Int32) throws(Errno) -> Int32 {
        try Self.call(name) { openat(directory, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
    }

    func openFile(_ name: [UInt8], in directory: Int32) throws(Errno) -> Int32 {
        // `O_NONBLOCK` is ignored by a regular file's reads; what it changes is
        // that a FIFO swapped in after the status was taken opens at once, for
        // the caller's own type check to refuse, rather than parking the
        // encode until something writes to it.
        try Self.call(name) { openat(directory, $0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC) }
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
        let count = try Self.call(name) { name in
            buffer.withUnsafeMutableBytes { raw in readlinkat(directory, name, raw.baseAddress, raw.count) }
        }
        guard count < buffer.count else { throw Errno.fileNameTooLong }
        return Array(buffer[..<count])
    }

    func read(_ descriptor: Int32, into buffer: UnsafeMutableRawBufferPointer) throws(Errno) -> Int {
        try Self.check(Darwin.read(descriptor, buffer.baseAddress, buffer.count))
    }

    func close(_ descriptor: Int32) { Darwin.close(descriptor) }

    // MARK: - Writes

    func makeDirectory(_ name: [UInt8], in directory: Int32) throws(Errno) {
        try Self.call(name) { mkdirat(directory, $0, S_IRWXU) }
    }

    func createFile(_ name: [UInt8], in directory: Int32) throws(Errno) -> Int32 {
        let descriptor = try Self.call(name) {
            openat(directory, $0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        }
        // Around the page cache, so a multi-GB arrival does not evict what the
        // rest of the system has cached.
        _ = fcntl(descriptor, F_NOCACHE, 1)
        return descriptor
    }

    func write(_ descriptor: Int32, from buffer: UnsafeRawBufferPointer, at offset: Int64) throws(Errno) -> Int {
        while true {
            let written = pwrite(descriptor, buffer.baseAddress, buffer.count, off_t(offset))
            if written >= 0 { return written }
            let code = errno
            guard code == EINTR else { throw Errno(rawValue: code) }
        }
    }

    func setSize(of descriptor: Int32, to size: Int64) throws(Errno) {
        try Self.check(ftruncate(descriptor, off_t(size)))
    }

    func holeSize(of descriptor: Int32) -> Int? {
        // 1 reports holes of no stated size (pathconf(2)), which gives a
        // hole nothing to align to.
        let size = fpathconf(descriptor, _PC_MIN_HOLE_SIZE)
        return size > 1 ? size : nil
    }

    func punchHole(in descriptor: Int32, at offset: Int64, length: Int64) throws(Errno) {
        var hole = fpunchhole_t(fp_flags: 0, reserved: 0, fp_offset: off_t(offset), fp_length: off_t(length))
        try Self.check(fcntl(descriptor, F_PUNCHHOLE, &hole))
    }

    func closeWritten(_ descriptor: Int32) throws(Errno) {
        try Self.check(Darwin.close(descriptor))
    }

    func makeSymlink(_ name: [UInt8], to target: [UInt8], in directory: Int32) throws(Errno) {
        try Self.call(target, name) { symlinkat($0, directory, $1) }
    }

    func setGroup(_ group: gid_t, of target: ClipboardArchiveEntryTarget) throws(Errno) {
        // The owner `-1` leaves it as it is.
        let owner = uid_t.max
        switch target {
        case .descriptor(let descriptor):
            try Self.check(fchown(descriptor, owner, group))
        case .name(let name, let directory):
            try Self.call(name) { fchownat(directory, $0, owner, group, AT_SYMLINK_NOFOLLOW) }
        }
    }

    func setAttributes(_ attributes: ClipboardArchiveAttributes, of target: ClipboardArchiveEntryTarget)
        throws(Errno)
    {
        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        // The buffer holds the attributes in the order of their bits, with no
        // length word ahead of them (setattrlist(2)).
        var buffer: [UInt8] = []
        func append<Value>(_ value: Value, as attribute: Int32) {
            list.commonattr |= attrgroup_t(attribute)
            withUnsafeBytes(of: value) { buffer.append(contentsOf: $0) }
        }
        if let creation = attributes.creation { append(creation, as: ATTR_CMN_CRTIME) }
        if let modification = attributes.modification { append(modification, as: ATTR_CMN_MODTIME) }
        if let mode = attributes.mode { append(UInt32(mode), as: ATTR_CMN_ACCESSMASK) }
        if let flags = attributes.flags { append(flags, as: ATTR_CMN_FLAGS) }
        switch target {
        case .descriptor(let descriptor):
            try Self.check(
                buffer.withUnsafeMutableBytes { raw in
                    fsetattrlist(descriptor, &list, raw.baseAddress, raw.count, 0)
                })
        case .name(let name, let directory):
            try Self.call(name) { name in
                buffer.withUnsafeMutableBytes { raw in
                    setattrlistat(directory, name, &list, raw.baseAddress, raw.count, UInt32(FSOPT_NOFOLLOW))
                }
            }
        }
    }

    func remove(_ name: [UInt8], in directory: Int32, isDirectory: Bool) throws(Errno) {
        try Self.call(name) { unlinkat(directory, $0, isDirectory ? AT_REMOVEDIR : 0) }
    }

    func rename(_ name: [UInt8], in directory: Int32, to newName: [UInt8], in newDirectory: Int32)
        throws(Errno)
    {
        try Self.call(name, newName) { renameatx_np(directory, $0, newDirectory, $1, UInt32(RENAME_EXCL)) }
    }

    // MARK: - Private

    /// Runs `syscall` on `name` as a C string, reading `errno` while the
    /// string still exists: freeing it may change `errno`.
    @discardableResult
    private static func call<Result: BinaryInteger>(
        _ name: [UInt8], _ syscall: (UnsafePointer<CChar>) -> Result
    ) throws(Errno) -> Result {
        try call(name, []) { first, _ in syscall(first) }
    }

    /// ``call(_:_:)`` for a call taking two names.
    @discardableResult
    private static func call<Result: BinaryInteger>(
        _ first: [UInt8], _ second: [UInt8],
        _ syscall: (UnsafePointer<CChar>, UnsafePointer<CChar>) -> Result
    ) throws(Errno) -> Result {
        let firstName = first.map { CChar(bitPattern: $0) } + [0]
        let secondName = second.map { CChar(bitPattern: $0) } + [0]
        var code: Int32 = 0
        let result = withExtendedLifetime((firstName, secondName)) {
            let result = syscall(firstName, secondName)
            if result < 0 { code = errno }
            return result
        }
        guard result >= 0 else { throw Errno(rawValue: code) }
        return result
    }

    @discardableResult
    private static func check<Result: BinaryInteger>(_ result: Result) throws(Errno) -> Result {
        guard result >= 0 else { throw Errno(rawValue: errno) }
        return result
    }
}
