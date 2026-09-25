import Darwin
import Foundation
import KernovaLogging
import System

/// One process's own directory under a staging parent that several processes
/// share, locked for as long as the process holds this object.
///
/// Every live root under a parent holds an ``ExclusiveFileLock`` on its
/// `.lock`, so ``reclaimAbandonedRoots()`` tells a live root from an abandoned
/// one by the lock alone, from any process, whenever it runs. A root appears
/// under its scanned name only once its lock is held: ``claim()`` builds it
/// under a hidden name and renames it into place, and reclaim never judges a
/// hidden entry.
///
/// `@unchecked Sendable`: an internal lock serializes ``claim()``.
public final class ProcessStagingRoot: @unchecked Sendable {
    private static let logger = KernovaLogger(
        subsystem: "app.kernova", category: "ProcessStagingRoot")

    /// The name of the file, directly under ``url``, whose lock marks a root as
    /// live.
    public static let lockFileName = ".lock"

    /// This root's directory, a fresh name under the parent. Nothing exists
    /// there until ``claim()``.
    public let url: URL

    private let parent: URL
    private let lock = NSLock()
    private var fileLock: ExclusiveFileLock?

    /// A root under `parent`; touches no disk.
    public init(parent: URL) {
        self.parent = parent
        url = parent.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    /// Creates ``url`` holding its locked `.lock`, the first time; later calls
    /// return at once.
    ///
    /// Call before creating anything under ``url``.
    ///
    /// - Throws: the error that stopped the root being built; nothing is left
    ///   under the parent, and a later call tries again.
    public func claim() throws {
        lock.lock()
        defer { lock.unlock() }
        guard fileLock == nil else { return }

        let manager = FileManager.default
        try manager.createDirectory(at: parent, withIntermediateDirectories: true)
        let building = parent.appendingPathComponent(
            "." + url.lastPathComponent, isDirectory: true)
        try manager.createDirectory(at: building, withIntermediateDirectories: false)
        do {
            guard
                let acquired = try ExclusiveFileLock.tryAcquire(
                    at: building.appendingPathComponent(Self.lockFileName),
                    creating: .exclusively)
            else { throw Errno.wouldBlock }
            // The lock rides the inode through the rename.
            guard renamex_np(building.path, url.path, UInt32(RENAME_EXCL)) == 0 else {
                throw Errno(rawValue: errno)
            }
            fileLock = acquired
        } catch {
            try? manager.removeItem(at: building)
            throw error
        }
    }

    /// Removes every other root under the parent whose lock no process holds,
    /// and every visible entry that has no `.lock` at all.
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
                // Held while the entry is removed, so a concurrent reclaimer
                // skips it as live.
                guard
                    let abandoned = try ExclusiveFileLock.tryAcquire(
                        at: entry.appendingPathComponent(Self.lockFileName), creating: .never)
                else { continue }
                try withExtendedLifetime(abandoned) { try manager.removeItem(at: entry) }
            } catch Errno.noSuchFileOrDirectory, Errno.notDirectory {
                // Staging from before roots were locked, or a stray file.
                do {
                    try manager.removeItem(at: entry)
                } catch {
                    logReclaimFailure(entry, error)
                }
            } catch {
                logReclaimFailure(entry, error)
            }
        }
    }

    private func logReclaimFailure(_ entry: URL, _ error: any Error) {
        // Another reclaimer removed it first.
        if case CocoaError.fileNoSuchFile = error { return }
        #log(
            Self.logger, .warning,
            "Could not reclaim staging entry '\(entry.lastPathComponent, privacy: .public)': \(error.localizedDescription, privacy: .public)"
        )
    }
}
