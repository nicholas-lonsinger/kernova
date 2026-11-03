#if os(Linux)
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import CKernovaShims

extension POSIXTreeFileSystem {
    /// Every supported Linux kernel has `openat2` (5.6 and later), so an
    /// `ENOSYS` from it is a failure like any other.
    static let kernelHasContainment = true

    static func open(
        _ directory: Int32, _ name: UnsafePointer<CChar>, _ flags: Int32, mode: UInt32, beneath: Bool
    ) -> Int32 {
        kernova_openat2(directory, name, flags, mode, beneath ? 1 : 0)
    }

    /// The errnos with which a target refuses an attribute it cannot hold:
    /// a symlink's mode is `EOPNOTSUPP` (`ENOTSUP` is the same value), a
    /// `user.` attribute on a symlink is `EPERM`, and a name outside the
    /// namespaces the kernel knows, such as an Apple attribute, is
    /// `EOPNOTSUPP`.
    static let unheldAttributeCodes: Set<Int32> = [EINVAL, EOPNOTSUPP, EPERM]

    static func bypassCache(_ descriptor: Int32) {}

    static func closeReporting(_ descriptor: Int32) -> Int32 {
        #if canImport(Glibc)
        Glibc.close(descriptor)
        #else
        Musl.close(descriptor)
        #endif
    }

    /// `utimensat`'s "leave this time as it is", `((1l << 30) - 2l)` in the
    /// kernel's `include/uapi/linux/stat.h`.
    private static let leaveTime = timespec(tv_sec: 0, tv_nsec: (1 << 30) - 2)

    /// The mode, then the modification time, one call each. Linux keeps no
    /// Darwin flags and sets no birth time, so those are left out.
    static func apply(_ attributes: TreeEntryAttributes, to target: TreeEntryTarget) throws(TreeFileSystemError) {
        let times = attributes.modificationTime.map {
            [leaveTime, timespec(tv_sec: Int($0.seconds), tv_nsec: Int($0.nanoseconds))]
        }
        switch target {
        case .descriptor(let descriptor):
            if let permissions = attributes.permissions { try check(fchmod(descriptor, mode_t(permissions))) }
            if let times { try check(futimens(descriptor, times)) }
        case .symlink(let name, let directory):
            if let permissions = attributes.permissions {
                try call(name) { fchmodat(directory, $0, mode_t(permissions), AT_SYMLINK_NOFOLLOW) }
            }
            if let times { try call(name) { utimensat(directory, $0, times, AT_SYMLINK_NOFOLLOW) } }
        }
    }

    /// `fsetxattr` on a descriptor; a symlink takes no `user.` attribute on
    /// Linux, so it is refused with `EPERM`.
    static func setExtendedAttribute(_ name: [UInt8], to value: [UInt8], of target: TreeEntryTarget)
        throws(TreeFileSystemError)
    {
        guard case .descriptor(let descriptor) = target else { throw TreeFileSystemError(code: EPERM) }
        try call(name) { name in
            value.withUnsafeBytes { kernova_set_xattr(descriptor, name, $0.baseAddress, $0.count) }
        }
    }

    /// A descriptor's own; `nil` for a symlink, which takes no `user.`
    /// attribute on Linux and cannot be opened for one.
    static func openAttributes(of target: TreeEntryTarget) throws(TreeFileSystemError) -> Int32? {
        guard case .descriptor(let descriptor) = target else { return nil }
        return descriptor
    }

    static func closeAttributes(_ descriptor: Int32, of target: TreeEntryTarget) {}

    static func listAttributes(_ descriptor: Int32, _ names: UnsafeMutableRawPointer?, _ size: Int) -> Int {
        kernova_list_xattr(descriptor, names?.assumingMemoryBound(to: CChar.self), size)
    }

    static func getAttribute(
        _ descriptor: Int32, _ name: UnsafePointer<CChar>, _ value: UnsafeMutableRawPointer?, _ size: Int
    ) -> Int {
        kernova_get_xattr(descriptor, name, value, size)
    }

    /// `SEEK_DATA` and `SEEK_HOLE` from the kernel's `include/uapi/linux/fs.h`,
    /// which the C library declares only under `_GNU_SOURCE`.
    static let seekData: Int32 = 3
    static let seekHole: Int32 = 4

    /// The errnos with which `lseek(2)` says the volume reports no holes.
    static let unreportedHoleCodes: Set<Int32> = [EINVAL, ENOTTY, EOPNOTSUPP]

    /// Linux's file systems take any name of bytes but `/` and NUL.
    static func nameRefusal(_ name: [UInt8]) -> TreeFileSystemError? { nil }

    static func renameExclusive(
        _ directory: Int32, _ name: UnsafePointer<CChar>, _ newDirectory: Int32, _ newName: UnsafePointer<CChar>
    ) -> Int32 {
        kernova_rename_exclusive(directory, name, newDirectory, newName)
    }

    static func readDescriptor(_ descriptor: Int32, _ buffer: UnsafeMutableRawPointer?, _ count: Int) -> Int {
        #if canImport(Glibc)
        Glibc.read(descriptor, buffer, count)
        #else
        Musl.read(descriptor, buffer, count)
        #endif
    }

    static func closeDescriptor(_ descriptor: Int32) {
        #if canImport(Glibc)
        _ = Glibc.close(descriptor)
        #else
        _ = Musl.close(descriptor)
        #endif
    }

    static func name(of entry: UnsafeMutablePointer<dirent>) -> [UInt8] {
        withUnsafeBytes(of: entry.pointee.d_name) { raw in Array(raw.prefix { $0 != 0 }) }
    }
}

extension POSIXTreeFileSystem {
    /// The volume's block size, `st_blksize`: every Linux file system reads a
    /// skipped range as zeros, and those that make holes make them in blocks.
    public func holeSize(of descriptor: Int32) -> Int? {
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_blksize > 1 else { return nil }
        return Int(status.st_blksize)
    }

    /// `fallocate` with `FALLOC_FL_PUNCH_HOLE | FALLOC_FL_KEEP_SIZE`.
    public func punchHole(in descriptor: Int32, at offset: Int64, length: Int64) throws(TreeFileSystemError) {
        try Self.check(kernova_punch_hole(descriptor, offset, length))
    }
}

extension POSIXTreeFileSystem {
    /// Linux stores no file compressed through decmpfs.
    public func compressedStorage(of descriptor: Int32, maxByteCount: Int) throws(TreeFileSystemError) -> [UInt8]? {
        nil
    }

    /// Linux keeps no resource forks.
    public func resourceForkSize(of descriptor: Int32, showingCompression: Bool) throws(TreeFileSystemError)
        -> UInt64
    {
        0
    }

    /// Linux keeps no resource forks, so there is nothing to read.
    public func readResourceFork(
        _ descriptor: Int32, into buffer: UnsafeMutableRawBufferPointer, at offset: UInt64, showingCompression: Bool
    ) throws(TreeFileSystemError) -> Int {
        0
    }

    /// `false`: Linux keeps no resource forks.
    public func writeResourceFork(_ descriptor: Int32, from buffer: UnsafeRawBufferPointer, at offset: UInt64)
        throws(TreeFileSystemError) -> Bool
    {
        false
    }

    /// `false`: Linux stores no file compressed through decmpfs.
    public func volumeStoresCompressedFiles(_ directory: Int32) throws(TreeFileSystemError) -> Bool { false }

    /// `ENOTSUP`: Linux stores no file compressed through decmpfs.
    public func setCompressedStorage(_ attribute: [UInt8], of descriptor: Int32) throws(TreeFileSystemError) {
        throw TreeFileSystemError(code: ENOTSUP)
    }

    /// `ENOTSUP`: Linux stores no file compressed through decmpfs.
    public func setCompressedFlags(_ flags: UInt32, of descriptor: Int32) throws(TreeFileSystemError) {
        throw TreeFileSystemError(code: ENOTSUP)
    }
}

extension FileStatus {
    /// The status `stat(2)` reported, which on Linux carries no birth time
    /// and no file flags.
    public init(_ status: stat) {
        self.init(
            kind: FileKind(mode: UInt32(status.st_mode)), permissions: UInt32(status.st_mode) & 0o7777,
            device: UInt64(status.st_dev), inode: UInt64(status.st_ino), size: Int64(status.st_size),
            owner: status.st_uid, group: status.st_gid, specialDevice: UInt64(status.st_rdev),
            modificationTime: FileTime(status.st_mtim))
    }
}
#endif
