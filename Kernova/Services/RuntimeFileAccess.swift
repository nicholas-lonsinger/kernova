import Foundation
import os

/// Owns the security-scoped access grants a live VM session holds.
///
/// VZ opens its file descriptors at configuration-build time and gives no
/// signal when it is done with them, so config-derived scopes (kernel/initrd,
/// external disks, shared directories) are held for the entire runtime and
/// released exactly once from `VMInstance.tearDownSession()`. Removable-media
/// scopes are keyed by item id instead, so a live eject releases exactly its
/// own grant and a re-attach replaces it cleanly.
@MainActor
final class RuntimeFileAccess {
    private static let logger = Logger(subsystem: "app.kernova", category: "RuntimeFileAccess")

    private var configScopes: [ScopedAccess] = []
    private var hotAttachScopes: [UUID: ScopedAccess] = [:]

    /// Replaces the config-derived scope set (releasing any prior set — a
    /// boot attempt after a retried teardown must not double-hold).
    func adoptConfigScopes(_ scopes: [ScopedAccess]) {
        configScopes.forEach { $0.release() }
        configScopes = scopes
        Self.logger.debug("Adopted \(scopes.count, privacy: .public) config scope(s)")
    }

    /// Registers the scope backing an attached USB device — cold-boot or
    /// hot-attach — keyed by the removable-media item's id, releasing any
    /// stale entry for that id.
    func addHotAttach(id: UUID, _ scope: ScopedAccess) {
        hotAttachScopes.removeValue(forKey: id)?.release()
        hotAttachScopes[id] = scope
    }

    /// Releases the scope for a detached USB device.
    func releaseHotAttach(id: UUID) {
        hotAttachScopes.removeValue(forKey: id)?.release()
    }

    /// Releases every scope this session holds.
    ///
    /// Safe to call repeatedly.
    func releaseAll() {
        let count = configScopes.count + hotAttachScopes.count
        if count > 0 {
            Self.logger.debug("Releasing all \(count, privacy: .public) scope(s)")
        }
        configScopes.forEach { $0.release() }
        configScopes.removeAll()
        hotAttachScopes.values.forEach { $0.release() }
        hotAttachScopes.removeAll()
    }
}

// MARK: - VMInstance boot-time scope acquisition

extension VMInstance {
    /// Opens scoped access for every bookmarked external path in the
    /// configuration, healing stale or moved bookmarks on the way.
    ///
    /// Called at the top of each boot attempt, before the configuration builder
    /// resolves any paths. The walk must stay in lockstep with
    /// `ConfigurationBuilder`'s — a new external-path field on `VMConfiguration`
    /// needs an entry in both, or its scope never opens and the builder reports
    /// a spurious not-found under the sandbox.
    func openRuntimeFileAccess() {
        var scopes: [ScopedAccess] = []
        var heals: [(inout VMConfiguration) -> Void] = []

        /// Opens one bookmark, queueing a heal through `apply` when the resolved
        /// reality (staleness, or a moved file) diverges from the stored fields.
        func open(
            _ bookmark: Data?,
            storedPath: String,
            apply: @escaping (inout VMConfiguration, String, Data) -> Void
        ) -> ScopedAccess? {
            guard let bookmark, let scope = ScopedAccess(bookmark: bookmark) else { return nil }
            let resolvedPath = scope.url.path(percentEncoded: false)
            // Canonical-form comparison: APFS may hand back a decomposed
            // (NFD) form of a name the panel stored precomposed (NFC); that
            // is not a move and must not re-heal on every boot.
            let moved =
                resolvedPath.precomposedStringWithCanonicalMapping
                != storedPath.precomposedStringWithCanonicalMapping
            if scope.isStale || moved {
                // Re-creating while the scope is active is Apple's documented
                // stale-bookmark pattern.
                if let fresh = SecurityScopedBookmark.make(for: scope.url) {
                    heals.append { config in apply(&config, resolvedPath, fresh) }
                }
            }
            return scope
        }

        let config = configuration

        if let kernelPath = config.kernelPath,
            let scope = open(
                config.kernelBookmark, storedPath: kernelPath,
                apply: { c, path, bookmark in
                    c.kernelPath = path
                    c.kernelBookmark = bookmark
                })
        {
            scopes.append(scope)
        }
        if let initrdPath = config.initrdPath,
            let scope = open(
                config.initrdBookmark, storedPath: initrdPath,
                apply: { c, path, bookmark in
                    c.initrdPath = path
                    c.initrdBookmark = bookmark
                })
        {
            scopes.append(scope)
        }
        for disk in config.storageDisks ?? [] where !disk.isInternal {
            let scope = open(disk.bookmark, storedPath: disk.path) { c, path, bookmark in
                guard let index = c.storageDisks?.firstIndex(where: { $0.id == disk.id }) else {
                    return
                }
                c.storageDisks?[index].path = path
                c.storageDisks?[index].bookmark = bookmark
            }
            if let scope { scopes.append(scope) }
        }
        for item in config.removableMedia ?? [] {
            let scope = open(item.bookmark, storedPath: item.path) { c, path, bookmark in
                guard let index = c.removableMedia?.firstIndex(where: { $0.id == item.id }) else {
                    return
                }
                c.removableMedia?[index].path = path
                c.removableMedia?[index].bookmark = bookmark
            }
            if let scope { runtimeFileAccess.addHotAttach(id: item.id, scope) }
        }
        for directory in config.sharedDirectories ?? [] {
            let scope = open(directory.bookmark, storedPath: directory.path) { c, path, bookmark in
                guard
                    let index = c.sharedDirectories?.firstIndex(where: { $0.id == directory.id })
                else { return }
                c.sharedDirectories?[index].path = path
                c.sharedDirectories?[index].bookmark = bookmark
            }
            if let scope { scopes.append(scope) }
        }

        if !heals.isEmpty {
            performConfigurationMutation { config in
                for heal in heals { heal(&config) }
            }
        }
        runtimeFileAccess.adoptConfigScopes(scopes)
    }
}
