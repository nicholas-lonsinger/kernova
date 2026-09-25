import Foundation
import KernovaTestSupport
import Testing

@testable import Kernova

@Suite("VMRemovableMediaReconciler Tests", .serialized, .admissionGated)
@MainActor
struct VMRemovableMediaReconcilerTests {
    /// What the reconciler asked a user to be told, in place of a presenter.
    private let failures = MockLibraryFailureSink()
    private let fileSystem = MockFileSystem()

    /// The reconciler under test is a library's own, so an edit reaches it the
    /// way every edit does — through the configuration write that queues the
    /// pass — and a refused pass settles the configuration that library holds.
    @MainActor
    private struct Harness {
        let library: VMLibrary
        let storage: MockVMStorageService
        let lifecycle: VMLifecycleCoordinator
        let virtualization: MockVirtualizationService

        var reconciler: VMRemovableMediaReconciler { library.removableMedia }

        /// The configuration `instance`'s bundle holds.
        func saved(_ instance: VMInstance) -> VMConfiguration? {
            storage.bundles[instance.bundleURL]
        }
    }

    private func makeHarness(
        removableMediaDeviceService: any RemovableMediaAttaching = MockRemovableMediaDeviceService()
    ) -> Harness {
        let virtualization = MockVirtualizationService()
        let lifecycle = makeTestLifecycle(
            virtualization: virtualization, removableMedia: removableMediaDeviceService,
            fileSystem: fileSystem)
        let storage = MockVMStorageService()
        let library = makeWiredLibrary(storage: storage, lifecycle: lifecycle, fileSystem: fileSystem)
        library.onFailure = { [failures] title, message in
            failures.record(title: title, message: message)
        }
        return Harness(
            library: library, storage: storage, lifecycle: lifecycle, virtualization: virtualization)
    }

    /// An instance in `harness`'s library, built with `mutate` and live on a
    /// session of its own.
    private func makeRunningInstance(
        in harness: Harness, _ mutate: (inout VMConfiguration) -> Void = { _ in }
    ) -> (instance: VMInstance, sessionID: UUID) {
        let instance = VMInstanceFixture.make(mutate: mutate)
        harness.library.register(instance, storage: harness.storage)
        let sessionID = UUID()
        instance.activity.placeForTesting(.running(sessionID: sessionID))
        instance.beginSessionContext()
        return (instance, sessionID)
    }

    /// Whether a removable-media reconcile holds `instance`.
    private func isReconciling(_ instance: VMInstance) -> Bool {
        instance.phase.operation?.kind == .reconcilingMedia
    }

    /// Helper: build a config with a single removable media item.
    private func configWithRemovable(
        _ base: VMConfiguration,
        path: String,
        readOnly: Bool = true,
        id: UUID = UUID()
    ) -> VMConfiguration {
        var c = base
        c.removableMedia = [RemovableMediaItem(id: id, path: path, readOnly: readOnly)]
        return c
    }

    @Test("refuseUnattachableEdit refuses a media change only on a live session no pass can drive")
    func refuseUnattachableEditTracksThePhase() {
        let reconciler = makeHarness().reconciler
        let sessionID = UUID()
        let live = VMLifecyclePhase.running(sessionID: sessionID)
        let unattachable: [VMLifecyclePhase] = [
            .operating(.saving, from: live), .operating(.capturingSnapshot(.live), from: live),
        ]
        let admitting: [VMLifecyclePhase] = [
            .running(sessionID: sessionID), .livePaused(sessionID: sessionID), .stopped, .suspended,
        ]

        for phase in unattachable + admitting {
            let instance = VMInstanceFixture.make()
            instance.activity.placeForTesting(phase)
            let old = instance.configuration
            let mediaChange = configWithRemovable(old, path: "/tmp/A.iso")
            var otherChange = old
            otherChange.memorySizeInGB = 6

            let refusesMedia = reconciler.refuseUnattachableEdit(
                on: instance, movingFrom: old, to: mediaChange)
            let refusesOther = reconciler.refuseUnattachableEdit(
                on: instance, movingFrom: old, to: otherChange)

            #expect(refusesMedia == unattachable.contains(phase), "\(phase)")
            #expect(refusesOther == false, "\(phase)")
        }
    }

    @Test("apply attaches a new removable item when added to the list")
    func liveRemovableAddAttaches() async throws {
        let mock = MockRemovableMediaDeviceService()
        let harness = makeHarness(removableMediaDeviceService: mock)
        let (instance, _) = makeRunningInstance(in: harness)

        let configuredUUID = UUID()
        let new = configWithRemovable(
            instance.configuration, path: "/tmp/install.iso", readOnly: true, id: configuredUUID)

        harness.library.editConfiguration(of: instance) { $0 = new }

        while instance.liveRemovableMedia.isEmpty { await Task.yield() }

        #expect(mock.attachCallCount == 1)
        #expect(mock.detachCallCount == 0)
        #expect(mock.lastAttachedPath == "/tmp/install.iso")
        #expect(mock.lastAttachedReadOnly == true)
        #expect(mock.lastAttachedDesiredUUID == configuredUUID)
        #expect(instance.liveRemovableMedia.count == 1)
        #expect(instance.liveRemovableMedia.first?.id == configuredUUID)
        #expect(instance.liveRemovableMedia.first?.path == "/tmp/install.iso")
    }

    @Test("apply detaches and clears tracking when the only item is removed")
    func liveRemovableRemoveDetaches() async throws {
        let mock = MockRemovableMediaDeviceService()
        let harness = makeHarness(removableMediaDeviceService: mock)
        let id = UUID()
        let (instance, sessionID) = makeRunningInstance(in: harness) {
            $0.removableMedia = [RemovableMediaItem(id: id, path: "/tmp/install.iso", readOnly: true)]
        }
        instance.recordAttachedMedia(
            RemovableMediaDeviceInfo(id: id, path: "/tmp/install.iso", readOnly: true), for: sessionID)

        harness.library.editConfiguration(of: instance) { $0.removableMedia = nil }

        while !instance.liveRemovableMedia.isEmpty { await Task.yield() }

        #expect(mock.detachCallCount == 1)
        #expect(mock.attachCallCount == 0)
        #expect(instance.liveRemovableMedia.isEmpty)
    }

    @Test("apply swaps the only item: detach old, attach new")
    func liveRemovableSwapDetachesThenAttaches() async throws {
        let mock = MockRemovableMediaDeviceService()
        let harness = makeHarness(removableMediaDeviceService: mock)
        let oldID = UUID()
        let (instance, sessionID) = makeRunningInstance(in: harness) {
            $0.removableMedia = [RemovableMediaItem(id: oldID, path: "/tmp/old.iso", readOnly: true)]
        }
        instance.recordAttachedMedia(
            RemovableMediaDeviceInfo(id: oldID, path: "/tmp/old.iso", readOnly: true), for: sessionID)

        let newID = UUID()
        harness.library.editConfiguration(of: instance) {
            $0.removableMedia = [RemovableMediaItem(id: newID, path: "/tmp/new.iso", readOnly: true)]
        }

        while instance.liveRemovableMedia.first?.path != "/tmp/new.iso" { await Task.yield() }

        #expect(mock.detachCallCount == 1)
        #expect(mock.attachCallCount == 1)
        #expect(mock.lastAttachedPath == "/tmp/new.iso")
        #expect(instance.liveRemovableMedia.count == 1)
        #expect(instance.liveRemovableMedia.first?.id == newID)
    }

    @Test("apply detaches and reattaches on readOnly flip (same id)")
    func liveRemovableReadOnlyFlipReattaches() async throws {
        let mock = MockRemovableMediaDeviceService()
        let harness = makeHarness(removableMediaDeviceService: mock)
        let id = UUID()
        let (instance, sessionID) = makeRunningInstance(in: harness) {
            $0.removableMedia = [RemovableMediaItem(id: id, path: "/tmp/install.iso", readOnly: true)]
        }
        instance.recordAttachedMedia(
            RemovableMediaDeviceInfo(id: id, path: "/tmp/install.iso", readOnly: true), for: sessionID)

        harness.library.editConfiguration(of: instance) {
            $0.removableMedia = [RemovableMediaItem(id: id, path: "/tmp/install.iso", readOnly: false)]
        }

        while instance.liveRemovableMedia.first?.readOnly != false { await Task.yield() }

        #expect(mock.detachCallCount == 1)
        #expect(mock.attachCallCount == 1)
        #expect(mock.lastAttachedReadOnly == false)
    }

    @Test("apply is a no-op when storageDisks change but removableMedia is unchanged")
    func liveRemovableNoopWhenOnlyStorageDisksChange() async throws {
        let mock = MockRemovableMediaDeviceService()
        let harness = makeHarness(removableMediaDeviceService: mock)
        let (instance, _) = makeRunningInstance(in: harness)

        let old = instance.configuration
        var new = old
        new.storageDisks = [
            StorageDisk(path: "Disk.asif", readOnly: false, label: "Main Disk", isInternal: true, kind: .virtio)
        ]

        harness.reconciler.apply(for: instance, old: old, new: new)
        for _ in 0..<5 { await Task.yield() }

        #expect(mock.attachCallCount == 0)
        #expect(mock.detachCallCount == 0)
    }

    @Test("apply is a no-op when VM is stopped, even with media change")
    func liveRemovableNoopWhenStopped() async throws {
        let mock = MockRemovableMediaDeviceService()
        let harness = makeHarness(removableMediaDeviceService: mock)
        let instance = VMInstanceFixture.make()
        instance.activity.placeForTesting(.stopped)

        let old = instance.configuration
        let new = configWithRemovable(old, path: "/tmp/install.iso")

        harness.reconciler.apply(for: instance, old: old, new: new)
        for _ in 0..<5 { await Task.yield() }

        #expect(mock.attachCallCount == 0)
        #expect(mock.detachCallCount == 0)
        #expect(instance.liveRemovableMedia.isEmpty)
    }

    @Test("apply is a no-op for a cold-paused VM, which has no session to attach to")
    func liveRemovableNoopWhenColdPaused() async throws {
        let mock = MockRemovableMediaDeviceService()
        let harness = makeHarness(removableMediaDeviceService: mock)
        let instance = VMInstanceFixture.make()
        instance.activity.placeForTesting(.suspended)

        let old = instance.configuration
        let new = configWithRemovable(old, path: "/tmp/install.iso")

        harness.reconciler.apply(for: instance, old: old, new: new)
        for _ in 0..<5 { await Task.yield() }

        #expect(mock.attachCallCount == 0)
        #expect(mock.detachCallCount == 0)
        #expect(instance.liveRemovableMedia.isEmpty)
        #expect(!failures.showError)
    }

    @Test("Live attach failure surfaces error")
    func liveRemovableAttachFailureSurfacesError() async throws {
        let mock = MockRemovableMediaDeviceService()
        mock.attachError = RemovableMediaDeviceError.diskImageNotFound("/tmp/missing.iso")
        let harness = makeHarness(removableMediaDeviceService: mock)
        let (instance, _) = makeRunningInstance(in: harness)

        harness.library.editConfiguration(of: instance) {
            $0 = configWithRemovable($0, path: "/tmp/missing.iso")
        }

        while !failures.showError { await Task.yield() }

        #expect(mock.attachCallCount == 1)
        #expect(failures.errorMessage != nil)
        #expect(instance.liveRemovableMedia.isEmpty)
    }

    @Test("deviceNotFound on detach is treated as confirmed-gone — reconcile continues with attach")
    func liveRemovableDetachDeviceNotFoundContinues() async throws {
        // deviceNotFound means the guest (or framework) already removed the
        // device — for example, the user ejected it from inside the guest.
        // The reconcile must clear tracking and proceed with the next
        // operation in the diff.
        let mock = MockRemovableMediaDeviceService()
        mock.detachError = RemovableMediaDeviceError.deviceNotFound
        let harness = makeHarness(removableMediaDeviceService: mock)
        let oldID = UUID()
        let (instance, sessionID) = makeRunningInstance(in: harness) {
            $0.removableMedia = [RemovableMediaItem(id: oldID, path: "/tmp/old.iso", readOnly: true)]
        }
        instance.recordAttachedMedia(
            RemovableMediaDeviceInfo(id: oldID, path: "/tmp/old.iso", readOnly: true), for: sessionID)

        let newID = UUID()
        harness.library.editConfiguration(of: instance) {
            $0.removableMedia = [RemovableMediaItem(id: newID, path: "/tmp/new.iso", readOnly: true)]
        }

        while instance.liveRemovableMedia.first?.path != "/tmp/new.iso" { await Task.yield() }

        #expect(mock.detachCallCount == 1)
        #expect(mock.attachCallCount == 1)
        #expect(instance.liveRemovableMedia.first?.path == "/tmp/new.iso")
    }

    @Test("A failed eject still attaches the rest of the target, and the config names both")
    func failedEjectDoesNotSkipTheRest() async throws {
        struct TransientError: Error {}
        let mock = MockRemovableMediaDeviceService()
        mock.detachError = TransientError()
        let harness = makeHarness(removableMediaDeviceService: mock)
        let old = RemovableMediaItem(path: "/tmp/old.iso", readOnly: true)
        let (instance, sessionID) = makeRunningInstance(in: harness) { $0.removableMedia = [old] }
        instance.recordAttachedMedia(
            RemovableMediaDeviceInfo(id: old.id, path: old.path, readOnly: true), for: sessionID)
        let new = RemovableMediaItem(path: "/tmp/new.iso", readOnly: true)

        harness.library.editConfiguration(of: instance) { $0.removableMedia = [new] }
        await waitForObservedChange { !isReconciling(instance) }

        #expect(mock.detachCallCount == 1)
        #expect(mock.attachCallCount == 1)
        #expect(Set(instance.liveRemovableMedia.map(\.path)) == ["/tmp/old.iso", "/tmp/new.iso"])
        #expect(Set(instance.configuration.removableMedia?.map(\.id) ?? []) == [old.id, new.id])
        #expect(failures.errorMessage?.contains("\u{201C}old.iso\u{201D}") == true)
    }

    @Test("A slot whose eject failed is not attached again, its medium still there")
    func failedEjectLeavesItsSlotAlone() async throws {
        struct TransientError: Error {}
        let mock = MockRemovableMediaDeviceService()
        mock.detachError = TransientError()
        let harness = makeHarness(removableMediaDeviceService: mock)
        let id = UUID()
        let (instance, sessionID) = makeRunningInstance(in: harness) {
            $0.removableMedia = [RemovableMediaItem(id: id, path: "/tmp/install.iso", readOnly: true)]
        }
        instance.recordAttachedMedia(
            RemovableMediaDeviceInfo(id: id, path: "/tmp/install.iso", readOnly: true), for: sessionID)

        harness.library.editConfiguration(of: instance) {
            $0.removableMedia = [RemovableMediaItem(id: id, path: "/tmp/install.iso", readOnly: false)]
        }
        await waitForObservedChange { !isReconciling(instance) }

        #expect(mock.detachCallCount == 1)
        #expect(mock.attachCallCount == 0)
        #expect(instance.configuration.removableMedia?.map(\.readOnly) == [true])
        #expect(failures.showError)
    }

    @Test("A pass attempts every item: one failed attach leaves the rest attached and named")
    func failedAttachDoesNotSkipTheRest() async throws {
        let mock = MockRemovableMediaDeviceService()
        mock.attachErrorsByPath["/tmp/bad.iso"] = RemovableMediaDeviceError.diskImageNotFound(
            "/tmp/bad.iso")
        let harness = makeHarness(removableMediaDeviceService: mock)
        let (instance, _) = makeRunningInstance(in: harness)
        let bad = RemovableMediaItem(path: "/tmp/bad.iso", readOnly: true)
        let good = RemovableMediaItem(path: "/tmp/good.iso", readOnly: true)

        harness.library.editConfiguration(of: instance) { $0.removableMedia = [bad, good] }
        await waitForObservedChange { !isReconciling(instance) }

        #expect(mock.attachCallCount == 2)
        #expect(instance.liveRemovableMedia.map(\.path) == ["/tmp/good.iso"])
        #expect(instance.configuration.removableMedia == [good])
        #expect(harness.saved(instance)?.removableMedia == [good])
        #expect(failures.errorMessage?.contains("\u{201C}bad\u{201D}") == true)
        #expect(failures.errorMessage?.contains("good") == false)
    }

    @Test("Detach noVirtualMachine error bails the reconcile silently")
    func liveRemovableDetachNoVMBails() async throws {
        let mock = MockRemovableMediaDeviceService()
        mock.detachError = RemovableMediaDeviceError.noVirtualMachine
        let harness = makeHarness(removableMediaDeviceService: mock)
        let oldID = UUID()
        let (instance, sessionID) = makeRunningInstance(in: harness) {
            $0.removableMedia = [RemovableMediaItem(id: oldID, path: "/tmp/old.iso", readOnly: true)]
        }
        instance.recordAttachedMedia(
            RemovableMediaDeviceInfo(id: oldID, path: "/tmp/old.iso", readOnly: true), for: sessionID)

        harness.library.editConfiguration(of: instance) {
            $0.removableMedia = [RemovableMediaItem(path: "/tmp/new.iso", readOnly: true)]
        }
        for _ in 0..<10 { await Task.yield() }

        #expect(mock.detachCallCount == 1)
        #expect(mock.attachCallCount == 0)
        #expect(!failures.showError)
    }

    @Test("Attach noVirtualMachine error bails the reconcile silently")
    func liveRemovableAttachNoVMBails() async throws {
        let mock = MockRemovableMediaDeviceService()
        mock.attachError = RemovableMediaDeviceError.noVirtualMachine
        let harness = makeHarness(removableMediaDeviceService: mock)
        let (instance, _) = makeRunningInstance(in: harness)

        harness.library.editConfiguration(of: instance) {
            $0 = configWithRemovable($0, path: "/tmp/install.iso")
        }
        for _ in 0..<10 { await Task.yield() }

        #expect(mock.attachCallCount == 1)
        #expect(mock.detachCallCount == 0)
        #expect(!failures.showError)
        #expect(instance.liveRemovableMedia.isEmpty)
    }

    @Test("Reconcile loop bails out when VM stops mid-pass — no spurious error")
    func liveRemovableReconcileBailsOutOnVMStop() async throws {
        let mock = SuspendingMockRemovableMediaDeviceService()
        let harness = makeHarness(removableMediaDeviceService: mock)
        let (instance, _) = makeRunningInstance(in: harness)

        let baseConfig = instance.configuration
        let configA = configWithRemovable(baseConfig, path: "/tmp/A.iso")
        let configB = configWithRemovable(baseConfig, path: "/tmp/B.iso")

        harness.library.editConfiguration(of: instance) { $0 = configA }
        await mock.waitUntilSuspended()
        // Stop the VM before the suspended attach resolves.
        harness.library.editConfiguration(of: instance) { $0 = configB }
        instance.activity.placeForTesting(.stopped)

        mock.resumeSuspended()
        for _ in 0..<10 { await Task.yield() }

        #expect(mock.attachCallCount == 1)
        #expect(mock.lastAttachedPath == "/tmp/A.iso")
        #expect(!failures.showError)
    }

    @Test("A pass overtaken by a force stop and restart records nothing on the successor")
    func liveRemovableOvertakenPassLeavesTheSuccessorAlone() async throws {
        let mock = SuspendingMockRemovableMediaDeviceService()
        let harness = makeHarness(removableMediaDeviceService: mock)
        let (instance, _) = makeRunningInstance(in: harness)

        let configA = configWithRemovable(instance.configuration, path: "/tmp/A.iso")
        harness.library.editConfiguration(of: instance) { $0 = configA }
        await mock.waitUntilSuspended()

        // Force Stop, then Start: the suspended attach now answers for a
        // session two transitions old.
        instance.handleSessionEvent(.guestDidStop)
        instance.beginSessionContext()
        instance.activity.placeForTesting(.running(sessionID: UUID()))

        mock.resumeSuspended()
        try await mock.operationCompleted.wait { mock.completedOperationCount == 1 }
        for _ in 0..<5 { await Task.yield() }

        #expect(mock.attachCallCount == 1)
        #expect(mock.detachCallCount == 0)
        #expect(instance.liveRemovableMedia.isEmpty)
        #expect(!failures.showError)
        #expect(instance.configuration == configA)
    }

    @Test("An overtaken pass's failure neither alerts nor rolls the config back")
    func liveRemovableOvertakenPassFailureIsDropped() async throws {
        let mock = SuspendingMockRemovableMediaDeviceService()
        let harness = makeHarness(removableMediaDeviceService: mock)
        let (instance, _) = makeRunningInstance(in: harness)

        let configA = configWithRemovable(instance.configuration, path: "/tmp/A.iso")
        harness.library.editConfiguration(of: instance) { $0 = configA }
        await mock.waitUntilSuspended()

        // The force stop is what makes the attach fail, so the alert would name
        // an error the user caused and the rollback would describe the
        // successor's — here empty — live media.
        mock.attachError = RemovableMediaDeviceError.diskImageNotFound("/tmp/A.iso")
        instance.handleSessionEvent(.guestDidStop)
        instance.beginSessionContext()
        instance.activity.placeForTesting(.running(sessionID: UUID()))

        mock.resumeSuspended()
        try await mock.operationCompleted.wait { mock.completedOperationCount == 1 }
        for _ in 0..<5 { await Task.yield() }

        #expect(!failures.showError)
        #expect(failures.errorMessage == nil)
        #expect(instance.configuration == configA)
        #expect(harness.saved(instance) == configA)
    }

    @Test("A target queued for a session that ends is dropped, not drained onto its successor")
    func liveRemovableQueuedTargetIsNotDrainedOntoTheSuccessor() async throws {
        let mock = SuspendingMockRemovableMediaDeviceService()
        let harness = makeHarness(removableMediaDeviceService: mock)
        let (instance, _) = makeRunningInstance(in: harness)

        let baseConfig = instance.configuration
        let configA = configWithRemovable(baseConfig, path: "/tmp/A.iso")
        let configB = configWithRemovable(baseConfig, path: "/tmp/B.iso")
        let configC = configWithRemovable(baseConfig, path: "/tmp/C.iso")

        // The pass for A suspends inside the attach; B queues behind it.
        harness.library.editConfiguration(of: instance) { $0 = configA }
        await mock.waitUntilSuspended()
        harness.library.editConfiguration(of: instance) { $0 = configB }

        // Force Stop; an edit to C made while stopped persists but queues
        // nothing, so B stays queued; then Start, cold-booting C.
        instance.handleSessionEvent(.guestDidStop)
        harness.library.editConfiguration(of: instance) { $0 = configC }
        instance.beginSessionContext()
        let successorID = UUID()
        instance.activity.placeForTesting(.running(sessionID: successorID))
        let coldBooted = RemovableMediaDeviceInfo(
            id: try #require(configC.removableMedia?.first?.id), path: "/tmp/C.iso", readOnly: true)
        instance.recordAttachedMedia(coldBooted, for: successorID)

        mock.resumeSuspended()
        try await mock.operationCompleted.wait { mock.completedOperationCount == 1 }
        for _ in 0..<10 { await Task.yield() }

        // Draining B here would detach C's medium and attach B's, leaving the
        // guest on B while the config says C.
        #expect(mock.attachCallCount == 1)
        #expect(mock.lastAttachedPath == "/tmp/A.iso")
        #expect(mock.detachCallCount == 0)
        #expect(instance.liveRemovableMedia == [coldBooted])
        #expect(instance.configuration == configC)
        #expect(!failures.showError)
    }

    @Test("Rapid-fire media swaps coalesce — one Task drains to the latest target")
    func liveRemovableRapidFireCoalescesToLatest() async throws {
        let mock = SuspendingMockRemovableMediaDeviceService()
        let harness = makeHarness(removableMediaDeviceService: mock)
        let (instance, _) = makeRunningInstance(in: harness)

        let baseConfig = instance.configuration
        let configA = configWithRemovable(baseConfig, path: "/tmp/A.iso")
        let configB = configWithRemovable(baseConfig, path: "/tmp/B.iso")
        let configC = configWithRemovable(baseConfig, path: "/tmp/C.iso")

        // Three rapid edits before the first attach can complete.
        harness.library.editConfiguration(of: instance) { $0 = configA }
        await mock.waitUntilSuspended()
        harness.library.editConfiguration(of: instance) { $0 = configB }
        harness.library.editConfiguration(of: instance) { $0 = configC }

        // Release the suspended attach (A); the loop should then detach A,
        // attach C (B was overwritten before any attach started for it).
        mock.resumeSuspended()
        await mock.waitUntilSuspended()
        mock.resumeSuspended()

        while instance.liveRemovableMedia.first?.path != "/tmp/C.iso" { await Task.yield() }

        // Final state: A then C attached; A detached. B was skipped entirely.
        #expect(mock.attachCallCount == 2)
        #expect(mock.detachCallCount == 1)
        #expect(mock.lastAttachedPath == "/tmp/C.iso")
        #expect(instance.liveRemovableMedia.first?.path == "/tmp/C.iso")
        #expect(instance.liveRemovableMedia.first?.id == configC.removableMedia?.first?.id)
    }

    @Test("A refused pass with a newer edit queued behind it leaves that edit to the next pass")
    func refusedPassDoesNotSettleOverAQueuedEdit() async throws {
        // The failing pass's session is still live and the newer target is
        // already saved as the configuration: settling on the live list there
        // would overwrite that edit, and the next pass would then drive the VM
        // onto a list the configuration no longer names.
        let mock = SuspendingMockRemovableMediaDeviceService()
        let harness = makeHarness(removableMediaDeviceService: mock)
        let (instance, _) = makeRunningInstance(in: harness)

        let baseConfig = instance.configuration
        let configA = configWithRemovable(baseConfig, path: "/tmp/A.iso")
        let configB = configWithRemovable(baseConfig, path: "/tmp/B.iso")

        harness.library.editConfiguration(of: instance) { $0 = configA }
        await mock.waitUntilSuspended()
        harness.library.editConfiguration(of: instance) { $0 = configB }

        // A's attach is refused; B's, which the drain runs next, lands.
        mock.attachError = RemovableMediaDeviceError.diskImageNotFound("/tmp/A.iso")
        mock.resumeSuspended()
        await mock.waitUntilSuspended()
        mock.attachError = nil
        mock.resumeSuspended()
        await waitForObservedChange { !isReconciling(instance) }

        #expect(mock.attachCallCount == 2)
        #expect(instance.liveRemovableMedia.map(\.path) == ["/tmp/B.iso"])
        #expect(instance.configuration == configB)
        #expect(harness.saved(instance) == configB)
        #expect(!failures.showError)
    }

    @Test("A refused pass that is the last one settles the configuration on the live list")
    func refusedLastPassSettlesOnTheLiveList() async throws {
        let mock = SuspendingMockRemovableMediaDeviceService()
        let harness = makeHarness(removableMediaDeviceService: mock)
        let (instance, _) = makeRunningInstance(in: harness)

        let baseConfig = instance.configuration
        let configA = configWithRemovable(baseConfig, path: "/tmp/A.iso")
        let configB = configWithRemovable(baseConfig, path: "/tmp/B.iso")

        harness.library.editConfiguration(of: instance) { $0 = configA }
        await mock.waitUntilSuspended()
        harness.library.editConfiguration(of: instance) { $0 = configB }

        // Both attaches are refused, so what is live when the queue empties —
        // nothing — is what the configuration ends up describing.
        mock.attachError = RemovableMediaDeviceError.diskImageNotFound("/tmp/A.iso")
        mock.resumeSuspended()
        await mock.waitUntilSuspended()
        mock.resumeSuspended()
        await waitForObservedChange { !isReconciling(instance) }

        #expect(mock.attachCallCount == 2)
        #expect(instance.liveRemovableMedia.isEmpty)
        #expect(instance.configuration.removableMedia == nil)
        #expect(harness.saved(instance)?.removableMedia == nil)
        #expect(failures.showError)
    }

    @Test("apply holds the VM in a reconcile from the edit's commit until the pass drains")
    func applyHoldsTheVMUntilThePassDrains() async throws {
        let mock = SuspendingMockRemovableMediaDeviceService()
        let harness = makeHarness(removableMediaDeviceService: mock)
        let (instance, _) = makeRunningInstance(in: harness)
        #expect(!isReconciling(instance))

        let configA = configWithRemovable(instance.configuration, path: "/tmp/A.iso")
        harness.library.editConfiguration(of: instance) { $0 = configA }

        // Held from the edit's own commit, before the pass has had a turn.
        #expect(isReconciling(instance))
        await mock.waitUntilSuspended()
        #expect(isReconciling(instance))

        mock.resumeSuspended()
        await waitForObservedChange { !isReconciling(instance) }
        #expect(mock.attachCallCount == 1)
        #expect(instance.liveRemovableMedia.count == 1)
    }

    @Test("A save issued right after an edit is refused as busy until the pass ends")
    func saveIssuedAfterAnEditIsRefusedUntilThePassEnds() async throws {
        // The reported shape: an edit, then Suspend in the same breath. The
        // save must not tear the session down under the pass its edit started,
        // or the saved state carries a device set the configuration no longer
        // describes.
        let mock = SuspendingMockRemovableMediaDeviceService()
        let harness = makeHarness(removableMediaDeviceService: mock)
        let (instance, _) = makeRunningInstance(in: harness)

        let configA = configWithRemovable(instance.configuration, path: "/tmp/A.iso")
        harness.library.editConfiguration(of: instance) { $0 = configA }
        await mock.waitUntilSuspended()

        await #expect(throws: VMAdmissionRefusal(refusal: .busy(.reconcilingMedia))) {
            try await harness.lifecycle.save(instance)
        }
        #expect(harness.virtualization.saveCallCount == 0)
        #expect(instance.hasLiveSession)

        mock.resumeSuspended()
        await waitForObservedChange { !isReconciling(instance) }
        try await harness.lifecycle.save(instance)
        #expect(mock.attachCallCount == 1)
        #expect(mock.completedOperationCount == 1)
        #expect(harness.virtualization.saveCallCount == 1)
        #expect(instance.phase == .suspended)
        #expect(!failures.showError)
    }

    @Test("An entry whose session is torn down before the drain reaches it is dropped")
    func entryForATornDownSessionIsDroppedBeforeTheDrain() async throws {
        let mock = MockRemovableMediaDeviceService()
        let harness = makeHarness(removableMediaDeviceService: mock)
        let (instance, _) = makeRunningInstance(in: harness)

        let baseConfig = instance.configuration
        let configA = configWithRemovable(baseConfig, path: "/tmp/A.iso")
        let configB = configWithRemovable(baseConfig, path: "/tmp/B.iso")

        // Started, then the session goes before the pass gets its turn: the
        // pass has nothing to act for, and the VM rests where the guest's end
        // left it.
        harness.library.editConfiguration(of: instance) { $0 = configA }
        instance.handleSessionEvent(.guestDidStop)
        await waitForObservedChange { !isReconciling(instance) }

        #expect(mock.attachCallCount == 0)
        #expect(instance.phase == .stopped)

        // The successor starts with nothing held.
        instance.beginSessionContext()
        instance.activity.placeForTesting(.running(sessionID: UUID()))

        // A later edit on the successor drives only its own target.
        harness.library.editConfiguration(of: instance) { $0 = configB }
        await waitForObservedChange { !isReconciling(instance) }

        #expect(mock.attachCallCount == 1)
        #expect(mock.lastAttachedPath == "/tmp/B.iso")
        #expect(!failures.showError)
    }

    @Test("A failed attach settles the config on the live state and saves it")
    func liveRemovableRollbackPersistsThroughTheLibrary() async throws {
        let mock = MockRemovableMediaDeviceService()
        mock.attachError = RemovableMediaDeviceError.diskImageNotFound("/tmp/new.iso")
        let harness = makeHarness(removableMediaDeviceService: mock)
        let oldID = UUID()
        let (instance, sessionID) = makeRunningInstance(in: harness) {
            $0.removableMedia = [RemovableMediaItem(id: oldID, path: "/tmp/old.iso", readOnly: true)]
        }
        instance.recordAttachedMedia(
            RemovableMediaDeviceInfo(id: oldID, path: "/tmp/old.iso", readOnly: true), for: sessionID)

        harness.library.editConfiguration(of: instance) {
            $0.removableMedia = [RemovableMediaItem(path: "/tmp/new.iso", readOnly: true)]
        }

        await waitForObservedChange { !isReconciling(instance) }

        // The detach landed and the attach did not, so the config describes an
        // empty drive — in memory and in the bundle alike.
        #expect(failures.showError)
        #expect(instance.configuration.removableMedia == nil)
        #expect(harness.saved(instance)?.removableMedia == nil)
    }
}
