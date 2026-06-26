import AppKit
import Foundation
import KernovaProtocol
import Testing

@testable import Kernova

/// Verifies the host "Copy to Mac" provider-retention lifecycle: each written
/// item's lazy data provider is retained in the app-scoped
/// `ClipboardCopyProviderRegistry` (not on the per-window controller) so a later
/// paste is served by a live object even after the window — and its controller —
/// is gone, and the bytes are produced on demand.
///
/// The controller writes to an injected private `NSPasteboard(name:)` rather
/// than `.general`, and to an injected fresh registry, so the test exercises the
/// real write/promise path without touching the developer's clipboard or
/// leaking state across tests.
@Suite("ClipboardContentViewController Copy-to-Mac retention")
@MainActor
struct ClipboardContentViewControllerRetentionTests {
    private func makeViewModel() -> VMLibraryViewModel {
        VMLibraryViewModel(
            storageService: MockVMStorageService(),
            diskImageService: MockDiskImageService(),
            virtualizationService: MockVirtualizationService(),
            installService: MockMacOSInstallService(),
            ipswService: MockIPSWService(),
            usbDeviceService: MockUSBDeviceService()
        )
    }

    private func makeInstance() -> VMInstance {
        let config = VMConfiguration(name: "Clipboard VM", guestOS: .linux, bootMode: .efi)
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(config.id.uuidString, isDirectory: true)
        return VMInstance(configuration: config, bundleURL: bundleURL)
    }

    @Test("copyToMac retains a provider per item in the registry and serves its bytes")
    func retainsProviderAndServesBytes() async throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("KernovaTest-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let registry = ClipboardCopyProviderRegistry()
        // The promise is never finished in-test, so break the registry↔provider
        // cycle by hand (production breaks it on pasteboardFinishedWithDataProvider).
        defer { registry.releaseAllForTesting() }

        let service = FakeClipboardService(content: ClipboardContent(text: "lazy bytes"))
        let instance = makeInstance()
        instance.clipboardService = service
        let vc = ClipboardContentViewController(
            instance: instance, viewModel: makeViewModel(),
            writePasteboard: pasteboard, providerRegistry: registry)

        #expect(registry.countForTesting == 0)

        // Drive the responder-chain copy action (→ copyToMac), which materializes
        // and writes on a @MainActor Task.
        vc.copy(nil)

        // Exactly one inline item → one retained provider once the write lands.
        try await waitUntil { registry.countForTesting == 1 }

        // The retained provider serves the inline bytes on demand — the provider
        // path is in use (an eager `setData` write would create no provider, so
        // the count would be 0) and a destination read returns the bytes.
        let textType = NSPasteboard.PasteboardType(ClipboardContent.utf8TextUTI)
        try await waitUntil { pasteboard.data(forType: textType) == Data("lazy bytes".utf8) }
    }

    @Test("a copied provider outlives the controller (survives window close before paste)")
    func providerOutlivesController() async throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("KernovaTest-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let registry = ClipboardCopyProviderRegistry()
        // The promise is never finished in-test, so break the registry↔provider
        // cycle by hand (production breaks it on pasteboardFinishedWithDataProvider).
        defer { registry.releaseAllForTesting() }

        weak var weakVC: ClipboardContentViewController?
        do {
            let service = FakeClipboardService(content: ClipboardContent(text: "durable bytes"))
            let instance = makeInstance()
            instance.clipboardService = service
            let vc = ClipboardContentViewController(
                instance: instance, viewModel: makeViewModel(),
                writePasteboard: pasteboard, providerRegistry: registry)
            weakVC = vc
            vc.copy(nil)
            // The copy Task uses the controller (weakly), so keep a strong ref
            // until the provider has been retained in the registry.
            try await waitUntil { registry.countForTesting == 1 }
        }

        // The controller (its window, in production) is now torn down…
        try await waitUntil { weakVC == nil }

        // …yet the registry kept the provider alive, so a paste still serves the
        // bytes. The regression this guards against — providers owned by the VC —
        // would vend empty here once the window closed.
        #expect(registry.countForTesting == 1)
        let textType = NSPasteboard.PasteboardType(ClipboardContent.utf8TextUTI)
        try await waitUntil { pasteboard.data(forType: textType) == Data("durable bytes".utf8) }
    }
}

/// Focused tests for the registry's retain/release bookkeeping, independent of
/// the controller and a live pasteboard.
@Suite("ClipboardCopyProviderRegistry")
@MainActor
struct ClipboardCopyProviderRegistryTests {
    private func makeProvider() -> LazyClipboardDataProvider {
        LazyClipboardDataProvider(provide: { _ in nil }, onFinished: { _ in })
    }

    @Test("release drops one provider and leaves the rest")
    func releaseDropsOne() {
        let registry = ClipboardCopyProviderRegistry()
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
        let registry = ClipboardCopyProviderRegistry()
        let provider = LazyClipboardDataProvider(
            provide: { _ in nil },
            onFinished: { registry.release($0) })
        registry.retain([provider])
        #expect(registry.countForTesting == 1)

        // The drop-on-finished wiring the controller relies on, exercised
        // directly (NSPasteboard fires this on the main run loop in production).
        provider.pasteboardFinishedWithDataProvider(NSPasteboard.withUniqueName())
        #expect(registry.countForTesting == 0)
    }
}

/// Minimal in-memory `ClipboardServicing` for driving the controller without a
/// live VM transport.
@MainActor
private final class FakeClipboardService: ClipboardServicing {
    var clipboardContent: ClipboardContent
    var isConnected: Bool = true
    var supportsBinaryRepresentations: Bool = true
    var lastTransferIssue: ClipboardTransferIssue?

    init(content: ClipboardContent) {
        self.clipboardContent = content
    }

    func stop() {}
    func grabIfChanged() {}
    func clearBuffer() { clipboardContent = .empty }
    // materializeForPreview / materializeForCopy use the protocol-extension
    // defaults (no-op / return clipboardContent unchanged).
}
