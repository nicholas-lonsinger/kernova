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
///
/// ``AppTerminationController/requestFullQuit()`` is driven through its
/// `terminateForTesting` seam, so the two-phase order is observable without the
/// real `NSApp.terminate` reaching the shared host.
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

    /// Records the terminate a full quit asks for, and what the gate would
    /// answer at that moment.
    @MainActor
    private final class TerminateSpy {
        let asked = AsyncGate()
        private(set) var askCount = 0
        /// The gate's reply, read from inside the terminate the pass asks for.
        private(set) var replyWhenAsked: NSApplication.TerminateReply?

        func record(_ reply: NSApplication.TerminateReply) {
            askCount += 1
            replyWhenAsked = reply
            asked.notify()
        }
    }

    @Test("A full quit saves first and asks to terminate second")
    func fullQuitSavesBeforeTerminating() async throws {
        let (controller, viewModel) = makeController()
        viewModel.keepInMenuBarOnQuit = true
        let spy = TerminateSpy()
        controller.terminateForTesting = { [weak controller] in
            spy.record(controller?.handleTerminationRequest() ?? .terminateCancel)
        }

        controller.requestFullQuit()
        // The save pass is a `Task`, so nothing has been asked to terminate on
        // the turn the request was made.
        #expect(spy.askCount == 0)

        try await spy.asked.wait { spy.askCount == 1 }
        // The pass has already run, so the gate has nothing to wait for — the
        // `.terminateLater` reply, and the nested run loop AppKit answers it
        // with, is what the two phases exist to avoid.
        #expect(spy.replyWhenAsked == .terminateNow)
    }

    @Test("A second full quit joins the pass already running rather than starting another")
    func secondFullQuitJoinsTheFirst() async throws {
        let (controller, viewModel) = makeController()
        viewModel.keepInMenuBarOnQuit = true
        let spy = TerminateSpy()
        controller.terminateForTesting = { [weak controller] in
            spy.record(controller?.handleTerminationRequest() ?? .terminateCancel)
        }

        controller.requestFullQuit()
        controller.requestFullQuit()

        try await spy.asked.wait { spy.askCount == 1 }
        // A second pass would reach `trySave` on a VM the first one holds and
        // force-stop it mid-write, so the terminate is asked for exactly once.
        #expect(spy.askCount == 1)
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
