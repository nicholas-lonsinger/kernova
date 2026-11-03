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
    /// Reads up to `buffer.count` bytes at `offset`, returning `0` at the end
    /// of the file.
    func read(_ descriptor: Int32, into buffer: UnsafeMutableRawBufferPointer, at offset: Int64)
        throws(TreeFileSystemError) -> Int
    /// The first run of the open file's stored bytes at or after `offset` —
    /// what lies between `offset` and it is a hole — or `nil` when only a
    /// hole lies past `offset`. A volume that reports no holes stores the
    /// whole file.
    func dataRun(in descriptor: Int32, from offset: Int64) throws(TreeFileSystemError) -> Range<Int64>?
    /// The names of `target`'s extended attributes, in no order; none where
    /// the OS keeps none on such a target.
    func extendedAttributeNames(of target: TreeEntryTarget) throws(TreeFileSystemError) -> [[UInt8]]
    /// The value of `target`'s extended attribute `name`, or `nil` when it is
    /// longer than `maxByteCount` bytes, which are then never read.
    func extendedAttribute(_ name: [UInt8], of target: TreeEntryTarget, maxByteCount: Int)
        throws(TreeFileSystemError) -> [UInt8]?
    /// The `com.apple.decmpfs` attribute of the open regular file — the header of its compressed storage
    /// and, for some types, its compressed bytes — or `nil` when the file is not stored compressed, the OS
    /// stores no file so, or the attribute is longer than `maxByteCount` bytes.
    func compressedStorage(of descriptor: Int32, maxByteCount: Int) throws(TreeFileSystemError) -> [UInt8]?
    /// The size of the open regular file's resource fork, 0 when it has none: as the file shows it, which
    /// for a compressed file is none, or, `showingCompression`, as its compressed storage holds it.
    func resourceForkSize(of descriptor: Int32, showingCompression: Bool) throws(TreeFileSystemError) -> UInt64
    /// Reads up to `buffer.count` bytes of the open regular file's resource fork at `offset`, as
    /// ``resourceForkSize(of:showingCompression:)`` sees it, returning `0` past its end.
    func readResourceFork(
        _ descriptor: Int32, into buffer: UnsafeMutableRawBufferPointer, at offset: UInt64, showingCompression: Bool
    ) throws(TreeFileSystemError) -> Int
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

    /// Creates the directory `name` in `directory`, searchable and writable by
    /// its owner alone until its own mode is applied, failing when anything
    /// already has the name.
    func makeDirectory(_ name: [UInt8], in directory: Int32) throws(TreeFileSystemError)
    /// Creates the regular file `name` in `directory`, readable and writable
    /// by its owner alone until its own mode is applied, and opens it for
    /// writing — failing when anything already has the name, a symlink
    /// included, which it never follows.
    func createFile(_ name: [UInt8], in directory: Int32) throws(TreeFileSystemError) -> Int32
    /// Creates the symlink `name` in `directory` pointing at `target`, failing
    /// when anything already has the name.
    func makeSymlink(_ name: [UInt8], to target: [UInt8], in directory: Int32) throws(TreeFileSystemError)
    /// Writes up to `buffer.count` bytes at `offset`, returning how many were
    /// written: at least one, for a buffer that is not empty.
    func write(_ descriptor: Int32, from buffer: UnsafeRawBufferPointer, at offset: Int64)
        throws(TreeFileSystemError) -> Int
    /// Sets the size of the open file `descriptor`, what it grows by reading
    /// as zeros.
    func setSize(of descriptor: Int32, to size: Int64) throws(TreeFileSystemError)
    /// The size, and alignment, of the holes the volume holding `descriptor`
    /// makes, or `nil` when it makes none.
    func holeSize(of descriptor: Int32) -> Int?
    /// Frees the blocks of `length` bytes at `offset` in the open file
    /// `descriptor`, which then read as zeros; both are multiples of
    /// ``holeSize(of:)``, and the range lies inside the file.
    func punchHole(in descriptor: Int32, at offset: Int64, length: Int64) throws(TreeFileSystemError)
    /// Closes a descriptor that was written through, reporting the write
    /// failure the system deferred to the close.
    func closeWritten(_ descriptor: Int32) throws(TreeFileSystemError)
    /// Sets the extended attribute `name` of `target` to `value`, doing
    /// nothing when the volume or the OS cannot hold that attribute there.
    func setExtendedAttribute(_ name: [UInt8], to value: [UInt8], of target: TreeEntryTarget)
        throws(TreeFileSystemError)
    /// Writes `buffer` into the open regular file's resource fork at
    /// `offset`, returning `false`, having written nothing, when the volume
    /// or the OS holds no resource fork there.
    func writeResourceFork(_ descriptor: Int32, from buffer: UnsafeRawBufferPointer, at offset: UInt64)
        throws(TreeFileSystemError) -> Bool
    /// Whether the volume holding the open directory `directory` stores
    /// decmpfs-compressed files; `false` where the OS stores none.
    func volumeStoresCompressedFiles(_ directory: Int32) throws(TreeFileSystemError) -> Bool
    /// Sets the `com.apple.decmpfs` attribute of the open, empty regular
    /// file, which is not yet compressed: ``CompressedFile``'s first step,
    /// and no one else's. `ENOTSUP` where the OS stores no compressed file.
    func setCompressedStorage(_ attribute: [UInt8], of descriptor: Int32) throws(TreeFileSystemError)
    /// Sets the open regular file's flags to `flags` with `UF_COMPRESSED`,
    /// which compresses a file whose storage is in place:
    /// ``CompressedFile``'s flag write, and no one else's. `ENOTSUP` where
    /// the OS stores no compressed file.
    func setCompressedFlags(_ flags: UInt32, of descriptor: Int32) throws(TreeFileSystemError)
    /// Applies `attributes` to `target`, leaving out each one the volume or
    /// the OS cannot hold there.
    func setAttributes(_ attributes: TreeEntryAttributes, of target: TreeEntryTarget) throws(TreeFileSystemError)
    /// The failure with which this OS refuses to land an entry named `name`
    /// whose absolute path, NUL excluded, is `pathByteCount` bytes long, or
    /// `nil` when it lands it.
    func landingRefusal(of name: [UInt8], pathByteCount: Int) -> TreeFileSystemError?
}

/// An extended attribute's name and value.
public struct ExtendedAttribute: Hashable, Sendable {
    /// The name, as the volume's bytes.
    public let name: [UInt8]
    /// The value.
    public let value: [UInt8]

    /// The attribute `name` holding `value`.
    public init(name: [UInt8], value: [UInt8]) {
        self.name = name
        self.value = value
    }
}

/// What a change of attributes, or an extended attribute read or written, applies to.
public enum TreeEntryTarget: Hashable, Sendable {
    /// An open descriptor.
    case descriptor(Int32)
    /// The symlink `name` in `directory`, itself rather than its target.
    case symlink([UInt8], in: Int32)
}

/// The attributes an entry lands with; `nil` leaves one as the entry was
/// created.
public struct TreeEntryAttributes: Hashable, Sendable {
    /// The permission and set-id bits, `0o7777` at most.
    public var permissions: UInt32?
    /// The BSD file flags.
    public var flags: UInt32?
    /// When the contents last changed.
    public var modificationTime: FileTime?
    /// When the entry was created.
    public var birthTime: FileTime?

    /// Attributes of the given values.
    public init(
        permissions: UInt32? = nil, flags: UInt32? = nil, modificationTime: FileTime? = nil,
        birthTime: FileTime? = nil
    ) {
        self.permissions = permissions
        self.flags = flags
        self.modificationTime = modificationTime
        self.birthTime = birthTime
    }

    /// Whether no attribute is set.
    public var isEmpty: Bool { self == TreeEntryAttributes() }

    /// Each attribute on its own, so a target refusing one refuses no other.
    public var separated: [TreeEntryAttributes] {
        [
            permissions.map { TreeEntryAttributes(permissions: $0) },
            flags.map { TreeEntryAttributes(flags: $0) },
            modificationTime.map { TreeEntryAttributes(modificationTime: $0) },
            birthTime.map { TreeEntryAttributes(birthTime: $0) },
        ].compactMap { $0 }
    }
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
    /// Whether the file is stored compressed: Darwin's `UF_COMPRESSED`.
    public var isCompressed: Bool { flags & FileStatus.compressedFlag != 0 }
    /// Darwin's `UF_COMPRESSED` (`sys/stat.h`), which marks a file stored
    /// through decmpfs.
    public static let compressedFlag: UInt32 = 0x20
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
