import Foundation
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
            lifecycle: VMLifecycleCoordinator(
                virtualizationService: virtualizationService,
                installService: MockMacOSInstallService(),
                ipswService: MockIPSWService(),
                usbDeviceService: MockUSBDeviceService(),
                linuxImageResolveService: MockLinuxImageResolveService(),
                downloadService: MockDownloadService(),
                fileSystem: fileSystem,
                downloadsDirectory: nil
            ),
            roster: roster
        )
        coordinator.onFailure = { [failures] error in
            failures.record(title: "Error", message: error.localizedDescription)
        }
        return (coordinator, roster, virtualizationService)
    }

    private func makeInstance(name: String = "Test VM") -> VMInstance {
        let config = VMConfiguration(name: name, guestOS: .linux, bootMode: .efi)
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(config.id.uuidString, isDirectory: true)
        return VMInstance(configuration: config, bundleURL: bundleURL)
    }

    /// A VM the coordinator has actually paused for sleep — the only way into
    /// the resume set, which no caller writes directly.
    private func makeSleepPaused(
        _ coordinator: VMSleepWakeCoordinator, roster: StubVMInstanceRoster, name: String
    ) async -> VMInstance {
        let instance = makeInstance(name: name)
        instance.enter(.running(sessionID: UUID()))
        roster.instances.append(instance)
        await coordinator.pauseAllForSleep()
        return instance
    }

    // MARK: - Sleep/Wake

    @Test("pauseAllForSleep pauses only running VMs")
    func pauseAllForSleepPausesRunning() async {
        let (coordinator, roster, virtService) = makeCoordinator()
        let running1 = makeInstance(name: "Running 1")
        running1.enter(.running(sessionID: UUID()))
        let running2 = makeInstance(name: "Running 2")
        running2.enter(.running(sessionID: UUID()))
        let stopped = makeInstance(name: "Stopped")
        stopped.enter(.stopped)
        let paused = makeInstance(name: "User Paused")
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
        let userPaused = makeInstance(name: "User Paused")
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
        let running = makeInstance(name: "Running")
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
        let stopped = makeInstance(name: "Stopped")
        stopped.enter(.stopped)
        roster.instances = [stopped]

        await coordinator.pauseAllForSleep()

        #expect(virtService.pauseCallCount == 0)
        #expect(coordinator.sleepPausedInstanceIDs.isEmpty)
    }

    @Test("resumeAllAfterWake is no-op when no sleep-paused VMs")
    func resumeAllAfterWakeNoOp() async {
        let (coordinator, roster, virtService) = makeCoordinator()
        let paused = makeInstance(name: "User Paused")
        paused.enter(.suspended)
        roster.instances = [paused]
        // sleepPausedInstanceIDs is empty

        await coordinator.resumeAllAfterWake()

        #expect(virtService.resumeCallCount == 0)
    }

    @Test("pauseAllForSleep skips non-running states")
    func pauseAllForSleepSkipsNonRunning() async {
        let (coordinator, roster, virtService) = makeCoordinator()
        let starting = makeInstance(name: "Starting")
        starting.enter(.starting(sessionID: nil))
        let saving = makeInstance(name: "Saving")
        saving.enter(.saving(sessionID: UUID()))
        let error = makeInstance(name: "Error")
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
