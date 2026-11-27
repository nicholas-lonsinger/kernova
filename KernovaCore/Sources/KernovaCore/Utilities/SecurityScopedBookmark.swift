import Foundation
import KernovaCommandModel
import KernovaKit
import KernovaLogging

/// An app-scoped security bookmark and the access it grants.
///
/// Nothing widens a bookmark: a wider one takes a new grant, which only a new
/// pick of the file gives.
package struct FileBookmark: Sendable, Hashable {
    package enum Access: Sendable, Hashable {
        case readWrite
        /// Made with `securityScopeAllowOnlyReadAccess`, so the scope it
        /// resolves to reads the file and never writes it.
        case readOnly
    }

    package let data: Data
    package let access: Access
}

extension FileBookmark {
    /// The bookmark a model records as two keys: `data` at its bookmark key
    /// and `readOnly` beside it, absent where the bookmark grants writing.
    /// `nil` without data.
    init?(data: Data?, readOnly: Bool?) {
        guard let data else { return nil }
        self.init(data: data, access: readOnly == true ? .readOnly : .readWrite)
    }

    /// `bookmark` as those two keys record it.
    static func recorded(_ bookmark: FileBookmark?) -> (data: Data?, readOnly: Bool?) {
        (bookmark?.data, bookmark?.access == .readOnly ? true : nil)
    }
}

extension KeyedDecodingContainer {
    /// The bookmark a model records at `key`, with its access at `readOnlyKey`
    /// (``FileBookmark/init(data:readOnly:)``).
    func decodeBookmark(_ key: Key, readOnly readOnlyKey: Key, in decoder: any Decoder) throws -> FileBookmark? {
        FileBookmark(
            data: try decodeIfPresent(Data.self, forKey: key),
            readOnly: try decode(Bool?.self, forKey: readOnlyKey, absentMeans: nil, in: decoder))
    }
}

/// Creation and resolution of app-scoped security bookmarks — the sandbox's
/// mechanism for persisting a user's open/save-panel grant across launches.
///
/// Every panel pick site converts its URL through ``capture(_:)`` and stores the
/// resulting `(path, bookmark)` pair on the model; every access site resolves it
/// back into live access via ``ScopedAccess``. A `nil` bookmark falls through to
/// the raw path, which the sandbox refuses to open for a file no grant or
/// entitlement covers
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
    package static func capture(_ url: URL) -> (path: String, bookmark: FileBookmark?) {
        (url.path(percentEncoded: false), make(for: url))
    }

    /// Creates an app-scoped bookmark for `url`, or `nil` (logged) when the
    /// system refuses — callers store the raw path alone and rely on the
    /// nil-bookmark fall-through.
    ///
    /// The bookmark grants read-write access, or read access alone where the
    /// system refuses that: a read-write scope is refused for a file the
    /// process can only read
    /// (docs/research/2026-11-18-pasteboard-file-grants.md, finding 15).
    static func make(for url: URL) -> FileBookmark? {
        let refusal: any Error
        do {
            return try bookmark(for: url, granting: .readWrite)
        } catch {
            refusal = error
        }
        do {
            let readOnly = try bookmark(for: url, granting: .readOnly)
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

    /// A fresh bookmark for `url` granting exactly what `replaced` grants, made
    /// under `replaced`'s active scope, or `nil` (logged) when the system
    /// refuses — the caller keeps the bookmark it has.
    ///
    /// Never narrower, which nothing widens again, and never wider, which would
    /// lift the Read Only a read-only bookmark holds its entry to
    /// (``StorageDisk/readOnly``) with no request from the user.
    static func renewal(of replaced: FileBookmark, at url: URL) -> FileBookmark? {
        do {
            return try bookmark(for: url, granting: replaced.access)
        } catch {
            logger.log(
                .notice,
                "Kept the bookmark of \(url.path(percentEncoded: false), privacy: .private); a fresh one was refused: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    private static func bookmark(for url: URL, granting access: FileBookmark.Access) throws -> FileBookmark {
        let options: URL.BookmarkCreationOptions =
            switch access {
            case .readWrite: .withSecurityScope
            case .readOnly: [.withSecurityScope, .securityScopeAllowOnlyReadAccess]
            }
        return FileBookmark(
            data: try url.bookmarkData(options: options, includingResourceValuesForKeys: nil, relativeTo: nil),
            access: access)
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
    /// the bookmark is absent or dead, where an open of the raw path meets
    /// the sandbox's own refusal.
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
