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
    /// Two kinds are excluded deliberately, both because the file belongs to
    /// the user rather than to the VM: a shared directory is a working folder
    /// the guest happens to mount, and a local IPSW is a reusable installer the
    /// user may still set up other VMs from.
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

    /// Bookmark blob → the path it currently resolves to, one resolution per
    /// *distinct* blob; a blob that no longer resolves is absent.
    ///
    /// Blocking and sandbox-touching — never call this on the main actor. The
    /// memo carries the cost: a clone copies its origin's bookmark bytes
    /// verbatim, so a library full of clones resolves once. Failures are
    /// memoized too, so a dead blob is neither re-resolved nor re-logged per
    /// reference carrying it.
    ///
    /// `resolve` turns one blob into a path; real resolution needs a
    /// panel-minted grant, so that is where a test substitutes its own.
    func resolvedTargets(
        resolving resolve: (Data) -> String? = { SecurityScopedBookmark.resolvedTargetPath($0) }
    ) -> [Data: String] {
        var attempts: [Data: String?] = [:]
        for reference in self {
            guard let bookmark = reference.bookmark, attempts[bookmark] == nil else { continue }
            attempts[bookmark] = resolve(bookmark)
        }
        return attempts.compactMapValues { $0 }
    }

    /// Every canonical path these references stand for — the union of each
    /// reference's stored path and, when `resolvedTargets` carries one, its
    /// bookmark's current target.
    ///
    /// Two reference sets name the same file when their identities intersect.
    func fileIdentities(resolvedTargets: [Data: String]) -> Set<String> {
        var identities: Set<String> = []
        for reference in self {
            identities.formUnion(
                ExternalFileReference.fileIdentities(
                    forPath: reference.path,
                    resolvedTarget: reference.bookmark.flatMap { resolvedTargets[$0] }))
        }
        return identities
    }
}

extension ExternalFileReference {
    /// One file's identity: its stored path, plus its bookmark's resolved
    /// target when the two differ.
    ///
    /// The union widens the match past either path alone: a VM that healed to
    /// the file's new home still meets a sibling holding the old path *and* a
    /// live bookmark, because the sibling contributes both. A bookmark that is
    /// absent or dead contributes nothing, so that reference is matchable on
    /// its stored path alone — two references whose stored paths have diverged
    /// with no usable bookmark between them never meet. Closing that takes a
    /// bookmark, not a wider comparison.
    static func fileIdentities(forPath path: String, resolvedTarget: String?) -> Set<String> {
        var identities: Set<String> = [canonicalPath(path)]
        if let resolvedTarget { identities.insert(canonicalPath(resolvedTarget)) }
        return identities
    }

    /// The comparison form of a path: `.`/`..` and a trailing slash removed,
    /// and the name precomposed.
    ///
    /// APFS hands back a decomposed (NFD) form of a name the open panel stored
    /// precomposed (NFC), and a `sharedDirectory` pick can carry a trailing
    /// slash the same file's disk pick does not. The `isDirectory` hint is
    /// pinned so the form is the string's alone — left to infer it, `URL` stats
    /// the path and keeps the trailing slash for a directory that exists.
    static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: false).standardizedFileURL
            .path(percentEncoded: false)
            .precomposedStringWithCanonicalMapping
    }

    /// A library VM as the shared-file check sees it: its name, and the
    /// external references that decide whether it shares a file.
    ///
    /// Snapshotted on the main actor so the resolution pass behind
    /// ``Swift/Sequence/fileIdentities(resolvedTargets:)`` can run detached.
    struct SharingCandidate: Sendable {
        let name: String
        let references: [ExternalFileReference]
    }
}

extension Sequence<ExternalFileReference.SharingCandidate> {
    /// The candidates reduced to what a match needs — each one's name and
    /// identity set — for ``VMCommandCore/sharingVMNames(matching:among:)``.
    func identified(resolvedTargets: [Data: String]) -> [(name: String, identities: Set<String>)] {
        map {
            (
                name: $0.name,
                identities: $0.references.fileIdentities(resolvedTargets: resolvedTargets)
            )
        }
    }
}
