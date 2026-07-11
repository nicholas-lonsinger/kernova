import Foundation
import os

/// Creation and resolution of app-scoped security bookmarks — the sandbox's
/// mechanism for persisting a user's open/save-panel grant across launches.
///
/// Every panel pick site converts its URL through ``capture(_:)`` and stores
/// the resulting `(path, bookmark)` pair on the model; every access site
/// resolves the bookmark back into live access via ``ScopedAccess``. A `nil`
/// bookmark (pre-sandbox configs, creation failures) falls through to the
/// raw path, which the sandbox denies for out-of-container files — surfacing
/// the existing missing-file UX, from which re-picking the file mints a
/// fresh bookmark.
enum SecurityScopedBookmark {
    fileprivate static let logger = Logger(
        subsystem: "app.kernova", category: "SecurityScopedBookmark")

    /// A resolved bookmark: the live URL plus whether the system asked for
    /// the bookmark data to be re-created (`isStale`).
    struct Resolution {
        let url: URL
        let isStale: Bool
    }

    /// Captures a panel-picked URL as the `(path, bookmark)` pair the models
    /// persist.
    ///
    /// The single call every pick site uses.
    static func capture(_ url: URL) -> (path: String, bookmark: Data?) {
        (url.path(percentEncoded: false), make(for: url))
    }

    /// Creates app-scoped bookmark data for `url`, or `nil` (logged) when
    /// the system refuses — callers store the raw path alone and rely on
    /// the nil-bookmark fall-through.
    static func make(for url: URL) -> Data? {
        do {
            return try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } catch {
            logger.error(
                "Failed to create security-scoped bookmark for \(url.path(percentEncoded: false), privacy: .private): \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    /// Runs `body` with the bookmark's scope active, passing the resolved
    /// URL (which tracks a moved file) — or `fallback` with no scope when
    /// the bookmark is absent or dead, letting the raw-path attempt surface
    /// the usual sandbox denial.
    ///
    /// The single momentary-scope idiom shared by the external-file
    /// trash/delete sites; existence probes use the
    /// ``fileExists(atPath:bookmark:)`` wrapper over it.
    static func withResolvedURL<T>(
        bookmark: Data?, fallback: URL, _ body: (URL) throws -> T
    ) rethrows -> T {
        guard let bookmark, let scope = ScopedAccess(bookmark: bookmark) else {
            return try body(fallback)
        }
        defer { scope.release() }
        return try body(scope.url)
    }

    /// Existence check that honors a bookmark when present: probes the
    /// bookmark's resolved location under a momentary scope — so a file the
    /// bookmark still tracks after a move reads as existing (boot-time
    /// healing updates the stored path) — falling back to a raw-path check
    /// when the bookmark is absent or dead.
    static func fileExists(atPath path: String, bookmark: Data?) -> Bool {
        withResolvedURL(bookmark: bookmark, fallback: URL(fileURLWithPath: path)) { url in
            FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
        }
    }

    /// Resolves bookmark data back to a URL, or `nil` (logged) when the
    /// bookmark no longer resolves (target deleted, volume gone).
    static func resolve(_ data: Data) -> Resolution? {
        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            return Resolution(url: url, isStale: isStale)
        } catch {
            logger.warning(
                "Failed to resolve security-scoped bookmark: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }
}

/// RAII handle for an active security-scoped resource grant.
///
/// Resolves a bookmark and starts scoped access on init; balances the stop
/// on ``release()`` (idempotent) or deinit. Unbalanced stops leak kernel
/// resources until relaunch, so all long-lived instances are owned by
/// `RuntimeFileAccess`, whose `releaseAll()` sits in the one session
/// teardown chokepoint; short-lived probe instances release via deinit.
///
/// Not `Sendable` — each instance stays in the isolation domain that
/// created it (main-actor for VM-runtime scopes, the probe's task for
/// momentary existence checks).
final class ScopedAccess {
    /// The bookmark's resolved live URL (which may differ from the stored
    /// path if the file moved — see the healing pass in
    /// `VMInstance.openRuntimeFileAccess()`).
    let url: URL

    /// `true` when the system asked for the bookmark to be re-created.
    let isStale: Bool

    // RATIONALE: `startAccessingSecurityScopedResource()` returning false is
    // NORMAL for paths that need no scope (inside the container, or covered
    // by the downloads entitlement) — the guard exists only to balance the
    // matching stop call, not to signal an error.
    private let didStart: Bool
    private var released = false

    /// Resolves `bookmark` and starts scoped access; `nil` when the
    /// bookmark doesn't resolve.
    init?(bookmark: Data) {
        guard let resolution = SecurityScopedBookmark.resolve(bookmark) else { return nil }
        self.url = resolution.url
        self.isStale = resolution.isStale
        self.didStart = resolution.url.startAccessingSecurityScopedResource()
    }

    /// Stops the scoped access if this instance started one.
    ///
    /// Idempotent.
    func release() {
        guard !released else { return }
        released = true
        if didStart {
            url.stopAccessingSecurityScopedResource()
        }
    }

    deinit {
        release()
    }
}
