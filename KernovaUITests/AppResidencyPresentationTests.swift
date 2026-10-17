import AppKit
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport
@testable import KernovaUI

/// Covers ``AppResidencyController/prepareToPresentWindow()`` — the chokepoint
/// every window that bypasses the summon path goes through, and where such a
/// window arms the auto-start pass.
///
/// The controller is exercised without ``AppResidencyController/start(provenance:)``:
/// that creates the menu-bar status item and installs a process-wide `willClose`
/// observer, neither of which belongs in a test host shared with every other
/// suite.
@Suite("AppResidencyController presentation", .serialized, .caseScoped)
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

    private func makeController(presence: TestAppPresence = TestAppPresence())
        -> (AppResidencyController, StubLaunchHost)
    {
        let viewModel = makeLibraryViewModel(preferences: preferences)
        let host = StubLaunchHost()
        let controller = AppResidencyController(
            viewModel: viewModel,
            windows: makeWindowRegistry(viewModel), heldAlerts: HeldAlerts(), presence: presence)
        controller.host = host
        return (controller, host)
    }

    @Test("A controller that has presented nothing arms nothing")
    func freshControllerArmsNothing() {
        let (controller, launchHost) = makeController()

        withExtendedLifetime(controller) {}
        #expect(launchHost.count == 0)
    }

    @Test("A second window re-arms the seam, leaving the once-per-process latch to the delegate")
    func repeatedPreparesReachTheSeamEachTime() {
        let (controller, launchHost) = makeController()

        controller.prepareToPresentWindow()
        controller.prepareToPresentWindow()

        #expect(launchHost.count == 2)
    }

    @Test("A window put up while headless brings the Dock icon back first, and only once")
    func prepareRestoresTheDockIcon() {
        let presence = TestAppPresence(activationPolicy: .accessory)
        let (controller, _) = makeController(presence: presence)

        controller.prepareToPresentWindow()
        controller.prepareToPresentWindow()

        #expect(presence.activationPolicy == .regular)
        #expect(presence.requests == [.setActivationPolicy(.regular)])
    }
}
