import Foundation
import KernovaAgentCore
import KernovaAgentHost
import KernovaCommandModel
import KernovaKit
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport

@Suite("VMSleepWakeCoordinator Tests", .serialized, .caseScoped)
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
            failures.record(title: "Error", message: error.localizedDescription, subject: .library)
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
        _ kind: VMNonBringUpKind, on instance: VMInstance, gate: GatedStep,
        resting rest: VMOperationRest = .asStarted
    ) throws -> VMOutcome {
        try instance.activity.launch(kind) { _ in
            try await gate.pass()
            return .rest(rest, ())
        }
    }

    // MARK: - Sleep

    @Test("A sleep pause freezes the VM's agent connections")
    func sleepPauseFreezesAgents() async throws {
        let (coordinator, roster, virtService) = makeCoordinator()
        let probe = AgentHubProbe()
        let instance = VMInstanceFixture.make(name: "Agent", agentConnector: probe)
        instance.activity.placeForTesting(.running(sessionID: UUID()))
        instance.agentHub.attach(probe, policy: PolicySnapshot(), republisher: GuestLogRepublisher(vmLabel: "Agent"))
        try await probe.changed.wait { probe.isStarted }
        #expect(probe.connect())
        roster.instances.append(instance)

        await sleep(coordinator, virtService)

        #expect(instance.status == .paused)
        try await probe.changed.wait { probe.commands.contains(.setPeerFrozen(true)) }
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
        // The capture's own ending took the pause off the queue.
        #expect(instance.activity.queuedFollowUpCountForTesting == 0)
        try await ack.waitUntilAllowed()
        await pass.value

        #expect(ack.pausesAtAllow == [1])
        #expect(instance.phase == .livePaused(sessionID: session))
        #expect(!failures.showError)
    }

    // MARK: - Wake

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
        roster.usbPassthroughGap = nil
        let instance = await makeSleepPaused(coordinator, roster: roster, virtService, name: "Held")
        let session = try #require(instance.liveSessionID)
        #expect(instance.phase == .livePaused(sessionID: session))
        let gate = GatedStep()
        let attach = try launchGated(.attachingUSB(registryID: 1), on: instance, gate: gate)
        try await gate.waitUntilEntered()

        let wake = coordinator.resumeAllAfterWake()
        #expect(instance.activity.queuedFollowUpCountForTesting == 1)
        #expect(virtService.resumeCallCount == 0)

        gate.release()
        try await attach.value()
        // The attach's own ending took the resume off the queue.
        #expect(instance.activity.queuedFollowUpCountForTesting == 0)
        await wake.value

        #expect(virtService.resumeCallCount == 1)
        #expect(instance.phase == .running(sessionID: session))
        #expect(!failures.showError)
    }

    /// Runs the sleep pass over one running VM whose pause parks in `mock`,
    /// then wakes while the pause still holds the VM.
    private func wakeDuringAParkedPause(
        _ mock: SuspendingMockVirtualizationService
    ) async -> (
        coordinator: VMSleepWakeCoordinator, instance: VMInstance, session: UUID,
        sleep: Task<Void, Never>, wake: Task<Void, Never>
    ) {
        let roster = StubVMInstanceRoster()
        let coordinator = VMSleepWakeCoordinator(
            lifecycle: makeTestLifecycle(virtualization: mock, fileSystem: fileSystem),
            roster: roster)
        coordinator.onFailure = { [failures] error in
            failures.record(title: "Error", message: error.localizedDescription, subject: .library)
        }
        let session = UUID()
        let instance = VMInstanceFixture.make(name: "Pausing")
        instance.activity.placeForTesting(.running(sessionID: session))
        roster.instances = [instance]
        let sleep = coordinator.pauseAllForSleep {}
        await mock.waitUntilSuspended()
        #expect(instance.phase.operation?.kind == .pausing)

        let wake = coordinator.resumeAllAfterWake()
        return (coordinator, instance, session, sleep, wake)
    }

    @Test("Wake while the sleep pause still runs resumes nothing when the pause fails")
    func wakeDuringARunningPauseThatFailsResumesNothing() async {
        let mock = SuspendingMockVirtualizationService()
        mock.pauseError = VirtualizationError.noVirtualMachine
        let (coordinator, instance, session, sleep, wake) = await wakeDuringAParkedPause(mock)
        #expect(instance.activity.queuedFollowUpCountForTesting == 1)

        mock.resumeSuspended()
        await sleep.value
        await wake.value
        // The composition root holds the coordinator; the pass holds it weakly.
        withExtendedLifetime(coordinator) {}

        #expect(mock.resumeCallCount == 0)
        #expect(instance.phase == .running(sessionID: session))
        #expect(instance.activity.queuedFollowUpCountForTesting == 0)
        // Only the sleep pass's own report of the failed pause: the resume
        // the pause's ending refused is not reported.
        #expect(failures.errors.count == 1)
        #expect(failures.errorMessage?.contains("Failed to pause") == true)
    }
}
