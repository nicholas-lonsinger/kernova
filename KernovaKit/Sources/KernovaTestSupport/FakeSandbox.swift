import Foundation
import KernovaKit
import KernovaSynchronization

/// The App Sandbox's grants of access to paths, counted as a Mac counts them: one count per exact path, which every
/// grant taken — a pasteboard read's, a security-scoped start's — raises and every grant given back lowers, whichever
/// holder took it (docs/research/2026-11-18-pasteboard-file-grants.md).
///
/// A give-back of a path holding no grant is recorded rather than counted: on a Mac it takes away a grant another
/// holder of the path took, or one a later holder takes.
public final class FakeSandbox: Sendable {
    private struct State: Sendable {
        var counts: [String: Int] = [:]
        var unheldGiveBacks: [String] = []
    }

    private let state: Locked<State>

    /// Fires after every grant and give-back; await it instead of polling.
    public let changed: AsyncGate

    /// The process's grants as ``SandboxFileGrants`` holds them over this sandbox: a start takes a grant and
    /// answers that it did.
    public let fileGrants: SandboxFileGrants

    /// A sandbox granting nothing yet.
    public init() {
        let state = Locked(State())
        let changed = AsyncGate()
        self.state = state
        self.changed = changed
        fileGrants = SandboxFileGrants(
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
            })
    }

    /// A pasteboard read took a grant of `url`'s path.
    public func grant(_ url: URL) {
        Self.take(url, in: state, changed)
    }

    /// How many grants of `url`'s path the process holds.
    public func grants(of url: URL) -> Int {
        state.withLock { $0.counts[Self.path(of: url)] ?? 0 }
    }

    /// Each path given back while it held no grant, in order.
    public var unheldGiveBacks: [String] { state.withLock { $0.unheldGiveBacks } }

    private static func take(_ url: URL, in state: Locked<State>, _ changed: AsyncGate) {
        state.withLock { $0.counts[path(of: url), default: 0] += 1 }
        changed.notify()
    }

    private static func path(of url: URL) -> String {
        url.standardizedFileURL.path
    }
}
