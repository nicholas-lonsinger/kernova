import AppKit
import KernovaTestSupport
import Testing

@testable import Kernova

/// Covers ``AppResidencyController/prepareToPresentWindow()`` — the chokepoint
/// every window that bypasses the summon path goes through to reach
/// `markInterfacePresented()`, the one setter of the `hasPresentedInterface`
/// latch.
///
/// That latch is what
/// ``AppResidencyController/automationIdleOutcome(isAutomationLaunch:hasPresentedInterface:hasVisibleUserWindow:keepInMenuBar:hasUninterruptibleWork:hasLiveGuest:hasIntentInFlight:)``
/// short-circuits on, so a window on screen can never be idle-quit out from
/// under the user by a reconcile that reads the window list a moment too late.
///
/// The controller is exercised without ``AppResidencyController/start(provenance:)``:
/// that creates the menu-bar status item and installs a process-wide `willClose`
/// observer, neither of which belongs in a test host shared with every other
/// suite. What is left is safe here because the test host is already `.regular`,
/// so the `setActivationPolicy(.regular)` inside `prepareToPresentWindow()` is a
/// no-op.
@Suite("AppResidencyController presentation", .serialized, .admissionGated)
@MainActor
struct AppResidencyPresentationTests {
    /// Isolated, pre-cleaned preferences for this suite's `VMLibraryViewModel`.
    private let preferences = makeEphemeralPreferences(suiteName: "test.kernova.appresidency")

    /// Counts the ``AppLaunchHosting/armAutoStartPass()`` seam the launch cluster
    /// owns. Held alongside the controller, which references it weakly.
    private final class StubLaunchHost: AppLaunchHosting {
        var count = 0

        func armAutoStartPass() { count += 1 }
        func awaitLibraryReady() async {}
        func requestFullQuit() {}
    }

    private func makeController() -> (AppResidencyController, StubLaunchHost) {
        let viewModel = VMLibraryViewModel(
            storageService: MockVMStorageService(),
            diskImageService: MockDiskImageService(),
            virtualizationService: MockVirtualizationService(),
            installService: MockMacOSInstallService(),
            ipswService: MockIPSWService(),
            usbDeviceService: MockUSBDeviceService(),
            preferences: preferences
        )
        let host = StubLaunchHost()
        let controller = AppResidencyController(
            viewModel: viewModel,
            preferences: preferences,
            windows: AppWindowRegistry(
                viewModel: viewModel,
                displayPlacement: VMDisplayPlacementController(viewModel: viewModel))
        )
        controller.host = host
        return (controller, host)
    }

    @Test("A controller that has presented nothing holds the latch clear")
    func freshControllerHasNotPresented() {
        let (controller, launchHost) = makeController()

        #expect(!controller.hasPresentedInterface)
        #expect(launchHost.count == 0)
    }

    @Test("Preparing to present a window latches the interface as presented")
    func prepareLatchesPresented() {
        let (controller, launchHost) = makeController()

        controller.prepareToPresentWindow()

        #expect(controller.hasPresentedInterface)
        #expect(launchHost.count == 1)
    }

    @Test("A second window keeps the latch and re-arms the auto-start pass seam")
    func repeatedPreparesKeepTheLatch() {
        let (controller, launchHost) = makeController()

        controller.prepareToPresentWindow()
        controller.prepareToPresentWindow()

        #expect(controller.hasPresentedInterface)
        #expect(launchHost.count == 2)
    }
}
