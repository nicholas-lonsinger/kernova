import Foundation
import KernovaKit
import KernovaLogging

/// Creation and resolution of app-scoped security bookmarks — the sandbox's
/// mechanism for persisting a user's open/save-panel grant across launches.
///
/// Every panel pick site converts its URL through ``capture(_:)`` and stores the
/// resulting `(path, bookmark)` pair on the model; every access site resolves it
/// back into live access via ``ScopedAccess``. A `nil` bookmark falls through to
/// the raw path, which the sandbox refuses to open for an out-of-container file
/// (docs/research/2026-11-18-pasteboard-file-grants.md, finding 8); re-picking
/// mints a fresh bookmark.
package enum SecurityScopedBookmark {
    fileprivate static let logger = KernovaLogger(
        subsystem: "app.kernova", category: "SecurityScopedBookmark")

    /// A resolved bookmark: the live URL plus whether the system asked for
    /// the bookmark data to be re-created (`isStale`).
    struct Resolution {
        let url: URL
        let isStale: Bool
    }

    /// Captures a panel-picked URL as the `(path, bookmark)` pair the models
    /// persist.
    package static func capture(_ url: URL) -> (path: String, bookmark: Data?) {
        (url.path(percentEncoded: false), make(for: url))
    }

    /// Creates app-scoped bookmark data for `url`, or `nil` (logged) when the
    /// system refuses — callers store the raw path alone and rely on the
    /// nil-bookmark fall-through.
    ///
    /// The bookmark grants read-write access, or read access alone where the
    /// system refuses that: a read-write scope is refused for a file the
    /// process can only read
    /// (docs/research/2026-11-18-pasteboard-file-grants.md, finding 15).
    static func make(for url: URL) -> Data? {
        let refusal: any Error
        do {
            return try data(for: url, scope: .withSecurityScope)
        } catch {
            refusal = error
        }
        do {
            let readOnly = try data(
                for: url, scope: [.withSecurityScope, .securityScopeAllowOnlyReadAccess])
            logger.log(
                .notice,
                "Bookmarked \(url.path(percentEncoded: false), privacy: .private) for read access alone; read-write was refused: \(refusal.localizedDescription, privacy: .public)"
            )
            return readOnly
        } catch {
            logger.log(
                .error,
                "Failed to create security-scoped bookmark for \(url.path(percentEncoded: false), privacy: .private): \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    /// A fresh bookmark for `url`, made under the active scope of the bookmark
    /// it replaces, or `nil` (logged) when the system refuses a read-write one —
    /// the caller keeps the bookmark it has.
    ///
    /// Read-write alone: the refusal does not say whether the replaced
    /// bookmark's scope or the file's permissions caused it, and a read-only
    /// bookmark stored in place of a read-write one is never widened again.
    static func renewal(for url: URL) -> Data? {
        do {
            return try data(for: url, scope: .withSecurityScope)
        } catch {
            logger.log(
                .notice,
                "Kept the bookmark of \(url.path(percentEncoded: false), privacy: .private); a fresh one was refused: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    private static func data(for url: URL, scope: URL.BookmarkCreationOptions) throws -> Data {
        try url.bookmarkData(options: scope, includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    /// Resolution options for an advisory read: mounts nothing and puts no
    /// system UI on screen.
    ///
    /// The default `[.withSecurityScope]` resolution is free to mount a network
    /// volume, and to show the system's own UI while it does. Every caller whose
    /// answer only feeds an affordance resolves through this instead, so a
    /// bookmark pointing at an unmounted volume costs one denial rather than a
    /// mount attempt the user did not ask for.
    static let advisoryResolution: URL.BookmarkResolutionOptions = [
        .withSecurityScope, .withoutUI, .withoutMounting,
    ]

    /// Runs `body` with the bookmark's scope active, passing the resolved
    /// URL (which tracks a moved file) — or `fallback` with no scope when
    /// the bookmark is absent or dead, letting the raw-path attempt surface
    /// the usual sandbox denial.
    static func withResolvedURL<T>(
        bookmark: Data?, fallback: URL,
        options: URL.BookmarkResolutionOptions = [.withSecurityScope],
        _ body: (URL) throws -> T
    ) rethrows -> T {
        guard let bookmark, let scope = ScopedAccess(bookmark: bookmark, options: options) else {
            return try body(fallback)
        }
        defer { scope.release() }
        return try body(scope.url)
    }

    /// Existence check that honors a bookmark when present: probes the
    /// bookmark's resolved location under a momentary scope, so a file the
    /// bookmark still tracks after a move reads as existing.
    ///
    /// Advisory, so it resolves through ``advisoryResolution``: this runs on
    /// every re-probe `AttachmentFileMonitor.revalidate()` sweeps, and a badge
    /// is never worth mounting a volume for. An auto-mounting volume that is
    /// currently unmounted therefore reads as missing, which the authoritative
    /// check at VM start still overrules.
    static func fileExists(atPath path: String, bookmark: Data?) -> Bool {
        withResolvedURL(
            bookmark: bookmark, fallback: URL(fileURLWithPath: path),
            options: advisoryResolution
        ) { url in
            FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
        }
    }

    /// The path `data` currently points at, without starting a scope — the
    /// identity of the file a reference tracks, for comparison alone.
    ///
    /// Advisory: the shared-file check runs over every library VM's references,
    /// where a UI prompt or a network-volume mount would be a surprise.
    static func resolvedTargetPath(_ data: Data) -> String? {
        resolve(data, options: advisoryResolution)?.url.path(percentEncoded: false)
    }

    /// Resolves bookmark data back to a URL, or `nil` (logged) when the
    /// bookmark no longer resolves (target deleted, volume gone).
    static func resolve(
        _ data: Data, options: URL.BookmarkResolutionOptions = [.withSecurityScope]
    ) -> Resolution? {
        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: data,
                options: options,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            return Resolution(url: url, isStale: isStale)
        } catch {
            logger.log(
                .warning,
                "Failed to resolve security-scoped bookmark: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }
}

/// RAII handle for an active security-scoped resource grant.
///
/// Resolves a bookmark and starts scoped access on init; balances the stop on
/// ``release()`` (idempotent) or deinit. Unbalanced stops leak kernel resources
/// until relaunch, so all long-lived instances are owned by `RuntimeFileAccess`,
/// whose `releaseAll()` sits in the one session teardown chokepoint.
///
/// Not `Sendable` — each instance stays in the isolation domain that created it.
final class ScopedAccess {
    /// The bookmark's resolved live URL, which may differ from the stored path
    /// if the file moved.
    let url: URL

    /// `true` when the system asked for the bookmark to be re-created.
    let isStale: Bool

    // `startAccessingSecurityScopedResource()` returns false for a path that
    // needs no scope (inside the container, or covered by the downloads
    // entitlement): no grant, and no error.
    private let grant: SandboxFileGrants.Grant?

    /// Resolves `bookmark` and starts scoped access; `nil` when the
    /// bookmark doesn't resolve.
    ///
    /// An advisory caller passes `SecurityScopedBookmark.advisoryResolution` so
    /// the resolution neither mounts a volume nor shows UI.
    init?(bookmark: Data, options: URL.BookmarkResolutionOptions = [.withSecurityScope]) {
        guard let resolution = SecurityScopedBookmark.resolve(bookmark, options: options) else {
            return nil
        }
        self.url = resolution.url
        self.isStale = resolution.isStale
        self.grant = SandboxFileGrants.shared.startAccessing(resolution.url)
    }

    /// Stops the scoped access if this instance started one; idempotent.
    func release() {
        grant?.release()
    }
}
