/// Why a ``DirectoryCursor`` could not move up.
public enum DirectoryCursorFailure: Error, Equatable {
    /// Reopening the parent failed.
    case system(TreeFileSystemError)
    /// The parent reached through `..` is not the directory the cursor came
    /// down from.
    case moved
}

/// A position in a directory tree held through descriptors alone.
///
/// The directory the cursor is at stays open; each one above it is closed and
/// known by its identity, and moving up reopens it through `..` and confirms
/// it is the directory the cursor came down from. So neither depth nor path
/// length bounds where it can go, and at most two directories are open at
/// once — the current one, and its child or its parent while it moves.
///
/// The cursor owns every descriptor it holds, and closes the last one when it
/// ends.
public struct DirectoryCursor<FileSystem: TreeFileSystem, Frame>: ~Copyable {
    private struct Level {
        let device: UInt64
        let inode: UInt64
        var frame: Frame
    }

    /// The file system the cursor's descriptors belong to.
    public let fileSystem: FileSystem
    /// The directory the cursor is at, open.
    public private(set) var descriptor: Int32
    private var level: Level
    private var ancestors: [Level] = []

    /// What the caller keeps for the directory the cursor is at.
    public var frame: Frame {
        get { level.frame }
        set { level.frame = newValue }
    }

    /// The frame of the directory above the current one, or `nil` at the
    /// top.
    public var parentFrame: Frame? { ancestors.last?.frame }

    /// Whether the cursor is at the directory it started from.
    public var isAtTop: Bool { ancestors.isEmpty }

    /// Starts at `descriptor`, an open directory whose status is `status`,
    /// taking ownership of it.
    public init(fileSystem: FileSystem, descriptor: Int32, status: FileStatus, frame: Frame) {
        self.fileSystem = fileSystem
        self.descriptor = descriptor
        level = Level(device: status.device, inode: status.inode, frame: frame)
    }

    /// Moves down into `child` — an open directory inside the current one,
    /// whose status is `status` — taking ownership of it and closing the
    /// current one.
    public mutating func descend(into child: Int32, status: FileStatus, frame: Frame) {
        ancestors.append(level)
        level = Level(device: status.device, inode: status.inode, frame: frame)
        let left = descriptor
        descriptor = child
        fileSystem.close(left)
    }

    /// Moves up to the parent, reopened through the current directory's `..`.
    ///
    /// - Parameter leaving: runs with the parent open and the directory being
    ///   left still open, given that directory's descriptor and frame — the
    ///   last point at which it is reachable, so a change that would make it
    ///   unsearchable belongs here.
    /// - Returns: the frame of the directory left.
    /// - Throws: ``DirectoryCursorFailure`` when the parent cannot be reached
    ///   or is not the directory the cursor came down from, or whatever
    ///   `leaving` throws. Either way the cursor stays where it was.
    public mutating func ascend(leaving: (Int32, Frame) throws -> Void = { _, _ in }) throws -> Frame {
        guard let parent = ancestors.last else {
            preconditionFailure("ascended past the directory the cursor started from")
        }
        let reopened: Int32
        do {
            reopened = try fileSystem.openParent(of: descriptor)
        } catch {
            throw DirectoryCursorFailure.system(error)
        }
        do {
            let status: FileStatus
            do {
                status = try fileSystem.status(of: reopened)
            } catch {
                throw DirectoryCursorFailure.system(error)
            }
            guard status.device == parent.device, status.inode == parent.inode else {
                throw DirectoryCursorFailure.moved
            }
            try leaving(descriptor, level.frame)
        } catch {
            fileSystem.close(reopened)
            throw error
        }
        let left = level
        let leftDescriptor = descriptor
        level = ancestors.removeLast()
        descriptor = reopened
        fileSystem.close(leftDescriptor)
        return left.frame
    }

    deinit {
        fileSystem.close(descriptor)
    }
}
