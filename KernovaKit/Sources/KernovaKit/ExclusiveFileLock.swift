import Darwin
import Foundation
import System

/// An exclusive `flock(2)` lock on one file, held from a successful
/// ``tryAcquire(at:creating:)`` until the lock is deinitialized.
///
/// The kernel releases the lock when its process exits, a crash included, and
/// the descriptor is close-on-exec, so a child the process spawns never keeps
/// it past the parent. The lock belongs to the open file description: a second
/// ``tryAcquire(at:creating:)`` on the same file from this process is refused
/// exactly as another process's is. All three are observed in "`F_GETLK` sees
/// another process's `flock`"
/// (docs/research/2026-09-24-file-coordination-rename-and-flock.md).
public final class ExclusiveFileLock: Sendable {
    /// Whether ``tryAcquire(at:creating:)`` may create the file.
    public enum Creation: Sendable {
        /// Only an existing file is locked.
        case never
        /// The file is created, and an existing one is refused.
        case exclusively
    }

    /// The open descriptor the lock rides on.
    let descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit {
        Darwin.close(descriptor)
    }

    /// Takes the lock on the file at `url` without waiting.
    ///
    /// - Returns: `nil` when the file is already locked by another open file
    ///   description, this process's own included.
    /// - Throws: the `errno` the open failed with — `Errno.noSuchFileOrDirectory`
    ///   or `Errno.notDirectory` for a missing file under ``Creation/never``, and
    ///   `Errno.fileExists` for an existing one under ``Creation/exclusively``.
    public static func tryAcquire(
        at url: URL, creating creation: Creation
    ) throws(Errno) -> ExclusiveFileLock? {
        var flags = O_RDONLY | O_EXLOCK | O_NONBLOCK | O_CLOEXEC
        if creation == .exclusively { flags |= O_CREAT | O_EXCL }
        let descriptor = Darwin.open(url.path, flags, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            let failure = Errno(rawValue: errno)
            if failure == .wouldBlock { return nil }
            throw failure
        }
        return ExclusiveFileLock(descriptor: descriptor)
    }
}
