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
    public static let shared = SandboxFileGrants(
        start: { $0.startAccessingSecurityScopedResource() }, stop: { $0.stopAccessingSecurityScopedResource() })

    /// One grant this process holds of `url`'s path, given back once: at ``release()``, or once nothing holds it.
    public final class Grant: Sendable {
        /// The URL the grant was taken through.
        public let url: URL
        private let grants: SandboxFileGrants
        private let started: Bool
        private let released = Locked(false)

        fileprivate init(url: URL, grants: SandboxFileGrants, started: Bool) {
            self.url = url
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
            grants.letGo(url, started: started)
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

    private let start: @Sendable (URL) -> Bool
    private let stop: @Sendable (URL) -> Void
    private let paths = Locked<[String: Holders]>([:])

    /// Grants that `start` takes and `stop` gives back.
    public init(start: @escaping @Sendable (URL) -> Bool, stop: @escaping @Sendable (URL) -> Void) {
        self.start = start
        self.stop = stop
    }

    /// Starts access to the security-scoped `url`: the grant it took, or nil when it took none.
    public func startAccessing(_ url: URL) -> Grant? {
        paths.withLock { paths in
            guard start(url) else { return nil }
            paths[Self.path(of: url), default: Holders()].count += 1
            return Grant(url: url, grants: self, started: true)
        }
    }

    /// The grant a pasteboard read took of the file or folder `url` names.
    func pasteboardGranted(_ url: URL) -> Grant {
        paths.withLock { $0[Self.path(of: url), default: Holders()].count += 1 }
        return Grant(url: url, grants: self, started: false)
    }

    /// A grant of `url` was let go: a started access's is given back now, a pasteboard read's once its path has no
    /// holder, and the last holder gives back every pasteboard read's grant of the path.
    private func letGo(_ url: URL, started: Bool) {
        paths.withLock { paths in
            let path = Self.path(of: url)
            guard var holders = paths[path] else { return }
            if started { stop(url) } else { holders.released.append(url) }
            holders.count -= 1
            guard holders.count <= 0 else {
                paths[path] = holders
                return
            }
            paths[path] = nil
            for url in holders.released { stop(url) }
        }
    }

    private static func path(of url: URL) -> String {
        url.standardizedFileURL.path
    }
}
