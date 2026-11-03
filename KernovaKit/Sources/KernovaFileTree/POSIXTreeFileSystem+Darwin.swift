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

    /// `fsetxattr` on `target`, a symlink opened itself through `O_SYMLINK`.
    static func setExtendedAttribute(_ name: [UInt8], to value: [UInt8], of target: TreeEntryTarget)
        throws(TreeFileSystemError)
    {
        switch target {
        case .descriptor(let descriptor):
            try setExtendedAttribute(name, to: value, on: descriptor)
        case .symlink(let linkName, let directory):
            let descriptor = try call(linkName) { openat(directory, $0, O_RDONLY | O_SYMLINK | O_CLOEXEC) }
            defer { closeDescriptor(descriptor) }
            try setExtendedAttribute(name, to: value, on: descriptor)
        }
    }

    private static func setExtendedAttribute(_ name: [UInt8], to value: [UInt8], on descriptor: Int32)
        throws(TreeFileSystemError)
    {
        try call(name) { name in
            value.withUnsafeBytes { fsetxattr(descriptor, name, $0.baseAddress, $0.count, 0, 0) }
        }
    }

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
