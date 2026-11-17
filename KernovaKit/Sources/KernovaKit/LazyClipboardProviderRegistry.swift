import AppKit
import Foundation
import KernovaLogging
import KernovaSynchronization

/// Owner of the live clipboard pasteboard data providers, holding each alive
/// until its pasteboard promise is finished.
///
/// `NSPasteboard` does **not** retain a data provider, and a promised item
/// outlives the code that wrote it. The set is never proactively cleared — a
/// destination may still read a prior copy's promise. A lock rather than
/// main-actor isolation: a provider releases itself from AppKit's
/// `NS_SWIFT_NONISOLATED` finish callback.
public final class LazyClipboardProviderRegistry: Sendable {
    /// Shared registry used by the host in production, one per process.
    ///
    /// Matches the single `NSPasteboard.general` every host write targets. The
    /// guest agent and tests construct their own instances.
    public static let shared = LazyClipboardProviderRegistry()

    private static let logger = KernovaLogger(
        subsystem: "app.kernova", category: "ClipboardProvider")

    private let live = Locked<Set<LazyClipboardDataProvider>>([])

    /// Creates an empty registry.
    public init() {}

    /// Retains `providers` for the lifetime of their pasteboard promise — until
    /// each is individually released when the pasteboard finishes with it.
    public func retain(_ providers: [LazyClipboardDataProvider]) {
        let count = live.withLock { live in
            live.formUnion(providers)
            return live.count
        }
        Self.logger.log(
            .debug,
            "Retained \(providers.count, privacy: .public) clipboard provider(s) (live: \(count, privacy: .public))"
        )
    }

    /// Drops the strong reference to a single provider the pasteboard is done
    /// with.
    public func release(_ provider: LazyClipboardDataProvider) {
        let count = live.withLock { live in
            live.remove(provider)
            return live.count
        }
        Self.logger.log(
            .debug,
            "Released a finished clipboard provider (live: \(count, privacy: .public))")
    }

    #if DEBUG
    /// Count of providers currently retained for an outstanding pasteboard
    /// promise.
    var countForTesting: Int { live.withLock { $0.count } }

    /// Releases every retained provider, breaking the registry↔provider retain
    /// cycle that production breaks via `pasteboardFinishedWithDataProvider`.
    func releaseAllForTesting() { live.withLock { $0.removeAll() } }
    #endif
}
