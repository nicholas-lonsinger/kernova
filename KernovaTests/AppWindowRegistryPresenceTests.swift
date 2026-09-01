import AppKit
import KernovaTestSupport
import Testing

@testable import Kernova

/// Covers `AppWindowRegistry.hasTrackedUserWindow(countingMiniaturized:)` — the
/// deterministic half of the window-presence answer the activation-policy
/// reconcile and the reopen leg both read — and the clipboard window's
/// close-driven deregistration.
///
/// Only the tracked windows are exercised for presence: the `NSApp.windows` scan
/// `hasUserWindow(countingMiniaturized:)` layers on top sees every other suite's
/// windows in the shared test host, so it has no deterministic answer here.
@Suite("AppWindowRegistry presence", .serialized, .admissionGated)
@MainActor
struct AppWindowRegistryPresenceTests {
    /// Isolated, pre-cleaned preferences for this suite's `VMLibraryViewModel`.
    private let preferences = makeEphemeralPreferences(suiteName: "test.kernova.appwindowregistry")

    private func makeRegistry() -> AppWindowRegistry {
        let viewModel = makeViewModel()
        return AppWindowRegistry(
            viewModel: viewModel,
            displayPlacement: VMDisplayPlacementController(viewModel: viewModel))
    }

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

    /// A VM the clipboard window opens for: sharing on, and a live session, which
    /// is what `accepts(.showClipboard, on:)` asks for.
    private func makeClipboardEligibleInstance() -> VMInstance {
        var config = VMConfiguration(name: "Clipboard VM", guestOS: .linux, bootMode: .efi)
        config.clipboardSharingEnabled = true
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(config.id.uuidString, isDirectory: true)
        return VMInstance(
            configuration: config, bundleURL: bundleURL, phase: .running(sessionID: UUID()))
    }

    @Test("A registry that has shown nothing tracks no on-screen window")
    func nothingShown() {
        let registry = makeRegistry()

        #expect(!registry.hasTrackedUserWindow(countingMiniaturized: true))
        #expect(!registry.hasTrackedUserWindow(countingMiniaturized: false))
    }

    @Test("The library window counts, however miniaturized windows are treated")
    func libraryShown() {
        let registry = makeRegistry()
        defer { registry.closeAll() }
        registry.showLibrary(bringToFront: true)

        #expect(registry.hasTrackedUserWindow(countingMiniaturized: true))
        #expect(registry.hasTrackedUserWindow(countingMiniaturized: false))
    }

    @Test("A miniaturized library window counts only when miniaturized windows do")
    func libraryMiniaturized() async throws {
        let registry = makeRegistry()
        defer { registry.closeAll() }
        registry.showLibrary(bringToFront: true)
        let window = try #require(registry.libraryWindow)

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
    func settingsShown() {
        let registry = makeRegistry()
        defer { registry.closeAll() }
        registry.showSettings(nil)

        #expect(registry.hasTrackedUserWindow(countingMiniaturized: true))
    }

    @Test("Closing a clipboard window deregisters it")
    func clipboardWindowCloseDeregisters() throws {
        let registry = makeRegistry()
        defer { registry.closeAll() }
        let instance = makeClipboardEligibleInstance()
        registry.showClipboard(for: instance)
        let window = try #require(registry.clipboardWindow(for: instance.instanceID))
        #expect(registry.hasAuxiliaryWindows)
        #expect(registry.hasTrackedUserWindow(countingMiniaturized: false))

        // `close()` dispatches `windowWillClose` synchronously, which is what
        // drives `ClipboardWindowController.onWillClose`.
        window.close()

        #expect(registry.clipboardWindow(for: instance.instanceID) == nil)
        #expect(!registry.hasAuxiliaryWindows)
    }

    @Test("A VM whose state refuses the clipboard opens no window")
    func clipboardRefusedForIneligibleVM() {
        let registry = makeRegistry()
        defer { registry.closeAll() }
        let config = VMConfiguration(name: "Stopped VM", guestOS: .linux, bootMode: .efi)
        let instance = VMInstance(
            configuration: config,
            bundleURL: FileManager.default.temporaryDirectory
                .appendingPathComponent(config.id.uuidString, isDirectory: true))

        registry.showClipboard(for: instance)

        #expect(registry.clipboardWindow(for: instance.instanceID) == nil)
        #expect(!registry.hasAuxiliaryWindows)
    }
}
