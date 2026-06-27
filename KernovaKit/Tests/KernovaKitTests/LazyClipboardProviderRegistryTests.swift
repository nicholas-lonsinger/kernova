import AppKit
import Foundation
import Testing

@testable import KernovaKit

/// Focused tests for the shared registry's retain/release bookkeeping,
/// independent of any controller or a live pasteboard.
@Suite("LazyClipboardProviderRegistry")
@MainActor
struct LazyClipboardProviderRegistryTests {
    private func makeProvider() -> LazyClipboardDataProvider {
        LazyClipboardDataProvider(provide: { _ in nil }, onFinished: { _ in })
    }

    @Test("release drops one provider and leaves the rest")
    func releaseDropsOne() {
        let registry = LazyClipboardProviderRegistry()
        let a = makeProvider()
        let b = makeProvider()
        registry.retain([a, b])
        #expect(registry.countForTesting == 2)

        registry.release(a)
        #expect(registry.countForTesting == 1)
        registry.release(b)
        #expect(registry.countForTesting == 0)
    }

    @Test("a provider's pasteboardFinishedWithDataProvider releases it from the registry")
    func finishedReleasesFromRegistry() {
        let registry = LazyClipboardProviderRegistry()
        let provider = LazyClipboardDataProvider(
            provide: { _ in nil },
            onFinished: { registry.release($0) })
        registry.retain([provider])
        #expect(registry.countForTesting == 1)

        // The drop-on-finished wiring both sides rely on, exercised directly
        // (NSPasteboard fires this on the main run loop in production).
        provider.pasteboardFinishedWithDataProvider(NSPasteboard.withUniqueName())
        #expect(registry.countForTesting == 0)
    }
}
