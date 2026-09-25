import Darwin
import Foundation
import System

/// An exclusive `flock(2)` lock on one file or directory, held from a
/// successful acquire until the lock is deinitialized.
///
/// `man 2 flock` shares a lock only through `dup(2)` or `fork(2)`, and each
/// acquire is a separate `open`, so a second acquire of the same path from this
/// process is refused exactly as another process's is (pinned by
/// `ExclusiveFileLockTests`). The kernel releases the lock when its process
/// exits, a crash included, and the descriptor is close-on-exec so a spawned
/// child never keeps it past the parent — both observed in "`F_GETLK` sees another process's `flock`"
/// (docs/research/2026-09-24-file-coordination-rename-and-flock.md).
public final class ExclusiveFileLock: Sendable {
    /// The open descriptor the lock rides on.
    let descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit {
        Darwin.close(descriptor)
    }

    /// Takes the lock on the existing file or directory at `url` without
    /// waiting.
    ///
    /// - Returns: `nil` when another open file description already holds a lock
    ///   on it, this process's own included.
    /// - Throws: the `errno` the open failed with — `Errno.noSuchFileOrDirectory`
    ///   when nothing is at `url`.
    public static func tryAcquire(at url: URL) throws(Errno) -> ExclusiveFileLock? {
        try tryAcquire(Darwin.open(url.path, O_RDONLY | O_EXLOCK | O_NONBLOCK | O_CLOEXEC))
    }

    /// Takes the lock on the file at `url` without waiting, first creating it
    /// empty and owner-only when nothing is there.
    ///
    /// - Returns: `nil` when another open file description already holds a lock
    ///   on it, this process's own included.
    /// - Throws: the `errno` the open failed with.
    public static func tryAcquire(creatingFileAt url: URL) throws(Errno) -> ExclusiveFileLock? {
        try tryAcquire(
            Darwin.open(
                url.path, O_RDONLY | O_CREAT | O_EXLOCK | O_NONBLOCK | O_CLOEXEC,
                S_IRUSR | S_IWUSR))
    }

    /// Wraps what an `O_EXLOCK | O_NONBLOCK` open returned.
    private static func tryAcquire(_ descriptor: Int32) throws(Errno) -> ExclusiveFileLock? {
        guard descriptor >= 0 else {
            let failure = Errno(rawValue: errno)
            if failure == .wouldBlock { return nil }
            throw failure
        }
        return ExclusiveFileLock(descriptor: descriptor)
    }
}
