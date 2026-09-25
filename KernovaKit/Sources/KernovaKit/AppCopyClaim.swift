import Foundation
import System

/// This process's claim to be the one running process of its copy of Kernova,
/// held until the claim is deinitialized.
///
/// The claim is an ``ExclusiveFileLock`` on a file in the group container named
/// for the copy's bundle, so one process of a copy holds it at a time and the
/// kernel frees it when that process exits, however it exits. The copy's
/// command socket path comes only from a claim, so only its holder binds it.
///
/// The lock file is never removed: a process that locked it after an unlink
/// would lock a fresh inode while the holder still has the old one.
public final class AppCopyClaim: Sendable {
    /// Where this copy's command socket binds.
    public let socketPath: String

    /// Held for the claim's lifetime; releasing it releases the claim.
    private let lock: ExclusiveFileLock

    private init(socketPath: String, lock: ExclusiveFileLock) {
        self.socketPath = socketPath
        self.lock = lock
    }

    /// What an attempt to claim a copy came to.
    public enum Acquisition: Sendable {
        /// This process now holds the copy's claim.
        case claimed(AppCopyClaim)
        /// Another claim already holds it — in the app, another process of
        /// this copy.
        case alreadyHeld
        /// This build can make no claim, and so binds no socket.
        case unavailable(Unavailable)
    }

    /// Why a build can make no claim.
    public enum Unavailable: Error, Sendable, Equatable {
        /// The copy's files have no name in the group container.
        case unnamed(KernovaAppGroup.CopyPathFailure)
        /// The lock file could not be opened, with the `errno` the open failed
        /// with.
        case unlockable(Errno)
    }

    /// Claims the copy of Kernova at `appBundle`, without waiting.
    public static func acquire(forAppBundle appBundle: URL) -> Acquisition {
        guard let container = KernovaAppGroup.containerURL() else {
            return .unavailable(.unnamed(.noContainer))
        }
        return acquire(forAppBundle: appBundle, in: container)
    }

    /// ``acquire(forAppBundle:)`` with the lock file inside `container`.
    static func acquire(forAppBundle appBundle: URL, in container: URL) -> Acquisition {
        let files: KernovaAppGroup.CopyFiles
        do throws(KernovaAppGroup.CopyPathFailure) {
            files = try KernovaAppGroup.CopyFiles(forAppBundle: appBundle, in: container)
        } catch {
            return .unavailable(.unnamed(error))
        }
        do throws(Errno) {
            guard let lock = try ExclusiveFileLock.tryAcquire(creatingFileAt: files.lockURL) else {
                return .alreadyHeld
            }
            return .claimed(AppCopyClaim(socketPath: files.socketPath, lock: lock))
        } catch {
            return .unavailable(.unlockable(error))
        }
    }
}
