import AppKit
import Foundation
import KernovaKit
import Testing
import KernovaTestSupport

@testable import Kernova
@testable import KernovaKit

/// Fresh per-test "Copy to Mac" harness: a private destination pasteboard, an
/// isolated provider registry, and an `AsyncGate` already wired to the
/// registry's retain/release signal so a test awaits the registration event
/// rather than polling `countForTesting` — the one-shot effect a starved CI
/// MainActor can miss inside a poll deadline (docs/TESTING.md "Async waits in tests").
///
/// File-scoped so every suite here shares one definition of the harness.
///
/// The caller still owns teardown (`pasteboard.releaseGlobally()` and
/// `registry.releaseAllForTesting()` in `defer`), since a `defer` only fires
/// at the end of the scope that declares it.
@MainActor
private func makeCopyToMacHarness() -> (
    pasteboard: NSPasteboard, registry: LazyClipboardProviderRegistry, retained: AsyncGate
) {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("KernovaTest-\(UUID().uuidString)"))
    let registry = LazyClipboardProviderRegistry()
    let retained = AsyncGate()
    registry.onChangeForTesting = { retained.notify() }
    return (pasteboard, registry, retained)
}

/// The mock-backed view model every clipboard-window suite drives, on the
/// caller's own `preferences` so selection/order persistence stays isolated.
@MainActor
private func makeClipboardViewModel(preferences: AppPreferences) -> VMLibraryViewModel {
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

/// The VM whose clipboard window is under test.
@MainActor
/// Builds an instance over an isolated defaults suite.
///
/// Ephemeral preferences, not `.shared`: the messages naming the paste ceiling
/// read it live, so an instance on the real domain makes those assertions depend
/// on whatever the developer last picked in Settings.
private func makeClipboardInstance(passthroughEnabled: Bool = false) -> VMInstance {
    var config = VMConfiguration(name: "Clipboard VM", guestOS: .linux, bootMode: .efi)
    config.clipboardPassthroughEnabled = passthroughEnabled
    let bundleURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(config.id.uuidString, isDirectory: true)
    return VMInstance(
        configuration: config, bundleURL: bundleURL,
        preferences: makeEphemeralPreferences(suiteName: "test.kernova.clipboard-vc-instance"))
}

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
@Suite("ClipboardContentViewController Copy-to-Mac retention", .admissionGated)
@MainActor
struct ClipboardContentViewControllerRetentionTests {
    /// Isolated, pre-cleaned preferences for this suite's `VMLibraryViewModel`.
    ///
    /// Selection/order persistence never touches the real `.standard` domain.
    private let preferences = makeEphemeralPreferences(suiteName: "test.kernova.clipboard-retention")

    @Test("copyToMac retains a provider per item in the registry and serves its bytes")
    func retainsProviderAndServesBytes() async throws {
        let (pasteboard, registry, retained) = makeCopyToMacHarness()
        defer { pasteboard.releaseGlobally() }
        // The promise is never finished in-test, so break the registry↔provider
        // cycle by hand (production breaks it on pasteboardFinishedWithDataProvider).
        defer { registry.releaseAllForTesting() }

        let service = FakeClipboardService(content: ClipboardContent(text: "lazy bytes"))
        let instance = makeClipboardInstance()
        instance.clipboardService = service
        let vc = ClipboardContentViewController(
            instance: instance, viewModel: makeClipboardViewModel(preferences: preferences),
            writePasteboard: pasteboard, providerRegistry: registry)

        #expect(registry.countForTesting == 0)

        // Drive the responder-chain copy action (→ copyToMac), which materializes
        // and writes on a @MainActor Task.
        vc.copy(nil)

        // Exactly one inline item → one retained provider once the write lands.
        try await retained.wait { registry.countForTesting == 1 }

        // `retain()` runs immediately after a successful write in the same
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
            let instance = makeClipboardInstance()
            instance.clipboardService = service
            let vc = ClipboardContentViewController(
                instance: instance, viewModel: makeClipboardViewModel(preferences: preferences),
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
        pasteboard.failNextWrite()

        let service = FakeClipboardService(content: ClipboardContent(text: "doomed write"))
        let instance = makeClipboardInstance()
        instance.clipboardService = service
        let vc = ClipboardContentViewController(
            instance: instance, viewModel: makeClipboardViewModel(preferences: preferences),
            writePasteboard: pasteboard, providerRegistry: registry)

        #expect(registry.countForTesting == 0)
        // → copyToMac → finishCopyToMac → prepareForNewContents(with:) then writeItems(→ false).
        vc.copy(nil)
        try await pasteboard.changed.wait { pasteboard.writeAttempts == 1 }

        // retain() runs only after a successful write, so the failed write
        // leaves the registry empty — the providers deallocate with the copy Task's
        // local array, never getting a finish callback (so no rollback is needed).
        #expect(registry.countForTesting == 0)
        // prepareForNewContents ran before the failed write — a latent
        // wipe-on-failure of the real clipboard, tracked as a follow-up and
        // observable via this seam.
        #expect(pasteboard.prepareCount == 1)
        // Marked host-only even though the write went on to fail — the option is
        // applied unconditionally up front, before the write is attempted, so
        // this failure-path write already proves every write is marked (#560).
        #expect(pasteboard.lastPrepareOptions == .currentHostOnly)
    }
}

/// Verifies the editor commit path (#394): per-keystroke work is hash-free and
/// the buffer is committed off-actor on a debounce, while blur/copy/close flush a
/// still-pending edit and an external update cancels a superseded one.
@Suite("ClipboardContentViewController editor commit", .admissionGated)
@MainActor
struct ClipboardContentViewControllerEditTests {
    /// Isolated, pre-cleaned preferences for this suite's `VMLibraryViewModel`.
    ///
    /// Selection/order persistence never touches the real `.standard` domain.
    private let preferences = makeEphemeralPreferences(suiteName: "test.kernova.clipboard-edit")

    private func makeController(
        service: FakeClipboardService, debounce: Duration
    ) -> ClipboardContentViewController {
        let instance = makeClipboardInstance()
        instance.clipboardService = service
        return ClipboardContentViewController(
            instance: instance, viewModel: makeClipboardViewModel(preferences: preferences),
            editDebounceInterval: debounce)
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

        // Blur/close now runs — and must neither overwrite the guest content nor
        // announce the edit that content superseded.
        vc.flushAndAnnounceEdit()
        #expect(service.clipboardContent == ClipboardContent(text: "guest content"))
        #expect(service.grabCallCount == 0)
    }

    @Test("blur doesn't even ask the transport when the user didn't edit the buffer")
    func blurWithoutAnEditAnnouncesNothing() {
        let service = FakeClipboardService(content: .empty)
        let vc = makeController(service: service, debounce: .seconds(60))
        _ = vc.view

        // Written past the editor and left unannounced, as a passthrough forward
        // that reached the buffer but never reached the guest would be.
        service.clipboardContent = ClipboardContent(text: "never announced")

        vc.flushAndAnnounceEdit()
        #expect(service.grabCallCount == 0)

        // Positive control: the same call announces once the user edits, so the
        // assertion above is the edit condition, not a severed hand-off.
        vc.setEditorTextForTesting("typed by the user")
        vc.flushAndAnnounceEdit()
        #expect(service.announcedCount == 1)
        #expect(service.clipboardContent == ClipboardContent(text: "typed by the user"))
    }

    /// A disconnected transport leaves its dedup latch unadvanced, so the edit is
    /// still owed — no window-side connection check required.
    @Test("an edit typed while disconnected is announced once the transport connects")
    func blurKeepsAnEditOwedWhileDisconnected() {
        let service = FakeClipboardService(content: .empty)
        service.isConnected = false
        let vc = makeController(service: service, debounce: .seconds(60))
        _ = vc.view

        vc.setEditorTextForTesting("typed before the agent connected")
        vc.flushAndAnnounceEdit()
        #expect(service.grabCallCount == 1)  // asked…
        #expect(service.announcedCount == 0)  // …but nothing went out
        // The text still reached the buffer — only the announcement is owed.
        #expect(service.clipboardContent == ClipboardContent(text: "typed before the agent connected"))

        service.isConnected = true
        vc.flushAndAnnounceEdit()
        #expect(service.announcedCount == 1)
    }

    @Test("blur publishes a typed edit once however many times focus bounces")
    func blurAnnouncesEachEditOnce() {
        let service = FakeClipboardService(content: .empty)
        let vc = makeController(service: service, debounce: .seconds(60))
        _ = vc.view

        vc.setEditorTextForTesting("first edit")
        vc.flushAndAnnounceEdit()
        #expect(service.announcedCount == 1)

        // Focus bounces back and forth with no further typing.
        vc.flushAndAnnounceEdit()
        vc.flushAndAnnounceEdit()
        #expect(service.grabCallCount == 3)  // asked every time…
        #expect(service.announcedCount == 1)  // …published once

        vc.setEditorTextForTesting("second edit")
        vc.flushAndAnnounceEdit()
        #expect(service.announcedCount == 2)
    }

    /// `hasPendingEdit` spans only the debounce, so authorship has to be tracked
    /// separately or typed text crosses only when the user blurs within it.
    @Test("blur announces an edit the debounce already committed")
    func blurAnnouncesADebouncedEdit() async throws {
        let service = FakeClipboardService(content: .empty)
        let committed = AsyncGate()
        service.onChangeForTesting = { committed.notify() }
        let vc = makeController(service: service, debounce: .milliseconds(1))
        _ = vc.view

        vc.setEditorTextForTesting("committed off-actor")
        try await committed.wait {
            service.clipboardContent == ClipboardContent(text: "committed off-actor")
        }

        vc.flushAndAnnounceEdit()  // nothing pending — the debounce already landed
        #expect(service.announcedCount == 1)
    }

    /// The supersession case after the debounce landed, where only the authorship
    /// flag is left to drop the edit.
    @Test("an external update also drops a committed, still-unsent edit")
    func externalUpdateDropsCommittedUnannouncedEdit() async throws {
        let service = FakeClipboardService(content: .empty)
        let committed = AsyncGate()
        service.onChangeForTesting = { committed.notify() }
        let vc = makeController(service: service, debounce: .milliseconds(1))
        _ = vc.view

        vc.setEditorTextForTesting("user edit")
        try await committed.wait {
            service.clipboardContent == ClipboardContent(text: "user edit")
        }

        service.clipboardContent = ClipboardContent(text: "guest content")
        vc.simulateObservationForTesting()

        vc.flushAndAnnounceEdit()
        #expect(service.grabCallCount == 0)
    }
}

/// Verifies the command bar's passthrough-driven visibility (#599): the manual
/// Paste from Mac / Copy to Mac / Clear actions — the command bar and their
/// responder-chain `paste:`/`copy:` equivalents — are withdrawn while automatic
/// passthrough is on, both at window-open time and live as the toggle changes,
/// and restored when it's turned back off.
@Suite("ClipboardContentViewController passthrough chrome", .admissionGated)
@MainActor
struct ClipboardContentViewControllerPassthroughChromeTests {
    /// Isolated, pre-cleaned preferences for this suite's `VMLibraryViewModel`.
    ///
    /// Selection/order persistence never touches the real `.standard` domain.
    private let preferences = makeEphemeralPreferences(suiteName: "test.kernova.clipboard-passthrough-chrome")

    private func makeController(instance: VMInstance) -> ClipboardContentViewController {
        ClipboardContentViewController(instance: instance, viewModel: makeClipboardViewModel(preferences: preferences))
    }

    @Test("passthrough off (the default) shows the command bar")
    func passthroughOffShowsCommandBar() {
        let vc = makeController(instance: makeClipboardInstance())
        _ = vc.view  // forces loadView + viewDidLoad → updateUI

        #expect(vc.isCommandBarHiddenForTesting == false)
    }

    @Test("passthrough already on when the window opens hides the command bar")
    func passthroughOnAtOpenHidesCommandBar() {
        let vc = makeController(instance: makeClipboardInstance(passthroughEnabled: true))
        _ = vc.view  // forces loadView + viewDidLoad → updateUI

        #expect(vc.isCommandBarHiddenForTesting == true)
    }

    @Test("toggling passthrough live shows/hides the command bar without reopening the window")
    func liveToggleUpdatesCommandBarVisibility() async throws {
        let instance = makeClipboardInstance()
        let vc = makeController(instance: instance)
        _ = vc.view  // forces loadView + viewDidLoad → observeServiceChanges
        #expect(vc.isCommandBarHiddenForTesting == false)

        // Driven through the production `ObservationLoop`, not
        // `simulateObservationForTesting()`: a hand-called `updateUI()` would
        // still pass if `observeServiceChanges`'s track closure stopped reading
        // `clipboardPassthroughEnabled`, which is exactly the regression that
        // would freeze the window's chrome until it is reopened.
        //
        // RATIONALE: genuine no-signal predicate (docs/TESTING.md "Async waits in
        // tests") — the observed effect is `commandBar.isHidden`, a plain AppKit
        // property with no Observable or `AsyncGate` signal to arm against; the
        // loop's internal re-arm hop is not test-facing.
        instance.configuration.clipboardPassthroughEnabled = true
        try await waitUntil { vc.isCommandBarHiddenForTesting }

        instance.configuration.clipboardPassthroughEnabled = false
        try await waitUntil { !vc.isCommandBarHiddenForTesting }
    }

    @Test("the hidden command bar actually lays out at zero height")
    func hiddenCommandBarCollapsesToZeroHeight() {
        let vc = makeController(instance: makeClipboardInstance(passthroughEnabled: true))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 360),
            styleMask: [.titled], backing: .buffered, defer: true)
        window.contentViewController = vc
        vc.view.layoutSubtreeIfNeeded()

        #expect(vc.isCommandBarHiddenForTesting == true)
        #expect(vc.commandBarLaidOutHeightForTesting == 0)
    }

    @Test("paste:/copy: are gated while passthrough is on and restored when it's off")
    func responderChainGatedByPassthrough() {
        let service = FakeClipboardService(content: ClipboardContent(text: "some content"))
        let instance = makeClipboardInstance(passthroughEnabled: true)
        instance.clipboardService = service
        let vc = makeController(instance: instance)
        _ = vc.view

        let pasteItem = NSMenuItem(
            title: "Paste", action: #selector(ClipboardContentViewController.paste(_:)), keyEquivalent: "")
        let copyItem = NSMenuItem(
            title: "Copy", action: #selector(ClipboardContentViewController.copy(_:)), keyEquivalent: "")

        #expect(vc.validateUserInterfaceItem(pasteItem) == false)
        #expect(vc.validateUserInterfaceItem(copyItem) == false)

        instance.configuration.clipboardPassthroughEnabled = false
        vc.simulateObservationForTesting()

        #expect(vc.validateUserInterfaceItem(pasteItem) == true)
        #expect(vc.validateUserInterfaceItem(copyItem) == true)
    }

    /// Drives the actions themselves, not just their validation.
    ///
    /// Validation is advisory — it greys a menu item out, but a direct
    /// `sendAction` (scripting, a service, any non-validating sender) reaches the
    /// action anyway, so the gate is asserted where it is enforced rather than
    /// where it is merely displayed.
    @Test("paste: performs no intake while passthrough is on")
    func pasteActionIsGatedByPassthrough() {
        let hostPasteboard = NSPasteboard(name: NSPasteboard.Name("KernovaTest-\(UUID().uuidString)"))
        defer { hostPasteboard.releaseGlobally() }
        hostPasteboard.clearContents()
        hostPasteboard.setString("from the Mac", forType: .string)

        let service = FakeClipboardService(content: .empty)
        let instance = makeClipboardInstance(passthroughEnabled: true)
        instance.clipboardService = service
        let vc = ClipboardContentViewController(
            instance: instance, viewModel: makeClipboardViewModel(preferences: preferences),
            readPasteboard: hostPasteboard)
        _ = vc.view

        vc.paste(nil)
        #expect(service.clipboardContent.isEmpty)

        // Positive control: the same action does take the text in once
        // passthrough is off, so the assertion above is the gate, not a broken
        // intake path.
        instance.configuration.clipboardPassthroughEnabled = false
        vc.paste(nil)
        #expect(service.clipboardContent == ClipboardContent(text: "from the Mac"))
    }

    @Test("copy: publishes nothing while passthrough is on")
    func copyActionIsGatedByPassthrough() async throws {
        let (pasteboard, registry, retained) = makeCopyToMacHarness()
        defer { pasteboard.releaseGlobally() }
        // The promise is never finished in-test, so break the registry↔provider
        // cycle by hand (production breaks it on pasteboardFinishedWithDataProvider).
        defer { registry.releaseAllForTesting() }

        let service = FakeClipboardService(content: ClipboardContent(text: "buffer bytes"))
        let instance = makeClipboardInstance(passthroughEnabled: true)
        instance.clipboardService = service
        let vc = ClipboardContentViewController(
            instance: instance, viewModel: makeClipboardViewModel(preferences: preferences),
            writePasteboard: pasteboard, providerRegistry: registry)

        vc.copy(nil)

        // `copyToMac` sets `isCopyingToMac` synchronously, before the publish
        // Task it launches — still false ⇒ the action returned at the gate.
        //
        // This, not the registry count or the served bytes, is the assertion
        // that separates the two paths: an ungated first copy would leave
        // `isCopyingToMac` set, whose re-entrancy guard then suppresses the
        // control copy below — so exactly one provider lands either way, and the
        // lazy provider reads `clipboardContent` at *paste* time, so the bytes
        // match either way too.
        #expect(vc.isCopyingToMacForTesting == false)
        #expect(registry.countForTesting == 0)

        // Positive control: ungated, the same action does publish.
        instance.configuration.clipboardPassthroughEnabled = false
        vc.copy(nil)
        #expect(vc.isCopyingToMacForTesting == true)

        try await retained.wait { registry.countForTesting == 1 }
        // Asserted before the read below: serving the promise finishes the
        // provider, which releases it from the registry and takes the count
        // back to 0.
        #expect(registry.countForTesting == 1)

        let textType = NSPasteboard.PasteboardType(ClipboardContent.utf8TextUTI)
        #expect(pasteboard.data(forType: textType) == Data("buffer bytes".utf8))
    }
}

/// One-shot latch the copy-outcome wait's predicate reads, since the render is
/// a synchronous step of the publish Task rather than observable state.
@MainActor
private final class CopyOutcomeLatch {
    var didRender = false
}

/// Verifies each terminal "Copy to Mac" outcome, and each transfer issue,
/// reaches the indicator as its own sentence.
///
/// The refused cases are the point: a refusal the user can't read is the same
/// as no refusal at all, and a mixed offer that drops its files must not lead
/// with an unqualified success.
@Suite("ClipboardContentViewController copy-outcome messages", .admissionGated)
@MainActor
struct ClipboardContentViewControllerCopyOutcomeTests {
    /// Isolated, pre-cleaned preferences for this suite's `VMLibraryViewModel`.
    ///
    /// Selection/order persistence never touches the real `.standard` domain.
    private let preferences = makeEphemeralPreferences(
        suiteName: "test.kernova.clipboard-copy-outcome")

    /// Runs one "Copy to Mac" to completion and returns what it left in the
    /// indicator, waiting on the controller's own render event.
    private func copyMessage(
        copyItems: [CopyToMacItem]? = nil, failWrite: Bool = false
    ) async throws -> String {
        let registry = LazyClipboardProviderRegistry()
        defer { registry.releaseAllForTesting() }
        let pasteboard = FakeWritePasteboard()
        if failWrite { pasteboard.failNextWrite() }

        let service = FakeClipboardService(content: ClipboardContent(text: "buffer bytes"))
        service.copyItems = copyItems
        let instance = makeClipboardInstance()
        instance.clipboardService = service
        let vc = ClipboardContentViewController(
            instance: instance, viewModel: makeClipboardViewModel(preferences: preferences),
            writePasteboard: pasteboard, providerRegistry: registry)

        let rendered = AsyncGate()
        let latch = CopyOutcomeLatch()
        vc.onCopyOutcomeForTesting = {
            latch.didRender = true
            rendered.notify()
        }

        vc.copy(nil)
        try await rendered.wait { latch.didRender }
        return vc.indicatorTextForTesting
    }

    @Test("a clean copy confirms the write")
    func writtenConfirmsTheCopy() async throws {
        #expect(try await copyMessage() == "Copied to Mac clipboard")
    }

    @Test("a write that drops the over-cap files names the cap, not a plain success")
    func writtenOverBudgetNamesTheCap() async throws {
        let inline = ClipboardContent.Representation(
            uti: ClipboardContent.utf8TextUTI, data: Data("note".utf8))
        let message = try await copyMessage(
            copyItems: [.resolved(inline), .droppedFile(.overPasteBudget)])
        // Built from the cap, not typed: retuning the cap moves this sentence.
        #expect(
            message
                == "Copied without the files — over the \(ClipboardPasteLimit.displayLimit(ClipboardPasteLimit.defaultBytes)) clipboard transfer limit"
        )
    }

    @Test("an all-dropped over-cap copy reports the refusal")
    func nothingServedOverBudgetReportsTheRefusal() async throws {
        let message = try await copyMessage(copyItems: [.droppedFile(.overPasteBudget)])
        #expect(
            message
                == ClipboardTransferWording.overCopyBudgetMessage(
                    limitBytes: ClipboardPasteLimit.defaultBytes))
    }

    @Test("nothing to serve and nothing dropped reports a fetch failure")
    func nothingServedWithoutReasonsReportsFetchFailure() async throws {
        #expect(try await copyMessage(copyItems: []) == "Couldn't fetch the clipboard content to copy")
    }

    @Test("a payload that stages nothing reports a preparation failure")
    func stagingFailureReportsPreparationFailure() async throws {
        // A file payload whose bytes were never pulled stages no file, so the
        // publish plans an item and ends up with no pasteboard spec.
        let unstageable = ClipboardContent.Representation(
            uti: "public.data", source: .pendingRemote(byteCount: 10), filename: "big.bin")
        let message = try await copyMessage(copyItems: [.resolved(unstageable)])
        #expect(message == "Couldn't prepare the clipboard content to copy")
    }

    @Test("a failed pasteboard write reports it")
    func writeFailureReportsIt() async throws {
        #expect(try await copyMessage(failWrite: true) == "Couldn't write to the Mac clipboard")
    }

    /// Stands a refusal on `instance`'s transfer report the way a producer does.
    private func report(
        _ failure: ClipboardTransferFailure, gesture: ClipboardTransferGesture,
        for instance: VMInstance
    ) {
        instance.clipboardTransfers.finish(
            ClipboardTransferFinish(
                gesture: gesture, outcome: .failed(failure), peerName: instance.name))
    }

    @Test("every error code the guest sends renders its own message")
    func peerReportedCodesRenderTheirOwnMessage() {
        let service = FakeClipboardService(content: ClipboardContent(text: "buffer bytes"))
        let instance = makeClipboardInstance()
        instance.clipboardService = service
        let vc = ClipboardContentViewController(
            instance: instance, viewModel: makeClipboardViewModel(preferences: preferences))

        let expected: [(ClipboardTransferFailure, String)] = [
            (
                .tooLarge(limitBytes: ClipboardPasteLimit.defaultBytes),
                "Too large to paste into the guest — over the \(ClipboardPasteLimit.displayLimit(ClipboardPasteLimit.defaultBytes)) clipboard transfer limit"
            ),
            (
                .peerReported(.pasteDiskFull),
                "The guest ran out of disk space receiving the clipboard file"
            ),
            (.peerReported(.pasteTimeout), "The clipboard transfer to the guest timed out"),
            (.peerReported(.pasteFailed), "Clipboard transfer failed on the guest side"),
        ]
        for (failure, message) in expected {
            // A fresh `date` is what re-fires the transient for a repeat refusal.
            report(failure, gesture: .peerPaste, for: instance)
            vc.simulateObservationForTesting()
            #expect(vc.indicatorTextForTesting == message)
        }
    }

    @Test("an outcome produced on this side shows the message it carries")
    func localFailureShowsItsOwnMessage() {
        let service = FakeClipboardService(content: ClipboardContent(text: "buffer bytes"))
        let instance = makeClipboardInstance()
        instance.clipboardService = service
        let vc = ClipboardContentViewController(
            instance: instance, viewModel: makeClipboardViewModel(preferences: preferences))

        report(
            .tooLarge(limitBytes: ClipboardPasteLimit.defaultBytes), gesture: .copy,
            for: instance)
        vc.simulateObservationForTesting()
        #expect(
            vc.indicatorTextForTesting
                == ClipboardTransferWording.overCopyBudgetMessage(
                    limitBytes: ClipboardPasteLimit.defaultBytes))
    }

    @Test("a refusal from the superseded service the reconnect replaced still renders")
    func supersededServiceRefusalStillRenders() {
        let instance = makeClipboardInstance()
        let superseded = FakeClipboardService(content: ClipboardContent(text: "buffer bytes"))
        // A real transport reports to the VM's reporter, which outlives it.
        superseded.reporter = instance.clipboardTransfers
        instance.clipboardService = superseded
        let vc = ClipboardContentViewController(
            instance: instance, viewModel: makeClipboardViewModel(preferences: preferences))
        // The clipboard channel reconnects: the window now shows a service that
        // knows nothing of the promise the old one left on the pasteboard.
        instance.clipboardService = FakeClipboardService(content: .empty)

        // That promise fires on a paste and fails against the dead channel.
        superseded.reportRefusal(.timedOut, gesture: .paste)
        vc.simulateObservationForTesting()

        #expect(
            vc.indicatorTextForTesting
                == "The transfer from the guest timed out, so the paste didn't finish.")
    }

    @Test("the window's bar renders the VM's running readout, whichever producer opened it")
    func transferBarRendersTheVMReport() throws {
        let instance = makeClipboardInstance()
        instance.clipboardService = FakeClipboardService(content: .empty)
        let vc = ClipboardContentViewController(
            instance: instance, viewModel: makeClipboardViewModel(preferences: preferences))
        // A drop is the other producer on this VM's report; the window's bar
        // shows it too.
        let operation = ClipboardTransferOperation(
            gesture: .drop, direction: .outbound, peerName: instance.name, revealDelay: 0,
            now: { 0 }, schedule: { _, _ in }, reporter: instance.clipboardTransfers)
        instance.clipboardTransfers.publish(
            from: operation,
            .running(
                ClipboardProgressSnapshot(
                    direction: .outbound, peerName: instance.name, currentItemName: nil,
                    filesCompleted: 0, fileCount: 1, bytesTransferred: 25, totalBytes: 100,
                    bytesPerSecond: nil, secondsRemaining: nil, gesture: .drop,
                    elapsedSeconds: 1), since: Date()))
        vc.simulateObservationForTesting()
        #expect(vc.transferBarFractionForTesting == 0.25)

        instance.clipboardTransfers.retire(operation)
        vc.simulateObservationForTesting()
        #expect(vc.transferBarFractionForTesting == nil)
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

    /// The VM's transfer report, as a real transport holds it — so a test can
    /// raise a refusal from a service the window is no longer showing.
    var reporter: ClipboardTransferReporter?

    /// Reports a refusal the way a real transport does.
    func reportRefusal(_ failure: ClipboardTransferFailure, gesture: ClipboardTransferGesture) {
        reporter?.finish(
            ClipboardTransferFinish(
                gesture: gesture, outcome: .failed(failure), peerName: "Clipboard VM"))
    }

    /// What `materializeForCopy` hands the publisher, or `nil` to resolve the
    /// buffer's own representations the way the protocol default does.
    ///
    /// Drives the publisher to each terminal outcome without a live transport.
    var copyItems: [CopyToMacItem]?

    /// Times the controller *asked* for an announcement, so a test can assert the
    /// outbound choke-point was (or wasn't) reached without a live transport.
    private(set) var grabCallCount = 0

    /// Times one actually went out — asks minus what the guards below swallow.
    private(set) var announcedCount = 0
    private var lastAnnouncedDigest: Data?

    init(content: ClipboardContent) {
        self.clipboardContent = content
    }

    func stop() {}

    /// Mirrors both real send guards: `isConnected`, and a latch advanced only by
    /// a successful send (`VsockClipboardService.lastGrabbedDigest` /
    /// `SpiceClipboardService.lastGrabbedText`).
    func grabIfChanged() {
        grabCallCount += 1
        guard isConnected else { return }
        guard clipboardContent.digest != lastAnnouncedDigest else { return }
        lastAnnouncedDigest = clipboardContent.digest
        announcedCount += 1
    }
    func clearBuffer() { clipboardContent = .empty }
    // materializeForPreview uses the protocol-extension default (no-op).

    func materializeForCopy() -> [CopyToMacItem] {
        copyItems ?? clipboardContent.representations.map { .resolved($0) }
    }
}
