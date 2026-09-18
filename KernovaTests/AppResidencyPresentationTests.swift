import AppKit
import KernovaTestSupport
import Testing

@testable import Kernova

/// Covers ``AppResidencyController/prepareToPresentWindow()`` — the chokepoint
/// every window that bypasses the summon path goes through, and where such a
/// window arms the auto-start pass.
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
    private let preferences = makeTestPreferences()

    /// Records the ``AppLaunchHosting/armAutoStartPass()`` seam the launch
    /// cluster owns. Held alongside the controller, which references it weakly.
    private final class StubLaunchHost: AppLaunchHosting {
        private(set) var count = 0

        func armAutoStartPass() { count += 1 }
        func awaitLibraryReady() async {}
        func requestFullQuit() {}
    }

    private func makeController() -> (AppResidencyController, StubLaunchHost) {
        let viewModel = makeLibraryViewModel(preferences: preferences)
        let host = StubLaunchHost()
        let controller = AppResidencyController(
            viewModel: viewModel,
            windows: AppWindowRegistry(
                viewModel: viewModel,
                displayPlacement: VMDisplayPlacementController(viewModel: viewModel))
        )
        controller.host = host
        return (controller, host)
    }

    @Test("A controller that has presented nothing arms nothing")
    func freshControllerArmsNothing() {
        let (controller, launchHost) = makeController()

        withExtendedLifetime(controller) {}
        #expect(launchHost.count == 0)
    }

    @Test("Preparing to present a window arms the auto-start pass")
    func prepareArmsThePass() {
        let (controller, launchHost) = makeController()

        controller.prepareToPresentWindow()

        #expect(launchHost.count == 1)
    }

    @Test("A second window re-arms the seam, leaving the once-per-process latch to the delegate")
    func repeatedPreparesReachTheSeamEachTime() {
        let (controller, launchHost) = makeController()

        controller.prepareToPresentWindow()
        controller.prepareToPresentWindow()

        #expect(launchHost.count == 2)
    }
}
