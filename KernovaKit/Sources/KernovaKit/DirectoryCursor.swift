import Darwin
import System

/// Why a ``DirectoryCursor`` could not move up.
enum DirectoryCursorFailure: Error, Equatable {
    /// Reopening the parent failed with this `errno`.
    case system(Errno)
    /// The parent reached through `..` is not the directory the cursor came
    /// down from.
    case moved

    /// The failure as one on the item at `path`.
    func naming(_ path: [UInt8]) -> ClipboardItemFailure {
        let display = ClipboardArchiveCodec.displayPath(path)
        switch self {
        case .system(let errno): return ClipboardItemFailure(itemPath: display, reason: .posix(errno.rawValue))
        case .moved: return ClipboardItemFailure(itemPath: display, reason: .unknown)
        }
    }
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
struct DirectoryCursor<Volume: ClipboardArchiveVolume, Frame>: ~Copyable {
    private struct Level {
        let device: dev_t
        let inode: ino_t
        var frame: Frame
    }

    let volume: Volume
    /// The directory the cursor is at, open.
    private(set) var descriptor: Int32
    private var level: Level
    private var ancestors: [Level] = []

    /// What the caller keeps for the directory the cursor is at.
    var frame: Frame {
        get { level.frame }
        set { level.frame = newValue }
    }

    /// The frame of the directory above the current one, or `nil` at the
    /// top.
    var parentFrame: Frame? { ancestors.last?.frame }

    /// Whether the cursor is at the directory it started from.
    var isAtTop: Bool { ancestors.isEmpty }

    /// Starts at `descriptor`, an open directory whose status is `status`,
    /// taking ownership of it.
    init(volume: Volume, descriptor: Int32, status: stat, frame: Frame) {
        self.volume = volume
        self.descriptor = descriptor
        level = Level(device: status.st_dev, inode: status.st_ino, frame: frame)
    }

    /// Moves down into `child` — an open directory inside the current one,
    /// whose status is `status` — taking ownership of it and closing the
    /// current one.
    mutating func descend(into child: Int32, status: stat, frame: Frame) {
        ancestors.append(level)
        level = Level(device: status.st_dev, inode: status.st_ino, frame: frame)
        let left = descriptor
        descriptor = child
        volume.close(left)
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
    mutating func ascend(leaving: (Int32, Frame) throws -> Void = { _, _ in }) throws -> Frame {
        guard let parent = ancestors.last else {
            preconditionFailure("ascended past the directory the cursor started from")
        }
        let reopened: Int32
        do {
            reopened = try volume.openDirectory([0x2E, 0x2E], in: descriptor)
        } catch {
            throw DirectoryCursorFailure.system(error)
        }
        do {
            let status: stat
            do {
                status = try volume.status(of: reopened)
            } catch {
                throw DirectoryCursorFailure.system(error)
            }
            guard status.st_dev == parent.device, status.st_ino == parent.inode else {
                throw DirectoryCursorFailure.moved
            }
            try leaving(descriptor, level.frame)
        } catch {
            volume.close(reopened)
            throw error
        }
        let left = level
        let leftDescriptor = descriptor
        level = ancestors.removeLast()
        descriptor = reopened
        volume.close(leftDescriptor)
        return left.frame
    }

    deinit {
        volume.close(descriptor)
    }
}
