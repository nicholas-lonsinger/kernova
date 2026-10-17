import Foundation
import KernovaLogging

/// Owns the security-scoped access grants a live VM session holds.
///
/// VZ opens its file descriptors at configuration-build time and gives no
/// signal when it is done with them, so config-derived scopes (kernel/initrd,
/// external disks) are held for the entire runtime and released exactly once
/// from `VMSessionContext.tearDown()`. The scopes of what a running VM can
/// take back — removable media, shared directories — are keyed by item id
/// instead, so taking one back releases exactly its own grant and a re-attach
/// replaces it cleanly.
@MainActor
final class RuntimeFileAccess {
    private static let logger = KernovaLogger(subsystem: "app.kernova", category: "RuntimeFileAccess")

    private var configScopes: [ScopedAccess] = []
    private var attachmentScopes: [UUID: ScopedAccess] = [:]

    /// Replaces the config-derived scope set (releasing any prior set — a
    /// boot attempt after a retried teardown must not double-hold).
    func adoptConfigScopes(_ scopes: [ScopedAccess]) {
        configScopes.forEach { $0.release() }
        configScopes = scopes
        #log(Self.logger, .debug, "Adopted \(scopes.count, privacy: .public) config scope(s)")
    }

    /// Registers the scope backing an attachment the running VM can take back
    /// — a removable-media item or a shared directory, at boot or added live —
    /// keyed by the item's id, releasing any stale entry for that id.
    func holdAttachmentScope(id: UUID, _ scope: ScopedAccess) {
        attachmentScopes.removeValue(forKey: id)?.release()
        attachmentScopes[id] = scope
    }

    /// Releases the scope of an attachment the running VM no longer holds.
    func releaseAttachmentScope(id: UUID) {
        attachmentScopes.removeValue(forKey: id)?.release()
    }

    /// Releases every scope this session holds.
    ///
    /// Safe to call repeatedly.
    func releaseAll() {
        let count = configScopes.count + attachmentScopes.count
        if count > 0 {
            #log(Self.logger, .debug, "Releasing all \(count, privacy: .public) scope(s)")
        }
        configScopes.forEach { $0.release() }
        configScopes.removeAll()
        attachmentScopes.values.forEach { $0.release() }
        attachmentScopes.removeAll()
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
    /// Called when each boot attempt opens its context, before the
    /// configuration builder resolves any paths. The walk is
    /// ``VMConfiguration/externalFileReferences``, and
    /// ``ExternalFileReference/Kind/opensRuntimeScope`` decides which kinds a
    /// boot takes a scope on.
    ///
    /// The heals land on the context, which the build reads
    /// (``effectiveConfiguration``); ``writeHeals(of:_:)`` writes them to the
    /// bundle.
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
            case .removableMedia, .sharedDirectory:
                context.fileAccess.holdAttachmentScope(id: reference.id, opened.scope)
            case .kernel, .initrd, .storageDisk, .localIPSW:
                scopes.append(opened.scope)
            }
        }

        context.heals = heals
        context.fileAccess.adoptConfigScopes(scopes)
    }

    /// Writes the heals `context`'s boot found to the bundle, as a write of
    /// the bring-up `permit` belongs to; a write that fails is reported, and
    /// the next boot heals again from the same bookmarks.
    func writeHeals(of context: VMSessionContext, _ permit: borrowing VMEditPermit) {
        let heals = context.heals
        guard !heals.isEmpty else { return }
        permit.updateConfiguration { config in
            for heal in heals {
                config.healExternalReference(
                    heal.reference, movedTo: heal.path, bookmark: heal.bookmark)
            }
        }
    }
}
