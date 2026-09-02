import Foundation
import KernovaTestSupport
import Testing

@testable import Kernova

@Suite("VMRemovableMediaReconciler Tests", .serialized, .admissionGated)
@MainActor
struct VMRemovableMediaReconcilerTests {
    /// What the reconciler asked a user to be told, in place of a presenter.
    private let failures = MockLibraryFailureSink()
    /// Every rollback the reconciler asked the library to persist.
    private let saved = SavedConfigurationRecorder()
    private let fileSystem = MockFileSystem()

    /// The instances the reconciler asked the library to persist, in order.
    final class SavedConfigurationRecorder {
        private(set) var instances: [VMInstance] = []
        func record(_ instance: VMInstance) { instances.append(instance) }
    }

    private func makeReconciler(
        usbDeviceService: any USBDeviceProviding = MockUSBDeviceService()
    ) -> VMRemovableMediaReconciler {
        let reconciler = VMRemovableMediaReconciler(
            lifecycle: VMLifecycleCoordinator(
                virtualizationService: MockVirtualizationService(),
                installService: MockMacOSInstallService(),
                ipswService: MockIPSWService(),
                usbDeviceService: usbDeviceService,
                linuxImageResolveService: MockLinuxImageResolveService(),
                downloadService: MockDownloadService(),
                fileSystem: fileSystem,
                downloadsDirectory: nil
            )
        )
        reconciler.onSaveConfiguration = { [saved] instance in
            saved.record(instance)
        }
        reconciler.onFailure = { [failures] error in
            failures.record(title: "Error", message: error.localizedDescription)
        }
        return reconciler
    }

    private func makeInstance(name: String = "Test VM") -> VMInstance {
        let config = VMConfiguration(name: name, guestOS: .linux, bootMode: .efi)
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(config.id.uuidString, isDirectory: true)
        return VMInstance(configuration: config, bundleURL: bundleURL)
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

    @Test("apply attaches a new removable item when added to the list")
    func liveRemovableAddAttaches() async throws {
        let mock = MockUSBDeviceService()
        let reconciler = makeReconciler(usbDeviceService: mock)
        let instance = makeInstance()
        instance.enter(.running(sessionID: UUID()))
        instance.beginSessionContext()

        let configuredUUID = UUID()
        let old = instance.configuration
        let new = configWithRemovable(old, path: "/tmp/install.iso", readOnly: true, id: configuredUUID)

        reconciler.apply(for: instance, old: old, new: new)

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
        let mock = MockUSBDeviceService()
        let reconciler = makeReconciler(usbDeviceService: mock)
        let instance = makeInstance()
        let sessionID = UUID()
        instance.enter(.running(sessionID: sessionID))
        instance.beginSessionContext()
        let id = UUID()
        instance.recordAttachedMedia(
            USBDeviceInfo(id: id, path: "/tmp/install.iso", readOnly: true), for: sessionID)
        var old = instance.configuration
        old.removableMedia = [RemovableMediaItem(id: id, path: "/tmp/install.iso", readOnly: true)]
        instance.configuration = old

        var new = old
        new.removableMedia = nil

        reconciler.apply(for: instance, old: old, new: new)

        while !instance.liveRemovableMedia.isEmpty { await Task.yield() }

        #expect(mock.detachCallCount == 1)
        #expect(mock.attachCallCount == 0)
        #expect(instance.liveRemovableMedia.isEmpty)
    }

    @Test("apply swaps the only item: detach old, attach new")
    func liveRemovableSwapDetachesThenAttaches() async throws {
        let mock = MockUSBDeviceService()
        let reconciler = makeReconciler(usbDeviceService: mock)
        let instance = makeInstance()
        let sessionID = UUID()
        instance.enter(.running(sessionID: sessionID))
        instance.beginSessionContext()
        let oldID = UUID()
        instance.recordAttachedMedia(
            USBDeviceInfo(id: oldID, path: "/tmp/old.iso", readOnly: true), for: sessionID)
        var old = instance.configuration
        old.removableMedia = [RemovableMediaItem(id: oldID, path: "/tmp/old.iso", readOnly: true)]
        instance.configuration = old

        let newID = UUID()
        var new = old
        new.removableMedia = [RemovableMediaItem(id: newID, path: "/tmp/new.iso", readOnly: true)]

        reconciler.apply(for: instance, old: old, new: new)

        while instance.liveRemovableMedia.first?.path != "/tmp/new.iso" { await Task.yield() }

        #expect(mock.detachCallCount == 1)
        #expect(mock.attachCallCount == 1)
        #expect(mock.lastAttachedPath == "/tmp/new.iso")
        #expect(instance.liveRemovableMedia.count == 1)
        #expect(instance.liveRemovableMedia.first?.id == newID)
    }

    @Test("apply detaches and reattaches on readOnly flip (same id)")
    func liveRemovableReadOnlyFlipReattaches() async throws {
        let mock = MockUSBDeviceService()
        let reconciler = makeReconciler(usbDeviceService: mock)
        let instance = makeInstance()
        let sessionID = UUID()
        instance.enter(.running(sessionID: sessionID))
        instance.beginSessionContext()
        let id = UUID()
        instance.recordAttachedMedia(
            USBDeviceInfo(id: id, path: "/tmp/install.iso", readOnly: true), for: sessionID)
        var old = instance.configuration
        old.removableMedia = [RemovableMediaItem(id: id, path: "/tmp/install.iso", readOnly: true)]
        instance.configuration = old

        var new = old
        new.removableMedia = [RemovableMediaItem(id: id, path: "/tmp/install.iso", readOnly: false)]

        reconciler.apply(for: instance, old: old, new: new)

        while instance.liveRemovableMedia.first?.readOnly != false { await Task.yield() }

        #expect(mock.detachCallCount == 1)
        #expect(mock.attachCallCount == 1)
        #expect(mock.lastAttachedReadOnly == false)
    }

    @Test("apply is a no-op when storageDisks change but removableMedia is unchanged")
    func liveRemovableNoopWhenOnlyStorageDisksChange() async throws {
        let mock = MockUSBDeviceService()
        let reconciler = makeReconciler(usbDeviceService: mock)
        let instance = makeInstance()
        instance.enter(.running(sessionID: UUID()))
        instance.beginSessionContext()

        let old = instance.configuration
        var new = old
        new.storageDisks = [
            StorageDisk(path: "Disk.asif", readOnly: false, label: "Main Disk", isInternal: true, kind: .virtio)
        ]

        reconciler.apply(for: instance, old: old, new: new)
        for _ in 0..<5 { await Task.yield() }

        #expect(mock.attachCallCount == 0)
        #expect(mock.detachCallCount == 0)
    }

    @Test("apply is a no-op when VM is stopped, even with media change")
    func liveRemovableNoopWhenStopped() async throws {
        let mock = MockUSBDeviceService()
        let reconciler = makeReconciler(usbDeviceService: mock)
        let instance = makeInstance()
        instance.enter(.stopped)

        let old = instance.configuration
        let new = configWithRemovable(old, path: "/tmp/install.iso")

        reconciler.apply(for: instance, old: old, new: new)
        for _ in 0..<5 { await Task.yield() }

        #expect(mock.attachCallCount == 0)
        #expect(mock.detachCallCount == 0)
        #expect(instance.liveRemovableMedia.isEmpty)
    }

    @Test("apply is a no-op for a cold-paused VM, which has no session to attach to")
    func liveRemovableNoopWhenColdPaused() async throws {
        let mock = MockUSBDeviceService()
        let reconciler = makeReconciler(usbDeviceService: mock)
        let instance = makeInstance()
        instance.enter(.suspended)

        let old = instance.configuration
        let new = configWithRemovable(old, path: "/tmp/install.iso")

        reconciler.apply(for: instance, old: old, new: new)
        for _ in 0..<5 { await Task.yield() }

        #expect(mock.attachCallCount == 0)
        #expect(mock.detachCallCount == 0)
        #expect(instance.liveRemovableMedia.isEmpty)
        #expect(!failures.showError)
    }

    @Test("Live attach failure surfaces error")
    func liveRemovableAttachFailureSurfacesError() async throws {
        let mock = MockUSBDeviceService()
        mock.attachError = USBDeviceError.diskImageNotFound("/tmp/missing.iso")
        let reconciler = makeReconciler(usbDeviceService: mock)
        let instance = makeInstance()
        instance.enter(.running(sessionID: UUID()))
        instance.beginSessionContext()

        let old = instance.configuration
        let new = configWithRemovable(old, path: "/tmp/missing.iso")

        reconciler.apply(for: instance, old: old, new: new)

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
        let mock = MockUSBDeviceService()
        mock.detachError = USBDeviceError.deviceNotFound
        let reconciler = makeReconciler(usbDeviceService: mock)
        let instance = makeInstance()
        let sessionID = UUID()
        instance.enter(.running(sessionID: sessionID))
        instance.beginSessionContext()
        let oldID = UUID()
        instance.recordAttachedMedia(
            USBDeviceInfo(id: oldID, path: "/tmp/old.iso", readOnly: true), for: sessionID)
        var old = instance.configuration
        old.removableMedia = [RemovableMediaItem(id: oldID, path: "/tmp/old.iso", readOnly: true)]
        instance.configuration = old

        let newID = UUID()
        var new = old
        new.removableMedia = [RemovableMediaItem(id: newID, path: "/tmp/new.iso", readOnly: true)]

        reconciler.apply(for: instance, old: old, new: new)

        while instance.liveRemovableMedia.first?.path != "/tmp/new.iso" { await Task.yield() }

        #expect(mock.detachCallCount == 1)
        #expect(mock.attachCallCount == 1)
        #expect(instance.liveRemovableMedia.first?.path == "/tmp/new.iso")
    }

    @Test("Transient detach error fails fast — reconcile aborts before attach")
    func liveRemovableTransientDetachErrorFailsFast() async throws {
        struct TransientError: Error {}
        let mock = MockUSBDeviceService()
        mock.detachError = TransientError()
        let reconciler = makeReconciler(usbDeviceService: mock)
        let instance = makeInstance()
        let sessionID = UUID()
        instance.enter(.running(sessionID: sessionID))
        instance.beginSessionContext()
        let oldID = UUID()
        instance.recordAttachedMedia(
            USBDeviceInfo(id: oldID, path: "/tmp/old.iso", readOnly: true), for: sessionID)
        var old = instance.configuration
        old.removableMedia = [RemovableMediaItem(id: oldID, path: "/tmp/old.iso", readOnly: true)]
        instance.configuration = old

        var new = old
        new.removableMedia = [RemovableMediaItem(path: "/tmp/new.iso", readOnly: true)]

        reconciler.apply(for: instance, old: old, new: new)

        while !failures.showError { await Task.yield() }
        for _ in 0..<5 { await Task.yield() }

        #expect(mock.detachCallCount == 1)
        // No attach attempted — preventing the device-leak.
        #expect(mock.attachCallCount == 0)
    }

    @Test("Detach noVirtualMachine error bails the reconcile silently")
    func liveRemovableDetachNoVMBails() async throws {
        let mock = MockUSBDeviceService()
        mock.detachError = USBDeviceError.noVirtualMachine
        let reconciler = makeReconciler(usbDeviceService: mock)
        let instance = makeInstance()
        let sessionID = UUID()
        instance.enter(.running(sessionID: sessionID))
        instance.beginSessionContext()
        let oldID = UUID()
        instance.recordAttachedMedia(
            USBDeviceInfo(id: oldID, path: "/tmp/old.iso", readOnly: true), for: sessionID)
        var old = instance.configuration
        old.removableMedia = [RemovableMediaItem(id: oldID, path: "/tmp/old.iso", readOnly: true)]
        instance.configuration = old

        var new = old
        new.removableMedia = [RemovableMediaItem(path: "/tmp/new.iso", readOnly: true)]

        reconciler.apply(for: instance, old: old, new: new)
        for _ in 0..<10 { await Task.yield() }

        #expect(mock.detachCallCount == 1)
        #expect(mock.attachCallCount == 0)
        #expect(!failures.showError)
    }

    @Test("Attach noVirtualMachine error bails the reconcile silently")
    func liveRemovableAttachNoVMBails() async throws {
        let mock = MockUSBDeviceService()
        mock.attachError = USBDeviceError.noVirtualMachine
        let reconciler = makeReconciler(usbDeviceService: mock)
        let instance = makeInstance()
        instance.enter(.running(sessionID: UUID()))
        instance.beginSessionContext()

        let old = instance.configuration
        let new = configWithRemovable(old, path: "/tmp/install.iso")

        reconciler.apply(for: instance, old: old, new: new)
        for _ in 0..<10 { await Task.yield() }

        #expect(mock.attachCallCount == 1)
        #expect(mock.detachCallCount == 0)
        #expect(!failures.showError)
        #expect(instance.liveRemovableMedia.isEmpty)
    }

    @Test("Reconcile loop bails out when VM stops mid-pass — no spurious error")
    func liveRemovableReconcileBailsOutOnVMStop() async throws {
        let mock = SuspendingMockUSBDeviceService()
        let reconciler = makeReconciler(usbDeviceService: mock)
        let instance = makeInstance()
        instance.enter(.running(sessionID: UUID()))
        instance.beginSessionContext()

        let baseConfig = instance.configuration
        let configA = configWithRemovable(baseConfig, path: "/tmp/A.iso")
        let configB = configWithRemovable(baseConfig, path: "/tmp/B.iso")

        reconciler.apply(for: instance, old: baseConfig, new: configA)
        await mock.waitUntilSuspended()
        // Stop the VM before the suspended attach resolves.
        reconciler.apply(for: instance, old: configA, new: configB)
        instance.enter(.stopped)

        mock.resumeSuspended()
        for _ in 0..<10 { await Task.yield() }

        #expect(mock.attachCallCount == 1)
        #expect(mock.lastAttachedPath == "/tmp/A.iso")
        #expect(!failures.showError)
    }

    @Test("A pass overtaken by a force stop and restart records nothing on the successor")
    func liveRemovableOvertakenPassLeavesTheSuccessorAlone() async throws {
        let mock = SuspendingMockUSBDeviceService()
        let reconciler = makeReconciler(usbDeviceService: mock)
        let instance = makeInstance()
        instance.enter(.running(sessionID: UUID()))
        instance.beginSessionContext()

        let baseConfig = instance.configuration
        let configA = configWithRemovable(baseConfig, path: "/tmp/A.iso")
        instance.configuration = configA
        reconciler.apply(for: instance, old: baseConfig, new: configA)
        await mock.waitUntilSuspended()

        // Force Stop, then Start: the suspended attach now answers for a
        // session two transitions old.
        instance.tearDownSession(restingAt: .stopped)
        instance.beginSessionContext()
        instance.enter(.running(sessionID: UUID()))

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
        let mock = SuspendingMockUSBDeviceService()
        let reconciler = makeReconciler(usbDeviceService: mock)
        let instance = makeInstance()
        instance.enter(.running(sessionID: UUID()))
        instance.beginSessionContext()

        let baseConfig = instance.configuration
        let configA = configWithRemovable(baseConfig, path: "/tmp/A.iso")
        instance.configuration = configA
        reconciler.apply(for: instance, old: baseConfig, new: configA)
        await mock.waitUntilSuspended()

        // The force stop is what makes the attach fail, so the alert would name
        // an error the user caused and the rollback would describe the
        // successor's — here empty — live media.
        mock.attachError = USBDeviceError.diskImageNotFound("/tmp/A.iso")
        instance.tearDownSession(restingAt: .stopped)
        instance.beginSessionContext()
        instance.enter(.running(sessionID: UUID()))

        mock.resumeSuspended()
        try await mock.operationCompleted.wait { mock.completedOperationCount == 1 }
        for _ in 0..<5 { await Task.yield() }

        #expect(!failures.showError)
        #expect(failures.errorMessage == nil)
        #expect(instance.configuration == configA)
    }

    @Test("A target queued for a session that ends is dropped, not drained onto its successor")
    func liveRemovableQueuedTargetIsNotDrainedOntoTheSuccessor() async throws {
        let mock = SuspendingMockUSBDeviceService()
        let reconciler = makeReconciler(usbDeviceService: mock)
        let instance = makeInstance()
        instance.enter(.running(sessionID: UUID()))
        instance.beginSessionContext()

        let baseConfig = instance.configuration
        let configA = configWithRemovable(baseConfig, path: "/tmp/A.iso")
        let configB = configWithRemovable(baseConfig, path: "/tmp/B.iso")
        let configC = configWithRemovable(baseConfig, path: "/tmp/C.iso")

        // The pass for A suspends inside the attach; B queues behind it.
        instance.configuration = configA
        reconciler.apply(for: instance, old: baseConfig, new: configA)
        await mock.waitUntilSuspended()
        instance.configuration = configB
        reconciler.apply(for: instance, old: configA, new: configB)

        // Force Stop; an edit to C made while stopped persists but queues
        // nothing, so B stays queued; then Start, cold-booting C.
        instance.tearDownSession(restingAt: .stopped)
        instance.configuration = configC
        reconciler.apply(for: instance, old: configB, new: configC)
        instance.beginSessionContext()
        let successorID = UUID()
        instance.enter(.running(sessionID: successorID))
        let coldBooted = USBDeviceInfo(
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
        let mock = SuspendingMockUSBDeviceService()
        let reconciler = makeReconciler(usbDeviceService: mock)
        let instance = makeInstance()
        instance.enter(.running(sessionID: UUID()))
        instance.beginSessionContext()

        let baseConfig = instance.configuration
        let configA = configWithRemovable(baseConfig, path: "/tmp/A.iso")
        let configB = configWithRemovable(baseConfig, path: "/tmp/B.iso")
        let configC = configWithRemovable(baseConfig, path: "/tmp/C.iso")

        // Three rapid edits before the first attach can complete.
        reconciler.apply(for: instance, old: baseConfig, new: configA)
        await mock.waitUntilSuspended()
        reconciler.apply(for: instance, old: configA, new: configB)
        reconciler.apply(for: instance, old: configB, new: configC)

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

    @Test("A failed attach rolls the config back to the live state and asks for a save")
    func liveRemovableRollbackPersistsThroughTheLibrary() async throws {
        let mock = MockUSBDeviceService()
        mock.attachError = USBDeviceError.diskImageNotFound("/tmp/new.iso")
        let reconciler = makeReconciler(usbDeviceService: mock)
        let instance = makeInstance()
        let sessionID = UUID()
        instance.enter(.running(sessionID: sessionID))
        instance.beginSessionContext()
        let oldID = UUID()
        instance.recordAttachedMedia(
            USBDeviceInfo(id: oldID, path: "/tmp/old.iso", readOnly: true), for: sessionID)
        var old = instance.configuration
        old.removableMedia = [RemovableMediaItem(id: oldID, path: "/tmp/old.iso", readOnly: true)]
        instance.configuration = old

        var new = old
        new.removableMedia = [RemovableMediaItem(path: "/tmp/new.iso", readOnly: true)]

        reconciler.apply(for: instance, old: old, new: new)

        while !failures.showError { await Task.yield() }

        // The detach landed and the attach did not, so the config describes an
        // empty drive — and the library is the one asked to write it.
        #expect(instance.configuration.removableMedia == nil)
        #expect(saved.instances.map(\.id) == [instance.id])
    }
}
