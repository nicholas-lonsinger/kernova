import Darwin
import Foundation
import KernovaLogging
import System

/// One process's own directory under a staging parent that several processes
/// share, locked for as long as the process holds this object.
///
/// The lock is an ``ExclusiveFileLock`` on the root directory itself, so a root
/// and its lock are one inode: nothing under the parent is live without its
/// lock held, and ``reclaimAbandonedRoots()`` tells a live root from an
/// abandoned one by the lock alone, from any process, whenever it runs. A root
/// appears under its scanned name only once its lock is held: ``claim()`` builds
/// it under a hidden name and renames it into place, and reclaim never judges a
/// hidden entry.
///
/// `@unchecked Sendable`: an internal lock serializes ``claim()``.
public final class ProcessStagingRoot: @unchecked Sendable {
    private static let logger = KernovaLogger(
        subsystem: "app.kernova", category: "ProcessStagingRoot")

    /// This root's directory, a fresh name under the parent. Nothing exists
    /// there until ``claim()``.
    public let url: URL

    private let parent: URL
    private let lock = NSLock()
    private var directoryLock: ExclusiveFileLock?

    /// A root under `parent`; touches no disk.
    public init(parent: URL) {
        self.parent = parent
        url = parent.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    /// Creates ``url`` and locks it, the first time; later calls return at once.
    ///
    /// Call before creating anything under ``url``.
    ///
    /// - Throws: the error that stopped the root being built; nothing is left
    ///   under the parent, and a later call tries again.
    public func claim() throws {
        lock.lock()
        defer { lock.unlock() }
        guard directoryLock == nil else { return }

        let manager = FileManager.default
        try manager.createDirectory(at: parent, withIntermediateDirectories: true)
        let building = parent.appendingPathComponent(
            "." + url.lastPathComponent, isDirectory: true)
        try manager.createDirectory(at: building, withIntermediateDirectories: false)
        do {
            guard let acquired = try ExclusiveFileLock.tryAcquire(at: building) else {
                throw Errno.wouldBlock
            }
            // The lock rides the inode through the rename.
            guard renamex_np(building.path, url.path, UInt32(RENAME_EXCL)) == 0 else {
                throw Errno(rawValue: errno)
            }
            directoryLock = acquired
        } catch {
            try? manager.removeItem(at: building)
            throw error
        }
    }

    /// Claims the root, then creates the directory at `target` under ``url``
    /// and any missing directories between them — never ``url`` itself, so a
    /// root removed from outside is not rebuilt without its lock.
    ///
    /// - Throws: `Errno.noSuchFileOrDirectory` once the root no longer exists,
    ///   or the error that stopped a directory being made.
    public func createDirectory(at target: URL) throws {
        try claim()
        let rootComponents = url.standardizedFileURL.pathComponents
        let targetComponents = target.standardizedFileURL.pathComponents
        guard
            targetComponents.count > rootComponents.count,
            targetComponents.starts(with: rootComponents)
        else {
            preconditionFailure("\(target.path) is not under the staging root \(url.path)")
        }
        var current = url
        for component in targetComponents.dropFirst(rootComponents.count) {
            current.appendPathComponent(component, isDirectory: true)
            if mkdir(current.path, S_IRWXU | S_IRWXG | S_IRWXO) != 0, errno != EEXIST {
                throw Errno(rawValue: errno)
            }
        }
    }

    /// Removes every visible entry under the parent whose lock no process
    /// holds: an exited process's root, and anything else left there.
    ///
    /// A root some process holds is kept, this process's own included; a
    /// hidden entry is a root still being built and is never judged. Safe to
    /// run from any process at any time, before or after ``claim()``.
    public func reclaimAbandonedRoots() {
        let manager = FileManager.default
        guard
            let entries = try? manager.contentsOfDirectory(
                at: parent, includingPropertiesForKeys: nil)
        else { return }
        for entry in entries where !entry.lastPathComponent.hasPrefix(".") {
            do {
                // Held while the entry is removed, so any other reclaimer's
                // try-lock on it is refused until it is gone.
                guard let abandoned = try ExclusiveFileLock.tryAcquire(at: entry) else { continue }
                try withExtendedLifetime(abandoned) { try manager.removeItem(at: entry) }
            } catch Errno.noSuchFileOrDirectory {
                // Another reclaimer removed it first.
            } catch {
                #log(
                    Self.logger, .warning,
                    "Could not reclaim staging entry '\(entry.lastPathComponent, privacy: .public)': \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }
}
