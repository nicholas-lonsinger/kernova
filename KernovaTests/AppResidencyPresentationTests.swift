import AppKit
import Testing

@testable import Kernova

/// Covers ``AppResidencyController/prepareToPresentWindow()`` — the chokepoint
/// every window that bypasses the summon path goes through, and the one place
/// such a window arms the auto-start pass asking for surfaced displays.
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

    /// Records the ``AppLaunchHosting/armAutoStartPass(surfacingDisplays:)`` seam
    /// the launch cluster owns. Held alongside the controller, which references
    /// it weakly.
    private final class StubLaunchHost: AppLaunchHosting {
        /// One entry per arming call, carrying the surfacing it asked for.
        var armings: [Bool] = []
        var count: Int { armings.count }

        func armAutoStartPass(surfacingDisplays: Bool) { armings.append(surfacingDisplays) }
        func awaitLibraryReady() async {}
        func requestFullQuit() {}
    }

    private func makeController() -> (AppResidencyController, StubLaunchHost) {
        let viewModel = makeLibraryViewModel(preferences: preferences)
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

    /// A headless launch arms the pass with no window, so the presentation that
    /// may follow it must still ask for surfacing — the delegate's
    /// once-per-process latch is what keeps the second arming from re-running
    /// the pass, and this seam must not pre-empt that by lying about surfacing.
    @Test("A presentation arms the auto-start pass asking for surfaced displays")
    func presentationArmsTheSurfacingPass() {
        let (controller, launchHost) = makeController()

        controller.prepareToPresentWindow()

        #expect(launchHost.armings == [true])
    }
}
