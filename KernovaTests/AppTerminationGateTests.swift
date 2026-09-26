import AppKit
import KernovaTestSupport
import Testing

@testable import Kernova

/// Covers ``AppTerminationController/handleTerminationRequest()`` — which quits
/// terminate the agent and which downgrade to a GUI close — and the latch
/// discipline behind ``AppTerminationController/shouldTerminateOnQuit``.
///
/// Safe in a shared test host because a case whose library holds anything a quit
/// saves or waits out sets `terminationEndingForTesting` first, so the
/// `.saveThenTerminate` branch never reaches
/// `reply(toApplicationShouldTerminate:)` and takes the process down. For the
/// same reason no case delivers a quit Apple Event, and every
/// `requestFullQuit()` goes through that seam: both call `NSApp.terminate`.
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

    private func makeController(
        residency: any SoftQuitHosting = SoftQuitSpy()
    ) -> (AppTerminationController, VMLibraryViewModel) {
        let viewModel = makeLibraryViewModel(preferences: preferences)
        return (
            AppTerminationController(viewModel: viewModel, residency: residency), viewModel
        )
    }

    /// An Apple event of `eventClass`/`eventID`, as one arrives.
    private func makeEvent(_ eventClass: AEEventClass, _ eventID: AEEventID) -> NSAppleEventDescriptor {
        NSAppleEventDescriptor(
            eventClass: eventClass, eventID: eventID,
            targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID))
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
        // A second pass's save would be refused as busy on the VM the first
        // one holds, and force-stop it mid-write, so exactly one pass runs and
        // ends.
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

    // MARK: - What a Quit Waits Out

    /// A full quit whose pass records how it ended, over a library that
    /// holds `instances`, each wired to it.
    private func makeFullQuit(
        holding instances: [VMInstance] = []
    ) -> (AppTerminationController, VMLibraryViewModel, EndingSpy) {
        let (controller, viewModel) = makeController()
        viewModel.keepInMenuBarOnQuit = true
        for instance in instances { instance.peers = viewModel.library }
        viewModel.library.admitForTesting(instances)
        let spy = EndingSpy()
        controller.terminationEndingForTesting = { ending in spy.record(ending, reply: nil) }
        return (controller, viewModel, spy)
    }

    /// Asks for a full quit and lets its pass run as far as it gets without
    /// anything else happening: the pass is a main-actor task enqueued by the
    /// request, so once the main queue has drained it has either ended or is
    /// parked on what it waits out.
    private func requestFullQuitAndLetItRun(_ controller: AppTerminationController) async {
        controller.requestFullQuit()
        await drainMainQueue()
    }

    @Test("R6: a quit waits out a snapshot trash")
    func quitWaitsOutASnapshotTrash() async throws {
        let instance = VMInstanceFixture.make(name: "Trashing")
        instance.activity.placeForTesting(.stopped)
        let (controller, viewModel, spy) = makeFullQuit(holding: [instance])
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

    @Test("R6: a quit waits out a delete's trashes")
    func quitWaitsOutADelete() async throws {
        let instance = VMInstanceFixture.make(name: "Deleting")
        instance.activity.placeForTesting(.stopped)
        let (controller, _, spy) = makeFullQuit(holding: [instance])
        let gate = GatedStep()
        let delete = Task { try await instance.activity.delete { _ in try await gate.pass() } }
        try await gate.waitUntilEntered()

        await requestFullQuitAndLetItRun(controller)
        #expect(spy.endings.isEmpty)

        gate.release()
        try await delete.value
        try await spy.ended.wait { spy.endings.count == 1 }
        #expect(instance.phase == .removed)
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

    @Test("A quit saves each live VM once its trash is waited out")
    func quitSavesTheLiveVMAfterItsWait() async throws {
        let instance = VMInstanceFixture.make(name: "Live")
        instance.activity.placeForTesting(.running(sessionID: UUID()))
        defer { VMInstanceFixture.removeBundle(of: instance) }
        let (controller, _, spy) = makeFullQuit(holding: [instance])
        let gate = GatedStep()
        let trash = try instance.activity.launch(.deletingSnapshot) { _ in
            try await gate.pass()
            return .rest(.asStarted, ())
        }
        try await gate.waitUntilEntered()

        await requestFullQuitAndLetItRun(controller)
        // Waited out rather than refused: the save is decided once the trash
        // has rested the VM live again.
        #expect(instance.phase.operation?.kind == .deletingSnapshot)
        #expect(spy.endings.isEmpty)

        gate.release()
        try await trash.value()
        try await spy.ended.wait { spy.endings.count == 1 }
        #expect(instance.phase == .suspended)
    }

    @Test("A resident app that stays in the menu bar downgrades a quit to a GUI close")
    func residentQuitClosesTheGUI() async throws {
        let spy = SoftQuitSpy()
        let (controller, viewModel) = makeController(residency: spy)
        viewModel.keepInMenuBarOnQuit = true

        #expect(!controller.shouldTerminateOnQuit)
        #expect(controller.handleTerminationRequest() == .terminateCancel)

        // The close is deferred to a `Task` so it runs after the cancelled
        // termination request settles.
        try await spy.closed.wait { spy.closeCount == 1 }
    }

    @Test("A resident app that does not stay in the menu bar terminates")
    func residentQuitWithoutMenuBarTerminates() {
        let spy = SoftQuitSpy()
        let (controller, viewModel) = makeController(residency: spy)
        viewModel.keepInMenuBarOnQuit = false

        #expect(controller.shouldTerminateOnQuit)
        #expect(controller.handleTerminationRequest() == .terminateNow)
        #expect(spy.closeCount == 0)
    }

    @Test("A quit a script sent terminates and saves, whichever handler delivered it")
    func scriptedQuitTerminates() {
        let spy = SoftQuitSpy()
        let (controller, viewModel) = makeController(residency: spy)
        viewModel.keepInMenuBarOnQuit = true
        // launchd: alive, and no application — the shape of `osascript`'s quit.
        controller.quitSenderPIDForTesting = { 1 }

        #expect(controller.handleTerminationRequest() == .terminateNow)
        #expect(controller.shouldTerminateOnQuit)
        #expect(spy.closeCount == 0)
    }

    @Test("A quit the app sent itself stays resident")
    func selfSentQuitStaysResident() async throws {
        let spy = SoftQuitSpy()
        let (controller, viewModel) = makeController(residency: spy)
        viewModel.keepInMenuBarOnQuit = true
        controller.quitSenderPIDForTesting = { getpid() }

        #expect(controller.handleTerminationRequest() == .terminateCancel)
        #expect(!controller.shouldTerminateOnQuit)

        try await spy.closed.wait { spy.closeCount == 1 }
    }

    @Test("Only the Standard Suite's quit is read as one")
    func onlyAQuitEventIsAQuit() {
        #expect(AppTerminationController.isQuitEvent(makeEvent(kCoreEventClass, kAEQuitApplication)))
        #expect(!AppTerminationController.isQuitEvent(makeEvent(kCoreEventClass, kAEOpenApplication)))
        #expect(!AppTerminationController.isQuitEvent(makeEvent(kAEMiscStandards, kAEQuitApplication)))
    }

    @Test("A terminate-and-save classification outranks staying in the menu bar, and never clears")
    func terminateAndSaveLatches() {
        let spy = SoftQuitSpy()
        let (controller, viewModel) = makeController(residency: spy)
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
        let spy = SoftQuitSpy()
        let (controller, viewModel) = makeController(residency: spy)
        viewModel.keepInMenuBarOnQuit = true

        controller.latchQuitClassification(.terminateAndRelaunch)
        #expect(controller.shouldTerminateOnQuit)

        controller.latchQuitClassification(.stayResident)
        #expect(controller.shouldTerminateOnQuit)
        #expect(controller.handleTerminationRequest() == .terminateNow)
        #expect(spy.closeCount == 0)
    }
}
