import Foundation
import KernovaSynchronization

/// The grants of sandbox access to files and folders this process starts and takes, counted by path: a
/// security-scoped URL's started access, and the grant a pasteboard read took (``PasteboardFileAccess``).
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

    /// Starts access to the security-scoped `url`, true when it took a grant: `url` then holds its path until
    /// ``stopAccessing(_:)``.
    public func startAccessing(_ url: URL) -> Bool {
        paths.withLock { paths in
            guard start(url) else { return false }
            paths[Self.path(of: url), default: Holders()].count += 1
            return true
        }
    }

    /// Gives back the grant ``startAccessing(_:)`` took for `url`, and every grant a pasteboard read of its path
    /// let go once that leaves the path no holder.
    public func stopAccessing(_ url: URL) {
        paths.withLock { paths in
            stop(url)
            letGo(Self.path(of: url), in: &paths)
        }
    }

    /// A pasteboard read took a grant of the file or folder `url` names, which holds its path until
    /// ``pasteboardGrantReleased(_:)``.
    func pasteboardGranted(_ url: URL) {
        paths.withLock { $0[Self.path(of: url), default: Holders()].count += 1 }
    }

    /// The pasteboard read's grant of `url` is no longer needed: given back now, or once its path has no holder.
    func pasteboardGrantReleased(_ url: URL) {
        paths.withLock { paths in
            let path = Self.path(of: url)
            paths[path, default: Holders()].released.append(url)
            letGo(path, in: &paths)
        }
    }

    /// One holder of `path` let go of it; the last gives back every pasteboard read's grant of it.
    private func letGo(_ path: String, in paths: inout [String: Holders]) {
        guard var holders = paths[path] else { return }
        holders.count -= 1
        guard holders.count <= 0 else {
            paths[path] = holders
            return
        }
        paths[path] = nil
        for url in holders.released { stop(url) }
    }

    private static func path(of url: URL) -> String {
        url.standardizedFileURL.path
    }
}
