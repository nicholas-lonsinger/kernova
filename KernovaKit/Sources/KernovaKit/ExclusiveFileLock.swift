import Darwin
import Foundation
import System

/// An exclusive `flock(2)` lock on one file or directory, held from a
/// successful acquire until the lock is deinitialized, which releases it
/// before returning.
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
        // `close` alone frees the lock only with the last reference to the
        // open file description, and a child any thread is spawning holds
        // one until its exec, close-on-exec notwithstanding; `LOCK_UN` frees
        // it for every reference
        // (docs/research/2026-10-07-a-spawning-child-holds-a-cloexec-flock-until-exec.md).
        let unlocked = flock(descriptor, LOCK_UN)
        assert(unlocked == 0, "flock(LOCK_UN) failed: errno \(errno)")
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

    /// Whether any open file description holds a lock on the existing file or
    /// directory at `url`, this process's own included, without taking one.
    ///
    /// `F_GETLK` reports a `flock(2)` lock with `l_pid` set to -1, so it tells
    /// only that a lock is held, never by whom.
    ///
    /// - Throws: the `errno` the open or the query failed with.
    public static func isHeld(at url: URL) throws(Errno) -> Bool {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { throw Errno(rawValue: errno) }
        defer { Darwin.close(descriptor) }
        var query = flock()
        query.l_type = Int16(F_WRLCK)
        query.l_whence = Int16(SEEK_SET)
        query.l_start = 0
        query.l_len = 0
        guard fcntl(descriptor, F_GETLK, &query) == 0 else { throw Errno(rawValue: errno) }
        return query.l_type != Int16(F_UNLCK)
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
