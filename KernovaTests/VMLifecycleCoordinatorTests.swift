import Testing
import Foundation
@testable import Kernova

@Suite("VMLifecycleCoordinator Tests")
@MainActor
struct VMLifecycleCoordinatorTests {
    /// `downloadsDirectory` moves the coordinator's Downloads-only destination
    /// invariant to a test-owned directory, so destination tests can name paths
    /// that must be honored without touching the user's Downloads.
    private func makeCoordinator(
        downloadsDirectory: URL? = nil
    ) -> (
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
            usbDeviceService: usbService,
            downloadsDirectory: downloadsDirectory
                ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
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
        #expect(virtService.lastStartBootIntoRecovery == false)
    }

    @Test("start forwards the bootIntoRecovery flag to the virtualization service")
    func startForwardsBootIntoRecovery() async throws {
        let (coordinator, virtService, _, _, _) = makeCoordinator()
        let instance = makeInstance()

        try await coordinator.start(instance, bootIntoRecovery: true)

        #expect(virtService.startCallCount == 1)
        #expect(virtService.lastStartBootIntoRecovery == true)
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

    @Test("installMacOS with a catalog context downloads the pinned URL, never the latest")
    func installMacOSCatalogUsesPinnedURL() async throws {
        let (coordinator, _, installService, ipswService, _) = makeCoordinator()
        let instance = makeInstance()
        let pinned = try #require(
            URL(string: "https://updates.cdn-apple.com/x/UniversalMac_15.6.1_24G90_Restore.ipsw"))
        let context = MacOSInstallContext(
            source: .catalogVersion,
            downloadDestinationPath: FileManager.default.temporaryDirectory
                .appendingPathComponent("UniversalMac_15.6.1_24G90_Restore.ipsw")
                .path(percentEncoded: false),
            remoteURL: pinned,
            version: "15.6.1",
            build: "24G90"
        )

        try await coordinator.installMacOS(on: instance, context: context)

        #expect(ipswService.fetchCallCount == 0)
        #expect(ipswService.downloadCallCount == 1)
        #expect(ipswService.lastDownloadRemoteURL == pinned)
        #expect(installService.installCallCount == 1)
    }

    @Test("installMacOS rejects a catalog context with no pinned URL")
    func installMacOSCatalogWithoutURLThrows() async {
        let (coordinator, _, _, ipswService, _) = makeCoordinator()
        let instance = makeInstance()
        let context = MacOSInstallContext(
            source: .catalogVersion,
            downloadDestinationPath: FileManager.default.temporaryDirectory
                .appendingPathComponent("test-restore.ipsw").path(percentEncoded: false)
        )

        await #expect(throws: IPSWError.self) {
            try await coordinator.installMacOS(on: instance, context: context)
        }
        // Never silently falls back to resolving the latest image.
        #expect(ipswService.fetchCallCount == 0)
    }

    @Test("A catalog destination outside Downloads falls back to the pinned image's filename")
    func normalizedDestinationKeepsPinnedFilename() throws {
        let (coordinator, _, _, _, _) = makeCoordinator()
        let elsewhere = URL(fileURLWithPath: "/Users/Shared/UniversalMac_15.6.1_24G90_Restore.ipsw")
        let pinned = try #require(
            URL(string: "https://updates.cdn-apple.com/x/UniversalMac_15.6.1_24G90_Restore.ipsw"))

        let normalized = coordinator.normalizedDownloadDestination(
            for: elsewhere, remoteURL: pinned)

        #expect(normalized.lastPathComponent == "UniversalMac_15.6.1_24G90_Restore.ipsw")
        #expect(
            normalized.path(percentEncoded: false) != VMCreationViewModel.defaultIPSWDownloadPath)
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

    @Test("installMacOS returns the VM to .initialBoot on a transient failure")
    func installMacOSTransientFailureReturnsToInitialBoot() async {
        let (coordinator, _, installService, _, _) = makeCoordinator()
        installService.installError = makeInstallVMLimitExceededError()
        let instance = makeInstance()
        instance.errorMessage = "stale message from an earlier failure"
        let context = MacOSInstallContext(source: .localFile, localIPSWPath: "/tmp/restore.ipsw")
        instance.configuration.installContext = context
        instance.onUpdateConfiguration = { mutate in mutate(&instance.configuration) }

        await #expect(throws: (any Error).self) {
            try await coordinator.installMacOS(on: instance, context: context)
        }

        #expect(instance.status == .initialBoot)
        #expect(instance.errorMessage == nil)
        // Retrying is the remedy, so the intent that drives the retry survives.
        #expect(instance.configuration.installContext == context)
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

    @Test("installMacOS asks the download to replace what is at the destination")
    func installMacOSFreshDownloadDelegatesTheDiscard() async throws {
        // The disposal belongs to the download, which holds the destination's
        // claim while it runs — trashing from the coordinator could reach a
        // bundle another VM is streaming into.
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("freshDownloadTrash-\(UUID().uuidString)", isDirectory: true)
        let (coordinator, _, _, ipswService, _) = makeCoordinator(downloadsDirectory: temp)
        let instance = makeInstance()

        let destination = temp.appendingPathComponent("RestoreImage.ipsw")

        let context = MacOSInstallContext(
            source: .downloadLatest,
            downloadDestinationPath: destination.path(percentEncoded: false),
            requestedFreshDownload: true
        )
        instance.configuration.installContext = context
        instance.onUpdateConfiguration = { mutate in mutate(&instance.configuration) }

        try await coordinator.installMacOS(on: instance, context: context)

        #expect(ipswService.lastDownloadDiscardsExisting == true)
        #expect(ipswService.lastDownloadDestinationURL == destination)
        // Nothing is trashed outside the download's claim.
        #expect(ipswService.discardResumeDataCallCount == 0)
    }

    @Test("installMacOS clears requestedFreshDownload before the download runs")
    func installMacOSFreshDownloadClearsTheFlagOnce() async {
        // A download that fails leaves the context for the retry Start — with
        // the flag already spent, so the retry resumes the partial rather than
        // trashing it and starting over.
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("freshDownloadOnce-\(UUID().uuidString)", isDirectory: true)
        let (coordinator, _, _, ipswService, _) = makeCoordinator(downloadsDirectory: temp)
        ipswService.downloadError = IPSWError.downloadFailed(URLError(.notConnectedToInternet))
        let instance = makeInstance()

        let context = MacOSInstallContext(
            source: .downloadLatest,
            downloadDestinationPath: temp.appendingPathComponent("RestoreImage.ipsw")
                .path(percentEncoded: false),
            requestedFreshDownload: true
        )
        instance.configuration.installContext = context
        instance.onUpdateConfiguration = { mutate in mutate(&instance.configuration) }

        await #expect(throws: IPSWError.self) {
            try await coordinator.installMacOS(on: instance, context: context)
        }

        #expect(ipswService.lastDownloadDiscardsExisting == true)
        #expect(instance.configuration.installContext?.requestedFreshDownload == false)
    }

    @Test("installMacOS surfaces a cleanup failure raised by the download")
    func installMacOSFreshDownloadSurfacesTrashFailure() async {
        // The download reports that it could not clear the way for the
        // replacement; the install must fail rather than install the file the
        // user asked to replace.
        let (coordinator, _, installService, ipswService, _) = makeCoordinator()
        ipswService.downloadError = IPSWError.freshDownloadCleanupFailed(
            path: "/tmp/cannot-trash.ipsw",
            underlying: NSError(
                domain: NSCocoaErrorDomain,
                code: NSFileWriteNoPermissionError,
                userInfo: [NSLocalizedDescriptionKey: "denied"]
            )
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
            #expect(instance.status == .error)
            #expect(installService.installCallCount == 0, "Install must not run on a failed download")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("installMacOS rejects requestedFreshDownload on a non-IPSW path")
    func installMacOSFreshDownloadRejectsNonIPSWPath() async {
        // The non-IPSW file sits inside the (injected) Downloads directory —
        // an out-of-Downloads path would be normalized to the default
        // destination before this guard is reached.
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("rejectNonIPSW-\(UUID().uuidString)", isDirectory: true)
        let (coordinator, _, _, ipswService, _) = makeCoordinator(downloadsDirectory: temp)
        let instance = makeInstance()
        // Path doesn't end in .ipsw — guard must fire before any trash attempt.
        let context = MacOSInstallContext(
            source: .downloadLatest,
            downloadDestinationPath: temp.appendingPathComponent("important.doc")
                .path(percentEncoded: false),
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
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("noFreshDownload-\(UUID().uuidString)", isDirectory: true)
        let (coordinator, _, _, ipswService, _) = makeCoordinator(downloadsDirectory: temp)
        let instance = makeInstance()

        let context = MacOSInstallContext(
            source: .downloadLatest,
            downloadDestinationPath: temp.appendingPathComponent("RestoreImage.ipsw")
                .path(percentEncoded: false)
        )
        instance.configuration.installContext = context
        instance.onUpdateConfiguration = { mutate in mutate(&instance.configuration) }

        try await coordinator.installMacOS(on: instance, context: context)

        // Nothing at the destination is disturbed: the download resumes or
        // skips over whatever is already there.
        #expect(ipswService.lastDownloadDiscardsExisting == false)
        #expect(ipswService.discardResumeDataCallCount == 0)
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

    @Test("attachUSBDevice attaches the resolved URL but tracks the stored path")
    func attachUSBDeviceTracksStoredPathWithResolvedURL() async throws {
        let (coordinator, _, _, _, usbService) = makeCoordinator()
        let instance = makeInstance()

        // A bookmark that tracked a moved file: the resolved location is
        // what must reach the service, while the tracked identity stays the
        // config's stored path so the live reconcile's path comparison
        // doesn't churn.
        let info = try await coordinator.attachUSBDevice(
            diskImagePath: "/old/location/media.iso",
            readOnly: true,
            resolvedURL: URL(fileURLWithPath: "/new/location/media.iso"),
            to: instance
        )

        #expect(usbService.lastAttachedPath == "/new/location/media.iso")
        #expect(info.path == "/old/location/media.iso")
        #expect(instance.liveRemovableMedia.first?.path == "/old/location/media.iso")
    }

    // MARK: - Download Destination Normalization

    @Test("normalizedDownloadDestination keeps Downloads paths and redirects others to the default")
    func normalizedDownloadDestinationEnforcesDownloads() throws {
        let (coordinator, _, _, _, _) = makeCoordinator()
        let downloads = try #require(
            FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first)
        let inDownloads = downloads.appendingPathComponent("Custom.ipsw")
        #expect(coordinator.normalizedDownloadDestination(for: inDownloads) == inDownloads)

        // A pre-sandbox custom destination outside Downloads can never be
        // written under the sandbox — it must fall back to the default.
        let elsewhere = URL(fileURLWithPath: "/Users/Shared/RestoreImage.ipsw")
        let normalized = coordinator.normalizedDownloadDestination(for: elsewhere)
        #expect(
            normalized.path(percentEncoded: false) == VMCreationViewModel.defaultIPSWDownloadPath)
    }

    @Test("Every destination a hand-edited config can name lands inside Downloads")
    func normalizedDownloadDestinationContainsEveryCandidate() throws {
        let downloads = FileManager.default.temporaryDirectory
            .appendingPathComponent("normalizedDestination-\(UUID().uuidString)", isDirectory: true)
        let (coordinator, _, _, _, _) = makeCoordinator(downloadsDirectory: downloads)

        // Traversal out of Downloads, the directory itself spelled two ways,
        // and a path that was never in Downloads at all.
        let persistedSpellings = [
            downloads.appendingPathComponent("../../evil.ipsw"),
            downloads.appendingPathComponent("sub/../evil.ipsw"),
            downloads,
            downloads.appendingPathComponent(""),
            URL(fileURLWithPath: "/Users/Shared/RestoreImage.ipsw"),
        ]
        // A remote URL is no safer: it comes out of the same `config.json`.
        // The last names nothing at all, which appended verbatim resolves to
        // the Downloads directory itself.
        let traversal = try #require(URL(string: "https://host/a%2F..%2F..%2Fevil.ipsw"))
        let pathless = try #require(URL(string: "https://example.com"))
        let remoteSpellings: [URL?] = [nil, traversal, pathless]

        for persisted in persistedSpellings {
            for remote in remoteSpellings {
                let normalized = coordinator.normalizedDownloadDestination(
                    for: persisted, remoteURL: remote)
                let context =
                    "persisted '\(persisted.path(percentEncoded: false))', remote '\(remote?.absoluteString ?? "none")'"
                #expect(
                    canonicalPath(normalized.deletingLastPathComponent())
                        == canonicalPath(downloads), "escaped Downloads for \(context)")
                #expect(
                    canonicalPath(normalized) != canonicalPath(downloads),
                    "named Downloads itself for \(context)")
                #expect(normalized.pathExtension.lowercased() == "ipsw", "not an IPSW for \(context)")
            }
        }
    }

    /// A path with `..` collapsed and any trailing separator dropped, so a
    /// directory and the same directory named as a parent compare equal.
    private func canonicalPath(_ url: URL) -> String {
        let path = url.standardizedFileURL.path(percentEncoded: false)
        guard path.count > 1, path.hasSuffix("/") else { return path }
        return String(path.dropLast())
    }
}
