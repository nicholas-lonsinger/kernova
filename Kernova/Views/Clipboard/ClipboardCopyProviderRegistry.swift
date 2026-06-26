import AppKit
import KernovaKit
import os

/// Process-lifetime owner of the live "Copy to Mac" pasteboard data providers.
///
/// A promised pasteboard item outlives the clipboard window that wrote it: after
/// a "Copy to Mac" the user can close the window — or the VM can stop, which
/// auto-closes it — and still paste the copied content later. `NSPasteboard`
/// does **not** retain a data provider; it requires the owner keep the provider
/// alive while the item's data is still promised. The per-window
/// `ClipboardContentViewController` is far shorter-lived than that promise, so
/// the providers are held here instead — the host analog of the guest agent's
/// process-lifetime `VsockGuestClipboardAgent.liveProviders`. Holding them on the
/// VC would drop them on window close and make a subsequent paste vend empty.
///
/// Providers are retained only after a successful write (so a failed or no-op
/// write needs no rollback — an unwritten provider never gets a finish callback
/// and deallocates with the caller's local array) and released when the
/// pasteboard reports the provider is finished (`pasteboardFinishedWithDataProvider`,
/// routed here via the provider's `onFinished`). The set is never proactively
/// cleared, since a destination may still read a prior copy's promise; the staged
/// file generations (`ClipboardFileStaging.maxGenerations`) cover that window for
/// file payloads.
@MainActor
final class ClipboardCopyProviderRegistry {
    /// Shared registry used in production — one per process, matching the single
    /// `NSPasteboard.general` every "Copy to Mac" targets.
    ///
    /// Tests inject their own instance so the count is isolated per test.
    static let shared = ClipboardCopyProviderRegistry()

    private static let logger = Logger(subsystem: "app.kernova", category: "ClipboardCopyProvider")

    private var live: Set<LazyClipboardDataProvider> = []

    /// Retains `providers` for the lifetime of their pasteboard promise — until
    /// each is individually released when the pasteboard finishes with it.
    func retain(_ providers: [LazyClipboardDataProvider]) {
        live.formUnion(providers)
        Self.logger.debug(
            "Retained \(providers.count, privacy: .public) Copy-to-Mac provider(s) (live: \(self.live.count, privacy: .public))"
        )
    }

    /// Drops the strong reference to a single provider the pasteboard is done
    /// with.
    func release(_ provider: LazyClipboardDataProvider) {
        live.remove(provider)
        Self.logger.debug(
            "Released a finished Copy-to-Mac provider (live: \(self.live.count, privacy: .public))")
    }

    #if DEBUG
    /// Count of providers currently retained for an outstanding "Copy to Mac"
    /// promise.
    ///
    /// Lets a test assert the retain-on-write / drop-on-finished lifecycle
    /// without reaching into `private` state.
    var countForTesting: Int { live.count }

    /// Releases every retained provider.
    ///
    /// A test injecting its own registry uses this to tear down the
    /// registry↔provider retain cycle that production breaks via
    /// `pasteboardFinishedWithDataProvider`, so the per-test registry doesn't
    /// outlive the test.
    func releaseAllForTesting() { live.removeAll() }
    #endif
}
