import AppKit
import KernovaTestSupport
import Testing

@testable import Kernova

/// Covers `AppWindowRegistry.hasTrackedUserWindow(countingMiniaturized:)` — the
/// deterministic half of the window-presence answer the activation-policy
/// reconcile and the reopen leg both read.
///
/// Only the tracked windows are exercised: the `NSApp.windows` scan
/// `hasUserWindow(countingMiniaturized:)` layers on top sees every other suite's
/// windows in the shared test host, so it has no deterministic answer here.
@Suite("AppWindowRegistry presence", .serialized, .admissionGated)
@MainActor
struct AppWindowRegistryPresenceTests {
    /// Isolated, pre-cleaned preferences for this suite's `VMLibraryViewModel`.
    private let preferences = makeEphemeralPreferences(suiteName: "test.kernova.appwindowregistry")

    private func makeRegistry() -> AppWindowRegistry {
        let viewModel = VMLibraryViewModel(
            storageService: MockVMStorageService(),
            diskImageService: MockDiskImageService(),
            virtualizationService: MockVirtualizationService(),
            installService: MockMacOSInstallService(),
            ipswService: MockIPSWService(),
            usbDeviceService: MockUSBDeviceService(),
            preferences: preferences
        )
        return AppWindowRegistry(
            viewModel: viewModel,
            displayPlacement: VMDisplayPlacementController(viewModel: viewModel))
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
}
