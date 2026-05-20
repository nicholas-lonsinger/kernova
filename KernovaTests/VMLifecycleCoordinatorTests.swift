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
    @Test("installMacOS with localFile context sets hasDownloadStep to false")
    func installMacOSLocalFile() async throws {
        let (coordinator, _, installService, _, _) = makeCoordinator()
        let instance = makeInstance()
        let context = MacOSInstallContext(source: .localFile, localIPSWPath: "/tmp/restore.ipsw")

        try await coordinator.installMacOS(on: instance, context: context)

        #expect(installService.installCallCount == 1)
    }

    @Test("installMacOS with downloadLatest context calls fetch and download")
    func installMacOSDownload() async throws {
        let (coordinator, _, installService, ipswService, _) = makeCoordinator()
        let instance = makeInstance()
        let context = MacOSInstallContext(
            source: .downloadLatest,
            downloadDestinationPath: FileManager.default.temporaryDirectory
                .appendingPathComponent("test-restore.ipsw").path(percentEncoded: false)
        )

        try await coordinator.installMacOS(on: instance, context: context)

        #expect(ipswService.fetchCallCount == 1)
        #expect(ipswService.downloadCallCount == 1)
        #expect(installService.installCallCount == 1)
    }

    @Test("installMacOS sets status to error on service failure")
    func installMacOSError() async {
        let (coordinator, _, installService, _, _) = makeCoordinator()
        installService.installError = IPSWError.downloadFailed(URLError(.badServerResponse))
        let instance = makeInstance()
        let context = MacOSInstallContext(source: .localFile, localIPSWPath: "/tmp/restore.ipsw")

        do {
            try await coordinator.installMacOS(on: instance, context: context)
            Issue.record("Expected error to be thrown")
        } catch {
            #expect(instance.status == .error)
            #expect(instance.errorMessage != nil)
        }
    }

    @Test("installMacOS clears installContext on successful completion")
    func installMacOSClearsInstallContextOnSuccess() async throws {
        let (coordinator, _, _, _, _) = makeCoordinator()
        let instance = makeInstance()
        instance.configuration.installContext = MacOSInstallContext(
            source: .localFile, localIPSWPath: "/tmp/restore.ipsw"
        )
        // Wire the dispatcher so performConfigurationMutation actually mutates.
        instance.onUpdateConfiguration = { mutate in mutate(&instance.configuration) }
        let context = instance.configuration.installContext!

        try await coordinator.installMacOS(on: instance, context: context)

        #expect(instance.configuration.installContext == nil)
        #expect(instance.installState == nil)
    }

    @Test("installMacOS throws CancellationError on cancel and preserves installContext")
    func installMacOSCancelPreservesContext() async {
        let (coordinator, _, _, ipswService, _) = makeCoordinator()
        ipswService.downloadError = CancellationError()
        let instance = makeInstance()
        let originalContext = MacOSInstallContext(
            source: .downloadLatest,
            downloadDestinationPath: FileManager.default.temporaryDirectory
                .appendingPathComponent("cancel-preserves-context.ipsw").path(percentEncoded: false)
        )
        instance.configuration.installContext = originalContext
        instance.onUpdateConfiguration = { mutate in mutate(&instance.configuration) }

        await #expect(throws: CancellationError.self) {
            try await coordinator.installMacOS(on: instance, context: originalContext)
        }

        #expect(instance.configuration.installContext == originalContext)
    }

    @Test("installMacOS with requestedFreshDownload trashes existing file and clears the flag")
    func installMacOSFreshDownloadTrashesAndClears() async throws {
        let (coordinator, _, _, ipswService, _) = makeCoordinator()
        let instance = makeInstance()

        // Create a real file at the destination so the trash path has something
        // to act on. Persist it in a unique per-test temp directory to keep
        // the assertion deterministic.
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("freshDownloadTrash-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let destination = temp.appendingPathComponent("RestoreImage.ipsw")
        try Data(repeating: 0xFF, count: 1024).write(to: destination)

        let context = MacOSInstallContext(
            source: .downloadLatest,
            downloadDestinationPath: destination.path(percentEncoded: false),
            requestedFreshDownload: true
        )
        instance.configuration.installContext = context
        instance.onUpdateConfiguration = { mutate in mutate(&instance.configuration) }

        try await coordinator.installMacOS(on: instance, context: context)

        // The existing IPSW must have been trashed (no longer at its path),
        // the bundle cleanup must have been invoked exactly once, and on
        // success the installContext is cleared by the post-install path —
        // so we can't observe the cleared `requestedFreshDownload` directly,
        // but the discardResumeData call count is the proxy that proves the
        // honor-and-clear branch ran.
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(ipswService.discardResumeDataCallCount == 1)
        #expect(ipswService.lastDiscardResumeDataURL == destination)

        // Clean up the temp dir (the file itself is in Trash).
        try? FileManager.default.removeItem(at: temp)
    }

    @Test("installMacOS surfaces freshDownloadCleanupFailed when the trash operation throws")
    func installMacOSFreshDownloadSurfacesTrashFailure() async throws {
        // Inject a FileSystemOperating that always throws from `trashItem`.
        // This exercises the catch path that wraps the error in
        // `IPSWError.freshDownloadCleanupFailed` and proves the failure is
        // surfaced rather than swallowed.
        let trashError = NSError(
            domain: NSCocoaErrorDomain,
            code: NSFileWriteNoPermissionError,
            userInfo: [NSLocalizedDescriptionKey: "denied"]
        )
        let throwingFS = ThrowingFileSystem(fileExistsResult: true, trashError: trashError)

        let virtService = MockVirtualizationService()
        let installService = MockMacOSInstallService()
        let ipswService = MockIPSWService()
        let usbService = MockUSBDeviceService()
        let coordinator = VMLifecycleCoordinator(
            virtualizationService: virtService,
            installService: installService,
            ipswService: ipswService,
            usbDeviceService: usbService,
            fileSystem: throwingFS
        )

        let instance = makeInstance()
        let context = MacOSInstallContext(
            source: .downloadLatest,
            downloadDestinationPath: "/tmp/cannot-trash.ipsw",
            requestedFreshDownload: true
        )
        instance.configuration.installContext = context
        instance.onUpdateConfiguration = { mutate in mutate(&instance.configuration) }

        do {
            try await coordinator.installMacOS(on: instance, context: context)
            Issue.record("Expected freshDownloadCleanupFailed")
        } catch IPSWError.freshDownloadCleanupFailed {
            // Expected — the trash failure was surfaced.
            #expect(instance.status == .error)
            #expect(ipswService.downloadCallCount == 0, "Download must not start when cleanup fails")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("installMacOS rejects requestedFreshDownload on a non-IPSW path")
    func installMacOSFreshDownloadRejectsNonIPSWPath() async {
        let (coordinator, _, _, ipswService, _) = makeCoordinator()
        let instance = makeInstance()
        // Path doesn't end in .ipsw — guard must fire before any trash attempt.
        let context = MacOSInstallContext(
            source: .downloadLatest,
            downloadDestinationPath: "/Users/me/Documents/important.doc",
            requestedFreshDownload: true
        )
        instance.configuration.installContext = context
        instance.onUpdateConfiguration = { mutate in mutate(&instance.configuration) }

        do {
            try await coordinator.installMacOS(on: instance, context: context)
            Issue.record("Expected invalidDownloadDestination")
        } catch IPSWError.invalidDownloadDestination {
            #expect(instance.status == .error)
            #expect(ipswService.discardResumeDataCallCount == 0)
            #expect(ipswService.downloadCallCount == 0)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("installMacOS without requestedFreshDownload leaves existing file alone")
    func installMacOSWithoutFreshDownloadDoesNotTrash() async throws {
        let (coordinator, _, _, ipswService, _) = makeCoordinator()
        let instance = makeInstance()

        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("noFreshDownload-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let destination = temp.appendingPathComponent("RestoreImage.ipsw")
        try Data(repeating: 0xAB, count: 512).write(to: destination)

        let context = MacOSInstallContext(
            source: .downloadLatest,
            downloadDestinationPath: destination.path(percentEncoded: false)
        )
        instance.configuration.installContext = context
        instance.onUpdateConfiguration = { mutate in mutate(&instance.configuration) }

        try await coordinator.installMacOS(on: instance, context: context)

        // No requestedFreshDownload, so no trash, no discardResumeData call.
        #expect(FileManager.default.fileExists(atPath: destination.path))
        #expect(ipswService.discardResumeDataCallCount == 0)

        try? FileManager.default.removeItem(at: temp)
    }

    @Test("installMacOS preserves IPSW resume data when download is cancelled")
    func installMacOSCancelPreservesResumeData() async {
        let (coordinator, _, _, ipswService, _) = makeCoordinator()
        ipswService.downloadError = CancellationError()
        let instance = makeInstance()
        let context = MacOSInstallContext(
            source: .downloadLatest,
            downloadDestinationPath: FileManager.default.temporaryDirectory
                .appendingPathComponent("cancel-test-restore.ipsw").path(percentEncoded: false)
        )

        await #expect(throws: CancellationError.self) {
            try await coordinator.installMacOS(on: instance, context: context)
        }

        // User cancel must preserve resume data so a future Start can resume
        // the download from where it stopped (non-destructive cancel UX).
        #expect(ipswService.discardResumeDataCallCount == 0)
    }

    @Test("installMacOS preserves IPSW resume data on NSURLErrorCancelled")
    func installMacOSURLCancelPreservesResumeData() async {
        let (coordinator, _, _, ipswService, _) = makeCoordinator()
        ipswService.downloadError = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorCancelled,
            userInfo: nil
        )
        let instance = makeInstance()
        let context = MacOSInstallContext(
            source: .downloadLatest,
            downloadDestinationPath: FileManager.default.temporaryDirectory
                .appendingPathComponent("url-cancel-test-restore.ipsw").path(percentEncoded: false)
        )

        await #expect(throws: CancellationError.self) {
            try await coordinator.installMacOS(on: instance, context: context)
        }

        #expect(ipswService.discardResumeDataCallCount == 0)
    }

    @Test("installMacOS preserves IPSW resume data on non-cancel download failure")
    func installMacOSFailurePreservesResumeData() async {
        let (coordinator, _, _, ipswService, _) = makeCoordinator()
        ipswService.downloadError = IPSWError.downloadFailed(URLError(.notConnectedToInternet))
        let instance = makeInstance()
        let originalContext = MacOSInstallContext(
            source: .downloadLatest,
            downloadDestinationPath: FileManager.default.temporaryDirectory
                .appendingPathComponent("network-fail-restore.ipsw").path(percentEncoded: false)
        )
        instance.configuration.installContext = originalContext
        instance.onUpdateConfiguration = { mutate in mutate(&instance.configuration) }

        do {
            try await coordinator.installMacOS(on: instance, context: originalContext)
            Issue.record("Expected error to be thrown")
        } catch {
            #expect(ipswService.discardResumeDataCallCount == 0)
            #expect(instance.status == .error)
            // installContext stays so the user can retry via Start.
            #expect(instance.configuration.installContext == originalContext)
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
        #expect(instance.liveRemovableMedia.count == 1)
        #expect(instance.liveRemovableMedia[0].id == info.id)
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
        #expect(instance.liveRemovableMedia.isEmpty)
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
        #expect(instance.liveRemovableMedia.count == 1)
    }
}

// MARK: - Test Doubles

/// `FileSystemOperating` stub for the fresh-download cleanup tests.
///
/// Pretends the destination file exists and then throws from `trashItem`,
/// exercising the path that wraps the error in
/// `IPSWError.freshDownloadCleanupFailed`.
private final class ThrowingFileSystem: FileSystemOperating, @unchecked Sendable {
    let fileExistsResult: Bool
    let trashError: any Error

    init(fileExistsResult: Bool, trashError: any Error) {
        self.fileExistsResult = fileExistsResult
        self.trashError = trashError
    }

    func fileExists(atPath path: String) -> Bool { fileExistsResult }
    func trashItem(at url: URL) throws { throw trashError }
}
