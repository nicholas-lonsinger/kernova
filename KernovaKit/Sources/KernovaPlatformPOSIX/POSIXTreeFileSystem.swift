#if canImport(Darwin) || os(Linux)
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// The volumes this machine mounts, through the `*at` system calls.
///
/// Containment rests on the callers' single names, each resolved in a
/// directory they opened. Every open of a name in a directory also asks the
/// kernel to refuse a resolution that leaves it — Linux's `openat2` with
/// `RESOLVE_BENEATH`, Darwin's `O_RESOLVE_BENEATH` from macOS 15.4 — where
/// the OS has it; ``openParent(of:)`` is the one open that leaves.
public struct POSIXTreeFileSystem: MutableTreeFileSystem {
    /// Whether opens ask the kernel to refuse a resolution that leaves the
    /// directory.
    let resolvesBeneath: Bool

    /// The file system, with the kernel's containment on every open of a
    /// name in a directory where this OS has it, and with it off when
    /// `kernelContainment` is `false` — so a test can show what the callers'
    /// own names hold alone.
    public init(kernelContainment: Bool = true) {
        resolvesBeneath = kernelContainment && Self.kernelHasContainment
    }

    /// `fstatat` with `AT_SYMLINK_NOFOLLOW`.
    public func status(of name: [UInt8], in directory: Int32) throws(TreeFileSystemError) -> FileStatus {
        var status = stat()
        try Self.call(name) { fstatat(directory, $0, &status, AT_SYMLINK_NOFOLLOW) }
        return FileStatus(status)
    }

    /// `fstat`.
    public func status(of descriptor: Int32) throws(TreeFileSystemError) -> FileStatus {
        var status = stat()
        try Self.check(fstat(descriptor, &status))
        return FileStatus(status)
    }

    /// `O_DIRECTORY | O_NOFOLLOW`, beneath `directory`.
    public func openDirectory(_ name: [UInt8], in directory: Int32) throws(TreeFileSystemError) -> Int32 {
        try open(name, in: directory, flags: O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    }

    /// `..` in `directory`, with no kernel containment: the open leaves `directory` by design.
    public func openParent(of directory: Int32) throws(TreeFileSystemError) -> Int32 {
        try Self.call([0x2E, 0x2E]) {
            Self.open(directory, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC, beneath: false)
        }
    }

    /// `O_RDONLY | O_NOFOLLOW | O_NONBLOCK`, beneath `directory`.
    public func openFile(_ name: [UInt8], in directory: Int32) throws(TreeFileSystemError) -> Int32 {
        // `O_NONBLOCK` is ignored by a regular file's reads; what it changes is
        // that a FIFO swapped in after the status was taken opens at once, for
        // the caller's own type check to refuse, rather than parking the
        // read until something writes to it.
        try open(name, in: directory, flags: O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    }

    /// `readdir` over a duplicate of `directory`.
    public func names(in directory: Int32) throws(TreeFileSystemError) -> [[UInt8]] {
        // `closedir` closes the descriptor `fdopendir` was handed, and the
        // caller still owns `directory`.
        let listing = try Self.check(dup(directory))
        guard let stream = fdopendir(listing) else {
            let code = errno
            Self.closeDescriptor(listing)
            throw TreeFileSystemError(code: code)
        }
        defer { closedir(stream) }
        var names: [[UInt8]] = []
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                // `readdir` returns NULL both at the end and on an error, telling
                // them apart only by `errno`.
                if errno != 0 { throw TreeFileSystemError(code: errno) }
                return names
            }
            let name = Self.name(of: entry)
            if name != [0x2E] && name != [0x2E, 0x2E] { names.append(name) }
        }
    }

    /// `readlinkat`.
    public func linkTarget(of name: [UInt8], in directory: Int32) throws(TreeFileSystemError) -> [UInt8] {
        let capacity = Int(PATH_MAX) + 1
        var buffer = [CChar](repeating: 0, count: capacity)
        let count = try Self.call(name) { name in readlinkat(directory, name, &buffer, capacity) }
        guard count < capacity else { throw TreeFileSystemError(code: ENAMETOOLONG) }
        return buffer[..<count].map { UInt8(truncatingIfNeeded: $0) }
    }

    /// `read(2)`.
    public func read(_ descriptor: Int32, into buffer: UnsafeMutableRawBufferPointer) throws(TreeFileSystemError)
        -> Int
    {
        try Self.check(Self.readDescriptor(descriptor, buffer.baseAddress, buffer.count))
    }

    /// `close(2)`.
    public func close(_ descriptor: Int32) { Self.closeDescriptor(descriptor) }

    // MARK: - Changes

    /// `fchmodat` with `AT_SYMLINK_NOFOLLOW`.
    public func setMode(_ mode: UInt32, of name: [UInt8], in directory: Int32) throws(TreeFileSystemError) {
        try Self.call(name) { fchmodat(directory, $0, mode_t(truncatingIfNeeded: mode), AT_SYMLINK_NOFOLLOW) }
    }

    /// `unlinkat`, with `AT_REMOVEDIR` for a directory.
    public func remove(_ name: [UInt8], in directory: Int32, isDirectory: Bool) throws(TreeFileSystemError) {
        try Self.call(name) { unlinkat(directory, $0, isDirectory ? AT_REMOVEDIR : 0) }
    }

    /// Darwin's `renameatx_np` with `RENAME_EXCL`; Linux's `renameat2` with `RENAME_NOREPLACE`.
    public func rename(_ name: [UInt8], in directory: Int32, to newName: [UInt8], in newDirectory: Int32)
        throws(TreeFileSystemError)
    {
        try Self.call(name, newName) { Self.renameExclusive(directory, $0, newDirectory, $1) }
    }

    // MARK: - Private

    /// Opens `name` in `directory`, beneath it unless `directory` is
    /// `AT_FDCWD`, where the name is a tree's root.
    private func open(_ name: [UInt8], in directory: Int32, flags: Int32) throws(TreeFileSystemError) -> Int32 {
        let beneath = resolvesBeneath && directory != AT_FDCWD
        return try Self.call(name) { Self.open(directory, $0, flags, beneath: beneath) }
    }

    /// Runs `syscall` on `name` as a C string, reading `errno` while the
    /// string still exists: freeing it may change `errno`.
    @discardableResult
    private static func call<Result: BinaryInteger>(
        _ name: [UInt8], _ syscall: (UnsafePointer<CChar>) -> Result
    ) throws(TreeFileSystemError) -> Result {
        try call(name, []) { first, _ in syscall(first) }
    }

    /// ``call(_:_:)`` for a call taking two names.
    @discardableResult
    private static func call<Result: BinaryInteger>(
        _ first: [UInt8], _ second: [UInt8],
        _ syscall: (UnsafePointer<CChar>, UnsafePointer<CChar>) -> Result
    ) throws(TreeFileSystemError) -> Result {
        let firstName = first.map { CChar(bitPattern: $0) } + [0]
        let secondName = second.map { CChar(bitPattern: $0) } + [0]
        var code: Int32 = 0
        let result = withExtendedLifetime((firstName, secondName)) {
            let result = syscall(firstName, secondName)
            if result < 0 { code = errno }
            return result
        }
        guard result >= 0 else { throw TreeFileSystemError(code: code) }
        return result
    }

    @discardableResult
    private static func check<Result: BinaryInteger>(_ result: Result) throws(TreeFileSystemError) -> Result {
        guard result >= 0 else { throw TreeFileSystemError(code: errno) }
        return result
    }
}

extension TreeFileSystemError: CustomStringConvertible {
    /// The OS's message for the `errno`, with its number.
    public var description: String { "\(String(cString: strerror(code))) (errno \(code))" }
}

extension FileTime {
    /// The instant `time` holds.
    public init(_ time: timespec) {
        self.init(seconds: Int64(time.tv_sec), nanoseconds: Int64(time.tv_nsec))
    }
}
#endif
