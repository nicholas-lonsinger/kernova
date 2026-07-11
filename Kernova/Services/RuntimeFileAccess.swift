import Foundation
import os

/// Owns the security-scoped access grants a live VM session holds.
///
/// VZ opens its file descriptors at configuration-build time and keeps them
/// for the machine's lifetime with no public signal that every fd is fully
/// retained, so config-derived scopes (kernel/initrd, external disks,
/// removable media, shared directories) are held for the entire runtime and
/// released exactly once from `VMInstance.tearDownSession()` — the one
/// chokepoint every stop/error/save/force-stop path funnels through, which
/// keeps start/stop trivially balanced. Hot-attached USB media get their own
/// keyed scopes, released on detach (or wholesale at teardown).
@MainActor
final class RuntimeFileAccess {
    private var configScopes: [ScopedAccess] = []
    private var hotAttachScopes: [UUID: ScopedAccess] = [:]

    /// Replaces the config-derived scope set (releasing any prior set — a
    /// boot attempt after a retried teardown must not double-hold).
    func adoptConfigScopes(_ scopes: [ScopedAccess]) {
        configScopes.forEach { $0.release() }
        configScopes = scopes
    }

    /// Registers the scope backing a hot-attached USB device, keyed by the
    /// removable-media item's id (releasing any stale entry for that id).
    func addHotAttach(id: UUID, _ scope: ScopedAccess) {
        hotAttachScopes.removeValue(forKey: id)?.release()
        hotAttachScopes[id] = scope
    }

    /// Releases the scope for a detached USB device.
    ///
    /// No-op for unknown ids
    /// (items attached without a bookmark never registered a scope).
    func releaseHotAttach(id: UUID) {
        hotAttachScopes.removeValue(forKey: id)?.release()
    }

    /// Releases everything — config scopes and any still-attached hot-attach
    /// scopes.
    ///
    /// Safe to call repeatedly.
    func releaseAll() {
        configScopes.forEach { $0.release() }
        configScopes.removeAll()
        hotAttachScopes.values.forEach { $0.release() }
        hotAttachScopes.removeAll()
    }
}

// MARK: - VMInstance boot-time scope acquisition

extension VMInstance {
    /// Opens scoped access for every bookmarked external path in the
    /// configuration and hands the scopes to `runtimeFileAccess` for the
    /// session's lifetime.
    ///
    /// Called at the top of each boot attempt (cold boot and restore), before
    /// the configuration builder resolves any paths; scoped access is
    /// process-wide, so the builder's detached build task is covered.
    ///
    /// Also the healing pass: a bookmark that resolves but is stale gets
    /// re-created, and one that resolves to a different path than stored
    /// (the file was moved — bookmarks track the file, not the path) gets
    /// its stored path updated so the builder and UI see the live location.
    /// Heals persist through `performConfigurationMutation`, which routes to
    /// `VMStorageService.saveConfiguration` when persistence is wired.
    /// Entries whose bookmark is `nil` or no longer resolves are skipped —
    /// the raw-path attempt surfaces the existing missing-file UX.
    func openRuntimeFileAccess() {
        var scopes: [ScopedAccess] = []
        var heals: [(inout VMConfiguration) -> Void] = []

        /// Opens one bookmark; queues a heal when the resolved reality
        /// (staleness or a moved file) diverges from the stored fields.
        /// `apply` writes the healed `(path, bookmark)` back onto the field
        /// this entry came from.
        func open(
            _ bookmark: Data?,
            storedPath: String,
            apply: @escaping (inout VMConfiguration, String, Data) -> Void
        ) {
            guard let bookmark, let scope = ScopedAccess(bookmark: bookmark) else { return }
            scopes.append(scope)
            let resolvedPath = scope.url.path(percentEncoded: false)
            if scope.isStale || resolvedPath != storedPath {
                // Re-creating while the scope is active is Apple's documented
                // stale-bookmark pattern; on failure keep the old (still
                // resolvable) bookmark and skip the heal.
                if let fresh = SecurityScopedBookmark.make(for: scope.url) {
                    heals.append { config in apply(&config, resolvedPath, fresh) }
                }
            }
        }

        let config = configuration

        if let kernelPath = config.kernelPath {
            open(config.kernelBookmark, storedPath: kernelPath) { c, path, bookmark in
                c.kernelPath = path
                c.kernelBookmark = bookmark
            }
        }
        if let initrdPath = config.initrdPath {
            open(config.initrdBookmark, storedPath: initrdPath) { c, path, bookmark in
                c.initrdPath = path
                c.initrdBookmark = bookmark
            }
        }
        for disk in config.storageDisks ?? [] where !disk.isInternal {
            open(disk.bookmark, storedPath: disk.path) { c, path, bookmark in
                guard let index = c.storageDisks?.firstIndex(where: { $0.id == disk.id }) else {
                    return
                }
                c.storageDisks?[index].path = path
                c.storageDisks?[index].bookmark = bookmark
            }
        }
        for item in config.removableMedia ?? [] {
            open(item.bookmark, storedPath: item.path) { c, path, bookmark in
                guard let index = c.removableMedia?.firstIndex(where: { $0.id == item.id }) else {
                    return
                }
                c.removableMedia?[index].path = path
                c.removableMedia?[index].bookmark = bookmark
            }
        }
        for directory in config.sharedDirectories ?? [] {
            open(directory.bookmark, storedPath: directory.path) { c, path, bookmark in
                guard
                    let index = c.sharedDirectories?.firstIndex(where: { $0.id == directory.id })
                else { return }
                c.sharedDirectories?[index].path = path
                c.sharedDirectories?[index].bookmark = bookmark
            }
        }

        if !heals.isEmpty {
            performConfigurationMutation { config in
                for heal in heals { heal(&config) }
            }
        }
        runtimeFileAccess.adoptConfigScopes(scopes)
    }
}
