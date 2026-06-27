import AppKit
import Foundation
import os

/// Owner of the live clipboard pasteboard data providers, holding each alive
/// until its pasteboard promise is finished.
///
/// A promised pasteboard item outlives the code that wrote it. On the host, a
/// "Copy to Mac" promise survives the clipboard window closing (or the VM
/// stopping, which auto-closes it) so the user can still paste later; in the
/// guest agent, an inbound-paste promise survives the offer that registered it.
/// `NSPasteboard` does **not** retain a data provider — it requires the owner
/// keep the provider alive while the item's data is still promised. Both sides
/// hold their providers here instead: the host in the process-wide `shared`
/// registry, the guest agent in one instance it owns for its lifetime.
///
/// Providers are retained only after a successful write (so a failed or no-op
/// write needs no rollback — an unwritten provider never gets a finish callback
/// and deallocates with the caller's local array) and released when the
/// pasteboard reports the provider is finished (`pasteboardFinishedWithDataProvider`,
/// routed here via the provider's `onFinished`). The set is never proactively
/// cleared, since a destination may still read a prior copy's promise; the staged
/// file generations (`ClipboardFileStaging.maxGenerations`) cover that window for
/// file payloads.
///
/// Thread-safe via an internal lock rather than actor isolation: the host calls
/// from its `@MainActor`, the guest agent from its main-queue-confined (but not
/// `@MainActor`) run loop, and the provider's nonisolated `onFinished` fires on
/// the pasteboard's main run loop on each side. A lock lets every site call
/// `retain`/`release` directly, with no isolation hop sending a non-`Sendable`
/// provider across an actor boundary.
public final class LazyClipboardProviderRegistry: @unchecked Sendable {
    /// Shared registry used by the host in production — one per process, matching
    /// the single `NSPasteboard.general` every "Copy to Mac" targets.
    ///
    /// The guest agent constructs its own instance instead (its providers are
    /// agent-lifetime, not process-immortal), and tests inject their own so the
    /// count is isolated per test.
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
    ///
    /// Lets a test assert the retain-on-write / drop-on-finished lifecycle
    /// without reaching into `private` state. Reached via `@testable import`.
    var countForTesting: Int { lock.withLock { live.count } }

    /// Fires after every `retain`/`release` so a test can await the registration
    /// or finish signal instead of polling.
    ///
    /// Driving an `AsyncGate` off this avoids the timing-sensitive
    /// `countForTesting` poll the `ci-test-timings` flakes trace back to. Set once
    /// before the registry is exercised; `releaseAllForTesting` is teardown-only
    /// and deliberately doesn't fire it.
    var onChangeForTesting: (() -> Void)?

    /// Releases every retained provider.
    ///
    /// A test injecting its own registry uses this to tear down the
    /// registry↔provider retain cycle that production breaks via
    /// `pasteboardFinishedWithDataProvider`, so the per-test registry doesn't
    /// outlive the test.
    func releaseAllForTesting() { lock.withLock { live.removeAll() } }
    #endif
}
