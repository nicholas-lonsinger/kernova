import Foundation

/// One user-picked path a configuration points at, with the app-scoped security
/// bookmark that reopens it under the sandbox.
///
/// ``VMConfiguration/externalFileReferences`` projects a configuration into
/// these and ``VMConfiguration/healExternalReference(_:movedTo:bookmark:)``
/// writes back; every consumer selects the kinds it handles through a ``Kind``
/// predicate, so a new kind is a compile error at each site rather than a walk
/// someone has to remember to widen.
struct ExternalFileReference: Sendable, Equatable {
    enum Kind: Sendable, Equatable, CaseIterable {
        case kernel
        case initrd
        case storageDisk
        case removableMedia
        case sharedDirectory
        case localIPSW
    }

    /// The referenced item's own id, or — for the kinds a configuration holds
    /// at most one of — an id seeded on the configuration.
    let id: UUID
    let kind: Kind
    let label: String
    let path: String
    let bookmark: Data?
}

extension ExternalFileReference.Kind {
    /// Whether ``VMInstance/openRuntimeFileAccess(into:)`` takes a scope on this
    /// kind for the VM's runtime.
    var opensRuntimeScope: Bool {
        switch self {
        case .kernel, .initrd, .storageDisk, .removableMedia, .sharedDirectory: true
        case .localIPSW: false
        }
    }

    /// Whether the storage settings panel renders a row for this kind, which is
    /// what its file-existence monitor badges.
    var hasStorageSettingsRow: Bool {
        switch self {
        case .storageDisk, .removableMedia: true
        case .kernel, .initrd, .sharedDirectory, .localIPSW: false
        }
    }

    /// Whether the delete sheet offers to trash this kind alongside the VM.
    ///
    /// Shared directories are excluded deliberately: they are the user's own
    /// working folders rather than artifacts of the VM, so offering to trash
    /// one is a foot-gun.
    var isOfferedOnVMDelete: Bool {
        switch self {
        case .kernel, .initrd, .storageDisk, .removableMedia: true
        case .sharedDirectory, .localIPSW: false
        }
    }
}

// MARK: - Opening a reference

extension ScopedAccess {
    /// Opens `reference`'s bookmark, reporting the healed `(path, bookmark)`
    /// when the resolved reality diverges from what the reference carries.
    ///
    /// `nil` when the reference has no bookmark or the bookmark no longer
    /// resolves; the caller then falls through to the raw path.
    static func open(
        _ reference: ExternalFileReference
    ) -> (scope: ScopedAccess, healedTo: (path: String, bookmark: Data)?)? {
        guard let bookmark = reference.bookmark, let scope = ScopedAccess(bookmark: bookmark) else {
            return nil
        }
        let resolvedPath = scope.url.path(percentEncoded: false)
        // Canonical-form comparison: APFS may hand back a decomposed
        // (NFD) form of a name the panel stored precomposed (NFC); that
        // is not a move and must not re-heal on every boot.
        let moved =
            resolvedPath.precomposedStringWithCanonicalMapping
            != reference.path.precomposedStringWithCanonicalMapping
        guard scope.isStale || moved else { return (scope, nil) }
        // Re-creating while the scope is active is Apple's documented
        // stale-bookmark pattern.
        guard let fresh = SecurityScopedBookmark.make(for: scope.url) else { return (scope, nil) }
        return (scope, (resolvedPath, fresh))
    }
}

// MARK: - Derivations

extension Sequence<ExternalFileReference> {
    /// Absolute path → bookmark, one entry per distinct path; a non-nil
    /// bookmark wins a collision.
    ///
    /// The bookmark is what lets a sandboxed probe of an out-of-container path
    /// answer at all.
    var bookmarksByPath: [String: Data?] {
        var refs: [String: Data?] = [:]
        for reference in self {
            if (refs[reference.path] ?? nil) != nil { continue }
            refs.updateValue(reference.bookmark, forKey: reference.path)
        }
        return refs
    }
}
