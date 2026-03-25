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
        MockIPSWService,
        MockUSBDeviceService
    ) {
        let virtService = MockVirtualizationService()
        let installService = MockMacOSInstallService()
        let ipswService = MockIPSWService()
        let usbService = MockUSBDeviceService()
        let coordinator = VMLifecycleCoordinator(
            virtualizationService: virtService,
            installService: installService,
            ipswService: ipswService,
            usbDeviceService: usbService
        )
        return (coordinator, virtService, installService, ipswService, usbService)
    }

    private func makeSuspendingCoordinator() -> (
        VMLifecycleCoordinator,
        SuspendingMockVirtualizationService
    ) {
        let suspendingService = SuspendingMockVirtualizationService()
        let coordinator = VMLifecycleCoordinator(
            virtualizationService: suspendingService,
            installService: MockMacOSInstallService(),
            ipswService: MockIPSWService(),
            usbDeviceService: MockUSBDeviceService()
        )
        return (coordinator, suspendingService)
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
        let (coordinator, virtService, _, _, _) = makeCoordinator()
        let instance = makeInstance()

        try await coordinator.start(instance)

        #expect(virtService.startCallCount == 1)
    }

    @Test("stop forwards to virtualization service")
    func stopForwards() throws {
        let (coordinator, virtService, _, _, _) = makeCoordinator()
        let instance = makeInstance()
        instance.status = .running

        try coordinator.stop(instance)

        #expect(virtService.stopCallCount == 1)
    }

    @Test("forceStop forwards to virtualization service")
    func forceStopForwards() async throws {
        let (coordinator, virtService, _, _, _) = makeCoordinator()
        let instance = makeInstance()
        instance.status = .running

        try await coordinator.forceStop(instance)

        #expect(virtService.forceStopCallCount == 1)
    }

    @Test("pause forwards to virtualization service")
    func pauseForwards() async throws {
        let (coordinator, virtService, _, _, _) = makeCoordinator()
        let instance = makeInstance()
        instance.status = .running

        try await coordinator.pause(instance)

        #expect(virtService.pauseCallCount == 1)
    }

    @Test("resume forwards to virtualization service")
    func resumeForwards() async throws {
        let (coordinator, virtService, _, _, _) = makeCoordinator()
        let instance = makeInstance()
        instance.status = .paused

        try await coordinator.resume(instance)

        #expect(virtService.resumeCallCount == 1)
    }

    @Test("save forwards to virtualization service")
    func saveForwards() async throws {
        let (coordinator, virtService, _, _, _) = makeCoordinator()
        let instance = makeInstance()
        instance.status = .running

        try await coordinator.save(instance)

        #expect(virtService.saveCallCount == 1)
    }

    // MARK: - Error Propagation

    @Test("start propagates error from virtualization service")
    func startPropagatesError() async {
        let (coordinator, virtService, _, _, _) = makeCoordinator()
        virtService.startError = VirtualizationError.noVirtualMachine
        let instance = makeInstance()

        await #expect(throws: VirtualizationError.self) {
            try await coordinator.start(instance)
        }
    }

    @Test("stop propagates error from virtualization service")
    func stopPropagatesError() {
        let (coordinator, virtService, _, _, _) = makeCoordinator()
        virtService.stopError = VirtualizationError.noVirtualMachine
        let instance = makeInstance()

        #expect(throws: VirtualizationError.self) {
            try coordinator.stop(instance)
        }
    }

    // MARK: - Operation Serialization

    @Test("hasActiveOperation returns false when no operation is running")
    func hasActiveOperationInitiallyFalse() {
        let (coordinator, _, _, _, _) = makeCoordinator()
        let instance = makeInstance()

        #expect(!coordinator.hasActiveOperation(for: instance.id))
    }

    @Test("hasActiveOperation returns true during an in-flight operation")
    func hasActiveOperationTrueDuringOperation() async throws {
        let (coordinator, suspendingService) = makeSuspendingCoordinator()
        let instance = makeInstance()

        // Start an operation that will suspend
        let task = Task { @MainActor in
            try await coordinator.start(instance)
        }

        // Wait for the operation to begin (the mock will signal via its continuation)
        await suspendingService.waitUntilSuspended()

        #expect(coordinator.hasActiveOperation(for: instance.id))

        // Let the operation complete
        suspendingService.resumeSuspended()
        try await task.value
    }

    @Test("concurrent operation on the same VM throws operationInProgress")
    func rejectsConcurrentOperationOnSameVM() async throws {
        let (coordinator, suspendingService) = makeSuspendingCoordinator()
        let instance = makeInstance()

        // Start an operation that will suspend
        let task = Task { @MainActor in
            try await coordinator.start(instance)
        }

        await suspendingService.waitUntilSuspended()

        // A second operation on the same VM should be rejected
        await #expect(throws: VMLifecycleCoordinator.LifecycleError.self) {
            try await coordinator.pause(instance)
        }

        // Clean up
        suspendingService.resumeSuspended()
        try await task.value
    }

    @Test("operations on different VMs are allowed concurrently")
    func allowsConcurrentOperationsOnDifferentVMs() async throws {
        let (coordinator, suspendingService) = makeSuspendingCoordinator()
        let instance1 = makeInstance(name: "VM 1")
        let instance2 = makeInstance(name: "VM 2")

        // Start an operation on instance1 that suspends
        let task = Task { @MainActor in
            try await coordinator.start(instance1)
        }

        await suspendingService.waitUntilSuspended()

        // A different VM should still be able to start (uses regular mock behavior for second call)
        suspendingService.shouldSuspendOnStart = false
        try await coordinator.start(instance2)

        // Clean up
        suspendingService.resumeSuspended()
        try await task.value
    }

    @Test("lock is released after operation completes successfully")
    func lockReleasedAfterSuccess() async throws {
        let (coordinator, _, _, _, _) = makeCoordinator()
        let instance = makeInstance()

        try await coordinator.start(instance)
        #expect(!coordinator.hasActiveOperation(for: instance.id))

        // A second operation should succeed
        instance.status = .running
        try await coordinator.pause(instance)
        #expect(!coordinator.hasActiveOperation(for: instance.id))
    }

    @Test("lock is released after operation fails")
    func lockReleasedAfterError() async throws {
        let (coordinator, virtService, _, _, _) = makeCoordinator()
        virtService.startError = VirtualizationError.noVirtualMachine
        let instance = makeInstance()

        await #expect(throws: VirtualizationError.self) {
            try await coordinator.start(instance)
        }

        #expect(!coordinator.hasActiveOperation(for: instance.id))

        // Should be able to retry after failure
        virtService.startError = nil
        try await coordinator.start(instance)
        #expect(virtService.startCallCount == 2)
    }

    @Test("stop bypasses serialization during an active operation")
    func stopBypassesSerializationDuringActiveOperation() async throws {
        let (coordinator, suspendingService) = makeSuspendingCoordinator()
        let instance = makeInstance()

        // Start an operation that will suspend
        let task = Task { @MainActor in
            try await coordinator.start(instance)
        }

        await suspendingService.waitUntilSuspended()
        #expect(coordinator.hasActiveOperation(for: instance.id))

        // Stop should succeed even though start is in flight
        try coordinator.stop(instance)

        // Active operation flag should be cleared by stop
        #expect(!coordinator.hasActiveOperation(for: instance.id))

        // Clean up — let the suspended start complete
        suspendingService.resumeSuspended()
        _ = try? await task.value
    }

    @Test("forceStop bypasses serialization during an active operation")
    func forceStopBypassesSerializationDuringActiveOperation() async throws {
        let (coordinator, suspendingService) = makeSuspendingCoordinator()
        let instance = makeInstance()

        // Start an operation that will suspend
        let task = Task { @MainActor in
            try await coordinator.start(instance)
        }

        await suspendingService.waitUntilSuspended()
        #expect(coordinator.hasActiveOperation(for: instance.id))

        // Force stop should succeed even though start is in flight
        try await coordinator.forceStop(instance)

        // Active operation flag should be cleared by forceStop
        #expect(!coordinator.hasActiveOperation(for: instance.id))

        // Clean up
        suspendingService.resumeSuspended()
        _ = try? await task.value
    }

    @Test("stop does not affect active operation tracking")
    func stopDoesNotAffectActiveOperationTracking() throws {
        let (coordinator, virtService, _, _, _) = makeCoordinator()
        let instance = makeInstance()
        instance.status = .running

        try coordinator.stop(instance)
        #expect(!coordinator.hasActiveOperation(for: instance.id))
        #expect(virtService.stopCallCount == 1)
    }

    @Test("stop error does not affect active operation tracking")
    func stopErrorDoesNotAffectActiveOperationTracking() async throws {
        let (coordinator, virtService, _, _, _) = makeCoordinator()
        virtService.stopError = VirtualizationError.noVirtualMachine
        let instance = makeInstance()

        #expect(throws: VirtualizationError.self) {
            try coordinator.stop(instance)
        }

        #expect(!coordinator.hasActiveOperation(for: instance.id))

        // Should be able to start after failed stop
        try await coordinator.start(instance)
        #expect(virtService.startCallCount == 1)
    }

    @Test("token prevents stale defer from clobbering after stop clears entry")
    func tokenPreventsStaleRemoval() async throws {
        let (coordinator, suspendingService) = makeSuspendingCoordinator()
        let instance = makeInstance()

        // Start an operation that will suspend (acquires token A)
        let task = Task { @MainActor in
            try await coordinator.start(instance)
        }

        await suspendingService.waitUntilSuspended()
        #expect(coordinator.hasActiveOperation(for: instance.id))

        // Stop clears the active operation entry (invalidating token A)
        try coordinator.stop(instance)
        #expect(!coordinator.hasActiveOperation(for: instance.id))

        // Resume the suspended start — its defer should NOT re-clear the entry
        // because its token no longer matches
        suspendingService.resumeSuspended()
        _ = try? await task.value

        // Now start a new operation — this should succeed because
        // the stale defer didn't clobber anything
        suspendingService.shouldSuspendOnStart = false
        try await coordinator.start(instance)
        #expect(!coordinator.hasActiveOperation(for: instance.id))
    }

    // MARK: - macOS Installation

    #if arch(arm64)
    @Test("installMacOS with localFile sets hasDownloadStep to false")
    func installMacOSLocalFile() async throws {
        let (coordinator, _, installService, _, _) = makeCoordinator()
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
        let (coordinator, _, installService, ipswService, _) = makeCoordinator()
        let instance = makeInstance()
        let wizard = VMCreationViewModel()
        wizard.selectedOS = .macOS
        wizard.ipswSource = .downloadLatest
        wizard.ipswDownloadPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-restore.ipsw").path(percentEncoded: false)

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
        let (coordinator, _, installService, _, _) = makeCoordinator()
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

    // MARK: - USB Device Pass-Through

    @Test("attachUSBDevice forwards to USB device service")
    func attachUSBDeviceForwards() async throws {
        let (coordinator, _, _, _, usbService) = makeCoordinator()
        let instance = makeInstance()

        let info = try await coordinator.attachUSBDevice(
            diskImagePath: "/tmp/test.dmg",
            readOnly: true,
            to: instance
        )

        #expect(usbService.attachCallCount == 1)
        #expect(usbService.lastAttachedPath == "/tmp/test.dmg")
        #expect(usbService.lastAttachedReadOnly == true)
        #expect(info.path == "/tmp/test.dmg")
        #expect(info.readOnly == true)
    }

    @Test("detachUSBDevice forwards to USB device service")
    func detachUSBDeviceForwards() async throws {
        let (coordinator, _, _, _, usbService) = makeCoordinator()
        let instance = makeInstance()

        let info = try await coordinator.attachUSBDevice(
            diskImagePath: "/tmp/test.dmg",
            readOnly: false,
            to: instance
        )

        try await coordinator.detachUSBDevice(info, from: instance)

        #expect(usbService.detachCallCount == 1)
        #expect(instance.attachedUSBDevices.isEmpty)
    }

    @Test("attachUSBDevice propagates error from USB device service")
    func attachUSBDevicePropagatesError() async {
        let (coordinator, _, _, _, usbService) = makeCoordinator()
        usbService.attachError = USBDeviceError.noVirtualMachine
        let instance = makeInstance()

        await #expect(throws: USBDeviceError.self) {
            try await coordinator.attachUSBDevice(
                diskImagePath: "/tmp/test.dmg",
                readOnly: false,
                to: instance
            )
        }
    }

    @Test("detachUSBDevice propagates error from USB device service")
    func detachUSBDevicePropagatesError() async throws {
        let (coordinator, _, _, _, usbService) = makeCoordinator()
        let instance = makeInstance()

        let info = try await coordinator.attachUSBDevice(
            diskImagePath: "/tmp/test.dmg",
            readOnly: false,
            to: instance
        )

        usbService.detachError = USBDeviceError.deviceNotFound

        await #expect(throws: USBDeviceError.self) {
            try await coordinator.detachUSBDevice(info, from: instance)
        }

        // Device should still be tracked since detach failed
        #expect(instance.attachedUSBDevices.count == 1)
    }
}
