/// The file-system calls that read a tree and move through it, each naming an
/// entry by one name relative to an open directory — never by a full path, so
/// no call meets `PATH_MAX` however deep the tree — and every name as the
/// volume's raw bytes, which on SMB, NFS and exFAT need not be UTF-8.
///
/// The platform's `AT_FDCWD` with an absolute path names a tree's own root.
/// Every other name is one entry of the open directory it is resolved in.
public protocol TreeFileSystem {
    /// The status of `name` in `directory`, not following a symlink.
    func status(of name: [UInt8], in directory: Int32) throws(TreeFileSystemError) -> FileStatus
    /// The status of an open descriptor.
    func status(of descriptor: Int32) throws(TreeFileSystemError) -> FileStatus
    /// Opens the directory `name` in `directory`, refusing a symlink.
    func openDirectory(_ name: [UInt8], in directory: Int32) throws(TreeFileSystemError) -> Int32
    /// Opens the directory above `directory`, through its `..` — the one open
    /// that leaves the directory it starts from, which ``DirectoryCursor``
    /// makes only to confirm the result is the directory it came down from.
    func openParent(of directory: Int32) throws(TreeFileSystemError) -> Int32
    /// Opens `name` in `directory` for reading, refusing a symlink and never
    /// waiting for a writer — opening a FIFO returns at once.
    func openFile(_ name: [UInt8], in directory: Int32) throws(TreeFileSystemError) -> Int32
    /// The names in an open directory, `.` and `..` left out, in no order.
    func names(in directory: Int32) throws(TreeFileSystemError) -> [[UInt8]]
    /// The target of the symlink `name` in `directory`.
    func linkTarget(of name: [UInt8], in directory: Int32) throws(TreeFileSystemError) -> [UInt8]
    /// Reads up to `buffer.count` bytes, returning `0` at the end of the file.
    func read(_ descriptor: Int32, into buffer: UnsafeMutableRawBufferPointer) throws(TreeFileSystemError) -> Int
    /// Closes a descriptor this file system opened.
    func close(_ descriptor: Int32)
}

/// The calls that change a tree, with the same naming rules as
/// ``TreeFileSystem``, from any number of threads at once.
public protocol MutableTreeFileSystem: TreeFileSystem, Sendable {
    /// Sets the permission and set-id bits of `name` in `directory`, not
    /// following a symlink.
    func setMode(_ mode: UInt32, of name: [UInt8], in directory: Int32) throws(TreeFileSystemError)
    /// Removes `name` from `directory` — an empty directory when
    /// `isDirectory`, otherwise anything else, a symlink itself rather than
    /// its target.
    func remove(_ name: [UInt8], in directory: Int32, isDirectory: Bool) throws(TreeFileSystemError)
    /// Renames `name` in `directory` to `newName` in `newDirectory`, failing
    /// when anything already has the new name — `EXDEV` when the two are on
    /// different volumes, `ENOTSUP` (Linux: `EINVAL`) when the volume cannot
    /// rename without replacing.
    func rename(_ name: [UInt8], in directory: Int32, to newName: [UInt8], in newDirectory: Int32)
        throws(TreeFileSystemError)
}

/// A file-system call's failure: the `errno` it set.
public struct TreeFileSystemError: Error, Hashable, Sendable {
    /// The `errno` value.
    public let code: Int32

    /// The failure `code` names.
    public init(code: Int32) {
        self.code = code
    }
}

/// What a tree entry is.
public enum FileKind: Hashable, Sendable {
    case regular
    case directory
    case symbolicLink
    case fifo
    case characterDevice
    case blockDevice
    case socket
    /// A type no other case names, such as a Darwin whiteout.
    case other

    /// The kind the type bits of a POSIX `st_mode` name — the same values on
    /// every POSIX system.
    public init(mode: UInt32) {
        switch mode & 0o170000 {
        case 0o100000: self = .regular
        case 0o040000: self = .directory
        case 0o120000: self = .symbolicLink
        case 0o010000: self = .fifo
        case 0o020000: self = .characterDevice
        case 0o060000: self = .blockDevice
        case 0o140000: self = .socket
        default: self = .other
        }
    }
}

/// An instant as a file's status carries it.
public struct FileTime: Hashable, Sendable {
    /// Whole seconds since 1970-01-01 00:00:00 UTC.
    public var seconds: Int64
    /// Nanoseconds past `seconds`, `0..<1_000_000_000`.
    public var nanoseconds: Int64

    /// The instant `nanoseconds` past `seconds`.
    public init(seconds: Int64, nanoseconds: Int64) {
        self.seconds = seconds
        self.nanoseconds = nanoseconds
    }
}

/// An entry's status, as every OS reports it.
public struct FileStatus: Hashable, Sendable {
    /// What the entry is.
    public var kind: FileKind
    /// The permission and set-id bits, `st_mode & 0o7777`.
    public var permissions: UInt32
    /// The volume the entry is on; with `inode`, the entry's identity.
    public var device: UInt64
    /// The entry's number on its volume.
    public var inode: UInt64
    /// The size in bytes.
    public var size: Int64
    /// The owning user's ID.
    public var owner: UInt32
    /// The owning group's ID.
    public var group: UInt32
    /// The device a character or block device names, as the OS encodes it.
    public var specialDevice: UInt64
    /// The BSD file flags; `0` where the OS keeps none.
    public var flags: UInt32
    /// When the contents last changed.
    public var modificationTime: FileTime
    /// When the entry was created; `nil` where the volume or the call keeps
    /// none.
    public var birthTime: FileTime?

    /// A status with every field given.
    public init(
        kind: FileKind, permissions: UInt32, device: UInt64, inode: UInt64, size: Int64 = 0,
        owner: UInt32 = 0, group: UInt32 = 0, specialDevice: UInt64 = 0, flags: UInt32 = 0,
        modificationTime: FileTime = FileTime(seconds: 0, nanoseconds: 0), birthTime: FileTime? = nil
    ) {
        self.kind = kind
        self.permissions = permissions
        self.device = device
        self.inode = inode
        self.size = size
        self.owner = owner
        self.group = group
        self.specialDevice = specialDevice
        self.flags = flags
        self.modificationTime = modificationTime
        self.birthTime = birthTime
    }
}
