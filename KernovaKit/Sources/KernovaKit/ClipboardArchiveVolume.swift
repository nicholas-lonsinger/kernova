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

/// The file-system calls the staged-item remover and a staged item's landing
/// make, with the same naming rules as ``ClipboardArchiveVolume``, from any
/// number of threads at once.
protocol ClipboardArchiveWritableVolume: ClipboardArchiveVolume, Sendable {
    /// Sets the permission and set-id bits of `name` in `directory`, not
    /// following a symlink.
    func setMode(_ mode: mode_t, of name: [UInt8], in directory: Int32) throws(Errno)
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

    func setMode(_ mode: mode_t, of name: [UInt8], in directory: Int32) throws(Errno) {
        try Self.call(name) { fchmodat(directory, $0, mode, AT_SYMLINK_NOFOLLOW) }
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
