import Foundation
import KernovaLogging

/// Owns the security-scoped access grants a live VM session holds.
///
/// VZ opens its file descriptors at configuration-build time and gives no
/// signal when it is done with them, so config-derived scopes (kernel/initrd,
/// external disks, shared directories) are held for the entire runtime and
/// released exactly once from `VMSessionContext.tearDown()`. Removable-media
/// scopes are keyed by item id instead, so a live eject releases exactly its
/// own grant and a re-attach replaces it cleanly.
@MainActor
final class RuntimeFileAccess {
    private static let logger = KernovaLogger(subsystem: "app.kernova", category: "RuntimeFileAccess")

    private var configScopes: [ScopedAccess] = []
    private var hotAttachScopes: [UUID: ScopedAccess] = [:]

    /// Replaces the config-derived scope set (releasing any prior set — a
    /// boot attempt after a retried teardown must not double-hold).
    func adoptConfigScopes(_ scopes: [ScopedAccess]) {
        configScopes.forEach { $0.release() }
        configScopes = scopes
        #log(Self.logger, .debug, "Adopted \(scopes.count, privacy: .public) config scope(s)")
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
            #log(Self.logger, .debug, "Releasing all \(count, privacy: .public) scope(s)")
        }
        configScopes.forEach { $0.release() }
        configScopes.removeAll()
        hotAttachScopes.values.forEach { $0.release() }
        hotAttachScopes.removeAll()
    }
}

// MARK: - VMInstance boot-time scope acquisition

/// An external file reference a boot found moved, and where its bookmark now
/// resolves.
struct ExternalReferenceHeal {
    let reference: ExternalFileReference
    let path: String
    let bookmark: Data
}

extension VMInstance {
    /// Opens scoped access for every bookmarked external path in the
    /// configuration, healing stale or moved bookmarks on the way.
    ///
    /// Called by ``beginSessionContext(_:bootedIntoRecovery:)`` at the top of each
    /// boot attempt with the freshly opened context, before the configuration
    /// builder resolves any paths. The walk is
    /// ``VMConfiguration/externalFileReferences``, and
    /// ``ExternalFileReference/Kind/opensRuntimeScope`` decides which kinds a
    /// boot takes a scope on.
    ///
    /// The heals land on the context, which the build reads
    /// (``effectiveConfiguration``), and are written to the bundle as well; a
    /// write that fails is reported, and the next boot heals again from the
    /// same bookmarks.
    func openRuntimeFileAccess(into context: VMSessionContext) {
        var scopes: [ScopedAccess] = []
        var heals: [ExternalReferenceHeal] = []

        for reference in configuration.externalFileReferences
        where reference.kind.opensRuntimeScope {
            guard let opened = ScopedAccess.open(reference) else { continue }
            if let healed = opened.healedTo {
                heals.append(
                    ExternalReferenceHeal(
                        reference: reference, path: healed.path, bookmark: healed.bookmark))
            }
            switch reference.kind {
            case .removableMedia:
                context.fileAccess.addHotAttach(id: reference.id, opened.scope)
            case .kernel, .initrd, .storageDisk, .sharedDirectory, .localIPSW:
                scopes.append(opened.scope)
            }
        }

        context.heals = heals
        if !heals.isEmpty {
            performConfigurationMutation { config in
                for heal in heals {
                    config.healExternalReference(
                        heal.reference, movedTo: heal.path, bookmark: heal.bookmark)
                }
            }
        }
        context.fileAccess.adoptConfigScopes(scopes)
    }
}
