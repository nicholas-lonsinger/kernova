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

    static func open(_ directory: Int32, _ name: UnsafePointer<CChar>, _ flags: Int32, beneath: Bool) -> Int32 {
        kernova_openat2(directory, name, flags, 0, beneath ? 1 : 0)
    }

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
