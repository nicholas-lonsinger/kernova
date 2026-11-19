import Foundation
import KernovaKit
import KernovaLogging
import KernovaSynchronization

/// The App Sandbox's grants of access to paths, counted as a Mac counts them: one count per exact path, which every
/// grant taken — a pasteboard read's, a security-scoped start's — raises and every grant given back lowers, whichever
/// holder took it (docs/research/2026-11-18-pasteboard-file-grants.md).
///
/// A give-back of a path holding no grant changes nothing, as on a Mac, and is recorded: it gave back more grants of
/// the path than were taken, so had another holder held the path, it would have taken that holder's grant.
public final class FakeSandbox: Sendable {
    private struct State: Sendable {
        var counts: [String: Int] = [:]
        var unheldGiveBacks: [String] = []
        /// The pasteboard generation `readItems` were read in.
        var readGeneration = 0
        /// The items whose file URL was read in `readGeneration`.
        var readItems: Set<Int> = []
        var bookmarksAsked = 0
        /// The paths whose file or folder refuses a bookmark.
        var refusingBookmarks: Set<String> = []
        var logged: [String] = []
    }

    private let state: Locked<State>

    /// Fires after every grant and give-back; await it instead of polling.
    public let changed: AsyncGate

    /// The process's grants as ``SandboxFileGrants`` holds them over this sandbox: a start takes a grant and
    /// answers that it did; a bookmark is made only of a path holding a grant whose file or folder doesn't refuse
    /// one, and resolves to wherever its file or folder has moved since.
    public let fileGrants: SandboxFileGrants

    /// A sandbox granting nothing yet.
    public init() {
        let state = Locked(State())
        let changed = AsyncGate()
        self.state = state
        self.changed = changed
        fileGrants = SandboxFileGrants(
            SandboxFileGrants.Platform(
                start: { url in
                    Self.take(url, in: state, changed)
                    return true
                },
                stop: { url in
                    state.withLock { state in
                        let path = Self.path(of: url)
                        guard let count = state.counts[path], count > 0 else {
                            return state.unheldGiveBacks.append(path)
                        }
                        state.counts[path] = count - 1
                    }
                    changed.notify()
                },
                bookmark: { url in
                    let path = Self.path(of: url)
                    let made = state.withLock { state in
                        defer { state.bookmarksAsked += 1 }
                        return (state.counts[path] ?? 0) > 0 && !state.refusingBookmarks.contains(path)
                    }
                    guard made else { throw CocoaError(.fileReadUnknown) }
                    return try url.bookmarkData()
                },
                resolve: { bookmark in
                    var stale = false
                    return try? URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &stale)
                }),
            logger: KernovaLogger(
                subsystem: "app.kernova", category: "SandboxFileGrants",
                sink: KernovaLogger.ForwardingSink { _, _, _, segments in
                    state.withLock { $0.logged.append(segments.map(\.text).joined()) }
                }))
    }

    /// A pasteboard read took a grant of `url`'s path.
    public func grant(_ url: URL) {
        Self.take(url, in: state, changed)
    }

    /// A read of the file URL `url` that pasteboard item `index` names, in the generation `changeCount` counts: the
    /// first of the generation takes a grant, as a pasteboard read on a Mac does, and a later one none.
    public func read(fileURL url: URL, ofItem index: Int, at changeCount: Int) {
        let first = state.withLock { state in
            if state.readGeneration != changeCount {
                state.readGeneration = changeCount
                state.readItems = []
            }
            return state.readItems.insert(index).inserted
        }
        if first { grant(url) }
    }

    /// The file or folder at `url` refuses a bookmark from now on, granted or not, as one a Mac can't open for the
    /// access a bookmark asks does.
    public func refuseBookmarks(of url: URL) {
        state.withLock { _ = $0.refusingBookmarks.insert(Self.path(of: url)) }
    }

    /// How many grants of `url`'s path the process holds.
    public func grants(of url: URL) -> Int {
        state.withLock { $0.counts[Self.path(of: url)] ?? 0 }
    }

    /// Each path given back while it held no grant, in order.
    public var unheldGiveBacks: [String] { state.withLock { $0.unheldGiveBacks } }

    /// The text of each record the grants logged, in order.
    public var logged: [String] { state.withLock { $0.logged } }

    /// How many bookmarks were asked for, made or not.
    public var bookmarksAsked: Int { state.withLock { $0.bookmarksAsked } }

    private static func take(_ url: URL, in state: Locked<State>, _ changed: AsyncGate) {
        state.withLock { $0.counts[path(of: url), default: 0] += 1 }
        changed.notify()
    }

    private static func path(of url: URL) -> String {
        url.resolvingSymlinksInPath().path
    }
}
