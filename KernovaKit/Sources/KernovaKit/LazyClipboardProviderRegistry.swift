import AppKit
import Foundation
import os

/// Owner of the live clipboard pasteboard data providers, holding each alive
/// until its pasteboard promise is finished.
///
/// `NSPasteboard` does **not** retain a data provider, and a promised item
/// outlives the code that wrote it. The set is never proactively cleared — a
/// destination may still read a prior copy's promise. Thread-safe via a lock,
/// not actor isolation: the host calls from `@MainActor`, the guest agent from
/// its main-queue-confined run loop, and a provider's deferred finish from the
/// main queue.
public final class LazyClipboardProviderRegistry: @unchecked Sendable {
    /// Shared registry used by the host in production, one per process.
    ///
    /// Matches the single `NSPasteboard.general` every "Copy to Mac" targets. The
    /// guest agent and tests construct their own instances.
    public static let shared = LazyClipboardProviderRegistry()

    private static let logger = Logger(subsystem: "app.kernova", category: "ClipboardProvider")

    private let lock = NSLock()
    private var live: Set<LazyClipboardDataProvider> = []

    /// Creates an empty registry.
    public init() {}

    /// Retains `providers` for the lifetime of their pasteboard promise — until
    /// each is individually released when the pasteboard finishes with it.
    public func retain(_ providers: [LazyClipboardDataProvider]) {
        let count = lock.withLock {
            live.formUnion(providers)
            return live.count
        }
        Self.logger.debug(
            "Retained \(providers.count, privacy: .public) clipboard provider(s) (live: \(count, privacy: .public))"
        )
        #if DEBUG
        onChangeForTesting?()
        #endif
    }

    /// Drops the strong reference to a single provider the pasteboard is done
    /// with.
    public func release(_ provider: LazyClipboardDataProvider) {
        let count = lock.withLock {
            live.remove(provider)
            return live.count
        }
        Self.logger.debug(
            "Released a finished clipboard provider (live: \(count, privacy: .public))")
        #if DEBUG
        onChangeForTesting?()
        #endif
    }

    #if DEBUG
    /// Count of providers currently retained for an outstanding pasteboard
    /// promise.
    var countForTesting: Int { lock.withLock { live.count } }

    /// Fires after every `retain`/`release` so a test can await the registration
    /// or finish signal instead of polling.
    ///
    /// Set it once before the registry is exercised; `releaseAllForTesting` is
    /// teardown-only and deliberately doesn't fire it.
    var onChangeForTesting: (() -> Void)?

    /// Releases every retained provider, breaking the registry↔provider retain
    /// cycle that production breaks via `pasteboardFinishedWithDataProvider`.
    func releaseAllForTesting() { lock.withLock { live.removeAll() } }
    #endif
}
