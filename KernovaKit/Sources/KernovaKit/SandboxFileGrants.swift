import Foundation
import KernovaSynchronization

/// The grants of sandbox access to files and folders this process starts and takes, counted by path: a
/// security-scoped URL's started access, and the grant a pasteboard read took (``PasteboardFileAccess``). Each is a
/// ``Grant``, which gives itself back once.
///
/// Giving a grant back takes away one of the process's grants of that exact path, whichever holder took it, and a
/// pasteboard read past an exhausted grant budget takes none while still naming the file
/// (docs/research/2026-11-18-pasteboard-file-grants.md). So a started access gives its grant back as it ends — its
/// start answered that it took one — while a pasteboard read's is given back only once nothing else here holds the
/// path: a grant the read never took then costs no other holder its access.
public final class SandboxFileGrants: Sendable {
    /// This process's grants.
    public static let shared = SandboxFileGrants(.system)

    /// The calls into the sandbox the grants make.
    public struct Platform: Sendable {
        /// Starts access to a security-scoped URL, true when it took a grant.
        public var start: @Sendable (URL) -> Bool
        /// Gives back one grant of the URL's path.
        public var stop: @Sendable (URL) -> Void
        /// A security-scoped bookmark granting read access to the file or folder at the URL, or the error this
        /// process can't make one for.
        public var bookmark: @Sendable (URL) throws -> Data
        /// The security-scoped URL of the file or folder a bookmark names now, or nil when it no longer resolves.
        public var resolve: @Sendable (Data) -> URL?

        /// Calls that make `start`, `stop`, `bookmark` and `resolve`.
        public init(
            start: @escaping @Sendable (URL) -> Bool, stop: @escaping @Sendable (URL) -> Void,
            bookmark: @escaping @Sendable (URL) throws -> Data, resolve: @escaping @Sendable (Data) -> URL?
        ) {
            self.start = start
            self.stop = stop
            self.bookmark = bookmark
            self.resolve = resolve
        }

        /// The App Sandbox's.
        public static let system = Platform(
            start: { $0.startAccessingSecurityScopedResource() }, stop: { $0.stopAccessingSecurityScopedResource() },
            // A bookmark of `.withSecurityScope` alone asks for read-write access, which a file the process can only
            // read refuses (docs/research/2026-11-18-pasteboard-file-grants.md).
            bookmark: {
                try $0.bookmarkData(
                    options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                    includingResourceValuesForKeys: nil)
            },
            resolve: { bookmark in
                var stale = false
                return try? URL(
                    resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI, .withoutMounting],
                    relativeTo: nil, bookmarkDataIsStale: &stale)
            })
    }

    /// One grant this process holds of `url`'s path, given back once: at ``release()``, or once nothing holds it.
    public final class Grant: Sendable {
        /// The URL the grant was taken through.
        public let url: URL
        /// The path the grant was counted under as it was taken, which its give-back is counted under too.
        private let path: String
        private let grants: SandboxFileGrants
        private let started: Bool
        private let released = Locked(false)

        fileprivate init(url: URL, path: String, grants: SandboxFileGrants, started: Bool) {
            self.url = url
            self.path = path
            self.grants = grants
            self.started = started
        }

        /// Gives the grant back, the first time only.
        public func release() {
            let first = released.withLock { released in
                defer { released = true }
                return !released
            }
            guard first else { return }
            grants.letGo(url, countedUnder: path, started: started)
        }

        deinit {
            release()
        }
    }

    /// One path's holders.
    private struct Holders {
        var count = 0
        /// The pasteboard reads' grants of the path whose holders let them go, given back once no holder remains.
        var released: [URL] = []
    }

    private let platform: Platform
    private let paths = Locked<[String: Holders]>([:])

    /// Grants that `platform` takes and gives back.
    public init(_ platform: Platform) {
        self.platform = platform
    }

    /// Starts access to the security-scoped `url`: the grant it took, or nil when it took none.
    public func startAccessing(_ url: URL) -> Grant? {
        let path = Self.path(of: url)
        return paths.withLock { paths in
            guard platform.start(url) else { return nil }
            paths[path, default: Holders()].count += 1
            return Grant(url: url, path: path, grants: self, started: true)
        }
    }

    /// A security-scoped bookmark granting read access to the file or folder at `url`, which this process makes only
    /// while it holds a grant of it.
    public func bookmark(of url: URL) throws -> Data {
        try platform.bookmark(url)
    }

    /// The file or folder `bookmark` names now, wherever it has moved since: its URL, and the grant started for it,
    /// nil for one that needs none, which whatever reads it holds until it has. Nil when the bookmark no longer
    /// resolves.
    public func reach(_ bookmark: Data) -> (url: URL, grant: Grant?)? {
        guard let url = platform.resolve(bookmark) else { return nil }
        return (url, startAccessing(url))
    }

    /// The grant a pasteboard read took of the file or folder `url` names.
    func pasteboardGranted(_ url: URL) -> Grant {
        let path = Self.path(of: url)
        paths.withLock { $0[path, default: Holders()].count += 1 }
        return Grant(url: url, path: path, grants: self, started: false)
    }

    /// A grant of `url`, counted under `path`, was let go: a started access's is given back now, a pasteboard read's
    /// once its path has no holder, and the last holder gives back every pasteboard read's grant of the path.
    private func letGo(_ url: URL, countedUnder path: String, started: Bool) {
        paths.withLock { paths in
            guard var holders = paths[path] else { return }
            if started { platform.stop(url) } else { holders.released.append(url) }
            holders.count -= 1
            guard holders.count <= 0 else {
                paths[path] = holders
                return
            }
            paths[path] = nil
            for url in holders.released { platform.stop(url) }
        }
    }

    /// `url`'s path as it stands, its links resolved, so a bookmark's URL and a pasteboard's name one path alike.
    private static func path(of url: URL) -> String {
        url.resolvingSymlinksInPath().path
    }
}
