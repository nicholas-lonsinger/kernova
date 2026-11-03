#if canImport(Darwin)
import Darwin

extension POSIXTreeFileSystem {
    /// Whether this kernel takes `O_RESOLVE_BENEATH`, which XNU added in
    /// macOS 15.4 (`xnu-11417.101.15`). Below it the same bit is `FMARK`
    /// (`sys/fcntl.h`), so it is passed only from 15.4.
    static let kernelHasContainment: Bool = {
        if #available(macOS 15.4, *) { return true }
        return false
    }()

    static func open(
        _ directory: Int32, _ name: UnsafePointer<CChar>, _ flags: Int32, mode: UInt32, beneath: Bool
    ) -> Int32 {
        openat(directory, name, flags | (beneath ? O_RESOLVE_BENEATH : 0), mode_t(mode))
    }

    /// The errnos with which a target refuses an attribute it cannot hold: on
    /// exFAT and FAT every flag but `UF_HIDDEN` is `EINVAL`, and a volume
    /// without extended attributes answers `ENOTSUP`.
    static let unheldAttributeCodes: Set<Int32> = [EINVAL, ENOTSUP, EOPNOTSUPP, EPERM]

    /// Around the page cache, so a multi-GB arrival does not evict what the
    /// rest of the system has cached.
    static func bypassCache(_ descriptor: Int32) { _ = fcntl(descriptor, F_NOCACHE, 1) }

    static func closeReporting(_ descriptor: Int32) -> Int32 { Darwin.close(descriptor) }

    /// `setattrlist(2)` on `target` with every attribute of `attributes` in one call.
    static func apply(_ attributes: TreeEntryAttributes, to target: TreeEntryTarget) throws(TreeFileSystemError) {
        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        // The buffer holds the attributes in the order of their bits, with no
        // length word ahead of them (setattrlist(2)).
        var buffer: [UInt8] = []
        func append<Value>(_ value: Value, as attribute: Int32) {
            list.commonattr |= attrgroup_t(attribute)
            withUnsafeBytes(of: value) { buffer.append(contentsOf: $0) }
        }
        if let birth = attributes.birthTime { append(timespec(birth), as: ATTR_CMN_CRTIME) }
        if let modification = attributes.modificationTime { append(timespec(modification), as: ATTR_CMN_MODTIME) }
        if let permissions = attributes.permissions { append(permissions, as: ATTR_CMN_ACCESSMASK) }
        if let flags = attributes.flags { append(flags, as: ATTR_CMN_FLAGS) }
        let count = buffer.count
        switch target {
        case .descriptor(let descriptor):
            try check(fsetattrlist(descriptor, &list, &buffer, count, 0))
        case .symlink(let name, let directory):
            try call(name) { setattrlistat(directory, $0, &list, &buffer, count, UInt32(FSOPT_NOFOLLOW)) }
        }
    }

    /// `fsetxattr` on `target`.
    static func setExtendedAttribute(_ name: [UInt8], to value: [UInt8], of target: TreeEntryTarget)
        throws(TreeFileSystemError)
    {
        guard let descriptor = try openAttributes(of: target) else { return }
        defer { closeAttributes(descriptor, of: target) }
        try call(name) { name in
            value.withUnsafeBytes { fsetxattr(descriptor, name, $0.baseAddress, $0.count, 0, 0) }
        }
    }

    /// The descriptor `target`'s extended attributes are reached through: a symlink opened itself, through
    /// `O_SYMLINK`.
    static func openAttributes(of target: TreeEntryTarget) throws(TreeFileSystemError) -> Int32? {
        switch target {
        case .descriptor(let descriptor):
            return descriptor
        case .symlink(let name, let directory):
            return try call(name) { openat(directory, $0, O_RDONLY | O_SYMLINK | O_CLOEXEC) }
        }
    }

    /// Closes what ``openAttributes(of:)`` opened for `target`.
    static func closeAttributes(_ descriptor: Int32, of target: TreeEntryTarget) {
        if case .symlink = target { closeDescriptor(descriptor) }
    }

    static func listAttributes(_ descriptor: Int32, _ names: UnsafeMutableRawPointer?, _ size: Int) -> Int {
        flistxattr(descriptor, names?.assumingMemoryBound(to: CChar.self), size, 0)
    }

    static func getAttribute(
        _ descriptor: Int32, _ name: UnsafePointer<CChar>, _ value: UnsafeMutableRawPointer?, _ size: Int
    ) -> Int {
        fgetxattr(descriptor, name, value, size, 0, 0)
    }

    static let seekData = SEEK_DATA
    static let seekHole = SEEK_HOLE

    /// The errnos with which `lseek(2)` says the volume reports no holes.
    static let unreportedHoleCodes: Set<Int32> = [EINVAL, ENOTTY, ENOTSUP, EOPNOTSUPP]

    /// `EILSEQ` for a name that is not UTF-8: APFS stores only UTF-8 names.
    static func nameRefusal(_ name: [UInt8]) -> TreeFileSystemError? {
        Array(String(decoding: name, as: UTF8.self).utf8) == name ? nil : TreeFileSystemError(code: EILSEQ)
    }

    static func renameExclusive(
        _ directory: Int32, _ name: UnsafePointer<CChar>, _ newDirectory: Int32, _ newName: UnsafePointer<CChar>
    ) -> Int32 {
        renameatx_np(directory, name, newDirectory, newName, UInt32(RENAME_EXCL))
    }

    static func readDescriptor(_ descriptor: Int32, _ buffer: UnsafeMutableRawPointer?, _ count: Int) -> Int {
        Darwin.read(descriptor, buffer, count)
    }

    static func closeDescriptor(_ descriptor: Int32) { _ = Darwin.close(descriptor) }

    static func name(of entry: UnsafeMutablePointer<dirent>) -> [UInt8] {
        withUnsafeBytes(of: entry.pointee.d_name) { raw in Array(raw.prefix(Int(entry.pointee.d_namlen))) }
    }
}

extension POSIXTreeFileSystem {
    /// `fpathconf(_PC_MIN_HOLE_SIZE)`; exFAT, FAT and HFS+ report none.
    public func holeSize(of descriptor: Int32) -> Int? {
        // 1 reports holes of no stated size (pathconf(2)), which gives a hole
        // nothing to align to.
        let size = fpathconf(descriptor, _PC_MIN_HOLE_SIZE)
        return size > 1 ? size : nil
    }

    /// `F_PUNCHHOLE`.
    public func punchHole(in descriptor: Int32, at offset: Int64, length: Int64) throws(TreeFileSystemError) {
        var hole = fpunchhole_t(fp_flags: 0, reserved: 0, fp_offset: off_t(offset), fp_length: off_t(length))
        try Self.check(fcntl(descriptor, F_PUNCHHOLE, &hole))
    }
}

extension POSIXTreeFileSystem {
    /// `fgetxattr` of `com.apple.decmpfs` with `XATTR_SHOWCOMPRESSION`, which alone shows it.
    public func compressedStorage(of descriptor: Int32, maxByteCount: Int) throws(TreeFileSystemError) -> [UInt8]? {
        try Self.attribute(Self.decmpfsName, of: descriptor, options: XATTR_SHOWCOMPRESSION, maxByteCount: maxByteCount)
    }

    /// `fgetxattr` of `XATTR_RESOURCEFORK_NAME` with no buffer.
    public func resourceForkSize(of descriptor: Int32, showingCompression: Bool) throws(TreeFileSystemError)
        -> UInt64
    {
        let size = Self.call(XATTR_RESOURCEFORK_NAME) { name in
            fgetxattr(descriptor, name, nil, 0, 0, Self.forkOptions(showingCompression))
        }
        switch size {
        case .success(let size): return UInt64(size)
        case .failure(let error) where error.code == ENOATTR: return 0
        case .failure(let error): throw error
        }
    }

    /// `fgetxattr` of `XATTR_RESOURCEFORK_NAME` at a position, which its 32-bit argument bounds; past the
    /// end it reads nothing.
    public func readResourceFork(
        _ descriptor: Int32, into buffer: UnsafeMutableRawBufferPointer, at offset: UInt64, showingCompression: Bool
    ) throws(TreeFileSystemError) -> Int {
        guard let position = UInt32(exactly: offset) else { throw TreeFileSystemError(code: EFBIG) }
        let size = try resourceForkSize(of: descriptor, showingCompression: showingCompression)
        guard offset < size else { return 0 }
        let count = Int(min(UInt64(buffer.count), size - offset))
        return try Self.check(
            fgetxattr(
                descriptor, XATTR_RESOURCEFORK_NAME, buffer.baseAddress, count, position,
                Self.forkOptions(showingCompression)))
    }

    /// `fsetxattr` of `XATTR_RESOURCEFORK_NAME` at a position, which its 32-bit argument bounds; `false` for
    /// the errnos with which a volume refuses an attribute it cannot hold.
    public func writeResourceFork(_ descriptor: Int32, from buffer: UnsafeRawBufferPointer, at offset: UInt64)
        throws(TreeFileSystemError) -> Bool
    {
        guard let position = UInt32(exactly: offset),
            UInt64(position) + UInt64(buffer.count) <= UInt64(UInt32.max) + 1
        else { throw TreeFileSystemError(code: EFBIG) }
        let written = fsetxattr(descriptor, XATTR_RESOURCEFORK_NAME, buffer.baseAddress, buffer.count, position, 0)
        guard written < 0 else { return true }
        let code = errno
        if Self.unheldAttributeCodes.contains(code) { return false }
        throw TreeFileSystemError(code: code)
    }

    /// `fgetattrlist` of `ATTR_VOL_CAPABILITIES` on `directory`: `VOL_CAP_FMT_DECMPFS_COMPRESSION` both valid
    /// and set, the check `copyfile` makes before it copies a file compressed.
    public func volumeStoresCompressedFiles(_ directory: Int32) throws(TreeFileSystemError) -> Bool {
        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        list.volattr = attrgroup_t(ATTR_VOL_INFO) | attrgroup_t(ATTR_VOL_CAPABILITIES)
        // A length word, then the capabilities (getattrlist(2)).
        struct Reply {
            var length: UInt32
            var capabilities: vol_capabilities_attr_t
        }
        var reply = Reply(length: 0, capabilities: vol_capabilities_attr_t())
        try Self.check(fgetattrlist(directory, &list, &reply, MemoryLayout<Reply>.size, 0))
        let format = Int(VOL_CAPABILITIES_FORMAT)
        let bit = UInt32(VOL_CAP_FMT_DECMPFS_COMPRESSION)
        let valid = withUnsafeBytes(of: reply.capabilities.valid) {
            $0.load(fromByteOffset: format * 4, as: UInt32.self)
        }
        let set = withUnsafeBytes(of: reply.capabilities.capabilities) {
            $0.load(fromByteOffset: format * 4, as: UInt32.self)
        }
        return valid & bit != 0 && set & bit != 0
    }

    /// `fsetxattr` of `com.apple.decmpfs` with `XATTR_SHOWCOMPRESSION`.
    public func setCompressedStorage(_ attribute: [UInt8], of descriptor: Int32) throws(TreeFileSystemError) {
        try Self.check(
            attribute.withUnsafeBytes {
                fsetxattr(descriptor, Self.decmpfsName, $0.baseAddress, $0.count, 0, XATTR_SHOWCOMPRESSION)
            })
    }

    /// One `fchflags` of `flags | UF_COMPRESSED`.
    public func setCompressedFlags(_ flags: UInt32, of descriptor: Int32) throws(TreeFileSystemError) {
        try Self.check(fchflags(descriptor, flags | UInt32(UF_COMPRESSED)))
    }

    static let decmpfsName = "com.apple.decmpfs"

    private static func forkOptions(_ showingCompression: Bool) -> Int32 {
        showingCompression ? XATTR_SHOWCOMPRESSION : 0
    }

    private static func call(_ name: String, _ syscall: (UnsafePointer<CChar>) -> Int) -> Result<
        Int, TreeFileSystemError
    > {
        let result = syscall(name)
        return result < 0 ? .failure(TreeFileSystemError(code: errno)) : .success(result)
    }

    /// The attribute `name` of `descriptor` read with `options`, or nil when it has none or it is longer than
    /// `maxByteCount`.
    private static func attribute(_ name: String, of descriptor: Int32, options: Int32, maxByteCount: Int)
        throws(TreeFileSystemError) -> [UInt8]?
    {
        while true {
            let size = fgetxattr(descriptor, name, nil, 0, 0, options)
            if size < 0 {
                let code = errno
                if code == ENOATTR { return nil }
                throw TreeFileSystemError(code: code)
            }
            guard size <= maxByteCount else { return nil }
            var value = [UInt8](repeating: 0, count: size)
            let got = value.withUnsafeMutableBytes { fgetxattr(descriptor, name, $0.baseAddress, size, 0, options) }
            // `ERANGE`: the value grew since its length was read.
            if got < 0 && errno == ERANGE { continue }
            try check(got)
            return Array(value[..<got])
        }
    }
}

extension timespec {
    init(_ time: FileTime) {
        self.init(tv_sec: Int(time.seconds), tv_nsec: Int(time.nanoseconds))
    }
}

extension FileStatus {
    /// The status `stat(2)` reported. A birth time of zero is a volume that
    /// keeps none.
    public init(_ status: stat) {
        let birth = status.st_birthtimespec
        self.init(
            kind: FileKind(mode: UInt32(status.st_mode)), permissions: UInt32(status.st_mode) & 0o7777,
            device: UInt64(UInt32(bitPattern: status.st_dev)), inode: UInt64(status.st_ino),
            size: Int64(status.st_size), owner: status.st_uid, group: status.st_gid,
            specialDevice: UInt64(UInt32(bitPattern: status.st_rdev)), flags: status.st_flags,
            modificationTime: FileTime(status.st_mtimespec),
            birthTime: birth.tv_sec == 0 && birth.tv_nsec == 0 ? nil : FileTime(birth))
    }
}
#endif
