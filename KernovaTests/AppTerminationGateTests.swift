import AppKit
import KernovaTestSupport
import Testing

@testable import Kernova

/// Covers ``AppTerminationController/handleTerminationRequest()`` — which quits
/// terminate the agent and which downgrade to a GUI close — and the latch
/// discipline behind ``AppTerminationController/shouldTerminateOnQuit``.
///
/// Safe in a shared test host because the fixture's library is empty and no save
/// or revert is in flight, so ``AppTerminationController/terminationOutcome(shouldTerminateAgent:isSavePassRunning:hasSaveInFlight:hasRevertInFlight:hasInstancesToSave:)``
/// can never return `.saveThenTerminate` — the one branch that calls
/// `reply(toApplicationShouldTerminate:)` and would take the process down. For
/// the same reason no case here calls `requestFullQuit()` or delivers a quit
/// Apple Event: both call `NSApp.terminate`.
///
/// The `.closeGUI` branch is exercised against a spy rather than a real
/// ``AppResidencyController``, whose `closeGUIForSoftQuit()` reaches
/// `syncActivationPolicy()` and can terminate.
@Suite("AppTerminationController gate", .serialized, .admissionGated)
@MainActor
struct AppTerminationGateTests {
    /// Isolated, pre-cleaned preferences for this suite's `VMLibraryViewModel`.
    private let preferences = makeEphemeralPreferences(suiteName: "test.kernova.apptermination")

    /// Records the GUI close a downgraded quit asks the residency cluster for.
    @MainActor
    private final class SoftQuitSpy: SoftQuitHosting {
        let closed = AsyncGate()
        private(set) var closeCount = 0

        func closeGUIForSoftQuit() {
            closeCount += 1
            closed.notify()
        }
    }

    private func makeController() -> (AppTerminationController, VMLibraryViewModel) {
        let viewModel = makeLibraryViewModel(preferences: preferences)
        return (AppTerminationController(viewModel: viewModel), viewModel)
    }

    @Test("With nothing to downgrade into, every quit terminates")
    func noResidencyTerminates() {
        let (controller, viewModel) = makeController()
        viewModel.keepInMenuBarOnQuit = true

        #expect(controller.shouldTerminateOnQuit)
        #expect(controller.handleTerminationRequest() == .terminateNow)
    }

    @Test("A resident app that stays in the status bar downgrades a quit to a GUI close")
    func residentQuitClosesTheGUI() async throws {
        let (controller, viewModel) = makeController()
        let spy = SoftQuitSpy()
        controller.residency = spy
        viewModel.keepInMenuBarOnQuit = true

        #expect(!controller.shouldTerminateOnQuit)
        #expect(controller.handleTerminationRequest() == .terminateCancel)

        // The close is deferred to a `Task` so it runs after the cancelled
        // termination request settles.
        try await spy.closed.wait { spy.closeCount == 1 }
    }

    @Test("A resident app that does not stay in the status bar terminates")
    func residentQuitWithoutStatusBarTerminates() {
        let (controller, viewModel) = makeController()
        let spy = SoftQuitSpy()
        controller.residency = spy
        viewModel.keepInMenuBarOnQuit = false

        #expect(controller.shouldTerminateOnQuit)
        #expect(controller.handleTerminationRequest() == .terminateNow)
        #expect(spy.closeCount == 0)
    }

    @Test("A terminate-and-save classification outranks staying in the status bar, and never clears")
    func terminateAndSaveLatches() {
        let (controller, viewModel) = makeController()
        let spy = SoftQuitSpy()
        controller.residency = spy
        viewModel.keepInMenuBarOnQuit = true

        controller.latchQuitClassification(.terminateAndSave)
        #expect(controller.shouldTerminateOnQuit)

        // Latches are only ever set, never reset: a later GUI-origin quit must
        // not clear what an external one demanded.
        controller.latchQuitClassification(.stayResident)
        #expect(controller.shouldTerminateOnQuit)
        #expect(controller.handleTerminationRequest() == .terminateNow)
        #expect(spy.closeCount == 0)
    }

    @Test("A terminate-and-relaunch classification latches the same way")
    func terminateAndRelaunchLatches() {
        let (controller, viewModel) = makeController()
        let spy = SoftQuitSpy()
        controller.residency = spy
        viewModel.keepInMenuBarOnQuit = true

        controller.latchQuitClassification(.terminateAndRelaunch)
        #expect(controller.shouldTerminateOnQuit)

        controller.latchQuitClassification(.stayResident)
        #expect(controller.shouldTerminateOnQuit)
        #expect(controller.handleTerminationRequest() == .terminateNow)
        #expect(spy.closeCount == 0)
    }
}
