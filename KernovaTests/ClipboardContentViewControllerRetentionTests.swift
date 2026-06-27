import AppKit
import Foundation
import KernovaKit
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

    /// Fresh per-test "Copy to Mac" harness: a private destination pasteboard, an
    /// isolated provider registry, and an `AsyncGate` already wired to the
    /// registry's retain/release signal so a test awaits the registration event
    /// rather than polling `countForTesting` — the one-shot effect a starved CI
    /// MainActor can miss inside a poll deadline (CLAUDE.md "Async waits in tests").
    ///
    /// The caller still owns teardown (`pasteboard.releaseGlobally()` and
    /// `registry.releaseAllForTesting()` in `defer`), since a `defer` only fires
    /// at the end of the scope that declares it.
    private func makeCopyToMacHarness() -> (
        pasteboard: NSPasteboard, registry: ClipboardCopyProviderRegistry, retained: AsyncGate
    ) {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("KernovaTest-\(UUID().uuidString)"))
        let registry = ClipboardCopyProviderRegistry()
        let retained = AsyncGate()
        registry.onChangeForTesting = { retained.notify() }
        return (pasteboard, registry, retained)
    }

    @Test("copyToMac retains a provider per item in the registry and serves its bytes")
    func retainsProviderAndServesBytes() async throws {
        let (pasteboard, registry, retained) = makeCopyToMacHarness()
        defer { pasteboard.releaseGlobally() }
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
        try await retained.wait { registry.countForTesting == 1 }

        // `retain()` runs immediately after a successful `writeObjects` in the same
        // synchronous step, so once the gate fires the promise is already on the
        // pasteboard and a destination read is served synchronously by the retained
        // provider — the provider path is in use (an eager `setData` write would
        // create no provider, leaving the count 0) and the read returns the bytes.
        let textType = NSPasteboard.PasteboardType(ClipboardContent.utf8TextUTI)
        #expect(pasteboard.data(forType: textType) == Data("lazy bytes".utf8))
    }

    @Test("a copied provider outlives the controller (survives window close before paste)")
    func providerOutlivesController() async throws {
        let (pasteboard, registry, retained) = makeCopyToMacHarness()
        defer { pasteboard.releaseGlobally() }
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
            // The copy Task holds the controller only weakly, so `vc` (alive to the
            // end of this Debug-build `do` scope) is the strong ref that keeps it
            // around until the provider has been retained.
            try await retained.wait { registry.countForTesting == 1 }
        }

        // The gate fired from inside the copy Task's final synchronous step, which
        // then returned and dropped its strong `self` before this continuation
        // resumed; the `do` scope just dropped the last strong ref (`vc`), so the
        // controller (its window, in production) is now deterministically torn down.
        #expect(weakVC == nil)

        // …yet the registry kept the provider alive, so a paste still serves the
        // bytes. The regression this guards against — providers owned by the VC —
        // would vend empty here once the window closed.
        #expect(registry.countForTesting == 1)
        let textType = NSPasteboard.PasteboardType(ClipboardContent.utf8TextUTI)
        #expect(pasteboard.data(forType: textType) == Data("durable bytes".utf8))
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

/// Verifies the editor commit path (#394): per-keystroke work is hash-free and
/// the buffer is committed off-actor on a debounce, while blur/copy/close flush a
/// still-pending edit and an external update cancels a superseded one.
@Suite("ClipboardContentViewController editor commit")
@MainActor
struct ClipboardContentViewControllerEditTests {
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

    private func makeController(
        service: FakeClipboardService, debounce: Duration
    ) -> ClipboardContentViewController {
        let instance = makeInstance()
        instance.clipboardService = service
        return ClipboardContentViewController(
            instance: instance, viewModel: makeViewModel(), editDebounceInterval: debounce)
    }

    @Test("a keystroke burst commits the buffer to the model off-actor after the debounce")
    func debouncedCommitLandsInModel() async throws {
        let service = FakeClipboardService(content: .empty)
        let vc = makeController(service: service, debounce: .milliseconds(1))

        vc.setEditorTextForTesting("hello off-actor")

        try await waitUntil { service.clipboardContent == ClipboardContent(text: "hello off-actor") }
    }

    @Test("flushPendingEdit commits the latest text before the debounce fires")
    func flushCommitsPendingEdit() {
        // A debounce long enough that it never fires during the test, so the only
        // path to the model is the synchronous flush.
        let service = FakeClipboardService(content: .empty)
        let vc = makeController(service: service, debounce: .seconds(60))

        vc.setEditorTextForTesting("typed then copied")
        #expect(service.clipboardContent.isEmpty)  // not yet committed by the debounce

        vc.flushPendingEdit()
        #expect(service.clipboardContent == ClipboardContent(text: "typed then copied"))
    }

    @Test("flushPendingEdit is a no-op with nothing pending")
    func flushWithoutPendingEditIsNoOp() {
        let service = FakeClipboardService(content: ClipboardContent(text: "guest content"))
        let vc = makeController(service: service, debounce: .seconds(60))

        vc.flushPendingEdit()  // no keystroke happened
        #expect(service.clipboardContent == ClipboardContent(text: "guest content"))
    }

    @Test("an external update cancels a pending edit so a later flush can't resurrect stale text")
    func externalUpdateCancelsPendingEdit() {
        let service = FakeClipboardService(content: .empty)
        let vc = makeController(service: service, debounce: .seconds(60))

        // The user types, then a guest update lands and rebuilds the editor before
        // the debounce fires.
        vc.setEditorTextForTesting("stale user edit")
        service.clipboardContent = ClipboardContent(text: "guest content")
        vc.simulateObservationForTesting()  // updateUI rebuild branch cancels the pending edit

        // Blur/close now flushes — and must NOT overwrite the guest content.
        vc.flushPendingEdit()
        #expect(service.clipboardContent == ClipboardContent(text: "guest content"))
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
