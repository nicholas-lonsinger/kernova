import AppKit
import Testing

@testable import Kernova

/// Covers ``AppResidencyController/noteDidUnhide()`` — the trigger that pays the
/// reconcile a hide defers. ⌘H turns every window's `isVisible` false without
/// closing one, so a background close landing mid-hide is illegible until the
/// app is back on screen, and the unhide is what makes it legible.
///
/// The controller is exercised without ``AppResidencyController/start(provenance:)``,
/// for the reason `AppResidencyPresentationTests` gives. A titled window is on
/// screen for the reconcile to read, so it resolves to `.showDockIcon` and its
/// `setActivationPolicy(.regular)` is a no-op against the already-`.regular`
/// test host.
@Suite("AppResidencyController unhide reconcile", .serialized, .admissionGated)
@MainActor
struct AppResidencyUnhideTests {
    /// Isolated, pre-cleaned preferences for this suite's `VMLibraryViewModel`.
    private let preferences = makeEphemeralPreferences(suiteName: "test.kernova.appresidencyunhide")

    private func makeController() -> AppResidencyController {
        let viewModel = makeLibraryViewModel(preferences: preferences)
        return AppResidencyController(
            viewModel: viewModel,
            preferences: preferences,
            windows: AppWindowRegistry(
                viewModel: viewModel,
                displayPlacement: VMDisplayPlacementController(viewModel: viewModel)))
    }

    @Test("A controller nothing has happened to has scheduled no reconcile")
    func freshControllerSchedulesNothing() {
        #expect(makeController().pendingActivationPolicySyncForTesting == nil)
    }

    @Test("Unhiding schedules the reconcile, which keeps the Dock icon")
    func unhideSchedulesTheReconcile() async throws {
        let window = makeTestWindow(styleMask: [.titled])
        window.orderFront(nil)
        defer { window.close() }
        let controller = makeController()

        controller.noteDidUnhide()

        let reconcile = try #require(controller.pendingActivationPolicySyncForTesting)
        await reconcile.value
        #expect(NSApp.activationPolicy() == .regular)
    }
}
