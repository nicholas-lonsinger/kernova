import Foundation
import KernovaTestSupport
import Testing

@testable import Kernova

@Suite("VMSleepWakeCoordinator Tests", .serialized, .admissionGated)
@MainActor
struct VMSleepWakeCoordinatorTests {
    /// What the coordinator asked a user to be told, in place of a presenter.
    private let failures = MockLibraryFailureSink()
    private let fileSystem = MockFileSystem()

    /// Stands in for the system's power acknowledgement.
    @MainActor
    private final class PowerAck {
        let allowed = AsyncGate()
        private(set) var count = 0
        /// How many pauses the mock had run each time sleep was allowed.
        private(set) var pausesAtAllow: [Int] = []

        func allow(pauses: Int) {
            count += 1
            pausesAtAllow.append(pauses)
            allowed.notify()
        }

        func waitUntilAllowed() async throws {
            try await allowed.wait { self.count > 0 }
        }
    }

    private func makeCoordinator(
        virtualizationService: MockVirtualizationService = MockVirtualizationService()
    ) -> (VMSleepWakeCoordinator, StubVMInstanceRoster, MockVirtualizationService) {
        let roster = StubVMInstanceRoster()
        let coordinator = VMSleepWakeCoordinator(
            lifecycle: makeTestLifecycle(virtualization: virtualizationService, fileSystem: fileSystem),
            roster: roster
        )
        coordinator.onFailure = { [failures] error in
            failures.record(title: "Error", message: error.localizedDescription)
        }
        return (coordinator, roster, virtualizationService)
    }

    /// Runs the sleep pass, answering the acknowledgement it fired.
    @discardableResult
    private func sleep(
        _ coordinator: VMSleepWakeCoordinator, _ virtService: MockVirtualizationService
    ) async -> PowerAck {
        let ack = PowerAck()
        await coordinator.pauseAllForSleep { [virtService] in
            ack.allow(pauses: virtService.pauseCallCount)
        }.value
        return ack
    }

    /// A VM the coordinator has actually paused for sleep.
    private func makeSleepPaused(
        _ coordinator: VMSleepWakeCoordinator, roster: StubVMInstanceRoster,
        _ virtService: MockVirtualizationService, name: String
    ) async -> VMInstance {
        let instance = VMInstanceFixture.make(name: name)
        instance.activity.placeForTesting(.running(sessionID: UUID()))
        roster.instances.append(instance)
        await sleep(coordinator, virtService)
        return instance
    }

    /// Launches `kind` with a body that parks on `gate` and then rests where
    /// it started.
    private func launchGated(
        _ kind: VMOperationKind, on instance: VMInstance, gate: GatedStep,
        resting rest: VMOperationRest = .asStarted
    ) throws -> VMOutcome {
        try instance.activity.launch(kind) { _ in
            try await gate.pass()
            return .rest(rest, ())
        }
    }

    // MARK: - Sleep

    @Test("Sleep pauses every running VM, then allows sleep")
    func sleepPausesRunningVMsThenAllowsSleep() async {
        let (coordinator, roster, virtService) = makeCoordinator()
        let running1 = VMInstanceFixture.make(name: "Running 1")
        running1.activity.placeForTesting(.running(sessionID: UUID()))
        let running2 = VMInstanceFixture.make(name: "Running 2")
        running2.activity.placeForTesting(.running(sessionID: UUID()))
        let stopped = VMInstanceFixture.make(name: "Stopped")
        stopped.activity.placeForTesting(.stopped)
        let suspended = VMInstanceFixture.make(name: "Suspended")
        suspended.activity.placeForTesting(.suspended)
        roster.instances = [running1, running2, stopped, suspended]

        let ack = await sleep(coordinator, virtService)

        #expect(ack.pausesAtAllow == [2])
        #expect(running1.status == .paused)
        #expect(running2.status == .paused)
        #expect(stopped.status == .stopped)
        #expect(suspended.status == .paused)
        #expect(!failures.showError)
    }

    @Test("A VM the user paused live is neither paused again, reported, nor resumed on wake")
    func userLivePausedVMIsLeftAlone() async {
        let (coordinator, roster, virtService) = makeCoordinator()
        let session = UUID()
        let userPaused = VMInstanceFixture.make(name: "User Paused")
        userPaused.activity.placeForTesting(.livePaused(sessionID: session))
        roster.instances = [userPaused]

        let ack = await sleep(coordinator, virtService)
        await coordinator.resumeAllAfterWake().value

        #expect(ack.count == 1)
        #expect(virtService.pauseCallCount == 0)
        #expect(virtService.resumeCallCount == 0)
        #expect(userPaused.phase == .livePaused(sessionID: session))
        #expect(!failures.showError)
    }

    @Test("A VM at rest gets nothing queued and nothing reported, and sleep is allowed at once")
    func vmAtRestGetsNothing() async {
        let (coordinator, roster, virtService) = makeCoordinator()
        let stopped = VMInstanceFixture.make(name: "Stopped")
        stopped.activity.placeForTesting(.stopped)
        let initial = VMInstanceFixture.make(name: "Initial")
        initial.activity.placeForTesting(.initialBoot)
        let failed = VMInstanceFixture.make(name: "Failed")
        failed.activity.placeForTesting(.failed(message: "Test failure"))
        let suspended = VMInstanceFixture.make(name: "Suspended")
        suspended.activity.placeForTesting(.suspended)
        // A cold boot that has no session yet has nothing to pause either.
        let starting = VMInstanceFixture.make(name: "Starting")
        starting.activity.placeForTesting(
            .operating(.bringUp(.guestStart(.starting(recovery: false))), from: .stopped))
        let all = [stopped, initial, failed, suspended, starting]
        roster.instances = all

        let ack = await sleep(coordinator, virtService)

        #expect(ack.count == 1)
        #expect(virtService.pauseCallCount == 0)
        for instance in all {
            #expect(instance.activity.queuedFollowUpCountForTesting == 0)
        }
        #expect(!failures.showError)
    }

    @Test("A failed sleep pause is reported before sleep is allowed, and not resumed on wake")
    func failedPauseIsReported() async {
        let virtService = MockVirtualizationService()
        virtService.pauseError = VirtualizationError.noVirtualMachine
        let (coordinator, roster, _) = makeCoordinator(virtualizationService: virtService)
        let running = VMInstanceFixture.make(name: "Running")
        running.activity.placeForTesting(.running(sessionID: UUID()))
        roster.instances = [running]

        let ack = await sleep(coordinator, virtService)
        #expect(ack.count == 1)
        #expect(failures.errorMessage?.contains("Running") == true)

        virtService.pauseError = nil
        await coordinator.resumeAllAfterWake().value
        #expect(virtService.resumeCallCount == 0)
        #expect(failures.errors.count == 1)
    }

    @Test("A sleep pause the termination refuses is not reported")
    func sleepDuringTerminationIsNotReported() async {
        let (coordinator, roster, virtService) = makeCoordinator()
        let running = VMInstanceFixture.make(name: "Running")
        running.activity.placeForTesting(.running(sessionID: UUID()))
        roster.instances = [running]
        roster.isTerminating = true

        let ack = await sleep(coordinator, virtService)

        #expect(ack.count == 1)
        #expect(virtService.pauseCallCount == 0)
        #expect(running.status == .running)
        #expect(!failures.showError)
    }

    /// #1371 test 2. A capture presents `.snapshotting`, so a pass reading
    /// whether the guest executes would never have asked.
    @Test("Sleep during a capture pauses the VM after it, and only then allows sleep")
    func sleepDuringACapturePausesAfterIt() async throws {
        let (coordinator, roster, virtService) = makeCoordinator()
        let session = UUID()
        let instance = VMInstanceFixture.make(name: "Capturing")
        instance.activity.placeForTesting(.running(sessionID: session))
        roster.instances = [instance]
        let gate = GatedStep()
        let capture = try launchGated(.capturingSnapshot(.live), on: instance, gate: gate)
        try await gate.waitUntilEntered()

        let ack = PowerAck()
        let pass = coordinator.pauseAllForSleep { [virtService] in
            ack.allow(pauses: virtService.pauseCallCount)
        }
        #expect(instance.activity.queuedFollowUpCountForTesting == 1)
        #expect(instance.status == .snapshotting)
        await drainMainQueue()
        #expect(ack.count == 0)
        #expect(virtService.pauseCallCount == 0)

        gate.release()
        try await capture.value()
        // The capture's own ending admitted the pause.
        #expect(instance.phase.operation?.kind == .pausing)
        try await ack.waitUntilAllowed()
        await pass.value

        #expect(ack.pausesAtAllow == [1])
        #expect(instance.phase == .livePaused(sessionID: session))
        #expect(!failures.showError)
    }

    @Test("A pause queued behind a save that ends the session is dropped, unreported")
    func pauseBehindASaveIsDropped() async throws {
        let (coordinator, roster, virtService) = makeCoordinator()
        let instance = VMInstanceFixture.make(name: "Saving")
        instance.activity.placeForTesting(.running(sessionID: UUID()))
        instance.beginSessionContextForTesting()
        roster.instances = [instance]
        let gate = GatedStep()
        let save = try launchGated(.saving, on: instance, gate: gate, resting: .atRest(.stopped))
        try await gate.waitUntilEntered()

        let ack = PowerAck()
        let pass = coordinator.pauseAllForSleep { [virtService] in
            ack.allow(pauses: virtService.pauseCallCount)
        }
        #expect(instance.activity.queuedFollowUpCountForTesting == 1)

        gate.release()
        try await save.value()
        await pass.value

        #expect(ack.pausesAtAllow == [0])
        #expect(instance.activity.queuedFollowUpCountForTesting == 0)
        #expect(instance.phase == .stopped)
        #expect(!failures.showError)
    }

    // MARK: - Wake

    @Test("Wake resumes only the VMs sleep paused")
    func wakeResumesOnlySleepPaused() async {
        let (coordinator, roster, virtService) = makeCoordinator()
        let suspended = VMInstanceFixture.make(name: "Suspended")
        suspended.activity.placeForTesting(.suspended)
        roster.instances = [suspended]
        let sleepPaused = await makeSleepPaused(
            coordinator, roster: roster, virtService, name: "Sleep Paused")

        await coordinator.resumeAllAfterWake().value

        #expect(virtService.resumeCallCount == 1)
        #expect(sleepPaused.status == .running)
        #expect(suspended.status == .paused)
    }

    @Test("A failed wake resume is reported, and a second wake has nothing left to resume")
    func failedResumeIsReported() async {
        let virtService = MockVirtualizationService()
        let (coordinator, roster, _) = makeCoordinator(virtualizationService: virtService)
        _ = await makeSleepPaused(coordinator, roster: roster, virtService, name: "Sleep Paused")
        virtService.resumeError = VirtualizationError.noVirtualMachine

        await coordinator.resumeAllAfterWake().value

        #expect(failures.errorMessage?.contains("Sleep Paused") == true)
        virtService.resumeError = nil
        await coordinator.resumeAllAfterWake().value
        #expect(virtService.resumeCallCount == 1)
    }

    @Test("Wake with nothing paused for sleep resumes nothing")
    func wakeWithNothingPausedIsANoOp() async {
        let (coordinator, roster, virtService) = makeCoordinator()
        let paused = VMInstanceFixture.make(name: "User Paused")
        paused.activity.placeForTesting(.suspended)
        roster.instances = [paused]

        await coordinator.resumeAllAfterWake().value

        #expect(virtService.resumeCallCount == 0)
        #expect(!failures.showError)
    }

    @Test("Wake passes over a sleep-paused VM that came to rest meanwhile")
    func wakeSkipsVMsNoLongerLive() async {
        let (coordinator, roster, virtService) = makeCoordinator()
        let instance = await makeSleepPaused(coordinator, roster: roster, virtService, name: "Was Paused")
        instance.activity.placeForTesting(.stopped)

        await coordinator.resumeAllAfterWake().value

        #expect(virtService.resumeCallCount == 0)
        #expect(!failures.showError)
    }

    @Test("Wake before the capture ends withdraws the pause, which never runs, and reports it")
    func wakeBeforeReleaseWithdrawsThePause() async throws {
        let (coordinator, roster, virtService) = makeCoordinator()
        let session = UUID()
        let instance = VMInstanceFixture.make(name: "Capturing")
        instance.activity.placeForTesting(.running(sessionID: session))
        roster.instances = [instance]
        let gate = GatedStep()
        let capture = try launchGated(.capturingSnapshot(.live), on: instance, gate: gate)
        try await gate.waitUntilEntered()
        let pass = coordinator.pauseAllForSleep {}
        #expect(instance.activity.queuedFollowUpCountForTesting == 1)

        // The platform stopped waiting, the Mac slept, and it has woken.
        let wake = coordinator.resumeAllAfterWake()

        #expect(instance.activity.queuedFollowUpCountForTesting == 0)
        #expect(failures.errorMessage?.contains("Capturing") == true)
        #expect(failures.errorMessage?.contains("slept before") == true)
        await pass.value
        await wake.value
        gate.release()
        try await capture.value()
        #expect(virtService.pauseCallCount == 0)
        #expect(virtService.resumeCallCount == 0)
        #expect(instance.phase == .running(sessionID: session))
        #expect(failures.errors.count == 1)
    }

    @Test("Wake while an attach holds a sleep-paused VM resumes it after the attach")
    func wakeDuringAnAttachResumesAfterIt() async throws {
        let (coordinator, roster, virtService) = makeCoordinator()
        roster.supportsUSBAccessories = true
        let instance = await makeSleepPaused(coordinator, roster: roster, virtService, name: "Held")
        let session = try #require(instance.liveSessionID)
        #expect(instance.phase == .livePaused(sessionID: session))
        let gate = GatedStep()
        let attach = try launchGated(.attachingUSB(registryID: 1), on: instance, gate: gate)
        try await gate.waitUntilEntered()

        let wake = coordinator.resumeAllAfterWake()
        #expect(instance.activity.queuedFollowUpCountForTesting == 1)

        gate.release()
        try await attach.value()
        // The attach's own ending admitted the resume.
        #expect(instance.phase.operation?.kind == .resuming)
        await wake.value

        #expect(virtService.resumeCallCount == 1)
        #expect(instance.phase == .running(sessionID: session))
        #expect(!failures.showError)
    }

    /// Wake's resume is a hot one: a VM that came to rest on its slot while
    /// the host slept is not restored behind the user's back.
    @Test("A wake passes over a VM that came to rest on its slot, keeping the slot")
    func wakeColdResumeOntoALiveIdentityIsRefused() async throws {
        let virtService = MockVirtualizationService()
        let lifecycle = makeTestLifecycle(virtualization: virtService, fileSystem: fileSystem)
        let mac = "aa:bb:cc:dd:ee:30"
        let library = makeWiredLibrary(lifecycle: lifecycle)
        let sleeper = library.registerFixture(name: "Sleeper") {
            $0.networkEnabled = true
            $0.macAddress = mac
        }
        sleeper.activity.placeForTesting(.running(sessionID: UUID()))
        let twin = library.registerFixture(name: "Twin") {
            $0.networkEnabled = true
            $0.macAddress = mac
        }
        let coordinator = VMSleepWakeCoordinator(lifecycle: lifecycle, roster: library)
        coordinator.onFailure = { [failures] error in
            failures.record(title: "Error", message: error.localizedDescription)
        }
        defer { VMInstanceFixture.removeBundle(of: sleeper) }

        await sleep(coordinator, virtService)
        // Between sleep and wake the paused VM came to rest on its suspend slot,
        // releasing its address, and its twin came up on it.
        try VMInstanceFixture.writeSaveFile(for: sleeper)
        sleeper.handleSessionEvent(.guestDidStop)
        twin.activity.placeForTesting(.running(sessionID: UUID()))

        await coordinator.resumeAllAfterWake().value

        #expect(virtService.resumeCallCount == 0)
        #expect(virtService.startCallCount == 0)
        #expect(sleeper.phase == .suspended)
        #expect(sleeper.hasSaveFile)
        #expect(twin.status == .running)
        // No hot resume is owed a VM that is no longer live-paused.
        #expect(failures.showError == false)
    }
}
