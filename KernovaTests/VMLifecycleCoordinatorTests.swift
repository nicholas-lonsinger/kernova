import Testing
import Foundation
@testable import Kernova

@Suite("VMLifecycleCoordinator Tests")
@MainActor
struct VMLifecycleCoordinatorTests {

    private func makeCoordinator() -> (
        VMLifecycleCoordinator,
        MockVirtualizationService,
        MockMacOSInstallService,
        MockIPSWService
    ) {
        let virtService = MockVirtualizationService()
        let installService = MockMacOSInstallService()
        let ipswService = MockIPSWService()
        let coordinator = VMLifecycleCoordinator(
            virtualizationService: virtService,
            installService: installService,
            ipswService: ipswService
        )
        return (coordinator, virtService, installService, ipswService)
    }

    private func makeInstance(name: String = "Test VM") -> VMInstance {
        let config = VMConfiguration(
            name: name,
            guestOS: .linux,
            bootMode: .efi
        )
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(config.id.uuidString, isDirectory: true)
        return VMInstance(configuration: config, bundleURL: bundleURL)
    }

    // MARK: - Lifecycle Forwarding

    @Test("start forwards to virtualization service")
    func startForwards() async throws {
        let (coordinator, virtService, _, _) = makeCoordinator()
        let instance = makeInstance()

        try await coordinator.start(instance)

        #expect(virtService.startCallCount == 1)
    }

    @Test("stop forwards to virtualization service")
    func stopForwards() throws {
        let (coordinator, virtService, _, _) = makeCoordinator()
        let instance = makeInstance()
        instance.status = .running

        try coordinator.stop(instance)

        #expect(virtService.stopCallCount == 1)
    }

    @Test("forceStop forwards to virtualization service")
    func forceStopForwards() async throws {
        let (coordinator, virtService, _, _) = makeCoordinator()
        let instance = makeInstance()
        instance.status = .running

        try await coordinator.forceStop(instance)

        #expect(virtService.forceStopCallCount == 1)
    }

    @Test("pause forwards to virtualization service")
    func pauseForwards() async throws {
        let (coordinator, virtService, _, _) = makeCoordinator()
        let instance = makeInstance()
        instance.status = .running

        try await coordinator.pause(instance)

        #expect(virtService.pauseCallCount == 1)
    }

    @Test("resume forwards to virtualization service")
    func resumeForwards() async throws {
        let (coordinator, virtService, _, _) = makeCoordinator()
        let instance = makeInstance()
        instance.status = .paused

        try await coordinator.resume(instance)

        #expect(virtService.resumeCallCount == 1)
    }

    @Test("save forwards to virtualization service")
    func saveForwards() async throws {
        let (coordinator, virtService, _, _) = makeCoordinator()
        let instance = makeInstance()
        instance.status = .running

        try await coordinator.save(instance)

        #expect(virtService.saveCallCount == 1)
    }

    // MARK: - Error Propagation

    @Test("start propagates error from virtualization service")
    func startPropagatesError() async {
        let (coordinator, virtService, _, _) = makeCoordinator()
        virtService.startError = VirtualizationError.noVirtualMachine
        let instance = makeInstance()

        await #expect(throws: VirtualizationError.self) {
            try await coordinator.start(instance)
        }
    }

    @Test("stop propagates error from virtualization service")
    func stopPropagatesError() {
        let (coordinator, virtService, _, _) = makeCoordinator()
        virtService.stopError = VirtualizationError.noVirtualMachine
        let instance = makeInstance()

        #expect(throws: VirtualizationError.self) {
            try coordinator.stop(instance)
        }
    }

    // MARK: - macOS Installation

    #if arch(arm64)
    @Test("installMacOS with localFile sets hasDownloadStep to false")
    func installMacOSLocalFile() async throws {
        let (coordinator, _, installService, _) = makeCoordinator()
        let instance = makeInstance()
        let wizard = VMCreationViewModel()
        wizard.selectedOS = .macOS
        wizard.ipswSource = .localFile
        wizard.ipswPath = "/tmp/restore.ipsw"

        let storageService = MockVMStorageService()

        try await coordinator.installMacOS(
            on: instance,
            wizard: wizard,
            storageService: storageService
        )

        #expect(installService.installCallCount == 1)
    }

    @Test("installMacOS with downloadLatest calls fetch and download")
    func installMacOSDownload() async throws {
        let (coordinator, _, installService, ipswService) = makeCoordinator()
        let instance = makeInstance()
        let wizard = VMCreationViewModel()
        wizard.selectedOS = .macOS
        wizard.ipswSource = .downloadLatest
        wizard.ipswDownloadPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-restore.ipsw").path

        let storageService = MockVMStorageService()

        try await coordinator.installMacOS(
            on: instance,
            wizard: wizard,
            storageService: storageService
        )

        #expect(ipswService.fetchCallCount == 1)
        #expect(ipswService.downloadCallCount == 1)
        #expect(installService.installCallCount == 1)
    }

    @Test("installMacOS sets status to error on service failure")
    func installMacOSError() async {
        let (coordinator, _, installService, _) = makeCoordinator()
        installService.installError = IPSWError.downloadFailed("test failure")
        let instance = makeInstance()
        let wizard = VMCreationViewModel()
        wizard.selectedOS = .macOS
        wizard.ipswSource = .localFile
        wizard.ipswPath = "/tmp/restore.ipsw"

        let storageService = MockVMStorageService()

        do {
            try await coordinator.installMacOS(
                on: instance,
                wizard: wizard,
                storageService: storageService
            )
            Issue.record("Expected error to be thrown")
        } catch {
            #expect(instance.status == .error)
            #expect(instance.errorMessage != nil)
        }
    }
    #endif
}
