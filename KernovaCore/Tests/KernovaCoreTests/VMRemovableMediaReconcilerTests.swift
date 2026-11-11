import Foundation
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport

@Suite("VMRemovableMediaReconciler Tests", .serialized, .caseScoped)
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
        removableMediaDeviceService: any RemovableMediaAttaching = MockRemovableMediaDeviceService(),
        usbAccessoryPassthrough: USBAccessoryPassthrough = .unavailable(.needsEntitlement)
    ) -> Harness {
        let virtualization = MockVirtualizationService()
        let lifecycle = makeTestLifecycle(
            virtualization: virtualization, removableMedia: removableMediaDeviceService,
            usbAccessoryPassthrough: usbAccessoryPassthrough, fileSystem: fileSystem)
        let storage = MockVMStorageService()
        let library = makeWiredLibrary(storage: storage, lifecycle: lifecycle, fileSystem: fileSystem)
        library.onFailure = { [failures] title, message, subject in
            failures.record(title: title, message: message, subject: subject)
        }
        return Harness(
            library: library, storage: storage, lifecycle: lifecycle, virtualization: virtualization)
    }

    /// An instance in `harness`'s library, built with `mutate` and live on a
    /// session of its own.
    private func makeRunningInstance(
        in harness: Harness, _ mutate: (inout VMConfiguration) -> Void = { _ in }
    ) -> (instance: VMInstance, sessionID: UUID) {
        let instance = harness.library.registerFixture(mutate: mutate)
        let sessionID = UUID()
        instance.activity.placeForTesting(.running(sessionID: sessionID))
        instance.beginSessionContextForTesting()
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

    @Test("A media edit is admitted only where a pass can drive it, and a machine-key edit never live")
    func mediaEditAdmissionTracksThePhase() {
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

            let takesMedia = (try? instance.activity.edit(.hotPlugMedia) { _ in }) != nil
            let takesMachineKeys = (try? instance.activity.edit(.machineKeys) { _ in }) != nil

            #expect(takesMedia == admitting.contains(phase), "\(phase)")
            #expect(takesMachineKeys == instance.phase.isAtRest, "\(phase)")
        }
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

        harness.library.editConfiguration(of: instance, as: .hotPlugMedia) {
            $0.removableMedia = [RemovableMediaItem(id: id, path: "/tmp/install.iso", readOnly: false)]
        }

        try await waitForChange { instance.liveRemovableMedia.first?.readOnly == false }

        #expect(mock.detachCallCount == 1)
        #expect(mock.attachCallCount == 1)
        #expect(mock.lastAttachedReadOnly == false)
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
        harness.library.editConfiguration(of: instance, as: .hotPlugMedia) {
            $0.removableMedia = [RemovableMediaItem(id: newID, path: "/tmp/new.iso", readOnly: true)]
        }

        try await waitForChange { instance.liveRemovableMedia.first?.path == "/tmp/new.iso" }

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

        harness.library.editConfiguration(of: instance, as: .hotPlugMedia) { $0.removableMedia = [new] }
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

        harness.library.editConfiguration(of: instance, as: .hotPlugMedia) {
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

        harness.library.editConfiguration(of: instance, as: .hotPlugMedia) { $0.removableMedia = [bad, good] }
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

        harness.library.editConfiguration(of: instance, as: .hotPlugMedia) {
            $0.removableMedia = [RemovableMediaItem(path: "/tmp/new.iso", readOnly: true)]
        }
        try await instance.waitUntilIdle()

        #expect(mock.detachCallCount == 1)
        #expect(mock.attachCallCount == 0)
        #expect(!failures.showError)
    }

    @Test("A pass whose session ends holds the VM until it drains, and records nothing")
    func liveRemovableEndedPassHoldsTheVMAndRecordsNothing() async throws {
        let mock = SuspendingMockRemovableMediaDeviceService()
        let harness = makeHarness(removableMediaDeviceService: mock)
        let (instance, _) = makeRunningInstance(in: harness)

        let configA = configWithRemovable(instance.configuration, path: "/tmp/A.iso")
        harness.library.editConfiguration(of: instance, as: .hotPlugMedia) { $0 = configA }
        try await mock.waitUntilSuspended()

        // A force stop lands under the suspended attach: no successor session
        // can come up while the pass still holds the VM.
        instance.handleSessionEvent(.guestDidStop)
        #expect(
            instance.activity.decide(.start(recovery: false), posture: .commit)
                == .refuse(.busy(.reconcilingMedia)))

        mock.resumeSuspended()
        try await mock.operationCompleted.wait { mock.completedOperationCount == 1 }
        try await waitForChange { instance.phase.operation == nil }

        #expect(mock.attachCallCount == 1)
        #expect(mock.detachCallCount == 0)
        #expect(instance.liveRemovableMedia.isEmpty)
        #expect(instance.phase == .stopped)
        #expect(!failures.showError)
        #expect(instance.configuration == configA)
    }

    @Test("A pass whose session ends drops its failure: no alert, no rollback")
    func liveRemovableEndedPassFailureIsDropped() async throws {
        let mock = SuspendingMockRemovableMediaDeviceService()
        let harness = makeHarness(removableMediaDeviceService: mock)
        let (instance, _) = makeRunningInstance(in: harness)

        let configA = configWithRemovable(instance.configuration, path: "/tmp/A.iso")
        harness.library.editConfiguration(of: instance, as: .hotPlugMedia) { $0 = configA }
        try await mock.waitUntilSuspended()

        // The force stop is what makes the attach fail, so an alert would name
        // an error the user caused and a rollback would describe live media
        // that no longer exists.
        mock.attachError = RemovableMediaDeviceError.diskImageNotFound("/tmp/A.iso")
        instance.handleSessionEvent(.guestDidStop)

        mock.resumeSuspended()
        try await mock.operationCompleted.wait { mock.completedOperationCount == 1 }
        try await waitForChange { instance.phase.operation == nil }

        #expect(!failures.showError)
        #expect(failures.errorMessage == nil)
        #expect(instance.configuration == configA)
        #expect(harness.saved(instance) == configA)
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

        harness.library.editConfiguration(of: instance, as: .hotPlugMedia) { $0 = configA }
        try await mock.waitUntilSuspended()
        harness.library.editConfiguration(of: instance, as: .hotPlugMedia) { $0 = configB }

        // A's attach is refused; B's, which the drain runs next, lands.
        mock.attachError = RemovableMediaDeviceError.diskImageNotFound("/tmp/A.iso")
        mock.resumeSuspended()
        try await mock.waitUntilSuspended()
        mock.attachError = nil
        mock.resumeSuspended()
        await waitForObservedChange { !isReconciling(instance) }

        #expect(mock.attachCallCount == 2)
        #expect(instance.liveRemovableMedia.map(\.path) == ["/tmp/B.iso"])
        #expect(instance.configuration == configB)
        #expect(harness.saved(instance) == configB)
        #expect(!failures.showError)
    }

    // MARK: - Edits Under Another Operation

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

        harness.library.editConfiguration(of: instance, as: .hotPlugMedia) {
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
