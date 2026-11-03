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

    static func open(_ directory: Int32, _ name: UnsafePointer<CChar>, _ flags: Int32, beneath: Bool) -> Int32 {
        openat(directory, name, flags | (beneath ? O_RESOLVE_BENEATH : 0))
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
