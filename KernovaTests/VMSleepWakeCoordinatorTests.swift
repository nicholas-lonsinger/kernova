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

    /// A VM the coordinator has actually paused for sleep — the only way into
    /// the resume set, which no caller writes directly.
    private func makeSleepPaused(
        _ coordinator: VMSleepWakeCoordinator, roster: StubVMInstanceRoster, name: String
    ) async -> VMInstance {
        let instance = VMInstanceFixture.make(name: name)
        instance.enter(.running(sessionID: UUID()))
        roster.instances.append(instance)
        await coordinator.pauseAllForSleep()
        return instance
    }

    // MARK: - Sleep/Wake

    @Test("pauseAllForSleep pauses only running VMs")
    func pauseAllForSleepPausesRunning() async {
        let (coordinator, roster, virtService) = makeCoordinator()
        let running1 = VMInstanceFixture.make(name: "Running 1")
        running1.enter(.running(sessionID: UUID()))
        let running2 = VMInstanceFixture.make(name: "Running 2")
        running2.enter(.running(sessionID: UUID()))
        let stopped = VMInstanceFixture.make(name: "Stopped")
        stopped.enter(.stopped)
        let paused = VMInstanceFixture.make(name: "User Paused")
        paused.enter(.suspended)
        roster.instances = [running1, running2, stopped, paused]

        await coordinator.pauseAllForSleep()

        #expect(virtService.pauseCallCount == 2)
        #expect(coordinator.sleepPausedInstanceIDs == Set([running1.id, running2.id]))
        #expect(running1.status == .paused)
        #expect(running2.status == .paused)
        #expect(stopped.status == .stopped)
        #expect(paused.status == .paused)
    }

    @Test("resumeAllAfterWake resumes only sleep-paused VMs")
    func resumeAllAfterWakeResumesOnlySleepPaused() async {
        let (coordinator, roster, virtService) = makeCoordinator()
        let userPaused = VMInstanceFixture.make(name: "User Paused")
        userPaused.enter(.suspended)
        roster.instances = [userPaused]
        let sleepPaused = await makeSleepPaused(coordinator, roster: roster, name: "Sleep Paused")

        await coordinator.resumeAllAfterWake()

        #expect(virtService.resumeCallCount == 1)
        #expect(sleepPaused.status == .running)
        #expect(userPaused.status == .paused)
        #expect(coordinator.sleepPausedInstanceIDs.isEmpty)
    }

    @Test("pauseAllForSleep handles pause failure gracefully")
    func pauseAllForSleepHandlesError() async {
        let virtService = MockVirtualizationService()
        virtService.pauseError = VirtualizationError.noVirtualMachine
        let (coordinator, roster, _) = makeCoordinator(virtualizationService: virtService)
        let running = VMInstanceFixture.make(name: "Running")
        running.enter(.running(sessionID: UUID()))
        roster.instances = [running]

        await coordinator.pauseAllForSleep()

        // Error is surfaced to the user
        #expect(failures.showError == true)
        #expect(failures.errorMessage?.contains("Running") == true)
        // Failed pause should not track the instance
        #expect(coordinator.sleepPausedInstanceIDs.isEmpty)
    }

    @Test("resumeAllAfterWake clears tracking set even on failure")
    func resumeAllAfterWakeClearsOnError() async {
        let virtService = MockVirtualizationService()
        let (coordinator, roster, _) = makeCoordinator(virtualizationService: virtService)
        _ = await makeSleepPaused(coordinator, roster: roster, name: "Sleep Paused")
        virtService.resumeError = VirtualizationError.noVirtualMachine

        await coordinator.resumeAllAfterWake()

        #expect(coordinator.sleepPausedInstanceIDs.isEmpty)
        // Error is surfaced to the user
        #expect(failures.showError == true)
        #expect(failures.errorMessage?.contains("Sleep Paused") == true)
    }

    @Test("pauseAllForSleep is no-op when no running VMs")
    func pauseAllForSleepNoOp() async {
        let (coordinator, roster, virtService) = makeCoordinator()
        let stopped = VMInstanceFixture.make(name: "Stopped")
        stopped.enter(.stopped)
        roster.instances = [stopped]

        await coordinator.pauseAllForSleep()

        #expect(virtService.pauseCallCount == 0)
        #expect(coordinator.sleepPausedInstanceIDs.isEmpty)
    }

    @Test("resumeAllAfterWake is no-op when no sleep-paused VMs")
    func resumeAllAfterWakeNoOp() async {
        let (coordinator, roster, virtService) = makeCoordinator()
        let paused = VMInstanceFixture.make(name: "User Paused")
        paused.enter(.suspended)
        roster.instances = [paused]
        // sleepPausedInstanceIDs is empty

        await coordinator.resumeAllAfterWake()

        #expect(virtService.resumeCallCount == 0)
    }

    @Test("pauseAllForSleep skips non-running states")
    func pauseAllForSleepSkipsNonRunning() async {
        let (coordinator, roster, virtService) = makeCoordinator()
        let starting = VMInstanceFixture.make(name: "Starting")
        starting.enter(.starting(sessionID: nil))
        let saving = VMInstanceFixture.make(name: "Saving")
        saving.enter(.saving(sessionID: UUID()))
        let error = VMInstanceFixture.make(name: "Error")
        error.enter(.failed(message: "Test failure"))
        roster.instances = [starting, saving, error]

        await coordinator.pauseAllForSleep()

        #expect(virtService.pauseCallCount == 0)
        #expect(coordinator.sleepPausedInstanceIDs.isEmpty)
    }

    @Test("resumeAllAfterWake skips VMs no longer paused")
    func resumeAllAfterWakeSkipsNonPaused() async {
        let (coordinator, roster, virtService) = makeCoordinator()
        let instance = await makeSleepPaused(coordinator, roster: roster, name: "Was Paused")
        instance.enter(.stopped)  // Status changed between sleep and wake

        await coordinator.resumeAllAfterWake()

        #expect(virtService.resumeCallCount == 0)
        #expect(coordinator.sleepPausedInstanceIDs.isEmpty)
    }
}
