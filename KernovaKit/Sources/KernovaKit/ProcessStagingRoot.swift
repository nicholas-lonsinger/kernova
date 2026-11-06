import Darwin
import Foundation
import KernovaLogging
import KernovaSynchronization
import System

/// What a staging root's removals go through when something outside the staging may name a file in what goes: a
/// pasteboard item never outlives the file it names, so every one naming a file in it is withdrawn first.
public protocol StagedContentRetirement: Sendable {
    /// This process's own staging at `directories` is going: withdraws every pasteboard item this process wrote
    /// that names a file there, then runs `remove`, both off the caller's stack. Called from any thread.
    func retire(_ directories: [URL], then remove: @escaping @Sendable () -> Void)

    /// Exited processes' staging roots at `roots` are going: withdraws every item of the pasteboard that names a
    /// file there, then runs `remove`, both off the caller's stack. Called from any thread.
    func retireAbandoned(_ roots: [URL], then remove: @escaping @Sendable () -> Void)

    /// This process is ending, leaving its staging at `root` for the next launch to reclaim: withdraws now every
    /// pasteboard item it wrote that names a file there.
    @MainActor func processEnding(_ root: URL)
}

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
public final class ProcessStagingRoot: Sendable {
    private static let logger = KernovaLogger(
        subsystem: "app.kernova", category: "ProcessStagingRoot")

    /// This root's directory, a fresh name under the parent, kept for the life
    /// of this object. Nothing exists there until ``claim()``.
    public let url: URL

    private let parent: URL

    /// Held across ``claim()``'s file-system work, which it serializes.
    private let directoryLock = Locked<ExclusiveFileLock?>(nil)

    /// What every removal under the parent goes through; nil where nothing outside the staging names a file in it.
    private let retirement: (any StagedContentRetirement)?

    /// A root under `parent` whose removals go through `retirement`; touches no disk.
    public init(parent: URL, retirement: (any StagedContentRetirement)? = nil) {
        self.parent = parent
        self.retirement = retirement
        url = parent.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    /// Removes `directory`, staged under this root, once nothing this process wrote names a file in it
    /// (``StagedContentRetirement/retire(_:then:)``): at once with no retirement. What is already gone is not a
    /// failure.
    func remove(_ directory: URL) {
        guard let retirement else { return Self.discard(directory) }
        retirement.retire([directory]) { Self.discard(directory) }
    }

    /// This process is ending: every pasteboard item it wrote that names a file under ``url`` is withdrawn now,
    /// and the root is left for the next launch's ``reclaimAbandonedRoots(then:)``.
    @MainActor public func processEnding() {
        retirement?.processEnding(url)
    }

    /// Removes `url` outright, whatever its depth or modes. Nothing is left to notice the failure but the log:
    /// every caller is already giving the content up.
    static func discard(_ url: URL) {
        do {
            try StagedItemRemoval.remove(at: url)
        } catch Errno.noSuchFileOrDirectory {
            // Already gone.
        } catch {
            logger.log(
                .error, "Could not remove staged content: \(String(describing: error), privacy: .public)")
        }
    }

    /// Makes sure ``url`` is a directory this object holds the lock on: builds
    /// and locks it the first time, and again under the same name whenever the
    /// directory it locked is no longer the entry at ``url`` — the system's temp
    /// cleaner removes old directories whatever locks they hold.
    ///
    /// Call before creating anything under ``url``. A rebuilt root is empty. The parent, and with it everything
    /// staged under it, is excluded from backups (``excludeFromBackups(_:)``).
    ///
    /// - Throws: the error that stopped the root being built, `Errno.fileExists`
    ///   when something else occupies ``url``; nothing is left under the parent,
    ///   and a later call tries again.
    public func claim() throws {
        try directoryLock.withLock { directoryLock in
            if let held = directoryLock {
                if Self.isEntry(at: url, lockedBy: held) { return }
                directoryLock = nil
            }

            let manager = FileManager.default
            try manager.createDirectory(at: parent, withIntermediateDirectories: true)
            Self.excludeFromBackups(parent)
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
                try? StagedItemRemoval.remove(at: building)
                throw error
            }
        }
    }

    /// Claims the root, then creates the directory at `target` under ``url``
    /// and any missing directories between them. ``url`` itself is made only by
    /// ``claim()``, so it never exists without its lock.
    ///
    /// - Throws: the error that stopped the root or a directory being made.
    public func createDirectory(at target: URL) throws {
        try claim()
        let rootPath = url.path
        let targetPath = target.path
        guard targetPath.hasPrefix(rootPath + "/") else {
            preconditionFailure("\(targetPath) is not under the staging root \(rootPath)")
        }
        var current = url
        for component in targetPath.dropFirst(rootPath.count + 1).split(separator: "/") {
            current.appendPathComponent(String(component), isDirectory: true)
            if mkdir(current.path, S_IRWXU | S_IRWXG | S_IRWXO) != 0, errno != EEXIST {
                throw Errno(rawValue: errno)
            }
        }
    }

    /// Marks `directory` excluded from backups, which excludes everything under it: what is staged is the user's
    /// copied content, and neither the sandboxed app's temporary directory (its container's `Data/tmp`) nor the
    /// guest agent's is excluded from Time Machine by any rule Apple documents. `isExcludedFromBackup`: "whether
    /// the resource is excluded from all backups of app data"
    /// ([URLResourceValues.isExcludedFromBackup](https://developer.apple.com/documentation/foundation/urlresourcevalues/isexcludedfrombackup)).
    static func excludeFromBackups(_ directory: URL) {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var directory = directory
        do {
            try directory.setResourceValues(values)
        } catch {
            logger.log(
                .error,
                "Could not exclude the staging directory from backups: \(String(describing: error), privacy: .public)")
        }
    }

    /// Whether the entry at `url` is the directory `held` has open.
    private static func isEntry(at url: URL, lockedBy held: ExclusiveFileLock) -> Bool {
        var entry = stat()
        var locked = stat()
        guard stat(url.path, &entry) == 0, fstat(held.descriptor, &locked) == 0 else { return false }
        return entry.st_dev == locked.st_dev && entry.st_ino == locked.st_ino
    }

    /// Removes every visible entry under the parent whose lock no process holds — an exited process's root, and
    /// anything else left there — once nothing on the pasteboard names a file in one
    /// (``StagedContentRetirement/retireAbandoned(_:then:)``), then runs `done`.
    ///
    /// A root some process holds is kept, this process's own included; a hidden entry is a root still being built
    /// and is never judged. Each entry taken stays locked until it is gone, so no other reclaimer takes it too.
    /// Safe to run from any process at any time, before or after ``claim()``.
    public func reclaimAbandonedRoots(then done: @escaping @Sendable () -> Void = {}) {
        let manager = FileManager.default
        var abandoned: [(entry: URL, lock: ExclusiveFileLock)] = []
        let entries = (try? manager.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)) ?? []
        for entry in entries where !entry.lastPathComponent.hasPrefix(".") {
            do {
                guard let lock = try ExclusiveFileLock.tryAcquire(at: entry) else { continue }
                abandoned.append((entry, lock))
            } catch Errno.noSuchFileOrDirectory {
                // Another reclaimer removed it first.
            } catch {
                Self.logger.log(
                    .warning,
                    "Could not reclaim staging entry '\(entry.lastPathComponent, privacy: .public)': \(String(describing: error), privacy: .public)"
                )
            }
        }
        let taken = abandoned
        let removeAll: @Sendable () -> Void = {
            for (entry, lock) in taken {
                withExtendedLifetime(lock) { Self.discard(entry) }
            }
            done()
        }
        guard let retirement, !taken.isEmpty else { return removeAll() }
        retirement.retireAbandoned(taken.map(\.entry), then: removeAll)
    }
}
