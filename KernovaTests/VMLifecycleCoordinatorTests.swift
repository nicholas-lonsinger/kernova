import CryptoKit
import Foundation
import KernovaTestSupport
import Observation
import Testing

@testable import Kernova

@Suite("VMLifecycleCoordinator Tests", .admissionGated)
@MainActor
struct VMLifecycleCoordinatorTests {
    /// The pinned catalog image the `.catalogVersion` cases install from.
    private static let pinnedRestoreImageURL = URL(
        string: "https://updates.cdn-apple.com/x/UniversalMac_15.6.1_24G90_Restore.ipsw")

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
        MockRemovableMediaDeviceService
    ) {
        let virtService = MockVirtualizationService()
        let installService = MockMacOSInstallService()
        let ipswService = MockIPSWService()
        let removableMediaService = MockRemovableMediaDeviceService()
        let coordinator = makeTestLifecycle(
            virtualization: virtService, installService: installService, ipswService: ipswService,
            removableMedia: removableMediaService, downloadsDirectory: downloadsDirectory)
        return (coordinator, virtService, installService, ipswService, removableMediaService)
    }

    private func makeSuspendingCoordinator() -> (
        VMLifecycleCoordinator,
        SuspendingMockVirtualizationService
    ) {
        let suspendingService = SuspendingMockVirtualizationService()
        let coordinator = makeTestLifecycle(virtualization: suspendingService)
        return (coordinator, suspendingService)
    }

    // MARK: - Lifecycle Forwarding

    @Test("start forwards to virtualization service")
    func startForwards() async throws {
        let (coordinator, virtService, _, _, _) = makeCoordinator()
        let instance = VMInstanceFixture.make()

        _ = try await coordinator.start(instance)

        #expect(virtService.startCallCount == 1)
        #expect(virtService.lastStartBootIntoRecovery == false)
    }

    @Test("start forwards the bootIntoRecovery flag to the virtualization service")
    func startForwardsBootIntoRecovery() async throws {
        let (coordinator, virtService, _, _, _) = makeCoordinator()
        let instance = VMInstanceFixture.make()

        _ = try await coordinator.start(instance, bootIntoRecovery: true)

        #expect(virtService.startCallCount == 1)
        #expect(virtService.lastStartBootIntoRecovery == true)
    }

    @Test("stop forwards to virtualization service")
    func stopForwards() async throws {
        let (coordinator, virtService, _, _, _) = makeCoordinator()
        let instance = VMInstanceFixture.make()
        instance.activity.placeForTesting(.running(sessionID: UUID()))

        try await coordinator.stop(instance)

        #expect(virtService.stopCallCount == 1)
    }

    @Test("forceStop forwards to virtualization service")
    func forceStopForwards() async throws {
        let (coordinator, virtService, _, _, _) = makeCoordinator()
        let instance = VMInstanceFixture.make()
        instance.activity.placeForTesting(.running(sessionID: UUID()))

        try await coordinator.forceStop(instance)

        #expect(virtService.forceStopCallCount == 1)
    }

    @Test("pause forwards to virtualization service")
    func pauseForwards() async throws {
        let (coordinator, virtService, _, _, _) = makeCoordinator()
        let instance = VMInstanceFixture.make()
        instance.activity.placeForTesting(.running(sessionID: UUID()))

        try await coordinator.pause(instance)

        #expect(virtService.pauseCallCount == 1)
    }

    @Test("resume forwards to virtualization service")
    func resumeForwards() async throws {
        let (coordinator, virtService, _, _, _) = makeCoordinator()
        let instance = VMInstanceFixture.make()
        instance.activity.placeForTesting(.suspended)

        try await coordinator.resume(instance)

        #expect(virtService.resumeCallCount == 1)
    }

    @Test("save forwards to virtualization service")
    func saveForwards() async throws {
        let (coordinator, virtService, _, _, _) = makeCoordinator()
        let instance = VMInstanceFixture.make()
        instance.activity.placeForTesting(.running(sessionID: UUID()))

        try await coordinator.save(instance)

        #expect(virtService.saveCallCount == 1)
    }

    // MARK: - Error Propagation

    @Test("start propagates error from virtualization service")
    func startPropagatesError() async {
        let (coordinator, virtService, _, _, _) = makeCoordinator()
        virtService.startError = VirtualizationError.noVirtualMachine
        let instance = VMInstanceFixture.make()

        await #expect(throws: VirtualizationError.self) {
            try await coordinator.start(instance)
        }
    }

    @Test("stop propagates error from virtualization service")
    func stopPropagatesError() async {
        let (coordinator, virtService, _, _, _) = makeCoordinator()
        virtService.stopError = VirtualizationError.noVirtualMachine
        let instance = VMInstanceFixture.make()

        await #expect(throws: VirtualizationError.self) {
            try await coordinator.stop(instance)
        }
    }

    // MARK: - Operation Serialization

    @Test("hasActiveOperation returns false when no operation is running")
    func hasActiveOperationInitiallyFalse() {
        let (coordinator, _, _, _, _) = makeCoordinator()
        let instance = VMInstanceFixture.make()

        #expect(!coordinator.hasActiveOperation(for: instance.id))
    }

    @Test("hasActiveOperation returns true during an in-flight operation")
    func hasActiveOperationTrueDuringOperation() async throws {
        let (coordinator, suspendingService) = makeSuspendingCoordinator()
        let instance = VMInstanceFixture.make()

        // Start an operation that will suspend
        let task = Task { @MainActor in
            try await coordinator.start(instance)
        }

        // Wait for the operation to begin (the mock will signal via its continuation)
        await suspendingService.waitUntilSuspended()

        #expect(coordinator.hasActiveOperation(for: instance.id))

        // Let the operation complete
        suspendingService.resumeSuspended()
        _ = try await task.value
    }

    @Test("an observed wait on hasUnsettledOperation wakes when the operation ends")
    func hasUnsettledOperationWakesAnObservedWait() async throws {
        // What the termination save pass holds a quit on: a pause or resume
        // settles without changing `VMStatus`, so the pass waits on this read
        // through `withObservationTracking`. Were it not observable the wait
        // would have nothing to wake on and the quit would hang.
        let (coordinator, suspendingService) = makeSuspendingCoordinator()
        let instance = VMInstanceFixture.make()
        let instanceID = instance.id

        let task = Task { @MainActor in
            try await coordinator.start(instance)
        }
        await suspendingService.waitUntilSuspended()
        #expect(coordinator.hasUnsettledOperation(for: instanceID))

        // The wait is on the *fire*, not on the read it guards: a coordinator
        // publishing no change would let the read settle anyway, so only the
        // fire separates a wait that woke from one that outlived its backstop.
        let gate = AsyncGate()
        let fired = ObservationFireRecorder()
        withObservationTracking {
            _ = coordinator.hasUnsettledOperation(for: instanceID)
        } onChange: {
            fired.record()
            gate.notify()
        }

        // Deferred so the operation ends after tracking is armed, which is the
        // ordering the pass sees.
        Task { @MainActor in suspendingService.resumeSuspended() }
        try await gate.wait { fired.didFire }
        #expect(!coordinator.hasUnsettledOperation(for: instanceID))
        _ = try await task.value
    }

    @Test("a stop taking the claim mid-operation leaves the operation unsettled")
    func stopDoesNotSettleTheOperationItInterrupts() async throws {
        // The pass waits before saving. `stop` and `forceStop` release the claim
        // so a user can always break in, but the operation they interrupt is
        // still inside VZ — resolving the wait there would issue the save as a
        // second concurrent VZ operation.
        let (coordinator, suspendingService) = makeSuspendingCoordinator()
        let instance = VMInstanceFixture.make()
        instance.activity.placeForTesting(.running(sessionID: UUID()))

        let task = Task { @MainActor in
            try await coordinator.start(instance)
        }
        await suspendingService.waitUntilSuspended()

        try await coordinator.stop(instance)

        #expect(!coordinator.hasActiveOperation(for: instance.id))
        #expect(coordinator.hasUnsettledOperation(for: instance.id))

        suspendingService.resumeSuspended()
        _ = try await task.value
        #expect(!coordinator.hasUnsettledOperation(for: instance.id))
    }

    @Test("concurrent operation on the same VM throws operationInProgress")
    func rejectsConcurrentOperationOnSameVM() async throws {
        let (coordinator, suspendingService) = makeSuspendingCoordinator()
        let instance = VMInstanceFixture.make()

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
        _ = try await task.value
    }

    @Test("a serialized operation waits out an owed removable-media reconcile")
    func serializedOperationWaitsForAnOwedReconcile() async throws {
        let (coordinator, virtService, _, _, _) = makeCoordinator()
        let instance = VMInstanceFixture.make()
        let sessionID = UUID()
        instance.activity.placeForTesting(.running(sessionID: sessionID))
        instance.beginSessionContext()
        instance.markRemovableMediaReconcileOwed(for: sessionID)

        let pause = Task { @MainActor in try await coordinator.pause(instance) }
        await waitForObservedChange { coordinator.hasUnsettledOperation(for: instance.id) }

        // The claim is held while the wait runs, and the body has not started.
        #expect(coordinator.hasActiveOperation(for: instance.id))
        #expect(virtService.pauseCallCount == 0)

        instance.clearRemovableMediaReconcileOwed(for: sessionID)
        try await pause.value
        #expect(virtService.pauseCallCount == 1)
        #expect(!coordinator.hasActiveOperation(for: instance.id))
    }

    @Test("a second operation arriving during the reconcile wait is refused")
    func secondOperationDuringTheReconcileWaitIsRefused() async throws {
        let (coordinator, virtService, _, _, _) = makeCoordinator()
        let instance = VMInstanceFixture.make()
        let sessionID = UUID()
        instance.activity.placeForTesting(.running(sessionID: sessionID))
        instance.beginSessionContext()
        instance.markRemovableMediaReconcileOwed(for: sessionID)

        let pause = Task { @MainActor in try await coordinator.pause(instance) }
        await waitForObservedChange { coordinator.hasUnsettledOperation(for: instance.id) }

        await #expect(throws: VMLifecycleCoordinator.LifecycleError.self) {
            try await coordinator.save(instance)
        }
        #expect(virtService.saveCallCount == 0)

        instance.clearRemovableMediaReconcileOwed(for: sessionID)
        try await pause.value
        #expect(virtService.pauseCallCount == 1)
    }

    @Test("stop and forceStop do not wait out an owed reconcile")
    func stopDoesNotWaitForAnOwedReconcile() async throws {
        let (coordinator, virtService, _, _, _) = makeCoordinator()
        for forced in [false, true] {
            let instance = VMInstanceFixture.make()
            let sessionID = UUID()
            instance.activity.placeForTesting(.running(sessionID: sessionID))
            instance.beginSessionContext()
            instance.markRemovableMediaReconcileOwed(for: sessionID)

            if forced {
                try await coordinator.forceStop(instance)
            } else {
                try await coordinator.stop(instance)
            }
            #expect(instance.status == .stopped)
        }
        #expect(virtService.stopCallCount == 1)
        #expect(virtService.forceStopCallCount == 1)
    }

    @Test("a session torn down mid-wait releases the waiting operation")
    func teardownMidWaitReleasesTheWaitingOperation() async throws {
        // A force stop during the wait drops the debt with the context; the
        // waiter wakes and the body runs against whatever the VM rests at.
        let (coordinator, virtService, _, _, _) = makeCoordinator()
        let instance = VMInstanceFixture.make()
        let sessionID = UUID()
        instance.activity.placeForTesting(.running(sessionID: sessionID))
        instance.beginSessionContext()
        instance.markRemovableMediaReconcileOwed(for: sessionID)

        let pause = Task { @MainActor in try await coordinator.pause(instance) }
        await waitForObservedChange { coordinator.hasUnsettledOperation(for: instance.id) }
        #expect(virtService.pauseCallCount == 0)

        instance.tearDownSession(restingAt: .stopped)
        _ = try? await pause.value
        #expect(virtService.pauseCallCount == 1)
        #expect(!coordinator.hasUnsettledOperation(for: instance.id))
    }

    @Test("a snapshot delete during another operation is rejected, not run")
    func rejectsSnapshotDeleteDuringAnotherOperation() async throws {
        let (coordinator, suspendingService) = makeSuspendingCoordinator()
        let store = MockVMBundleMachineFiles()
        let instance = VMInstanceFixture.make(bundleFactory: VMBundle.Factory(machineFiles: store))

        let task = Task { @MainActor in
            try await coordinator.start(instance)
        }
        await suspendingService.waitUntilSuspended()

        // A revert reads the very directory this would move to the Trash.
        await #expect(throws: VMLifecycleCoordinator.LifecycleError.self) {
            try await coordinator.discardSnapshot(instance, snapshotID: UUID()) {}
        }
        #expect(store.discardedIDs.isEmpty)

        suspendingService.resumeSuspended()
        _ = try await task.value
    }

    @Test("operations on different VMs are allowed concurrently")
    func allowsConcurrentOperationsOnDifferentVMs() async throws {
        let (coordinator, suspendingService) = makeSuspendingCoordinator()
        let instance1 = VMInstanceFixture.make(name: "VM 1")
        let instance2 = VMInstanceFixture.make(name: "VM 2")

        // Start an operation on instance1 that suspends
        let task = Task { @MainActor in
            try await coordinator.start(instance1)
        }

        await suspendingService.waitUntilSuspended()

        // A different VM should still be able to start (uses regular mock behavior for second call)
        suspendingService.shouldSuspendOnStart = false
        _ = try await coordinator.start(instance2)

        // Clean up
        suspendingService.resumeSuspended()
        _ = try await task.value
    }

    @Test("lock is released after operation completes successfully")
    func lockReleasedAfterSuccess() async throws {
        let (coordinator, _, _, _, _) = makeCoordinator()
        let instance = VMInstanceFixture.make()

        _ = try await coordinator.start(instance)
        #expect(!coordinator.hasActiveOperation(for: instance.id))

        // A second operation should succeed
        instance.activity.placeForTesting(.running(sessionID: UUID()))
        try await coordinator.pause(instance)
        #expect(!coordinator.hasActiveOperation(for: instance.id))
    }

    @Test("lock is released after operation fails")
    func lockReleasedAfterError() async throws {
        let (coordinator, virtService, _, _, _) = makeCoordinator()
        virtService.startError = VirtualizationError.noVirtualMachine
        let instance = VMInstanceFixture.make()

        await #expect(throws: VirtualizationError.self) {
            try await coordinator.start(instance)
        }

        #expect(!coordinator.hasActiveOperation(for: instance.id))

        // Should be able to retry after failure
        virtService.startError = nil
        _ = try await coordinator.start(instance)
        #expect(virtService.startCallCount == 2)
    }

    @Test("stop bypasses serialization during an active operation")
    func stopBypassesSerializationDuringActiveOperation() async throws {
        let (coordinator, suspendingService) = makeSuspendingCoordinator()
        let instance = VMInstanceFixture.make()

        // Start an operation that will suspend
        let task = Task { @MainActor in
            try await coordinator.start(instance)
        }

        await suspendingService.waitUntilSuspended()
        #expect(coordinator.hasActiveOperation(for: instance.id))

        // Stop should succeed even though start is in flight
        try await coordinator.stop(instance)

        // Active operation flag should be cleared by stop
        #expect(!coordinator.hasActiveOperation(for: instance.id))

        // Clean up — let the suspended start complete
        suspendingService.resumeSuspended()
        _ = try? await task.value
    }

    @Test("forceStop bypasses serialization during an active operation")
    func forceStopBypassesSerializationDuringActiveOperation() async throws {
        let (coordinator, suspendingService) = makeSuspendingCoordinator()
        let instance = VMInstanceFixture.make()

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
    func stopDoesNotAffectActiveOperationTracking() async throws {
        let (coordinator, virtService, _, _, _) = makeCoordinator()
        let instance = VMInstanceFixture.make()
        instance.activity.placeForTesting(.running(sessionID: UUID()))

        try await coordinator.stop(instance)
        #expect(!coordinator.hasActiveOperation(for: instance.id))
        #expect(virtService.stopCallCount == 1)
    }

    @Test("stop error does not affect active operation tracking")
    func stopErrorDoesNotAffectActiveOperationTracking() async throws {
        let (coordinator, virtService, _, _, _) = makeCoordinator()
        virtService.stopError = VirtualizationError.noVirtualMachine
        let instance = VMInstanceFixture.make()

        await #expect(throws: VirtualizationError.self) {
            try await coordinator.stop(instance)
        }

        #expect(!coordinator.hasActiveOperation(for: instance.id))

        // Should be able to start after failed stop
        _ = try await coordinator.start(instance)
        #expect(virtService.startCallCount == 1)
    }

    @Test("token prevents stale defer from clobbering after stop clears entry")
    func tokenPreventsStaleRemoval() async throws {
        let (coordinator, suspendingService) = makeSuspendingCoordinator()
        let instance = VMInstanceFixture.make()

        // Start an operation that will suspend (acquires token A)
        let task = Task { @MainActor in
            try await coordinator.start(instance)
        }

        await suspendingService.waitUntilSuspended()
        #expect(coordinator.hasActiveOperation(for: instance.id))

        // Stop clears the active operation entry (invalidating token A)
        try await coordinator.stop(instance)
        #expect(!coordinator.hasActiveOperation(for: instance.id))

        // Resume the suspended start — its defer should NOT re-clear the entry
        // because its token no longer matches
        suspendingService.resumeSuspended()
        _ = try? await task.value

        // Now start a new operation — this should succeed because
        // the stale defer didn't clobber anything
        suspendingService.shouldSuspendOnStart = false
        _ = try await coordinator.start(instance)
        #expect(!coordinator.hasActiveOperation(for: instance.id))
    }

    // MARK: - macOS Installation

    @Test("installMacOS with localFile context sets hasDownloadStep to false")
    func installMacOSLocalFile() async throws {
        let (coordinator, _, installService, _, _) = makeCoordinator()
        let instance = VMInstanceFixture.make()
        let library = makeWiredLibrary(holding: [instance])
        defer { withExtendedLifetime(library) {} }
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
        let instance = VMInstanceFixture.make()
        let library = makeWiredLibrary(holding: [instance])
        defer { withExtendedLifetime(library) {} }
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
        let persisted = downloads.appendingPathComponent(RestoreImageFilename.fallback)
        let context = MacOSInstallContext(
            source: .downloadLatest,
            downloadDestinationPath: persisted.path(percentEncoded: false)
        )
        let instance = VMInstanceFixture.make { $0.installContext = context }
        let library = makeWiredLibrary(holding: [instance])
        defer { withExtendedLifetime(library) {} }

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
        let instance = VMInstanceFixture.make()
        let library = makeWiredLibrary(holding: [instance])
        defer { withExtendedLifetime(library) {} }
        let pinned = try #require(Self.pinnedRestoreImageURL)
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
        let instance = VMInstanceFixture.make()
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
        let pinned = try #require(Self.pinnedRestoreImageURL)

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
        let instance = VMInstanceFixture.make()
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
        let context = MacOSInstallContext(source: .localFile, localIPSWPath: "/tmp/restore.ipsw")
        let instance = VMInstanceFixture.make { $0.installContext = context }
        instance.activity.placeForTesting(.failed(message: "stale message from an earlier failure"))
        let library = makeWiredLibrary(holding: [instance])
        defer { withExtendedLifetime(library) {} }

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
        let context = MacOSInstallContext(source: .localFile, localIPSWPath: "/tmp/restore.ipsw")
        let instance = VMInstanceFixture.make { $0.installContext = context }
        let library = makeWiredLibrary(holding: [instance])
        defer { withExtendedLifetime(library) {} }

        try await coordinator.installMacOS(on: instance, context: context)

        #expect(instance.configuration.installContext == nil)
        #expect(instance.setupState == nil)
    }

    @Test("installMacOS records the image the install ran from")
    func installMacOSRecordsTheInstalledImage() async throws {
        let (coordinator, _, installService, _, _) = makeCoordinator()
        let instance = VMInstanceFixture.make()
        let library = makeWiredLibrary(holding: [instance])
        defer { withExtendedLifetime(library) {} }
        installService.installedImage = .macOSRestoreImage(version: "15.6.1", build: "24G90")
        let context = MacOSInstallContext(source: .localFile, localIPSWPath: "/tmp/restore.ipsw")

        try await coordinator.installMacOS(on: instance, context: context)

        #expect(
            instance.configuration.installedImage
                == .macOSRestoreImage(version: "15.6.1", build: "24G90"))
    }

    @Test("A failed install records no image")
    func installMacOSFailureRecordsNoImage() async {
        let (coordinator, _, installService, _, _) = makeCoordinator()
        let instance = VMInstanceFixture.make()
        let library = makeWiredLibrary(holding: [instance])
        defer { withExtendedLifetime(library) {} }
        installService.installError = MacOSInstallError.unsupportedRestoreImage
        let context = MacOSInstallContext(source: .localFile, localIPSWPath: "/tmp/restore.ipsw")

        _ = try? await coordinator.installMacOS(on: instance, context: context)

        #expect(instance.configuration.installedImage == nil)
    }

    @Test("installMacOS throws CancellationError on cancel and preserves installContext")
    func installMacOSCancelPreservesContext() async {
        let downloads = FileManager.default.temporaryDirectory
            .appendingPathComponent("cancelPreservesContext-\(UUID().uuidString)", isDirectory: true)
        let (coordinator, _, _, ipswService, _) = makeCoordinator(downloadsDirectory: downloads)
        ipswService.downloadError = CancellationError()
        // Already naming the file the resolved image derives, so nothing but the
        // cancel can touch the context.
        let originalContext = MacOSInstallContext(
            source: .downloadLatest,
            downloadDestinationPath: downloads.appendingPathComponent(
                RestoreImageFilename.destination(for: ipswService.fetchResult.url)
            ).path(percentEncoded: false)
        )
        let instance = VMInstanceFixture.make { $0.installContext = originalContext }
        let library = makeWiredLibrary(holding: [instance])
        defer { withExtendedLifetime(library) {} }

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

        // The persisted destination is the one the resolved image derives, so
        // the file the user confirmed replacing is the file the download writes.
        let destination = temp.appendingPathComponent(
            RestoreImageFilename.destination(for: ipswService.fetchResult.url))

        let context = MacOSInstallContext(
            source: .downloadLatest,
            downloadDestinationPath: destination.path(percentEncoded: false),
            requestedFreshDownload: true
        )
        let instance = VMInstanceFixture.make { $0.installContext = context }
        let library = makeWiredLibrary(holding: [instance])
        defer { withExtendedLifetime(library) {} }

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

        let persisted = temp.appendingPathComponent(RestoreImageFilename.fallback)
        let context = MacOSInstallContext(
            source: .downloadLatest,
            downloadDestinationPath: persisted.path(percentEncoded: false),
            requestedFreshDownload: true
        )
        let instance = VMInstanceFixture.make { $0.installContext = context }
        let library = makeWiredLibrary(holding: [instance])
        defer { withExtendedLifetime(library) {} }

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

        // Honored, not lapsed: the persisted destination is already the one the
        // resolved image derives.
        let context = MacOSInstallContext(
            source: .downloadLatest,
            downloadDestinationPath: temp.appendingPathComponent(
                RestoreImageFilename.destination(for: ipswService.fetchResult.url)
            ).path(percentEncoded: false),
            requestedFreshDownload: true
        )
        let instance = VMInstanceFixture.make { $0.installContext = context }
        let library = makeWiredLibrary(holding: [instance])
        defer { withExtendedLifetime(library) {} }

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

        let context = MacOSInstallContext(
            source: .downloadLatest,
            downloadDestinationPath: destination.path(percentEncoded: false),
            requestedFreshDownload: true
        )
        let instance = VMInstanceFixture.make { $0.installContext = context }
        let library = makeWiredLibrary(holding: [instance])
        defer { withExtendedLifetime(library) {} }

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
        // Path doesn't end in .ipsw — guard must fire before any trash attempt.
        let context = MacOSInstallContext(
            source: .catalogVersion,
            downloadDestinationPath: temp.appendingPathComponent("important.doc")
                .path(percentEncoded: false),
            requestedFreshDownload: true,
            remoteURL: Self.pinnedRestoreImageURL
        )
        let instance = VMInstanceFixture.make { $0.installContext = context }
        let library = makeWiredLibrary(holding: [instance])
        defer { withExtendedLifetime(library) {} }

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

        let context = MacOSInstallContext(
            source: .downloadLatest,
            downloadDestinationPath: temp.appendingPathComponent(
                RestoreImageFilename.destination(for: ipswService.fetchResult.url)
            ).path(percentEncoded: false)
        )
        let instance = VMInstanceFixture.make { $0.installContext = context }
        let library = makeWiredLibrary(holding: [instance])
        defer { withExtendedLifetime(library) {} }

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
        let instance = VMInstanceFixture.make()
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
        let instance = VMInstanceFixture.make()
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
        // Already naming the file the resolved image derives, so the retry
        // context that survives is the one that went in.
        let originalContext = MacOSInstallContext(
            source: .downloadLatest,
            downloadDestinationPath: downloads.appendingPathComponent(
                RestoreImageFilename.destination(for: ipswService.fetchResult.url)
            ).path(percentEncoded: false)
        )
        let instance = VMInstanceFixture.make { $0.installContext = originalContext }
        let library = makeWiredLibrary(holding: [instance])
        defer { withExtendedLifetime(library) {} }

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

    // MARK: - macOS Install Steps Whose Write Fails

    /// A VM carrying `context`, registered in a library over `storage`.
    private func makeInstallingInstance(
        context: MacOSInstallContext, storage: MockVMStorageService
    ) -> (VMInstance, VMLibrary) {
        let instance = VMInstanceFixture.make(guestOS: .macOS) { $0.installContext = context }
        return (instance, makeWiredLibrary(holding: [instance], storage: storage))
    }

    @Test("A latest install whose destination move cannot be saved fails before the download")
    func installMacOSLatestWhoseDestinationMoveFailsStopsBeforeTheDownload() async {
        let downloads = FileManager.default.temporaryDirectory
            .appendingPathComponent("latestMoveUnsaved-\(UUID().uuidString)", isDirectory: true)
        let (coordinator, _, installService, ipswService, _) = makeCoordinator(
            downloadsDirectory: downloads)
        let context = MacOSInstallContext(
            source: .downloadLatest,
            downloadDestinationPath: downloads.appendingPathComponent(RestoreImageFilename.fallback)
                .path(percentEncoded: false))
        let storage = MockVMStorageService()
        let (instance, library) = makeInstallingInstance(context: context, storage: storage)
        defer { withExtendedLifetime(library) {} }
        storage.saveConfigurationError = NSError(domain: "test", code: 1)

        await #expect(throws: VMLibrary.SettingsWriteFailure.self) {
            try await coordinator.installMacOS(on: instance, context: context)
        }

        #expect(ipswService.downloadCallCount == 0)
        #expect(installService.installCallCount == 0)
        #expect(instance.configuration.installContext == context)
        #expect(storage.bundles[instance.bundleURL]?.installContext == context)
        #expect(instance.status == .error)
    }

    @Test("A Download & Replace whose flag cannot be cleared fails before anything is replaced")
    func installMacOSFreshDownloadWhoseClearFailsReplacesNothing() async {
        let downloads = FileManager.default.temporaryDirectory
            .appendingPathComponent("freshClearUnsaved-\(UUID().uuidString)", isDirectory: true)
        let (coordinator, _, installService, ipswService, _) = makeCoordinator(
            downloadsDirectory: downloads)
        // Honored, not lapsed: nothing is written before the flag's clear.
        let context = MacOSInstallContext(
            source: .downloadLatest,
            downloadDestinationPath: downloads.appendingPathComponent(
                RestoreImageFilename.destination(for: ipswService.fetchResult.url)
            ).path(percentEncoded: false),
            requestedFreshDownload: true)
        let storage = MockVMStorageService()
        let (instance, library) = makeInstallingInstance(context: context, storage: storage)
        defer { withExtendedLifetime(library) {} }
        storage.saveConfigurationError = NSError(domain: "test", code: 1)

        await #expect(throws: VMLibrary.SettingsWriteFailure.self) {
            try await coordinator.installMacOS(on: instance, context: context)
        }

        // The replace belongs to the download, which never ran.
        #expect(ipswService.downloadCallCount == 0)
        #expect(ipswService.discardResumeDataCallCount == 0)
        #expect(installService.installCallCount == 0)
        #expect(instance.configuration.installContext?.requestedFreshDownload == true)
        #expect(storage.bundles[instance.bundleURL]?.installContext == context)
        #expect(instance.status == .error)
    }

    @Test("An install whose completion cannot be saved fails and keeps its context for the next Start")
    func installMacOSWhoseCompletionFailsKeepsTheContext() async {
        let (coordinator, _, installService, _, _) = makeCoordinator()
        let context = MacOSInstallContext(source: .localFile, localIPSWPath: "/tmp/restore.ipsw")
        let storage = MockVMStorageService()
        let (instance, library) = makeInstallingInstance(context: context, storage: storage)
        defer { withExtendedLifetime(library) {} }
        storage.saveConfigurationError = NSError(domain: "test", code: 1)

        await #expect(throws: VMLibrary.SettingsWriteFailure.self) {
            try await coordinator.installMacOS(on: instance, context: context)
        }

        #expect(installService.installCallCount == 1)
        #expect(instance.configuration.installContext == context)
        #expect(instance.configuration.installedImage == nil)
        #expect(storage.bundles[instance.bundleURL] == instance.configuration)
        #expect(instance.status == .error)
    }

    @Test("A local IPSW whose heal cannot be saved still installs from the resolved file")
    func installMacOSLocalIPSWWhoseHealFailsInstallsFromTheResolvedFile() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("localIPSWHeal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let picked = directory.appendingPathComponent("Picked.ipsw")
        try Data("restore image".utf8).write(to: picked)
        let bookmark = try #require(SecurityScopedBookmark.make(for: picked))
        // Moved since the pick, so the bookmark resolves somewhere the stored
        // path no longer names.
        try FileManager.default.moveItem(at: picked, to: directory.appendingPathComponent("Moved.ipsw"))
        let context = MacOSInstallContext(
            source: .localFile, localIPSWPath: picked.path(percentEncoded: false),
            localIPSWBookmark: bookmark)
        let (coordinator, _, installService, _, _) = makeCoordinator()
        let storage = MockVMStorageService()
        let (instance, library) = makeInstallingInstance(context: context, storage: storage)
        defer { withExtendedLifetime(library) {} }
        storage.saveConfigurationError = NSError(domain: "test", code: 1)
        var contextDuringInstall: MacOSInstallContext?
        installService.onInstall = {
            contextDuringInstall = instance.configuration.installContext
            // Writable again by the time the install completes.
            storage.saveConfigurationError = nil
        }

        try await coordinator.installMacOS(on: instance, context: context)

        #expect(installService.lastRestoreImageURL?.lastPathComponent == "Moved.ipsw")
        // The heal never landed: the bundle still named the picked path.
        #expect(contextDuringInstall == context)
        #expect(instance.configuration.installContext == nil)
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
        let library: VMLibrary
        let storage: MockVMStorageService
    }

    private func makeLinuxFixture() throws -> LinuxFixture {
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

        let coordinator = makeTestLifecycle(
            linuxImageResolveService: resolveService, downloadService: downloadService,
            fileSystem: fileSystem, downloadsDirectory: downloads)
        let storage = MockVMStorageService()
        return LinuxFixture(
            coordinator: coordinator, resolveService: resolveService,
            downloadService: downloadService, fileSystem: fileSystem, downloads: downloads,
            contents: contents, digest: digest,
            library: makeWiredLibrary(storage: storage), storage: storage)
    }

    /// A Linux VM carrying `context`, registered in `fixture`'s library.
    private func makeLinuxInstance(
        context: LinuxInstallContext, in fixture: LinuxFixture,
        mutate: (inout VMConfiguration) -> Void = { _ in }
    ) -> VMInstance {
        let instance = VMInstanceFixture.make(name: "Debian") {
            $0.linuxInstallContext = context
            mutate(&$0)
        }
        instance.activity.placeForTesting(.initialBoot)
        fixture.library.register(instance, storage: fixture.storage)
        return instance
    }

    @Test("downloadLinuxImage resolves, downloads, verifies and attaches the ISO")
    func downloadLinuxImageHappyPath() async throws {
        let fixture = try makeLinuxFixture()
        defer { try? FileManager.default.removeItem(at: fixture.downloads) }
        let entry = makeLinuxCatalogEntry()
        let instance = makeLinuxInstance(
            context: LinuxInstallContext(source: .catalogEntry(entry)), in: fixture)

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

    @Test("downloadLinuxImage records the catalog image the ISO came from")
    func downloadLinuxImageRecordsTheCatalogImage() async throws {
        let fixture = try makeLinuxFixture()
        defer { try? FileManager.default.removeItem(at: fixture.downloads) }
        let context = LinuxInstallContext(
            source: .catalogEntry(
                makeLinuxCatalogEntry(distribution: "Ubuntu Desktop", version: "26.04 LTS")))
        let instance = makeLinuxInstance(context: context, in: fixture)

        try await fixture.coordinator.downloadLinuxImage(on: instance, context: context)

        #expect(
            instance.configuration.installedImage
                == .linuxCatalogImage(distribution: "Ubuntu Desktop", version: "26.04 LTS"))
    }

    @Test("downloadLinuxImage records nothing for a user-supplied URL")
    func downloadLinuxImageRecordsNothingForAURL() async throws {
        let fixture = try makeLinuxFixture()
        defer { try? FileManager.default.removeItem(at: fixture.downloads) }
        let context = makeCustomURLContext(fixture: fixture, verified: true)
        let instance = makeLinuxInstance(context: context, in: fixture)

        try await fixture.coordinator.downloadLinuxImage(on: instance, context: context)

        #expect(instance.configuration.installedImage == nil)
    }

    @Test("A failed Linux download records no image")
    func downloadLinuxImageFailureRecordsNoImage() async throws {
        let fixture = try makeLinuxFixture()
        defer { try? FileManager.default.removeItem(at: fixture.downloads) }
        fixture.downloadService.downloadError = DownloadError.downloadFailed(
            URLError(.notConnectedToInternet))
        let context = LinuxInstallContext(source: .catalogEntry(makeLinuxCatalogEntry()))
        let instance = makeLinuxInstance(context: context, in: fixture)

        _ = try? await fixture.coordinator.downloadLinuxImage(on: instance, context: context)

        #expect(instance.configuration.installedImage == nil)
    }

    @Test("downloadLinuxImage keeps a pre-existing main disk and puts the ISO in front of it")
    func downloadLinuxImageKeepsExistingDisks() async throws {
        let fixture = try makeLinuxFixture()
        defer { try? FileManager.default.removeItem(at: fixture.downloads) }
        let context = LinuxInstallContext(source: .catalogEntry(makeLinuxCatalogEntry()))
        let existing = StorageDisk(
            path: "Disk.asif", readOnly: false, label: "Main Disk", isInternal: true, kind: .virtio)
        let instance = makeLinuxInstance(context: context, in: fixture) {
            $0.storageDisks = [existing]
        }

        try await fixture.coordinator.downloadLinuxImage(on: instance, context: context)

        let disks = try #require(instance.configuration.storageDisks)
        #expect(disks.count == 2)
        #expect(disks[1] == existing)
    }

    @Test("downloadLinuxImage over an empty configured disk list synthesizes the main disk")
    func downloadLinuxImageSynthesizesMainDiskForEmptyList() async throws {
        let fixture = try makeLinuxFixture()
        defer { try? FileManager.default.removeItem(at: fixture.downloads) }
        let context = LinuxInstallContext(source: .catalogEntry(makeLinuxCatalogEntry()))
        let instance = makeLinuxInstance(context: context, in: fixture) { $0.storageDisks = [] }

        try await fixture.coordinator.downloadLinuxImage(on: instance, context: context)

        let disks = try #require(instance.configuration.storageDisks)
        #expect(disks.count == 2)
        #expect(disks[1].label == "Main Disk")
        #expect(disks[1].isInternal)
    }

    @Test("A Linux download whose destination cannot be saved fails before the download")
    func downloadLinuxImageWhoseDestinationFailsStopsBeforeTheDownload() async throws {
        let fixture = try makeLinuxFixture()
        defer { try? FileManager.default.removeItem(at: fixture.downloads) }
        let context = LinuxInstallContext(source: .catalogEntry(makeLinuxCatalogEntry()))
        let instance = makeLinuxInstance(context: context, in: fixture)
        fixture.storage.saveConfigurationError = NSError(domain: "test", code: 1)

        await #expect(throws: VMLibrary.SettingsWriteFailure.self) {
            try await fixture.coordinator.downloadLinuxImage(on: instance, context: context)
        }

        #expect(fixture.downloadService.downloadCallCount == 0)
        #expect(fixture.downloadService.adoptExistingFileCallCount == 0)
        #expect(instance.configuration.linuxInstallContext == context)
        #expect(fixture.storage.bundles[instance.bundleURL]?.linuxInstallContext == context)
        #expect(instance.status == .error)
    }

    @Test("A Linux installer whose attach cannot be saved fails the setup and attaches nothing")
    func downloadLinuxImageWhoseAttachFailsAttachesNothing() async throws {
        let fixture = try makeLinuxFixture()
        defer { try? FileManager.default.removeItem(at: fixture.downloads) }
        // Already naming the resolved destination, so the attach is the one
        // write the pipeline makes.
        let destination = fixture.downloads.appendingPathComponent(
            fixture.resolveService.resolveResult.destinationFilename)
        let context = LinuxInstallContext(
            source: .catalogEntry(makeLinuxCatalogEntry()),
            downloadDestinationPath: destination.path(percentEncoded: false))
        let instance = makeLinuxInstance(context: context, in: fixture)
        let held = instance.configuration
        fixture.storage.saveConfigurationError = NSError(domain: "test", code: 1)

        await #expect(throws: VMLibrary.SettingsWriteFailure.self) {
            try await fixture.coordinator.downloadLinuxImage(on: instance, context: context)
        }

        #expect(fixture.downloadService.downloadCallCount == 1)
        #expect(instance.configuration == held)
        #expect(fixture.storage.bundles[instance.bundleURL] == held)
        #expect(instance.status == .error)
    }

    @Test("downloadLinuxImage persists the destination before the download runs")
    func downloadLinuxImagePersistsDestination() async throws {
        // Read on the failure path: a successful run clears the context.
        let fixture = try makeLinuxFixture()
        defer { try? FileManager.default.removeItem(at: fixture.downloads) }
        fixture.downloadService.downloadError = DownloadError.downloadFailed(
            URLError(.notConnectedToInternet))
        let context = LinuxInstallContext(source: .catalogEntry(makeLinuxCatalogEntry()))
        let instance = makeLinuxInstance(context: context, in: fixture)

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
        let instance = makeLinuxInstance(context: context, in: fixture)

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
        let unnormalized = makeTestLifecycle(downloadsDirectory: nil)
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
        let instance = makeLinuxInstance(context: context, in: fixture)

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
        let instance = makeLinuxInstance(context: context, in: fixture)

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
        let instance = makeLinuxInstance(context: context, in: fixture)

        try await fixture.coordinator.downloadLinuxImage(on: instance, context: context)

        let written = fixture.downloads.appendingPathComponent(resolved.destinationFilename)
        #expect(fixture.downloadService.lastDownloadDestinationURL == written)
        #expect(try Data(contentsOf: usersFile) == usersBytes)
        #expect(fixture.fileSystem.trashedURLs.isEmpty)
        #expect(
            instance.configuration.storageDisks?.first?.path
                == written.path(percentEncoded: false))
        // Its length is not the length the mirror states, so a stat refuses it
        // and no adoption is attempted — the file is never read.
        #expect(fixture.downloadService.adoptExistingFileCallCount == 0)
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
        let instance = makeLinuxInstance(context: context, in: fixture)

        await #expect(throws: DownloadError.self) {
            try await fixture.coordinator.downloadLinuxImage(on: instance, context: context)
        }

        #expect(
            fixture.fileSystem.trashedURLs
                == [fixture.downloads.appendingPathComponent(resolved.destinationFilename)])
    }

    // MARK: - Adopting a File Already in Downloads

    @Test("A file in Downloads hashing to the published digest is adopted instead of downloaded")
    func downloadLinuxImageAdoptsAMatchingLocalFile() async throws {
        let fixture = try makeLinuxFixture()
        defer { try? FileManager.default.removeItem(at: fixture.downloads) }
        // What a browser download of the same image leaves behind: the mirror's
        // own name, the mirror's own bytes.
        let resolved = fixture.resolveService.resolveResult
        let usersFile = fixture.downloads.appendingPathComponent(resolved.filename)
        try fixture.contents.write(to: usersFile)
        let context = LinuxInstallContext(source: .catalogEntry(makeLinuxCatalogEntry()))
        let instance = makeLinuxInstance(context: context, in: fixture)

        var observedSteps: [Int] = []
        let persist = instance.onUpdateConfiguration
        instance.onUpdateConfiguration = { mutate in
            if let index = instance.setupState?.currentStepIndex { observedSteps.append(index) }
            return persist?(mutate) ?? .refused(.noLibrary)
        }

        try await fixture.coordinator.downloadLinuxImage(on: instance, context: context)

        let destination = fixture.downloads.appendingPathComponent(resolved.destinationFilename)
        #expect(fixture.downloadService.downloadCallCount == 0)
        #expect(fixture.downloadService.adoptExistingFileCallCount == 1)
        #expect(fixture.downloadService.lastAdoptSourceURL == usersFile)
        #expect(fixture.downloadService.lastAdoptDestinationURL == destination)
        // The digest decided the adoption, so the pipeline still reaches Verify.
        #expect(observedSteps == [0, 1])

        // The user's file is theirs: still where they left it, byte for byte,
        // and the VM boots the destination the pipeline named.
        #expect(try Data(contentsOf: usersFile) == fixture.contents)
        #expect(try Data(contentsOf: destination) == fixture.contents)
        #expect(
            instance.configuration.storageDisks?.first?.path
                == destination.path(percentEncoded: false))
        #expect(fixture.fileSystem.trashedURLs.isEmpty)
        #expect(instance.configuration.linuxInstallContext == nil)
        #expect(instance.setupState == nil)
        #expect(instance.status == .stopped)
    }

    @Test("A same-named file of the right length but the wrong bytes is downloaded past")
    func downloadLinuxImageRefusesAMatchingLengthImposter() async throws {
        let fixture = try makeLinuxFixture()
        defer { try? FileManager.default.removeItem(at: fixture.downloads) }
        // Everything the cheap checks can see agrees; only the digest does not.
        let resolved = fixture.resolveService.resolveResult
        let usersFile = fixture.downloads.appendingPathComponent(resolved.filename)
        let usersBytes = Data(repeating: 0x41, count: fixture.contents.count)
        try usersBytes.write(to: usersFile)
        let context = LinuxInstallContext(source: .catalogEntry(makeLinuxCatalogEntry()))
        let instance = makeLinuxInstance(context: context, in: fixture)

        try await fixture.coordinator.downloadLinuxImage(on: instance, context: context)

        let destination = fixture.downloads.appendingPathComponent(resolved.destinationFilename)
        #expect(fixture.downloadService.adoptExistingFileCallCount == 0)
        #expect(fixture.downloadService.downloadCallCount == 1)
        #expect(fixture.downloadService.lastDownloadDestinationURL == destination)
        // A file that failed a digest that was never its own is still the
        // user's, so nothing happens to it.
        #expect(try Data(contentsOf: usersFile) == usersBytes)
        #expect(fixture.fileSystem.trashedURLs.isEmpty)
        #expect(instance.status == .stopped)
    }

    @Test("A URL pick with no digest never probes Downloads")
    func downloadLinuxImageSkipsTheProbeWithoutADigest() async throws {
        let fixture = try makeLinuxFixture()
        defer { try? FileManager.default.removeItem(at: fixture.downloads) }
        // The very bytes the pipeline is about to fetch are already there under
        // the source's name — and with no digest published, nothing can say so.
        fixture.resolveService.resolveResult = makeResolvedLinuxImage(
            sha256: nil, sizeBytes: UInt64(fixture.contents.count))
        let resolved = fixture.resolveService.resolveResult
        try fixture.contents.write(
            to: fixture.downloads.appendingPathComponent(resolved.filename))
        let context = makeCustomURLContext(fixture: fixture, verified: false)
        let instance = makeLinuxInstance(context: context, in: fixture)

        try await fixture.coordinator.downloadLinuxImage(on: instance, context: context)

        #expect(fixture.downloadService.adoptExistingFileCallCount == 0)
        #expect(fixture.downloadService.downloadCallCount == 1)
        #expect(instance.status == .stopped)
    }

    @Test("A destination already on disk is not probed against the candidate")
    func downloadLinuxImageSkipsTheProbeWhenTheDestinationExists() async throws {
        let fixture = try makeLinuxFixture()
        defer { try? FileManager.default.removeItem(at: fixture.downloads) }
        // The state the first adoption leaves behind: both names in Downloads,
        // holding the same bytes. A second VM from the same catalog entry must
        // not read the candidate end to end only to be refused the link.
        let resolved = fixture.resolveService.resolveResult
        try fixture.contents.write(
            to: fixture.downloads.appendingPathComponent(resolved.filename))
        let destination = fixture.downloads.appendingPathComponent(resolved.destinationFilename)
        try fixture.contents.write(to: destination)
        fixture.downloadService.downloadedContents = nil
        let context = LinuxInstallContext(source: .catalogEntry(makeLinuxCatalogEntry()))
        let instance = makeLinuxInstance(context: context, in: fixture)

        try await fixture.coordinator.downloadLinuxImage(on: instance, context: context)

        #expect(fixture.downloadService.adoptExistingFileCallCount == 0)
        // The ordinary path owns this: the download skips over the file already
        // at the destination, and Verify holds it to the same digest.
        #expect(fixture.downloadService.downloadCallCount == 1)
        #expect(
            instance.configuration.storageDisks?.first?.path
                == destination.path(percentEncoded: false))
        #expect(instance.status == .stopped)
    }

    @Test("A refused adoption falls through to the download and its verify step")
    func downloadLinuxImageDownloadsWhenAdoptionIsRefused() async throws {
        let fixture = try makeLinuxFixture()
        defer { try? FileManager.default.removeItem(at: fixture.downloads) }
        // What a transfer already streaming to the destination looks like from
        // here: the file matches, and the adoption is refused anyway.
        fixture.downloadService.adoptExistingFileResult = false
        let resolved = fixture.resolveService.resolveResult
        try fixture.contents.write(
            to: fixture.downloads.appendingPathComponent(resolved.filename))
        let context = LinuxInstallContext(source: .catalogEntry(makeLinuxCatalogEntry()))
        let instance = makeLinuxInstance(context: context, in: fixture)

        try await fixture.coordinator.downloadLinuxImage(on: instance, context: context)

        let destination = fixture.downloads.appendingPathComponent(resolved.destinationFilename)
        #expect(fixture.downloadService.adoptExistingFileCallCount == 1)
        #expect(fixture.downloadService.downloadCallCount == 1)
        #expect(
            instance.configuration.storageDisks?.first?.path
                == destination.path(percentEncoded: false))
        #expect(instance.configuration.linuxInstallContext == nil)
        #expect(instance.status == .stopped)
    }

    @Test("A source name already shaped like the destination is not adopted onto itself")
    func downloadLinuxImageDoesNotAdoptTheDestinationItself() async throws {
        let fixture = try makeLinuxFixture()
        defer { try? FileManager.default.removeItem(at: fixture.downloads) }
        // Nothing stops a source publishing the discriminated name this app
        // would derive for it, and a file cannot be linked onto itself.
        let isoURL = fixture.resolveService.resolveResult.isoURL
        fixture.resolveService.resolveResult = makeResolvedLinuxImage(
            filename: LinuxImageFilename.destination(for: isoURL),
            sha256: fixture.digest,
            sizeBytes: UInt64(fixture.contents.count))
        let destination = fixture.downloads.appendingPathComponent(
            fixture.resolveService.resolveResult.destinationFilename)
        try fixture.contents.write(to: destination)
        let context = LinuxInstallContext(source: .catalogEntry(makeLinuxCatalogEntry()))
        let instance = makeLinuxInstance(context: context, in: fixture)

        try await fixture.coordinator.downloadLinuxImage(on: instance, context: context)

        #expect(fixture.downloadService.adoptExistingFileCallCount == 0)
        // The ordinary path handles it: the download skips over the file
        // already sitting complete at the destination, and Verify checks it.
        #expect(fixture.downloadService.downloadCallCount == 1)
        #expect(instance.status == .stopped)
    }

    @Test("downloadLinuxImage throws CancellationError from the resolve step and keeps the context")
    func downloadLinuxImageCancelDuringResolve() async throws {
        let fixture = try makeLinuxFixture()
        defer { try? FileManager.default.removeItem(at: fixture.downloads) }
        fixture.resolveService.resolveError = CancellationError()
        let context = LinuxInstallContext(source: .catalogEntry(makeLinuxCatalogEntry()))
        let instance = makeLinuxInstance(context: context, in: fixture)

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
        let instance = makeLinuxInstance(context: context, in: fixture)

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
        let instance = makeLinuxInstance(context: context, in: fixture)

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
        let instance = makeLinuxInstance(context: context, in: fixture)

        // Sampled at each configuration write, the two points in the pipeline
        // whose step is known: the destination is persisted while Download
        // runs, and the ISO is attached once Verify has finished.
        var observedSteps: [Int] = []
        let persist = instance.onUpdateConfiguration
        instance.onUpdateConfiguration = { mutate in
            if let index = instance.setupState?.currentStepIndex { observedSteps.append(index) }
            return persist?(mutate) ?? .refused(.noLibrary)
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
        let instance = makeLinuxInstance(context: context, in: fixture)

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
        let instance = makeLinuxInstance(context: context, in: fixture)

        var observedSteps: [Int] = []
        let persist = instance.onUpdateConfiguration
        instance.onUpdateConfiguration = { mutate in
            if let index = instance.setupState?.currentStepIndex { observedSteps.append(index) }
            return persist?(mutate) ?? .refused(.noLibrary)
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
        let instance = makeLinuxInstance(context: context, in: fixture)

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
        let instance = makeLinuxInstance(context: context, in: fixture)

        await #expect(throws: LinuxImageURLError.self) {
            try await fixture.coordinator.downloadLinuxImage(on: instance, context: context)
        }

        #expect(fixture.downloadService.downloadCallCount == 0)
        #expect(instance.status == .error)
        #expect(instance.configuration.linuxInstallContext == context)
    }

    // MARK: - Removable Media Attach/Detach

    @Test("attachRemovableMedia forwards to removable media device service")
    func attachRemovableMediaForwards() async throws {
        let (coordinator, _, _, _, removableMediaService) = makeCoordinator()
        let sessionID = UUID()
        let instance = VMInstanceFixture.make()
        instance.beginSessionContext()
        instance.activity.placeForTesting(.running(sessionID: sessionID))

        let info = try await coordinator.attachRemovableMedia(
            diskImagePath: "/tmp/test.dmg",
            readOnly: true,
            to: instance,
            for: sessionID
        )

        #expect(removableMediaService.attachCallCount == 1)
        #expect(removableMediaService.lastAttachedPath == "/tmp/test.dmg")
        #expect(removableMediaService.lastAttachedReadOnly == true)
        #expect(info.path == "/tmp/test.dmg")
        #expect(info.readOnly == true)
        #expect(instance.liveRemovableMedia.count == 1)
        #expect(instance.liveRemovableMedia[0].id == info.id)
    }

    @Test("detachRemovableMedia forwards to removable media device service")
    func detachRemovableMediaForwards() async throws {
        let (coordinator, _, _, _, removableMediaService) = makeCoordinator()
        let sessionID = UUID()
        let instance = VMInstanceFixture.make()
        instance.beginSessionContext()
        instance.activity.placeForTesting(.running(sessionID: sessionID))

        let info = try await coordinator.attachRemovableMedia(
            diskImagePath: "/tmp/test.dmg",
            readOnly: false,
            to: instance,
            for: sessionID
        )

        try await coordinator.detachRemovableMedia(info, from: instance, for: sessionID)

        #expect(removableMediaService.detachCallCount == 1)
        #expect(instance.liveRemovableMedia.isEmpty)
    }

    @Test("attachRemovableMedia propagates error from removable media device service")
    func attachRemovableMediaPropagatesError() async {
        let (coordinator, _, _, _, removableMediaService) = makeCoordinator()
        removableMediaService.attachError = RemovableMediaDeviceError.noVirtualMachine
        let sessionID = UUID()
        let instance = VMInstanceFixture.make()
        instance.activity.placeForTesting(.running(sessionID: sessionID))

        await #expect(throws: RemovableMediaDeviceError.self) {
            try await coordinator.attachRemovableMedia(
                diskImagePath: "/tmp/test.dmg",
                readOnly: false,
                to: instance,
                for: sessionID
            )
        }
    }

    @Test("detachRemovableMedia propagates error from removable media device service")
    func detachRemovableMediaPropagatesError() async throws {
        let (coordinator, _, _, _, removableMediaService) = makeCoordinator()
        let sessionID = UUID()
        let instance = VMInstanceFixture.make()
        instance.beginSessionContext()
        instance.activity.placeForTesting(.running(sessionID: sessionID))

        let info = try await coordinator.attachRemovableMedia(
            diskImagePath: "/tmp/test.dmg",
            readOnly: false,
            to: instance,
            for: sessionID
        )

        removableMediaService.detachError = RemovableMediaDeviceError.deviceNotFound

        await #expect(throws: RemovableMediaDeviceError.self) {
            try await coordinator.detachRemovableMedia(info, from: instance, for: sessionID)
        }

        // Device should still be tracked since detach failed
        #expect(instance.liveRemovableMedia.count == 1)
    }

    @Test("attachRemovableMedia and detachRemovableMedia never reach the service for a superseded session")
    func removableMediaPassThroughDropsASupersededSession() async throws {
        let (coordinator, _, _, _, removableMediaService) = makeCoordinator()
        let sessionID = UUID()
        let instance = VMInstanceFixture.make()
        instance.beginSessionContext()
        instance.activity.placeForTesting(.running(sessionID: sessionID))

        let info = try await coordinator.attachRemovableMedia(
            diskImagePath: "/tmp/test.dmg",
            readOnly: true,
            to: instance,
            for: sessionID
        )
        // Force stop and restart: the pass acting for `sessionID` is overtaken.
        instance.tearDownSession(restingAt: .stopped)
        instance.beginSessionContext()
        instance.activity.placeForTesting(.running(sessionID: UUID()))
        let attachesBefore = removableMediaService.attachCallCount

        // `noVirtualMachine` specifically: it is the case `VMLibrary`'s
        // abandon-the-reconcile arms catch. `RemovableMediaDeviceError` is not
        // `Equatable`, so the arm is what states the expectation.
        var attachBailed = false
        do {
            _ = try await coordinator.attachRemovableMedia(
                diskImagePath: "/tmp/test.dmg",
                readOnly: true,
                to: instance,
                for: sessionID
            )
        } catch RemovableMediaDeviceError.noVirtualMachine {
            attachBailed = true
        }
        var detachBailed = false
        do {
            try await coordinator.detachRemovableMedia(info, from: instance, for: sessionID)
        } catch RemovableMediaDeviceError.noVirtualMachine {
            detachBailed = true
        }

        #expect(attachBailed)
        #expect(detachBailed)
        #expect(removableMediaService.attachCallCount == attachesBefore)
        #expect(removableMediaService.detachCallCount == 0)
        #expect(instance.liveRemovableMedia.isEmpty)
    }

    @Test("attachRemovableMedia attaches the resolved URL but tracks the stored path")
    func attachRemovableMediaTracksStoredPathWithResolvedURL() async throws {
        let (coordinator, _, _, _, removableMediaService) = makeCoordinator()
        let sessionID = UUID()
        let instance = VMInstanceFixture.make()
        instance.beginSessionContext()
        instance.activity.placeForTesting(.running(sessionID: sessionID))

        // A bookmark that tracked a moved file: the resolved location is
        // what must reach the service, while the tracked identity stays the
        // config's stored path so the live reconcile's path comparison
        // doesn't churn.
        let info = try await coordinator.attachRemovableMedia(
            diskImagePath: "/old/location/media.iso",
            readOnly: true,
            resolvedURL: URL(fileURLWithPath: "/new/location/media.iso"),
            to: instance,
            for: sessionID
        )

        #expect(removableMediaService.lastAttachedPath == "/new/location/media.iso")
        #expect(info.path == "/old/location/media.iso")
        #expect(instance.liveRemovableMedia.first?.path == "/old/location/media.iso")
    }

    // MARK: - Download Destination Normalization

    @Test("normalizedDownloadDestination keeps Downloads paths and redirects others to the default")
    func normalizedDownloadDestinationEnforcesDownloads() throws {
        let downloads = FileManager.default.temporaryDirectory
            .appendingPathComponent("Downloads-\(UUID().uuidString)", isDirectory: true)
        let (coordinator, _, _, _, _) = makeCoordinator(downloadsDirectory: downloads)
        let inDownloads = downloads.appendingPathComponent("Custom.ipsw")
        #expect(coordinator.normalizedDownloadDestination(for: inDownloads) == inDownloads)

        // A pre-sandbox custom destination outside Downloads can never be
        // written under the sandbox — it must fall back to the default.
        let elsewhere = URL(fileURLWithPath: "/Users/Shared/RestoreImage.ipsw")
        let normalized = coordinator.normalizedDownloadDestination(for: elsewhere)
        #expect(normalized == downloads.appendingPathComponent(RestoreImageFilename.fallback))
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
        // path unexamined.
        let coordinator = makeTestLifecycle(downloadsDirectory: nil)
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

/// Records that a `withObservationTracking` `onChange` fired, from the
/// `@Sendable` closure the API hands it — which no actor-isolated state can be
/// written from.
private final class ObservationFireRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var didFire: Bool { lock.withLock { value } }

    func record() { lock.withLock { value = true } }
}
