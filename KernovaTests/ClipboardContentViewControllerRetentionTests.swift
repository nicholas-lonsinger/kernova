import AppKit
import Foundation
import Testing
import KernovaTestSupport

@testable import Kernova
@testable import KernovaKit

/// Verifies the host "Copy to Mac" provider-retention lifecycle: each written
/// item's lazy data provider is retained in the app-scoped
/// `LazyClipboardProviderRegistry` (not on the per-window controller) so a later
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
    /// Isolated, pre-cleaned preferences for this suite's `VMLibraryViewModel`.
    ///
    /// Selection/order persistence never touches the real `.standard` domain.
    private let preferences = makeEphemeralPreferences(suiteName: "test.kernova.clipboard-retention")

    private func makeViewModel() -> VMLibraryViewModel {
        VMLibraryViewModel(
            storageService: MockVMStorageService(),
            diskImageService: MockDiskImageService(),
            virtualizationService: MockVirtualizationService(),
            installService: MockMacOSInstallService(),
            ipswService: MockIPSWService(),
            usbDeviceService: MockUSBDeviceService(),
            preferences: preferences
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
    /// MainActor can miss inside a poll deadline (docs/TESTING.md "Async waits in tests").
    ///
    /// The caller still owns teardown (`pasteboard.releaseGlobally()` and
    /// `registry.releaseAllForTesting()` in `defer`), since a `defer` only fires
    /// at the end of the scope that declares it.
    private func makeCopyToMacHarness() -> (
        pasteboard: NSPasteboard, registry: LazyClipboardProviderRegistry, retained: AsyncGate
    ) {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("KernovaTest-\(UUID().uuidString)"))
        let registry = LazyClipboardProviderRegistry()
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

    @Test("a forced pasteboard write failure retains no provider (#405)")
    func writeFailureRetainsNothing() async throws {
        let registry = LazyClipboardProviderRegistry()
        defer { registry.releaseAllForTesting() }
        // The concrete NSPasteboard can't be made to fail; the write-only seam can.
        let pasteboard = FakeWritePasteboard()
        pasteboard.failNextWrite = true
        let wrote = AsyncGate()
        pasteboard.onWrite = { wrote.notify() }

        let service = FakeClipboardService(content: ClipboardContent(text: "doomed write"))
        let instance = makeInstance()
        instance.clipboardService = service
        let vc = ClipboardContentViewController(
            instance: instance, viewModel: makeViewModel(),
            writePasteboard: pasteboard, providerRegistry: registry)

        #expect(registry.countForTesting == 0)
        // → copyToMac → finishCopyToMac → prepareForNewContents(with:) then writeObjects(→ false).
        vc.copy(nil)
        try await wrote.wait { pasteboard.writeAttempts == 1 }

        // retain() runs only after a successful writeObjects, so the failed write
        // leaves the registry empty — the providers deallocate with the copy Task's
        // local array, never getting a finish callback (so no rollback is needed).
        #expect(registry.countForTesting == 0)
        // prepareForNewContents ran before the failed write — a latent
        // wipe-on-failure of the real clipboard, tracked as a follow-up and
        // observable via this seam.
        #expect(pasteboard.prepareCount == 1)
        // Marked host-only even though the write went on to fail — the option is
        // applied unconditionally up front, before writeObjects is attempted, so
        // this failure-path write already proves every write is marked (#560).
        #expect(pasteboard.lastPrepareOptions == .currentHostOnly)
    }
}

/// Verifies the editor commit path (#394): per-keystroke work is hash-free and
/// the buffer is committed off-actor on a debounce, while blur/copy/close flush a
/// still-pending edit and an external update cancels a superseded one.
@Suite("ClipboardContentViewController editor commit")
@MainActor
struct ClipboardContentViewControllerEditTests {
    /// Isolated, pre-cleaned preferences for this suite's `VMLibraryViewModel`.
    ///
    /// Selection/order persistence never touches the real `.standard` domain.
    private let preferences = makeEphemeralPreferences(suiteName: "test.kernova.clipboard-edit")

    private func makeViewModel() -> VMLibraryViewModel {
        VMLibraryViewModel(
            storageService: MockVMStorageService(),
            diskImageService: MockDiskImageService(),
            virtualizationService: MockVirtualizationService(),
            installService: MockMacOSInstallService(),
            ipswService: MockIPSWService(),
            usbDeviceService: MockUSBDeviceService(),
            preferences: preferences
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
        let committed = AsyncGate()
        service.onChangeForTesting = { committed.notify() }
        let vc = makeController(service: service, debounce: .milliseconds(1))

        vc.setEditorTextForTesting("hello off-actor")

        try await committed.wait { service.clipboardContent == ClipboardContent(text: "hello off-actor") }
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
    var clipboardContent: ClipboardContent {
        didSet { onChangeForTesting?() }
    }

    /// Fires after each post-init `clipboardContent` write.
    ///
    /// Lets a test `AsyncGate` wake on the controller's debounced off-actor commit
    /// instead of polling.
    var onChangeForTesting: (() -> Void)?

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

/// A `HostWritePasteboard` whose `writeObjects` can be forced to fail, so the
/// host "Copy to Mac" write-failure path is exercisable — the concrete
/// `NSPasteboard` is a class cluster that can't be made to fail.
///
/// Not `Sendable`: single-threaded test use driven on the main actor. `onWrite`
/// fires inside `writeObjects` so a test can await the write attempt event-driven
/// rather than polling.
private final class FakeWritePasteboard: HostWritePasteboard {
    private(set) var prepareCount = 0
    private(set) var lastPrepareOptions: NSPasteboard.ContentsOptions?
    private(set) var writeAttempts = 0
    var failNextWrite = false
    var onWrite: (() -> Void)?

    /// Bumped on every successful write so it mirrors `NSPasteboard.changeCount`.
    private(set) var changeCount = 0

    @discardableResult func prepareForNewContents(with options: NSPasteboard.ContentsOptions) -> Int {
        prepareCount += 1
        lastPrepareOptions = options
        return prepareCount
    }

    func writeObjects(_ objects: [any NSPasteboardWriting]) -> Bool {
        writeAttempts += 1
        let shouldFail = failNextWrite
        failNextWrite = false
        if !shouldFail { changeCount += 1 }
        onWrite?()
        return !shouldFail
    }
}
