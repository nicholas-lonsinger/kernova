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
/// `terminationEndingForTesting` seam, so the two-phase order is observable
/// without the real `NSApp.terminate` — or an unmatched
/// `reply(toApplicationShouldTerminate:)` — reaching the shared host.
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

    /// Records how each finished save pass ended, and what the gate would
    /// answer at that moment.
    @MainActor
    private final class EndingSpy {
        let ended = AsyncGate()
        private(set) var endings: [AppTerminationController.TerminationEnding] = []
        /// The gate's reply, read from inside the ending the pass performs.
        private(set) var replyWhenEnded: NSApplication.TerminateReply?

        func record(
            _ ending: AppTerminationController.TerminationEnding,
            reply: NSApplication.TerminateReply?
        ) {
            endings.append(ending)
            replyWhenEnded = reply
            ended.notify()
        }
    }

    @Test("A full quit saves first and asks to terminate second")
    func fullQuitSavesBeforeTerminating() async throws {
        let (controller, viewModel) = makeController()
        viewModel.keepInMenuBarOnQuit = true
        let spy = EndingSpy()
        controller.terminationEndingForTesting = { [weak controller] ending in
            spy.record(ending, reply: controller?.handleTerminationRequest())
        }

        controller.requestFullQuit()
        // The save pass is a `Task`, so nothing has ended on the turn the
        // request was made.
        #expect(spy.endings.isEmpty)

        try await spy.ended.wait { spy.endings.count == 1 }
        // Nothing deferred this quit, so the pass asks for one of its own.
        #expect(spy.endings == [.terminate])
        // The pass has already run, so the gate has nothing to wait for — the
        // `.terminateLater` reply, and the nested run loop AppKit answers it
        // with, is what the two phases exist to avoid.
        #expect(spy.replyWhenEnded == .terminateNow)
    }

    @Test("A second full quit joins the pass already running rather than starting another")
    func secondFullQuitJoinsTheFirst() async throws {
        let (controller, viewModel) = makeController()
        viewModel.keepInMenuBarOnQuit = true
        let spy = EndingSpy()
        controller.terminationEndingForTesting = { ending in spy.record(ending, reply: nil) }

        controller.requestFullQuit()
        controller.requestFullQuit()

        try await spy.ended.wait { spy.endings.count == 1 }
        // A second pass would reach `trySave` on a VM the first one holds and
        // force-stop it mid-write, so exactly one pass runs and ends.
        #expect(spy.endings == [.terminate])
    }

    @Test("A quit AppKit begins while the pass runs is answered by the pass, not left waiting")
    func deferredQuitIsAnsweredByThePass() async throws {
        let (controller, viewModel) = makeController()
        viewModel.keepInMenuBarOnQuit = true
        let spy = EndingSpy()
        controller.terminationEndingForTesting = { ending in spy.record(ending, reply: nil) }

        controller.requestFullQuit()
        // A quit Apple Event, a logout, or a TCC revocation landing while the
        // pass is still queued: deferred rather than vetoed, because a
        // `.terminateCancel` reaches loginwindow as a refusal to shut down.
        #expect(controller.handleTerminationRequest() == .terminateLater)

        try await spy.ended.wait { spy.endings.count == 1 }
        // AppKit is waiting on that reply, so the pass answers it rather than
        // asking for a second termination.
        #expect(spy.endings == [.deferredReply])
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
