import AppKit
import KernovaTestSupport
import Testing

@testable import Kernova

/// Covers `AppWindowRegistry.hasTrackedUserWindow(countingMiniaturized:)` — the
/// deterministic half of the window-presence answer the activation-policy
/// reconcile and the reopen leg both read — the clipboard window's
/// close-driven deregistration, and the `WindowResidencyHosting` call a
/// presentation owes.
///
/// Only the tracked windows are exercised for presence: the `NSApp.windows` scan
/// `hasUserWindow(countingMiniaturized:)` layers on top also sees the windows of
/// every test running alongside this one in the shared test host, so it has no
/// deterministic answer here.
@Suite("AppWindowRegistry presence", .serialized, .admissionGated, .scopedWindows)
@MainActor
struct AppWindowRegistryPresenceTests {
    private let preferences = makeTestPreferences()
    private let autosave = WindowAutosaveScope.unsaved()

    /// Records the residency calls the registry makes, standing in for the
    /// controller that answers them in the resident app.
    private final class StubResidencyHost: WindowResidencyHosting {
        var prepareCount = 0
        var syncCount = 0
        var guiPosture = GUIPosture.foreground

        func prepareToPresentWindow() { prepareCount += 1 }
        func syncActivationPolicy() { syncCount += 1 }
    }

    private func makeRegistry() -> AppWindowRegistry {
        let viewModel = makeLibraryViewModel(preferences: preferences)
        return AppWindowRegistry(
            viewModel: viewModel,
            displayPlacement: VMDisplayPlacementController(viewModel: viewModel, autosaveScope: autosave),
            autosaveScope: autosave)
    }

    /// A VM the clipboard window opens for: sharing on, and a live session, which
    /// is what `accepts(.showClipboard, on:)` asks for.
    private func makeClipboardEligibleInstance() -> VMInstance {
        VMInstanceFixture.make(name: "Clipboard VM", phase: .running(sessionID: UUID())) {
            $0.clipboardSharingEnabled = true
        }
    }

    @Test("A registry that has shown nothing tracks no on-screen window")
    func nothingShown() {
        let registry = makeRegistry()

        #expect(!registry.hasTrackedUserWindow(countingMiniaturized: true))
        #expect(!registry.hasTrackedUserWindow(countingMiniaturized: false))
    }

    @Test("The library window counts, however miniaturized windows are treated")
    func libraryShown() throws {
        let registry = makeRegistry()
        registry.showLibrary(bringToFront: true)
        adoptAppWindow(try #require(registry.libraryWindow))

        #expect(registry.hasTrackedUserWindow(countingMiniaturized: true))
        #expect(registry.hasTrackedUserWindow(countingMiniaturized: false))
    }

    @Test("A miniaturized library window counts only when miniaturized windows do")
    func libraryMiniaturized() async throws {
        let registry = makeRegistry()
        registry.showLibrary(bringToFront: true)
        let window = try #require(registry.libraryWindow)
        adoptAppWindow(window)

        // AppKit reports the miniaturize a runloop turn later — the window is
        // still `isVisible` when `miniaturize(_:)` returns — so the wait is
        // driven by the notification that reports it.
        let gate = AsyncGate()
        let observer = NotificationCenter.default.addObserver(
            forName: NSWindow.didMiniaturizeNotification, object: window, queue: .main
        ) { _ in gate.notify() }
        defer { NotificationCenter.default.removeObserver(observer) }
        window.miniaturize(nil)
        try await gate.wait { window.isMiniaturized && !window.isVisible }

        #expect(registry.hasTrackedUserWindow(countingMiniaturized: true))
        #expect(!registry.hasTrackedUserWindow(countingMiniaturized: false))
    }

    @Test("The Settings window counts on its own")
    func settingsShown() throws {
        let registry = makeRegistry()
        registry.showSettings(nil)
        adoptAppWindow(try #require(registry.settingsWindow))

        #expect(registry.hasTrackedUserWindow(countingMiniaturized: true))
    }

    @Test("Closing a clipboard window deregisters it")
    func clipboardWindowCloseDeregisters() throws {
        let registry = makeRegistry()
        let instance = makeClipboardEligibleInstance()
        registry.showClipboard(for: instance)
        let window = try #require(registry.clipboardWindow(for: instance.instanceID))
        adoptAppWindow(window)
        #expect(registry.hasTrackedUserWindow(countingMiniaturized: false))

        // `close()` dispatches `windowWillClose` synchronously, which is what
        // drives `ClipboardWindowController.onWillClose`.
        window.close()

        #expect(registry.clipboardWindow(for: instance.instanceID) == nil)
    }

    @Test("Showing a clipboard window asks residency to prepare, and its close deregisters it")
    func clipboardWindowDrivesResidency() throws {
        let registry = makeRegistry()
        let host = StubResidencyHost()
        registry.residency = host
        let instance = makeClipboardEligibleInstance()

        registry.showClipboard(for: instance)
        let window = try #require(registry.clipboardWindow(for: instance.instanceID))
        adoptAppWindow(window)

        #expect(host.prepareCount == 1)

        // The close is answered by the registry's own deregistration; the
        // resident app's global `willClose` observer runs the reconcile, since
        // a clipboard window is titled.
        window.close()

        #expect(registry.clipboardWindow(for: instance.instanceID) == nil)
    }

    @Test("A VM whose state refuses the clipboard opens no window")
    func clipboardRefusedForIneligibleVM() {
        let registry = makeRegistry()
        let instance = VMInstanceFixture.make(name: "Stopped VM")

        registry.showClipboard(for: instance)

        #expect(registry.clipboardWindow(for: instance.instanceID) == nil)
    }
}
