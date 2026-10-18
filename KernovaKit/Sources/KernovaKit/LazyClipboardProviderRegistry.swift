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
    /// Matches the single `NSPasteboard.general` every "Copy to Mac" targets. The
    /// guest agent and tests construct their own instances.
    public static let shared = LazyClipboardProviderRegistry()

    private static let logger = KernovaLogger(
        subsystem: "app.kernova", category: "ClipboardProvider")

    private struct State: Sendable {
        var live: Set<LazyClipboardDataProvider> = []
        #if DEBUG
        var onChange: (@Sendable () -> Void)?
        var changeHook: (@Sendable () -> Void)? { onChange }
        #else
        var changeHook: (@Sendable () -> Void)? { nil }
        #endif
    }

    private let state = Locked(State())

    /// Creates an empty registry.
    public init() {}

    /// Retains `providers` for the lifetime of their pasteboard promise — until
    /// each is individually released when the pasteboard finishes with it.
    public func retain(_ providers: [LazyClipboardDataProvider]) {
        let (count, onChange) = state.withLock { state in
            state.live.formUnion(providers)
            return (state.live.count, state.changeHook)
        }
        #log(
            Self.logger, .debug,
            "Retained \(providers.count, privacy: .public) clipboard provider(s) (live: \(count, privacy: .public))"
        )
        onChange?()
    }

    /// Drops the strong reference to a single provider the pasteboard is done
    /// with.
    public func release(_ provider: LazyClipboardDataProvider) {
        let (count, onChange) = state.withLock { state in
            state.live.remove(provider)
            return (state.live.count, state.changeHook)
        }
        #log(
            Self.logger, .debug,
            "Released a finished clipboard provider (live: \(count, privacy: .public))")
        onChange?()
    }

    #if DEBUG
    /// Count of providers currently retained for an outstanding pasteboard
    /// promise.
    var countForTesting: Int { state.withLock { $0.live.count } }

    /// Installs `hook`, fired after every `retain`/`release` so a test can await
    /// the registration or finish signal instead of polling.
    ///
    /// `releaseAllForTesting` is teardown-only and doesn't fire it.
    func setOnChangeForTesting(_ hook: @escaping @Sendable () -> Void) {
        state.withLock { $0.onChange = hook }
    }

    /// Releases every retained provider, breaking the registry↔provider retain
    /// cycle that production breaks via `pasteboardFinishedWithDataProvider`.
    func releaseAllForTesting() { state.withLock { $0.live.removeAll() } }
    #endif
}
