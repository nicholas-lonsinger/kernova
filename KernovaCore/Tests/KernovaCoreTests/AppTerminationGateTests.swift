import Foundation
import KernovaAgentCore
import KernovaAgentHost
import KernovaCommandModel
import KernovaKit
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport

/// Covers ``AppTerminationController/handleTerminationRequest()`` — which quits
/// terminate the agent and which downgrade to a GUI close — and the latch
/// discipline behind ``AppTerminationController/shouldTerminateOnQuit``.
///
/// Every controller here ends its termination into an ``EndingSpy`` and reads
/// its quit event and that event's sender from the case.
///
/// The `.closeGUI` branch is exercised against a spy rather than a real
/// ``AppResidencyController``, whose `closeGUIForSoftQuit()` reaches
/// `syncActivationPolicy()` and can terminate.
@Suite("AppTerminationController gate", .serialized, .caseScoped)
@MainActor
struct AppTerminationGateTests {
    private let preferences = makeTestPreferences()

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

    /// A controller whose terminations end into `endings`, and whose pending
    /// quit was delivered by `quitEvent`.
    private func makeController(
        residency: any SoftQuitHosting = SoftQuitSpy(),
        diskImages: MockDiskImageService = MockDiskImageService(),
        endings: EndingSpy = EndingSpy(),
        quitEvent: AppTerminationController.QuitEvent? = nil
    ) -> (AppTerminationController, VMLibraryViewModel) {
        let viewModel = makeLibraryViewModel(preferences: preferences, diskImageService: diskImages)
        let controller = AppTerminationController(
            viewModel: viewModel, residency: residency,
            pendingQuitEvent: { quitEvent },
            // Every sender is alive and no application: the shape of
            // `osascript`'s quit.
            senderProbe: .init(isProcessAlive: { _ in true }, bundleID: { _ in nil }),
            endTermination: { ending in endings.record(ending) })
        return (controller, viewModel)
    }

    /// Records how each finished save pass ended, and what the gate would
    /// answer at that moment.
    @MainActor
    private final class EndingSpy {
        let ended = AsyncGate()
        private(set) var endings: [AppTerminationController.TerminationEnding] = []
        /// The controller whose gate is asked from inside each ending, if any.
        weak var gate: AppTerminationController?
        /// The gate's reply, read from inside the ending the pass performs.
        private(set) var replyWhenEnded: AppTerminationController.TerminationReply?

        func record(_ ending: AppTerminationController.TerminationEnding) {
            endings.append(ending)
            replyWhenEnded = gate?.handleTerminationRequest()
            ended.notify()
        }
    }

    @Test("A full quit saves first and asks to terminate second")
    func fullQuitSavesBeforeTerminating() async throws {
        let spy = EndingSpy()
        let (controller, viewModel) = makeController(endings: spy)
        viewModel.keepInMenuBarOnQuit = true
        spy.gate = controller

        controller.requestFullQuit()
        // The save pass is a `Task`, so nothing has ended on the turn the
        // request was made.
        #expect(spy.endings.isEmpty)

        try await spy.ended.wait { spy.endings.count == 1 }
        // Nothing deferred this quit, so the pass asks for one of its own.
        #expect(spy.endings == [.terminate])
        // The pass has already run, so the gate has nothing to wait for — the
        // `.later` reply, and the nested run loop AppKit answers it with, is
        // what the two phases exist to avoid.
        #expect(spy.replyWhenEnded == .now)
    }

    @Test("A second full quit joins the pass already running rather than starting another")
    func secondFullQuitJoinsTheFirst() async throws {
        let spy = EndingSpy()
        let (controller, viewModel) = makeController(endings: spy)
        viewModel.keepInMenuBarOnQuit = true

        controller.requestFullQuit()
        controller.requestFullQuit()

        try await spy.ended.wait { spy.endings.count == 1 }
        // A second pass's save would be refused as busy on the VM the first
        // one holds, and force-stop it mid-write, so exactly one pass runs and
        // ends.
        #expect(spy.endings == [.terminate])
    }

    @Test("A quit AppKit begins while the pass runs is answered by the pass, not left waiting")
    func deferredQuitIsAnsweredByThePass() async throws {
        let spy = EndingSpy()
        let (controller, viewModel) = makeController(endings: spy)
        viewModel.keepInMenuBarOnQuit = true

        controller.requestFullQuit()
        // A quit Apple Event, a logout, or a TCC revocation landing while the
        // pass is still queued: deferred rather than vetoed, because a
        // `.cancel` reaches loginwindow as a refusal to shut down.
        #expect(controller.handleTerminationRequest() == .later)

        try await spy.ended.wait { spy.endings.count == 1 }
        // AppKit is waiting on that reply, so the pass answers it rather than
        // asking for a second termination.
        #expect(spy.endings == [.deferredReply])
    }

    // MARK: - What a Quit Waits Out

    /// A full quit whose pass records how it ended.
    private func makeFullQuit(
        diskImages: MockDiskImageService = MockDiskImageService()
    ) -> (AppTerminationController, VMLibraryViewModel, EndingSpy) {
        let spy = EndingSpy()
        let (controller, viewModel) = makeController(diskImages: diskImages, endings: spy)
        viewModel.keepInMenuBarOnQuit = true
        return (controller, viewModel, spy)
    }

    /// A VM named `name` in `viewModel`'s library, with the library as its
    /// peers.
    private func admitPeer(named name: String, to viewModel: VMLibraryViewModel) -> VMInstance {
        let instance = viewModel.library.admitFixture(name: name)
        instance.peers = viewModel.library
        return instance
    }

    /// Asks for a full quit and lets its pass run as far as it gets without
    /// anything else happening: the pass is a main-actor task enqueued by the
    /// request, so once the main queue has drained it has either ended or is
    /// parked on what it waits out.
    private func requestFullQuitAndLetItRun(_ controller: AppTerminationController) async {
        controller.requestFullQuit()
        await drainMainQueue()
    }

    @Test("A quit waits out a snapshot trash")
    func quitWaitsOutASnapshotTrash() async throws {
        let (controller, viewModel, spy) = makeFullQuit()
        let instance = admitPeer(named: "Trashing", to: viewModel)
        instance.activity.placeForTesting(.stopped)
        let gate = GatedStep()
        let trash = try instance.activity.launch(.deletingSnapshot) { _ in
            try await gate.pass()
            return .rest(.asStarted, ())
        }
        try await gate.waitUntilEntered()

        await requestFullQuitAndLetItRun(controller)
        #expect(viewModel.library.isTerminating)
        #expect(spy.endings.isEmpty)

        gate.release()
        try await trash.value()
        try await spy.ended.wait { spy.endings.count == 1 }
        #expect(spy.endings == [.terminate])
    }

    @Test("A quit waits out an arrival withdrawing the bundle a cancel took back")
    func quitWaitsOutAWithdrawal() async throws {
        let (controller, viewModel, spy) = makeFullQuit()
        let gate = GatedStep()
        let arrival = viewModel.library.beginGatedArrival(named: "Withdrawn", gate: gate)
        try await gate.waitUntilEntered()
        #expect(arrival.beginPublishing())
        #expect(arrival.requestCancel() == .withdrawn)

        await requestFullQuitAndLetItRun(controller)
        #expect(spy.endings.isEmpty)

        gate.release()
        await arrival.settle()
        try await spy.ended.wait { spy.endings.count == 1 }
    }

    @Test("A quit saves every other live VM while one VM's save is still running")
    func quitSavesOtherVMsBeforeWaiting() async throws {
        let (controller, viewModel, spy) = makeFullQuit()
        let stuck = admitPeer(named: "Stuck", to: viewModel)
        stuck.activity.placeForTesting(.running(sessionID: UUID()))
        let gate = GatedStep()
        let save = try stuck.activity.launch(.saving) { _ in
            try await gate.pass()
            return .rest(.asStarted, ())
        }
        try await gate.waitUntilEntered()
        let live = admitPeer(named: "Live", to: viewModel)
        live.activity.placeForTesting(.running(sessionID: UUID()))

        controller.requestFullQuit()
        try await waitForChange { live.phase == .suspended }
        #expect(stuck.phase.operation?.kind == .saving)
        #expect(spy.endings.isEmpty)

        gate.release()
        try await save.value()
        try await spy.ended.wait { spy.endings.count == 1 }
        #expect(stuck.phase == .suspended)
    }

    /// A display that takes nothing over.
    @MainActor
    private final class IdleDisplay: GuestDragDisplay {
        func injectNudge(_ nudge: GuestDragNudge) {}
        func injectDrag(at point: CGPoint) {}
        func returnToExitPoint() {}
        func injectRelease() {}
        func beginHostSession(carrying take: any GuestDragTaking) -> Bool { false }
        func resumeTracking() {}
    }

    @Test("A quit that terminates now retires every drag out of a guest before it answers")
    func terminationRetiresDragsFirst() throws {
        let (controller, viewModel) = makeController()
        viewModel.keepInMenuBarOnQuit = false
        let instance = viewModel.library.admitFixture(name: "Drag VM", guestOS: .macOS)
        let hub = FakeDragOutHub()
        let peer = PeerHandle(rawValue: 3)
        instance.dragOut.hub = hub
        instance.dragOut.consolePeerChanged(peer)
        instance.dragOut.offerReceived(Data(repeating: 0x5A, count: 16), from: peer)
        let display = IdleDisplay()
        let taken = instance.dragOut.takeGuestDrag(display: display, while: { true })
        let take = try #require(taken)
        var retiredFirst = false
        take.whenRetired { retiredFirst = true }

        #expect(controller.handleTerminationRequest() == .now)

        #expect(retiredFirst)
        #expect(take.phase == .abandoned)
    }

    @Test("A quit a script sent terminates and saves, whichever handler delivered it")
    func scriptedQuitTerminates() {
        let spy = SoftQuitSpy()
        let (controller, viewModel) = makeController(
            residency: spy, quitEvent: .init(senderPID: 1))
        viewModel.keepInMenuBarOnQuit = true

        #expect(controller.handleTerminationRequest() == .now)
        #expect(controller.shouldTerminateOnQuit)
        #expect(spy.closeCount == 0)
    }

    @Test("A quit the app sent itself stays resident")
    func selfSentQuitStaysResident() async throws {
        let spy = SoftQuitSpy()
        let (controller, viewModel) = makeController(
            residency: spy, quitEvent: .init(senderPID: getpid()))
        viewModel.keepInMenuBarOnQuit = true

        #expect(controller.handleTerminationRequest() == .cancel)
        #expect(!controller.shouldTerminateOnQuit)

        try await spy.closed.wait { spy.closeCount == 1 }
    }

    @Test("A terminate-and-relaunch classification latches the same way")
    func terminateAndRelaunchLatches() {
        let spy = SoftQuitSpy()
        let (controller, viewModel) = makeController(residency: spy)
        viewModel.keepInMenuBarOnQuit = true

        controller.latchQuitClassification(.terminateAndRelaunch)
        #expect(controller.shouldTerminateOnQuit)

        controller.latchQuitClassification(.stayResident)
        #expect(controller.shouldTerminateOnQuit)
        #expect(controller.handleTerminationRequest() == .now)
        #expect(spy.closeCount == 0)
    }
}
