import CryptoKit
import Foundation
import Testing

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

    @Test("installMacOS with downloadLatest context downloads the resolved image, named after it")
    func installMacOSDownload() async throws {
        let downloads = FileManager.default.temporaryDirectory
            .appendingPathComponent("installLatest-\(UUID().uuidString)", isDirectory: true)
        let (coordinator, _, installService, ipswService, _) = makeCoordinator(
            downloadsDirectory: downloads)
        let instance = makeInstance()
        // What the wizard persisted: the fallback name it shows before its own
        // lookup answers.
        let persisted = downloads.appendingPathComponent(RestoreImageFilename.fallback)
        let context = MacOSInstallContext(
            source: .downloadLatest,
            downloadDestinationPath: persisted.path(percentEncoded: false)
        )

        try await coordinator.installMacOS(on: instance, context: context)

        let expected = downloads.appendingPathComponent(
            RestoreImageFilename.destination(for: ipswService.fetchResult.url))
        #expect(ipswService.fetchCallCount == 1)
        #expect(ipswService.downloadCallCount == 1)
        #expect(ipswService.lastDownloadRemoteURL == ipswService.fetchResult.url)
        #expect(ipswService.lastDownloadDestinationURL == expected)
        #expect(installService.installCallCount == 1)
        #expect(installService.lastRestoreImageURL == expected)
    }

    @Test("A latest install re-points the persisted destination at the file it downloads")
    func installMacOSLatestPersistsTheDerivedDestination() async {
        // The persisted path is what a resume across relaunches and a delete's
        // sidecar cleanup are keyed to, so it has to name the file the bytes
        // land in. Read on the failure path: a successful install clears the
        // context before anything can inspect it.
        let downloads = FileManager.default.temporaryDirectory
            .appendingPathComponent("latestDestination-\(UUID().uuidString)", isDirectory: true)
        let (coordinator, _, _, ipswService, _) = makeCoordinator(downloadsDirectory: downloads)
        ipswService.downloadError = DownloadError.downloadFailed(URLError(.notConnectedToInternet))
        let instance = makeInstance()
        let persisted = downloads.appendingPathComponent(RestoreImageFilename.fallback)
        let context = MacOSInstallContext(
            source: .downloadLatest,
            downloadDestinationPath: persisted.path(percentEncoded: false)
        )
        instance.configuration.installContext = context
        instance.onUpdateConfiguration = { mutate in mutate(&instance.configuration) }

        await #expect(throws: DownloadError.self) {
            try await coordinator.installMacOS(on: instance, context: context)
        }

        let expected = downloads.appendingPathComponent(
            RestoreImageFilename.destination(for: ipswService.fetchResult.url))
        #expect(ipswService.lastDownloadDestinationURL == expected)
        #expect(
            instance.configuration.installContext?.downloadDestinationPath
                == expected.path(percentEncoded: false))
        // The old path's partial belongs to a build this install is no longer
        // fetching, and moving the only pointer to it would strand it.
        #expect(ipswService.discardResumeDataCallCount == 1)
        #expect(ipswService.lastDiscardResumeDataURL == persisted)
        #expect(ipswService.lastDiscardResumeDataPermanently == false)
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
        installService.installError = DownloadError.downloadFailed(URLError(.badServerResponse))
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
        #expect(instance.setupState == nil)
    }

    @Test("installMacOS throws CancellationError on cancel and preserves installContext")
    func installMacOSCancelPreservesContext() async {
        let downloads = FileManager.default.temporaryDirectory
            .appendingPathComponent("cancelPreservesContext-\(UUID().uuidString)", isDirectory: true)
        let (coordinator, _, _, ipswService, _) = makeCoordinator(downloadsDirectory: downloads)
        ipswService.downloadError = CancellationError()
        let instance = makeInstance()
        // Already naming the file the resolved image derives, so nothing but the
        // cancel can touch the context.
        let originalContext = MacOSInstallContext(
            source: .downloadLatest,
            downloadDestinationPath: downloads.appendingPathComponent(
                RestoreImageFilename.destination(for: ipswService.fetchResult.url)
            ).path(percentEncoded: false)
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

        // The persisted destination is the one the resolved image derives, so
        // the file the user confirmed replacing is the file the download writes.
        let destination = temp.appendingPathComponent(
            RestoreImageFilename.destination(for: ipswService.fetchResult.url))

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

    @Test("A latest destination that moved lapses Download & Replace rather than retargeting it")
    func installMacOSLatestFreshDownloadLapsesOnAMovedDestination() async {
        // "Download & Replace" was confirmed in the wizard against the
        // destination shown there. When the install resolves a newer image, the
        // file at the derived destination is one the user never saw, so
        // honoring the flag would trash bytes nobody agreed to lose.
        // Read on the failure path: a successful install clears the context.
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("freshDownloadMoved-\(UUID().uuidString)", isDirectory: true)
        let (coordinator, _, _, ipswService, _) = makeCoordinator(downloadsDirectory: temp)
        ipswService.downloadError = DownloadError.downloadFailed(URLError(.notConnectedToInternet))
        let instance = makeInstance()

        let persisted = temp.appendingPathComponent(RestoreImageFilename.fallback)
        let context = MacOSInstallContext(
            source: .downloadLatest,
            downloadDestinationPath: persisted.path(percentEncoded: false),
            requestedFreshDownload: true
        )
        instance.configuration.installContext = context
        instance.onUpdateConfiguration = { mutate in mutate(&instance.configuration) }

        await #expect(throws: DownloadError.self) {
            try await coordinator.installMacOS(on: instance, context: context)
        }

        let derived = temp.appendingPathComponent(
            RestoreImageFilename.destination(for: ipswService.fetchResult.url))
        #expect(ipswService.lastDownloadDestinationURL == derived)
        #expect(ipswService.lastDownloadDiscardsExisting == false)
        // The lapse spares the file at the *derived* destination; the sidecar
        // left at the path being abandoned is still discarded.
        #expect(ipswService.discardResumeDataCallCount == 1)
        #expect(ipswService.lastDiscardResumeDataURL == persisted)
        // The lapse is persisted with the re-pointed path, so the retry Start
        // that reads this context does not resurrect the confirmation.
        #expect(
            instance.configuration.installContext?.downloadDestinationPath
                == derived.path(percentEncoded: false))
        #expect(instance.configuration.installContext?.requestedFreshDownload == false)
    }

    @Test("installMacOS clears requestedFreshDownload before the download runs")
    func installMacOSFreshDownloadClearsTheFlagOnce() async {
        // A download that fails leaves the context for the retry Start — with
        // the flag already spent, so the retry resumes the partial rather than
        // trashing it and starting over.
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("freshDownloadOnce-\(UUID().uuidString)", isDirectory: true)
        let (coordinator, _, _, ipswService, _) = makeCoordinator(downloadsDirectory: temp)
        ipswService.downloadError = DownloadError.downloadFailed(URLError(.notConnectedToInternet))
        let instance = makeInstance()

        // Honored, not lapsed: the persisted destination is already the one the
        // resolved image derives.
        let context = MacOSInstallContext(
            source: .downloadLatest,
            downloadDestinationPath: temp.appendingPathComponent(
                RestoreImageFilename.destination(for: ipswService.fetchResult.url)
            ).path(percentEncoded: false),
            requestedFreshDownload: true
        )
        instance.configuration.installContext = context
        instance.onUpdateConfiguration = { mutate in mutate(&instance.configuration) }

        await #expect(throws: DownloadError.self) {
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
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("freshDownloadTrashFails-\(UUID().uuidString)", isDirectory: true)
        let (coordinator, _, installService, ipswService, _) = makeCoordinator(
            downloadsDirectory: temp)
        // The destination the resolved image derives, so the replacement is
        // actually requested and can fail.
        let destination = temp.appendingPathComponent(
            RestoreImageFilename.destination(for: ipswService.fetchResult.url))
        ipswService.downloadError = DownloadError.freshDownloadCleanupFailed(
            path: destination.path(percentEncoded: false),
            underlying: NSError(
                domain: NSCocoaErrorDomain,
                code: NSFileWriteNoPermissionError,
                userInfo: [NSLocalizedDescriptionKey: "denied"]
            )
        )

        let instance = makeInstance()
        let context = MacOSInstallContext(
            source: .downloadLatest,
            downloadDestinationPath: destination.path(percentEncoded: false),
            requestedFreshDownload: true
        )
        instance.configuration.installContext = context
        instance.onUpdateConfiguration = { mutate in mutate(&instance.configuration) }

        do {
            try await coordinator.installMacOS(on: instance, context: context)
            Issue.record("Expected freshDownloadCleanupFailed")
        } catch DownloadError.freshDownloadCleanupFailed {
            #expect(instance.status == .error)
            #expect(installService.installCallCount == 0, "Install must not run on a failed download")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("installMacOS rejects requestedFreshDownload on a non-IPSW path")
    func installMacOSFreshDownloadRejectsNonIPSWPath() async throws {
        // The non-IPSW file sits inside the (injected) Downloads directory —
        // an out-of-Downloads path would be normalized to the pinned image's
        // filename before this guard is reached. A pinned source is what keeps
        // such a path: "Download Latest" always names its destination from the
        // URL it resolved, which is always an `.ipsw`.
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("rejectNonIPSW-\(UUID().uuidString)", isDirectory: true)
        let (coordinator, _, _, ipswService, _) = makeCoordinator(downloadsDirectory: temp)
        let instance = makeInstance()
        // Path doesn't end in .ipsw — guard must fire before any trash attempt.
        let context = MacOSInstallContext(
            source: .catalogVersion,
            downloadDestinationPath: temp.appendingPathComponent("important.doc")
                .path(percentEncoded: false),
            requestedFreshDownload: true,
            remoteURL: try #require(
                URL(
                    string:
                        "https://updates.cdn-apple.com/x/UniversalMac_15.6.1_24G90_Restore.ipsw"))
        )
        instance.configuration.installContext = context
        instance.onUpdateConfiguration = { mutate in mutate(&instance.configuration) }

        do {
            try await coordinator.installMacOS(on: instance, context: context)
            Issue.record("Expected invalidDownloadDestination")
        } catch DownloadError.invalidDownloadDestination {
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
            downloadDestinationPath: temp.appendingPathComponent(
                RestoreImageFilename.destination(for: ipswService.fetchResult.url)
            ).path(percentEncoded: false)
        )
        instance.configuration.installContext = context
        instance.onUpdateConfiguration = { mutate in mutate(&instance.configuration) }

        try await coordinator.installMacOS(on: instance, context: context)

        // Nothing at the destination is disturbed: the download resumes or
        // skips over whatever is already there. The destination did not move
        // either, so there is no superseded sidecar to discard.
        #expect(ipswService.lastDownloadDiscardsExisting == false)
        #expect(ipswService.discardResumeDataCallCount == 0)
    }

    @Test("installMacOS preserves IPSW resume data when download is cancelled")
    func installMacOSCancelPreservesResumeData() async {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cancelResumeData-\(UUID().uuidString)", isDirectory: true)
        let (coordinator, _, _, ipswService, _) = makeCoordinator(downloadsDirectory: temp)
        ipswService.downloadError = CancellationError()
        let instance = makeInstance()
        // The destination the resolved image derives, so the cancel is the only
        // thing that could reach the partial sitting there.
        let context = MacOSInstallContext(
            source: .downloadLatest,
            downloadDestinationPath: temp.appendingPathComponent(
                RestoreImageFilename.destination(for: ipswService.fetchResult.url)
            ).path(percentEncoded: false)
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
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("urlCancelResumeData-\(UUID().uuidString)", isDirectory: true)
        let (coordinator, _, _, ipswService, _) = makeCoordinator(downloadsDirectory: temp)
        ipswService.downloadError = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorCancelled,
            userInfo: nil
        )
        let instance = makeInstance()
        let context = MacOSInstallContext(
            source: .downloadLatest,
            downloadDestinationPath: temp.appendingPathComponent(
                RestoreImageFilename.destination(for: ipswService.fetchResult.url)
            ).path(percentEncoded: false)
        )

        await #expect(throws: CancellationError.self) {
            try await coordinator.installMacOS(on: instance, context: context)
        }

        #expect(ipswService.discardResumeDataCallCount == 0)
    }

    @Test("installMacOS preserves IPSW resume data on non-cancel download failure")
    func installMacOSFailurePreservesResumeData() async {
        let downloads = FileManager.default.temporaryDirectory
            .appendingPathComponent("networkFailure-\(UUID().uuidString)", isDirectory: true)
        let (coordinator, _, _, ipswService, _) = makeCoordinator(downloadsDirectory: downloads)
        ipswService.downloadError = DownloadError.downloadFailed(URLError(.notConnectedToInternet))
        let instance = makeInstance()
        // Already naming the file the resolved image derives, so the retry
        // context that survives is the one that went in.
        let originalContext = MacOSInstallContext(
            source: .downloadLatest,
            downloadDestinationPath: downloads.appendingPathComponent(
                RestoreImageFilename.destination(for: ipswService.fetchResult.url)
            ).path(percentEncoded: false)
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

    // MARK: - Linux Installer Image

    /// The Linux pipeline's own seams, over a test-owned Downloads directory
    /// the download mock really writes into — verification reads the file back,
    /// so nothing here can be faked with a path alone.
    private struct LinuxFixture {
        let coordinator: VMLifecycleCoordinator
        let resolveService: MockLinuxImageResolveService
        let downloadService: MockDownloadService
        let fileSystem: MockFileSystem
        let downloads: URL
        /// The bytes the download writes and the digest they hash to.
        let contents: Data
        let digest: String
    }

    private func makeLinuxFixture(name: String = #function) throws -> LinuxFixture {
        let downloads = FileManager.default.temporaryDirectory
            .appendingPathComponent("linuxImage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)

        let contents = Data("kernova linux image fixture".utf8)
        let digest = SHA256.hash(data: contents).map { String(format: "%02x", $0) }.joined()

        let resolveService = MockLinuxImageResolveService()
        resolveService.resolveResult = makeResolvedLinuxImage(
            sha256: digest, sizeBytes: UInt64(contents.count))
        let downloadService = MockDownloadService()
        downloadService.downloadedContents = contents
        let fileSystem = MockFileSystem()

        let coordinator = VMLifecycleCoordinator(
            virtualizationService: MockVirtualizationService(),
            installService: MockMacOSInstallService(),
            ipswService: MockIPSWService(),
            usbDeviceService: MockUSBDeviceService(),
            linuxImageResolveService: resolveService,
            downloadService: downloadService,
            fileSystem: fileSystem,
            downloadsDirectory: downloads
        )
        return LinuxFixture(
            coordinator: coordinator, resolveService: resolveService,
            downloadService: downloadService, fileSystem: fileSystem, downloads: downloads,
            contents: contents, digest: digest)
    }

    /// A Linux VM carrying `context`, with the configuration dispatcher wired so
    /// `performConfigurationMutation` is observable.
    private func makeLinuxInstance(context: LinuxInstallContext) -> VMInstance {
        let instance = makeInstance(name: "Debian")
        instance.configuration.linuxInstallContext = context
        instance.onUpdateConfiguration = { mutate in mutate(&instance.configuration) }
        instance.status = .initialBoot
        return instance
    }

    @Test("downloadLinuxImage resolves, downloads, verifies and attaches the ISO")
    func downloadLinuxImageHappyPath() async throws {
        let fixture = try makeLinuxFixture()
        defer { try? FileManager.default.removeItem(at: fixture.downloads) }
        let entry = makeLinuxCatalogEntry()
        let instance = makeLinuxInstance(context: LinuxInstallContext(source: .catalogEntry(entry)))

        try await fixture.coordinator.downloadLinuxImage(
            on: instance, context: LinuxInstallContext(source: .catalogEntry(entry)))

        let expected = fixture.downloads.appendingPathComponent(
            fixture.resolveService.resolveResult.destinationFilename)
        #expect(fixture.resolveService.resolveCallCount == 1)
        #expect(fixture.resolveService.lastResolvedEntry == entry)
        #expect(fixture.downloadService.lastDownloadRemoteURL == fixture.resolveService.resolveResult.isoURL)
        #expect(fixture.downloadService.lastDownloadDestinationURL == expected)
        // The resolution's own size is the ceiling the transfer is held to.
        #expect(
            fixture.downloadService.lastDownloadExpectedSizeBytes
                == fixture.resolveService.resolveResult.sizeBytes)

        // The installer boots ahead of the synthesized main disk, read-only and
        // on the USB bus its `.iso` extension implies.
        let disks = try #require(instance.configuration.storageDisks)
        #expect(disks.count == 2)
        #expect(disks[0].path == expected.path(percentEncoded: false))
        #expect(disks[0].readOnly)
        #expect(disks[0].kind == .usbMassStorage)
        // Labelled for the image the mirror published, not for the
        // discriminated filename the bytes landed in.
        #expect(disks[0].label == "debian-13.6.0-arm64-netinst")
        #expect(disks[1].label == "Main Disk")
        #expect(disks[1].isInternal)

        // The intent is spent: the next Start takes the normal boot path.
        #expect(instance.configuration.linuxInstallContext == nil)
        #expect(instance.setupState == nil)
        #expect(fixture.fileSystem.trashedURLs.isEmpty)
        // The pipeline put the VM in `.installing`; it has to come to rest in a
        // status the auto-boot chained off this return can start from.
        #expect(instance.status == .stopped)
    }

    @Test("downloadLinuxImage keeps a pre-existing main disk and puts the ISO in front of it")
    func downloadLinuxImageKeepsExistingDisks() async throws {
        let fixture = try makeLinuxFixture()
        defer { try? FileManager.default.removeItem(at: fixture.downloads) }
        let context = LinuxInstallContext(source: .catalogEntry(makeLinuxCatalogEntry()))
        let instance = makeLinuxInstance(context: context)
        let existing = StorageDisk(
            path: "Disk.asif", readOnly: false, label: "Main Disk", isInternal: true, kind: .virtio)
        instance.configuration.storageDisks = [existing]

        try await fixture.coordinator.downloadLinuxImage(on: instance, context: context)

        let disks = try #require(instance.configuration.storageDisks)
        #expect(disks.count == 2)
        #expect(disks[1] == existing)
    }

    @Test("downloadLinuxImage persists the destination before the download runs")
    func downloadLinuxImagePersistsDestination() async throws {
        // Read on the failure path: a successful run clears the context.
        let fixture = try makeLinuxFixture()
        defer { try? FileManager.default.removeItem(at: fixture.downloads) }
        fixture.downloadService.downloadError = DownloadError.downloadFailed(
            URLError(.notConnectedToInternet))
        let context = LinuxInstallContext(source: .catalogEntry(makeLinuxCatalogEntry()))
        let instance = makeLinuxInstance(context: context)

        await #expect(throws: DownloadError.self) {
            try await fixture.coordinator.downloadLinuxImage(on: instance, context: context)
        }

        let expected = fixture.downloads.appendingPathComponent(
            fixture.resolveService.resolveResult.destinationFilename)
        #expect(
            instance.configuration.linuxInstallContext?.downloadDestinationPath
                == expected.path(percentEncoded: false))
        #expect(instance.status == .error)
    }

    @Test("A persisted destination outside Downloads is replaced by the resolved filename")
    func downloadLinuxImageRederivesDestination() async throws {
        let fixture = try makeLinuxFixture()
        defer { try? FileManager.default.removeItem(at: fixture.downloads) }
        // A hand-edited config.json, and a name from a resolution that has since
        // been superseded: neither may decide where the bytes land.
        let stale = URL(fileURLWithPath: "/Users/Shared/../../etc/passwd")
        let context = LinuxInstallContext(
            source: .catalogEntry(makeLinuxCatalogEntry()),
            downloadDestinationPath: stale.path(percentEncoded: false))
        let instance = makeLinuxInstance(context: context)

        try await fixture.coordinator.downloadLinuxImage(on: instance, context: context)

        let expected = fixture.downloads.appendingPathComponent(
            fixture.resolveService.resolveResult.destinationFilename)
        #expect(fixture.downloadService.lastDownloadDestinationURL == expected)
        // The partial at the abandoned path can never be resumed, so it goes
        // before the only pointer to it moves.
        #expect(fixture.downloadService.discardedResumeDataURLs == [stale])
    }

    @Test("linuxDownloadDestination names the file inside Downloads, never from the persisted path")
    func linuxDownloadDestinationIgnoresPersisted() throws {
        let fixture = try makeLinuxFixture()
        defer { try? FileManager.default.removeItem(at: fixture.downloads) }

        let derived = fixture.coordinator.linuxDownloadDestination(
            persisted: URL(fileURLWithPath: "/Users/Shared/old.iso"), filename: "debian.iso")
        #expect(derived == fixture.downloads.appendingPathComponent("debian.iso"))

        // With normalization disabled the persisted path is all there is, and
        // it is taken only while it still names an ISO: the download writes
        // over it and a digest failure trashes it.
        let unnormalized = VMLifecycleCoordinator(
            virtualizationService: MockVirtualizationService(),
            installService: MockMacOSInstallService(),
            ipswService: MockIPSWService(),
            usbDeviceService: MockUSBDeviceService(),
            downloadsDirectory: nil
        )
        let persisted = URL(fileURLWithPath: "/Users/Shared/old.iso")
        #expect(
            unnormalized.linuxDownloadDestination(persisted: persisted, filename: "debian.iso")
                == persisted)
        #expect(unnormalized.linuxDownloadDestination(persisted: nil, filename: "debian.iso") == nil)
        #expect(
            unnormalized.linuxDownloadDestination(
                persisted: URL(fileURLWithPath: "/Users/Shared/notes.txt"), filename: "debian.iso")
                == nil)
    }

    @Test("A checksum mismatch trashes the image, discards its bundle, and keeps the context")
    func downloadLinuxImageChecksumMismatch() async throws {
        let fixture = try makeLinuxFixture()
        defer { try? FileManager.default.removeItem(at: fixture.downloads) }
        // The mirror's manifest and the bytes disagree — a truncated or
        // tampered-with download.
        fixture.resolveService.resolveResult = makeResolvedLinuxImage(
            sha256: String(repeating: "a", count: 64))
        let context = LinuxInstallContext(source: .catalogEntry(makeLinuxCatalogEntry()))
        let instance = makeLinuxInstance(context: context)

        let expected = fixture.downloads.appendingPathComponent(
            fixture.resolveService.resolveResult.destinationFilename)
        do {
            try await fixture.coordinator.downloadLinuxImage(on: instance, context: context)
            Issue.record("Expected checksumMismatch")
        } catch DownloadError.checksumMismatch(let filename, let expected, let actual) {
            // The name the mirror published, which is what the user is shown —
            // not the discriminated name the bytes were written to.
            #expect(filename == fixture.resolveService.resolveResult.filename)
            // The digest the manifest stated, against what the bytes hash to.
            #expect(expected == fixture.resolveService.resolveResult.sha256)
            #expect(actual == fixture.digest)
        }

        // Left in place the bad file would satisfy the skip-existing fast path
        // on every retry, so it goes, and the retry re-resolves from scratch.
        #expect(fixture.fileSystem.trashedURLs == [expected])
        #expect(fixture.downloadService.discardedResumeDataURLs == [expected])
        #expect(instance.configuration.linuxInstallContext != nil)
        #expect(instance.status == .error)
        #expect(instance.errorMessage != nil)
        #expect(instance.configuration.storageDisks == nil)
    }

    @Test("A file already at the destination is verified rather than trusted")
    func downloadLinuxImageVerifiesTheSkipExistingPath() async throws {
        let fixture = try makeLinuxFixture()
        defer { try? FileManager.default.removeItem(at: fixture.downloads) }
        // The download returns without fetching, exactly as the service does
        // when a completed file with no resumable bundle is already there.
        fixture.downloadService.downloadedContents = nil
        let destination = fixture.downloads.appendingPathComponent(
            fixture.resolveService.resolveResult.destinationFilename)
        try Data("not the image the mirror published".utf8).write(to: destination)

        let context = LinuxInstallContext(source: .catalogEntry(makeLinuxCatalogEntry()))
        let instance = makeLinuxInstance(context: context)

        await #expect(throws: DownloadError.self) {
            try await fixture.coordinator.downloadLinuxImage(on: instance, context: context)
        }

        #expect(fixture.fileSystem.trashedURLs == [destination])
        #expect(instance.configuration.storageDisks == nil)
    }

    @Test("A file already in Downloads under the mirror's own name is never touched")
    func downloadLinuxImageLeavesACollidingFileAlone() async throws {
        let fixture = try makeLinuxFixture()
        defer { try? FileManager.default.removeItem(at: fixture.downloads) }
        // The mirror names its ISO after a file the user already has. Nothing
        // the mirror chooses may decide which file is downloaded over, adopted
        // in place of a download, or trashed for failing a digest.
        let resolved = fixture.resolveService.resolveResult
        let usersFile = fixture.downloads.appendingPathComponent(resolved.filename)
        let usersBytes = Data("the user's own ISO".utf8)
        try usersBytes.write(to: usersFile)
        let context = LinuxInstallContext(source: .catalogEntry(makeLinuxCatalogEntry()))
        let instance = makeLinuxInstance(context: context)

        try await fixture.coordinator.downloadLinuxImage(on: instance, context: context)

        let written = fixture.downloads.appendingPathComponent(resolved.destinationFilename)
        #expect(fixture.downloadService.lastDownloadDestinationURL == written)
        #expect(try Data(contentsOf: usersFile) == usersBytes)
        #expect(fixture.fileSystem.trashedURLs.isEmpty)
        #expect(
            instance.configuration.storageDisks?.first?.path
                == written.path(percentEncoded: false))
    }

    @Test("A digest failure trashes only the file the download wrote")
    func downloadLinuxImageMismatchSparesACollidingFile() async throws {
        let fixture = try makeLinuxFixture()
        defer { try? FileManager.default.removeItem(at: fixture.downloads) }
        fixture.resolveService.resolveResult = makeResolvedLinuxImage(
            sha256: String(repeating: "a", count: 64))
        let resolved = fixture.resolveService.resolveResult
        let usersFile = fixture.downloads.appendingPathComponent(resolved.filename)
        try Data("the user's own ISO".utf8).write(to: usersFile)
        let context = LinuxInstallContext(source: .catalogEntry(makeLinuxCatalogEntry()))
        let instance = makeLinuxInstance(context: context)

        await #expect(throws: DownloadError.self) {
            try await fixture.coordinator.downloadLinuxImage(on: instance, context: context)
        }

        #expect(
            fixture.fileSystem.trashedURLs
                == [fixture.downloads.appendingPathComponent(resolved.destinationFilename)])
    }

    @Test("downloadLinuxImage throws CancellationError from the resolve step and keeps the context")
    func downloadLinuxImageCancelDuringResolve() async throws {
        let fixture = try makeLinuxFixture()
        defer { try? FileManager.default.removeItem(at: fixture.downloads) }
        fixture.resolveService.resolveError = CancellationError()
        let context = LinuxInstallContext(source: .catalogEntry(makeLinuxCatalogEntry()))
        let instance = makeLinuxInstance(context: context)

        await #expect(throws: CancellationError.self) {
            try await fixture.coordinator.downloadLinuxImage(on: instance, context: context)
        }

        #expect(fixture.downloadService.downloadCallCount == 0)
        #expect(instance.configuration.linuxInstallContext == context)
        // A cancel must leave the partial download alone for the next Start.
        #expect(fixture.downloadService.discardResumeDataCallCount == 0)
    }

    @Test("A cancelled download surfaces as CancellationError however URLSession words it")
    func downloadLinuxImageURLCancel() async throws {
        let fixture = try makeLinuxFixture()
        defer { try? FileManager.default.removeItem(at: fixture.downloads) }
        fixture.downloadService.downloadError = NSError(
            domain: NSURLErrorDomain, code: NSURLErrorCancelled, userInfo: nil)
        let context = LinuxInstallContext(source: .catalogEntry(makeLinuxCatalogEntry()))
        let instance = makeLinuxInstance(context: context)

        await #expect(throws: CancellationError.self) {
            try await fixture.coordinator.downloadLinuxImage(on: instance, context: context)
        }

        #expect(fixture.downloadService.discardResumeDataCallCount == 0)
    }

    @Test("A resolution failure leaves the VM in .error with the context intact")
    func downloadLinuxImageResolveFailure() async throws {
        let fixture = try makeLinuxFixture()
        defer { try? FileManager.default.removeItem(at: fixture.downloads) }
        fixture.resolveService.resolveError = LinuxImageResolveError.noMatchingImage(
            pattern: "debian-13.*-arm64-netinst.iso")
        let context = LinuxInstallContext(source: .catalogEntry(makeLinuxCatalogEntry()))
        let instance = makeLinuxInstance(context: context)

        await #expect(throws: LinuxImageResolveError.self) {
            try await fixture.coordinator.downloadLinuxImage(on: instance, context: context)
        }

        #expect(instance.status == .error)
        #expect(instance.configuration.linuxInstallContext == context)
    }

    @Test("The setup state walks Download then Verify as the pipeline runs")
    func downloadLinuxImageDrivesTheSetupState() async throws {
        let fixture = try makeLinuxFixture()
        defer { try? FileManager.default.removeItem(at: fixture.downloads) }
        fixture.downloadService.progressSamples = [
            DownloadProgress(bytesWritten: 10, totalBytes: 100, bytesPerSecond: 5)
        ]
        let context = LinuxInstallContext(source: .catalogEntry(makeLinuxCatalogEntry()))
        let instance = makeLinuxInstance(context: context)

        // Sampled at each configuration write, the two points in the pipeline
        // whose step is known: the destination is persisted while Download
        // runs, and the ISO is attached once Verify has finished.
        var observedSteps: [Int] = []
        let persist = instance.onUpdateConfiguration
        instance.onUpdateConfiguration = { mutate in
            if let index = instance.setupState?.currentStepIndex { observedSteps.append(index) }
            persist?(mutate)
        }

        try await fixture.coordinator.downloadLinuxImage(on: instance, context: context)

        #expect(observedSteps == [0, 1])
        #expect(instance.setupState == nil)
    }

    // MARK: - Linux Installer Image From a URL

    /// A pasted-URL context naming the image the fixture's resolve answers with.
    private func makeCustomURLContext(
        fixture: LinuxFixture, verified: Bool
    ) -> LinuxInstallContext {
        LinuxInstallContext(
            source: .customURL(
                CustomLinuxImage(
                    url: fixture.resolveService.resolveResult.isoURL,
                    sha256: verified ? fixture.digest : nil)))
    }

    @Test("A URL pick downloads, verifies against the supplied digest and attaches the ISO")
    func downloadLinuxImageFromVerifiedURL() async throws {
        let fixture = try makeLinuxFixture()
        defer { try? FileManager.default.removeItem(at: fixture.downloads) }
        let context = makeCustomURLContext(fixture: fixture, verified: true)
        let instance = makeLinuxInstance(context: context)

        try await fixture.coordinator.downloadLinuxImage(on: instance, context: context)

        // The URL is re-resolved on every attempt, for the size that bounds the
        // transfer — not to find out which file to fetch.
        #expect(fixture.resolveService.lastResolvedCustomImage?.sha256 == fixture.digest)
        #expect(fixture.resolveService.lastResolvedEntry == nil)
        let expected = fixture.downloads.appendingPathComponent(
            fixture.resolveService.resolveResult.destinationFilename)
        #expect(fixture.downloadService.lastDownloadDestinationURL == expected)
        #expect(instance.configuration.storageDisks?.first?.path == expected.path(percentEncoded: false))
        #expect(instance.configuration.linuxInstallContext == nil)
        #expect(fixture.fileSystem.trashedURLs.isEmpty)
        #expect(instance.status == .stopped)
    }

    @Test("A URL pick with no digest attaches the ISO without a verify step")
    func downloadLinuxImageFromUnverifiedURL() async throws {
        let fixture = try makeLinuxFixture()
        defer { try? FileManager.default.removeItem(at: fixture.downloads) }
        // What the server serves is not what any digest names — with none
        // supplied there is nothing to hold it to, which is what the wizard
        // told the user.
        fixture.resolveService.resolveResult = makeResolvedLinuxImage(sha256: nil)
        let context = makeCustomURLContext(fixture: fixture, verified: false)
        let instance = makeLinuxInstance(context: context)

        var observedSteps: [Int] = []
        let persist = instance.onUpdateConfiguration
        instance.onUpdateConfiguration = { mutate in
            if let index = instance.setupState?.currentStepIndex { observedSteps.append(index) }
            persist?(mutate)
        }

        try await fixture.coordinator.downloadLinuxImage(on: instance, context: context)

        // Download is the whole flow, so the pipeline never leaves step 0.
        #expect(observedSteps == [0, 0])
        #expect(instance.configuration.storageDisks?.count == 2)
        #expect(instance.configuration.linuxInstallContext == nil)
        #expect(fixture.fileSystem.trashedURLs.isEmpty)
        #expect(instance.status == .stopped)
    }

    @Test("A URL pick whose bytes miss the supplied digest is trashed, not attached")
    func downloadLinuxImageFromURLChecksumMismatch() async throws {
        let fixture = try makeLinuxFixture()
        defer { try? FileManager.default.removeItem(at: fixture.downloads) }
        let wrong = String(repeating: "0", count: 64)
        fixture.resolveService.resolveResult = makeResolvedLinuxImage(sha256: wrong)
        let context = LinuxInstallContext(
            source: .customURL(
                CustomLinuxImage(
                    url: fixture.resolveService.resolveResult.isoURL, sha256: wrong)))
        let instance = makeLinuxInstance(context: context)

        await #expect(throws: DownloadError.self) {
            try await fixture.coordinator.downloadLinuxImage(on: instance, context: context)
        }

        // Left in place it would satisfy the skip-existing fast path forever.
        let expected = fixture.downloads.appendingPathComponent(
            fixture.resolveService.resolveResult.destinationFilename)
        #expect(fixture.fileSystem.trashedURLs == [expected])
        #expect(instance.configuration.storageDisks == nil)
        // The intent survives for the next Start, its destination now persisted.
        #expect(instance.configuration.linuxInstallContext?.source == context.source)
        #expect(instance.status == .error)
    }

    @Test("A URL edited past admission is refused before anything is downloaded")
    func downloadLinuxImageFromEditedURL() async throws {
        let fixture = try makeLinuxFixture()
        defer { try? FileManager.default.removeItem(at: fixture.downloads) }
        // The real resolve is what refuses this; the mock's job here is only to
        // report that the refusal reached the pipeline.
        fixture.resolveService.resolveError = LinuxImageURLError.insecureURL
        let context = LinuxInstallContext(
            source: .customURL(
                CustomLinuxImage(
                    url: URL(string: "http://mirror.example/alpine-3.22-aarch64.iso")!,
                    sha256: nil)))
        let instance = makeLinuxInstance(context: context)

        await #expect(throws: LinuxImageURLError.self) {
            try await fixture.coordinator.downloadLinuxImage(on: instance, context: context)
        }

        #expect(fixture.downloadService.downloadCallCount == 0)
        #expect(instance.status == .error)
        #expect(instance.configuration.linuxInstallContext == context)
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

    // MARK: - Latest Download Destination

    @Test("latestDownloadDestination names the download after the URL the install resolved")
    func latestDestinationFollowsTheResolvedURL() throws {
        let downloads = FileManager.default.temporaryDirectory
            .appendingPathComponent("latestFollowsURL-\(UUID().uuidString)", isDirectory: true)
        let (coordinator, _, _, _, _) = makeCoordinator(downloadsDirectory: downloads)
        let persisted = downloads.appendingPathComponent(RestoreImageFilename.fallback)
        let resolved = try #require(
            URL(
                string:
                    "https://updates.cdn-apple.com/fullrestores/UniversalMac_26.5.2_25F84_Restore.ipsw"
            ))

        let destination = coordinator.latestDownloadDestination(
            persisted: persisted, resolvedURL: resolved)

        #expect(
            destination
                == downloads.appendingPathComponent("UniversalMac_26.5.2_25F84_Restore.ipsw"))
    }

    @Test("An off-convention latest URL still lands on a name unique to it")
    func latestDestinationForOffConventionURL() throws {
        let downloads = FileManager.default.temporaryDirectory
            .appendingPathComponent("latestOffConvention-\(UUID().uuidString)", isDirectory: true)
        let (coordinator, _, _, _, _) = makeCoordinator(downloadsDirectory: downloads)
        let persisted = downloads.appendingPathComponent(RestoreImageFilename.fallback)
        let resolved = try #require(URL(string: "https://example.com/restore.ipsw"))

        let destination = coordinator.latestDownloadDestination(
            persisted: persisted, resolvedURL: resolved)

        #expect(
            destination
                == downloads.appendingPathComponent(RestoreImageFilename.unique(for: resolved)))
        // Sharing the fallback would let an unrelated image already sitting
        // there satisfy this download.
        #expect(destination != persisted)
    }

    @Test("With normalization disabled the persisted destination is what the install writes")
    func latestDestinationKeepsPersistedWithoutDownloads() throws {
        // No Downloads directory at all — the one state that leaves a persisted
        // path unexamined, so the `makeCoordinator` fallback is bypassed here.
        let coordinator = VMLifecycleCoordinator(
            virtualizationService: MockVirtualizationService(),
            installService: MockMacOSInstallService(),
            ipswService: MockIPSWService(),
            usbDeviceService: MockUSBDeviceService(),
            downloadsDirectory: nil
        )
        let persisted = URL(fileURLWithPath: "/Users/Shared/RestoreImage.ipsw")
        let resolved = try #require(
            URL(
                string:
                    "https://updates.cdn-apple.com/fullrestores/UniversalMac_26.5.2_25F84_Restore.ipsw"
            ))

        #expect(
            coordinator.latestDownloadDestination(persisted: persisted, resolvedURL: resolved)
                == persisted)
    }

    /// A path with `..` collapsed and any trailing separator dropped, so a
    /// directory and the same directory named as a parent compare equal.
    private func canonicalPath(_ url: URL) -> String {
        let path = url.standardizedFileURL.path(percentEncoded: false)
        guard path.count > 1, path.hasSuffix("/") else { return path }
        return String(path.dropLast())
    }
}
