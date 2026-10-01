import Foundation
import KernovaKit
import KernovaTestSupport
import Testing

@testable import Kernova

/// The attachment verbs, driven with no view model and no presenter: every
/// edit's happy path, the state gate each refuses on, the consent a trashing
/// removal asks for, and the files that are never trashed however the removal
/// is asked for.
@Suite("VMCommandCore Attachment Tests", .serialized, .caseScoped)
@MainActor
struct VMCommandCoreAttachmentTests {
    private let preferences = makeTestPreferences()
    private let scratch = TestScratchDirectory(prefix: "VMCommandCoreAttachmentTests")

    private struct Harness {
        let core: VMCommandCore
        let library: VMLibrary
        let storage: MockVMStorageService
        let diskImages: MockDiskImageService
        let fileSystem: MockFileSystem
        let removableMediaDevices: MockRemovableMediaDeviceService
        let virtualization: MockVirtualizationService
        let liveShares: MockLiveDirectorySharing
    }

    private func makeHarness(
        diskImages: MockDiskImageService = MockDiskImageService(),
        usbAccessoryService: (any USBAccessoryProviding)? = nil
    ) -> Harness {
        let storage = MockVMStorageService()
        let fileSystem = MockFileSystem()
        let removableMediaDevices = MockRemovableMediaDeviceService()
        let virtualization = MockVirtualizationService()
        let liveShares = MockLiveDirectorySharing()
        let lifecycle = makeTestLifecycle(
            virtualization: virtualization,
            removableMedia: removableMediaDevices,
            liveDirectorySharing: liveShares,
            usbAccessoryService: usbAccessoryService,
            fileSystem: fileSystem)
        let library = makeWiredLibrary(
            storage: storage,
            // Real, so the in-bundle disk a verb writes or trashes goes through
            // the same recorded file system as every other.
            machineFiles: VMBundleMachineFiles(fileSystem: fileSystem),
            lifecycle: lifecycle,
            fileSystem: fileSystem,
            preferences: preferences)
        let core = VMCommandCore(
            library: library,
            lifecycle: lifecycle,
            storageService: storage,
            diskImageService: diskImages,
            fileSystem: fileSystem,
            preferences: preferences
        )
        return Harness(
            core: core, library: library, storage: storage, diskImages: diskImages,
            fileSystem: fileSystem, removableMediaDevices: removableMediaDevices,
            virtualization: virtualization, liveShares: liveShares)
    }

    @discardableResult
    private func makeInstance(
        in harness: Harness, name: String = "Core VM", phase: VMLifecyclePhase = .stopped,
        guestOS: VMGuestOS = .linux, mutate: (inout VMConfiguration) -> Void = { _ in }
    ) -> VMInstance {
        RegisteredVMInstanceFixture.register(
            name: name, phase: phase, guestOS: guestOS, library: harness.library,
            preferences: preferences, mutate: mutate)
    }

    private func commandError(_ body: () async throws -> Void) async -> CommandError? {
        do {
            try await body()
            return nil
        } catch let error as CommandError {
            return error
        } catch {
            return nil
        }
    }

    private func externalPath(_ suffix: String) -> String {
        scratch.url
            .appendingPathComponent("\(UUID().uuidString)-\(suffix)")
            .path(percentEncoded: false)
    }

    // MARK: - Storage: attach

    @Test("Attaching disks appends every pick and skips a path already carried")
    func attachStorageDisksSkipsDuplicates() throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness)
        let first = externalPath("one.img")
        let second = externalPath("two.img")

        try harness.core.attachStorageDisks(
            .id(instance.id), paths: [PickedFile(path: first, bookmark: Data([1]))])
        try harness.core.attachStorageDisks(
            .id(instance.id),
            paths: [PickedFile(path: first, bookmark: nil), PickedFile(path: second, bookmark: nil)])

        let disks = instance.configuration.storageDisks ?? []
        // The synthesized main disk materializes alongside the two picks.
        #expect(disks.map(\.path).filter { $0 == first }.count == 1)
        #expect(disks.contains { $0.path == second })
        #expect(disks.first { $0.path == first }?.bookmark == Data([1]))
    }

    // MARK: - Storage: create

    @Test("Creating a disk writes a bundle-relative entry with a collision-free label")
    func createStorageDiskUniqueLabel() async throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness) {
            $0.storageDisks = [
                StorageDisk(
                    path: "AdditionalDisks/a.asif", label: "100 GB Disk", isInternal: true,
                    kind: .virtio)
            ]
        }

        try await harness.core.createStorageDisk(.id(instance.id), sizeInGB: 100)

        let disks = instance.configuration.storageDisks ?? []
        #expect(disks.count == 2)
        #expect(disks[1].label == "100 GB Disk 2")
        #expect(disks[1].isInternal)
        #expect(disks[1].kind == .virtio)
        #expect(disks[1].path.hasPrefix("AdditionalDisks/"))
        #expect(disks[1].path.hasSuffix(".asif"))
        #expect(harness.diskImages.createDiskImageCallCount == 1)
        #expect(harness.diskImages.lastCreatedSizeInGB == 100)
    }

    @Test("A failed disk write removes what it may have left and leaves the list alone")
    func createStorageDiskWriteFailureCleansUp() async throws {
        let diskImages = MockDiskImageService()
        diskImages.createDiskImageError = DiskImageError.writeFailed(NSError(domain: "t", code: 1))
        let harness = makeHarness(diskImages: diskImages)
        let instance = makeInstance(in: harness)

        let refusal = await commandError {
            try await harness.core.createStorageDisk(.id(instance.id), sizeInGB: 32)
        }

        #expect(refusal?.isOperationFailure == true)
        // App-internal: the path was minted for this create and no entry names it.
        #expect(harness.fileSystem.removedURLs.count == 1)
        #expect(harness.fileSystem.trashedURLs.isEmpty)
        #expect(instance.configuration.storageDisks == nil)
    }

    @Test("A create that failed before writing leaves the destination untouched")
    func createStorageDiskPreWriteFailureTrashesNothing() async throws {
        let diskImages = MockDiskImageService()
        diskImages.createDiskImageError = DiskImageError.templateMissing(sizeInGB: 32)
        let harness = makeHarness(diskImages: diskImages)
        let instance = makeInstance(in: harness)

        let refusal = await commandError {
            try await harness.core.createStorageDisk(.id(instance.id), sizeInGB: 32)
        }

        #expect(refusal?.isOperationFailure == true)
        #expect(harness.fileSystem.trashedURLs.isEmpty)
        #expect(harness.fileSystem.removedURLs.isEmpty)
        #expect(instance.configuration.storageDisks == nil)
    }

    @Test("R1(b): a configuration edit, a Start or a delete during a disk's image write is refused busy")
    func createStorageDiskHoldsTheVM() async throws {
        let diskImages = MockDiskImageService()
        diskImages.holdCreateDiskImage()
        let harness = makeHarness(diskImages: diskImages)
        let instance = makeInstance(in: harness)

        let creation = Task { @MainActor in
            try await harness.core.createStorageDisk(.id(instance.id), sizeInGB: 8)
        }
        try await diskImages.parked.wait { diskImages.isParked }
        #expect(instance.phase.operation?.kind == .creatingStorageDisk)

        let cpus = instance.configuration.cpuCount
        let edit = await commandError {
            try harness.core.setConfiguration(
                .id(instance.id), assignments: [ConfigurationEntry(key: "cpus", value: String(cpus + 1))],
                consent: .all)
        }
        #expect(edit?.isBusy == true)
        let start = await commandError {
            try await harness.core.start(.id(instance.id), recovery: false, consent: .none)
        }
        #expect(start?.isBusy == true)
        let delete = await commandError {
            try await harness.core.delete(
                .id(instance.id), permanently: false, alsoRemoving: [], consent: .all)
        }
        #expect(delete?.isBusy == true)

        diskImages.resumeCreateDiskImage()
        try await creation.value

        #expect(instance.phase == .stopped)
        #expect(instance.configuration.cpuCount == cpus)
        #expect(instance.configuration.storageDisks?.last?.isInternal == true)
        #expect(harness.virtualization.startCallCount == 0)
    }

    // MARK: - Storage: label, note, read-only, order

    @Test("A rename trims the label, persists it, and saves once")
    func renameStorageDiskPersists() throws {
        let harness = makeHarness()
        let disk = StorageDisk(
            path: "AdditionalDisks/x.asif", label: "Original", isInternal: true, kind: .virtio)
        let instance = makeInstance(in: harness) { $0.storageDisks = [disk] }

        try harness.core.renameStorageDisk(.id(instance.id), disk: disk.id, to: "  Renamed  ")

        #expect(instance.configuration.storageDisks?[0].label == "Renamed")
        #expect(harness.storage.bundles[instance.bundleURL]?.storageDisks?[0].label == "Renamed")
        #expect(harness.storage.saveConfigurationCallCount == 1)
    }

    @Test("An empty rename is ignored and saves nothing")
    func renameStorageDiskEmptyIsIgnored() throws {
        let harness = makeHarness()
        let disk = StorageDisk(
            path: "AdditionalDisks/x.asif", label: "Original", isInternal: true, kind: .virtio)
        let instance = makeInstance(in: harness) { $0.storageDisks = [disk] }

        try harness.core.renameStorageDisk(.id(instance.id), disk: disk.id, to: "   ")

        #expect(instance.configuration.storageDisks?[0].label == "Original")
        #expect(harness.storage.saveConfigurationCallCount == 0)
    }

    @Test("A note is trimmed, an empty one clears it, and an unchanged one saves nothing")
    func storageDiskNotes() throws {
        let harness = makeHarness()
        let disk = StorageDisk(
            path: "AdditionalDisks/x.asif", label: "Data", isInternal: true, kind: .virtio)
        let instance = makeInstance(in: harness) { $0.storageDisks = [disk] }

        try harness.core.setStorageDiskNotes(
            .id(instance.id), disk: disk.id, notes: "  holds the build cache  ")
        #expect(instance.configuration.storageDisks?[0].notes == "holds the build cache")
        #expect(harness.storage.saveConfigurationCallCount == 1)

        try harness.core.setStorageDiskNotes(
            .id(instance.id), disk: disk.id, notes: "holds the build cache")
        #expect(harness.storage.saveConfigurationCallCount == 1)

        try harness.core.setStorageDiskNotes(.id(instance.id), disk: disk.id, notes: "   ")
        #expect(instance.configuration.storageDisks?[0].notes == "")
        #expect(harness.storage.saveConfigurationCallCount == 2)
    }

    @Test("An unchanged edit leaves a VM with no configured disk list untouched")
    func unchangedEditNeverMaterializesTheList() throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness)
        let main = instance.effectiveStorageDisks[0]

        try harness.core.setStorageDiskNotes(.id(instance.id), disk: main.id, notes: main.notes)
        try harness.core.renameStorageDisk(.id(instance.id), disk: main.id, to: main.label)
        try harness.core.setStorageDiskReadOnly(
            .id(instance.id), disk: main.id, readOnly: main.readOnly)

        // Materializing is itself a write, so an edit that changes nothing has
        // to stop before it.
        #expect(instance.configuration.storageDisks == nil)
        #expect(harness.storage.saveConfigurationCallCount == 0)
    }

    @Test("An edit to the synthesized main disk persists the whole materialized list")
    func editingTheMainDiskMaterializesTheList() throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness)
        let mainDisk = instance.effectiveStorageDisks[0]

        try harness.core.setStorageDiskNotes(
            .id(instance.id), disk: mainDisk.id, notes: "the startup disk")

        #expect(instance.configuration.storageDisks?.count == 1)
        #expect(instance.configuration.storageDisks?[0].notes == "the startup disk")
        #expect(
            harness.storage.bundles[instance.bundleURL]?.storageDisks?[0].notes
                == "the startup disk")
    }

    @Test("Read-only is written straight through")
    func storageDiskReadOnly() throws {
        let harness = makeHarness()
        let disk = StorageDisk(
            path: "AdditionalDisks/x.asif", label: "Data", isInternal: true, kind: .virtio)
        let instance = makeInstance(in: harness) { $0.storageDisks = [disk] }

        try harness.core.setStorageDiskReadOnly(.id(instance.id), disk: disk.id, readOnly: true)

        #expect(instance.configuration.storageDisks?[0].readOnly == true)
    }

    @Test("A reorder ranks the disks it names and keeps the rest behind them")
    func reorderStorageDisks() throws {
        let harness = makeHarness()
        let first = StorageDisk(path: "AdditionalDisks/a.asif", label: "A", isInternal: true)
        let second = StorageDisk(path: "AdditionalDisks/b.asif", label: "B", isInternal: true)
        let unnamed = StorageDisk(path: "AdditionalDisks/c.asif", label: "C", isInternal: true)
        let instance = makeInstance(in: harness) { $0.storageDisks = [first, second, unnamed] }

        try harness.core.reorderStorageDisks(.id(instance.id), order: [second.id, first.id])

        #expect(instance.configuration.storageDisks?.map(\.label) == ["B", "A", "C"])
    }

    // MARK: - Storage: removal

    @Test("A removal that keeps the file drops the entry and touches nothing on disk")
    func removeStorageDiskKeepingTheFile() async throws {
        let harness = makeHarness()
        let main = StorageDisk(path: "Disk.asif", label: "Main Disk", isInternal: true)
        let extra = StorageDisk(path: "AdditionalDisks/x.asif", label: "Extra", isInternal: true)
        let instance = makeInstance(in: harness) { $0.storageDisks = [main, extra] }

        try await harness.core.removeStorageDisk(
            .id(instance.id), disk: extra.id, trashFile: false, consent: .none)

        #expect(instance.configuration.storageDisks?.map(\.id) == [main.id])
        #expect(harness.fileSystem.trashedURLs.isEmpty)
    }

    @Test("A trashing removal asks for consent, then trashes the external file")
    func removeStorageDiskTrashesAfterConsent() async throws {
        let harness = makeHarness()
        let path = externalPath("external.img")
        let external = StorageDisk(path: path, label: "External", isInternal: false)
        let keeper = StorageDisk(path: "AdditionalDisks/k.asif", label: "Keeper", isInternal: true)
        let instance = makeInstance(in: harness) { $0.storageDisks = [external, keeper] }

        let refusal = await commandError {
            try await harness.core.removeStorageDisk(
                .id(instance.id), disk: external.id, trashFile: true, consent: .none)
        }
        #expect(refusal?.confirmationPrompt?.kind == .removeAttachment)
        #expect(refusal?.confirmationPrompt?.confirmTitle == "Move to Trash")
        // Refused, so nothing moved.
        #expect(instance.configuration.storageDisks?.count == 2)

        try await harness.core.removeStorageDisk(
            .id(instance.id), disk: external.id, trashFile: true, consent: .all)

        #expect(instance.configuration.storageDisks?.map(\.id) == [keeper.id])
        #expect(harness.fileSystem.trashedURLs == [URL(fileURLWithPath: path)])
    }

    @Test("A trashing removal of an in-bundle disk resolves the file against the bundle")
    func removeInternalStorageDiskTrashesInsideTheBundle() async throws {
        let harness = makeHarness()
        let internalDisk = StorageDisk(
            path: "AdditionalDisks/x.asif", label: "Extra", isInternal: true)
        let keeper = StorageDisk(path: "AdditionalDisks/k.asif", label: "Keeper", isInternal: true)
        let instance = makeInstance(in: harness) { $0.storageDisks = [internalDisk, keeper] }

        try await harness.core.removeStorageDisk(
            .id(instance.id), disk: internalDisk.id, trashFile: true, consent: .all)

        #expect(
            harness.fileSystem.trashedURLs
                == [instance.bundleURL.appendingPathComponent("AdditionalDisks/x.asif")])
    }

    @Test(
        "A trashing removal holds the VM through the trash, so a Start meanwhile is refused busy",
        arguments: [true, false])
    func removeStorageDiskHoldsTheVMThroughTheTrash(isInternal: Bool) async throws {
        let harness = makeHarness()
        let disk =
            isInternal
            ? StorageDisk(path: "AdditionalDisks/x.asif", label: "Extra", isInternal: true)
            : StorageDisk(path: externalPath("external.img"), label: "External", isInternal: false)
        let keeper = StorageDisk(path: "AdditionalDisks/k.asif", label: "Keeper", isInternal: true)
        let instance = makeInstance(in: harness) { $0.storageDisks = [disk, keeper] }
        harness.fileSystem.holdTrash()

        let removal = Task { @MainActor in
            try await harness.core.removeStorageDisk(
                .id(instance.id), disk: disk.id, trashFile: true, consent: .all)
        }
        try await harness.fileSystem.trashParked.wait { harness.fileSystem.isTrashParked }
        #expect(instance.phase.operation?.kind == .removingStorageDisk)
        // The entry went first; the file is what is still in flight.
        #expect(instance.configuration.storageDisks?.map(\.id) == [keeper.id])
        let start = await commandError {
            try await harness.core.start(.id(instance.id), recovery: false, consent: .none)
        }
        #expect(start?.isBusy == true)

        harness.fileSystem.resumeTrash()
        try await removal.value

        #expect(instance.phase == .stopped)
        let trashed =
            isInternal
            ? instance.bundleURL.appendingPathComponent(disk.path) : URL(fileURLWithPath: disk.path)
        #expect(harness.fileSystem.trashedURLs == [trashed])
        #expect(harness.virtualization.startCallCount == 0)
    }

    @Test("A file another VM still references is kept, however the removal is asked for")
    func removeStorageDiskKeepsASharedFile() async throws {
        let harness = makeHarness()
        let path = externalPath("shared.img")
        let disk = StorageDisk(path: path, label: "Shared", isInternal: false)
        let keeper = StorageDisk(path: "AdditionalDisks/k.asif", label: "Keeper", isInternal: true)
        let target = makeInstance(in: harness, name: "Target") { $0.storageDisks = [disk, keeper] }
        _ = makeInstance(in: harness, name: "Other") {
            $0.storageDisks = [StorageDisk(path: path, label: "Shared")]
        }

        // A shared file is offered detach-only, so that is what confirming does.
        let refusal = await commandError {
            try await harness.core.removeStorageDisk(
                .id(target.id), disk: disk.id, trashFile: true, consent: .none)
        }
        #expect(refusal?.confirmationPrompt?.confirmTitle == "Remove from VM")
        #expect(refusal?.confirmationPrompt?.message.contains("Other") == true)

        try await harness.core.removeStorageDisk(
            .id(target.id), disk: disk.id, trashFile: true, consent: .all)

        #expect(target.configuration.storageDisks?.map(\.id) == [keeper.id])
        #expect(harness.fileSystem.trashedURLs.isEmpty)
    }

    @Test("A missing file is swallowed, and any other trash failure is reported")
    func removeStorageDiskTrashFailures() async throws {
        let harness = makeHarness()
        var failures: [CommandError] = []
        harness.core.onFailure = { failure, _ in failures.append(failure) }
        let ghost = StorageDisk(path: externalPath("ghost.img"), label: "Ghost")
        let doomed = StorageDisk(path: externalPath("locked.img"), label: "Locked")
        let keeper = StorageDisk(path: "AdditionalDisks/k.asif", label: "Keeper", isInternal: true)
        let instance = makeInstance(in: harness) { $0.storageDisks = [ghost, doomed, keeper] }

        harness.fileSystem.trashError = CocoaError(.fileNoSuchFile)
        try await harness.core.removeStorageDisk(
            .id(instance.id), disk: ghost.id, trashFile: true, consent: .all)
        #expect(failures.isEmpty)

        harness.fileSystem.trashError = CocoaError(.fileWriteNoPermission)
        try await harness.core.removeStorageDisk(
            .id(instance.id), disk: doomed.id, trashFile: true, consent: .all)

        // The entry goes either way; only the second failure is worth telling
        // the user about.
        #expect(instance.configuration.storageDisks?.map(\.id) == [keeper.id])
        #expect(failures.count == 1)
        #expect(failures.first?.isOperationFailure == true)
    }

    @Test("The synthesized main disk is a VM's only disk, so its removal is refused")
    func removeSyntheticMainDiskIsRefused() async throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness) { $0.storageDisks = nil }
        let synthetic = StorageDisk.mainDisk(
            layout: VMBundleLayout(bundleURL: instance.bundleURL))

        let refusal = await commandError {
            try await harness.core.removeStorageDisk(
                .id(instance.id), disk: synthetic.id, trashFile: true, consent: .all)
        }

        #expect(refusal?.isOperationFailure == true)
        #expect(instance.configuration.storageDisks == nil)
        #expect(harness.fileSystem.trashedURLs.isEmpty)
    }

    @Test("Disk.asif goes like any other disk once the VM has a sibling")
    func removeMainDiskWithASiblingSucceeds() async throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness)
        let main = StorageDisk.mainDisk(layout: VMBundleLayout(bundleURL: instance.bundleURL))
        let extra = StorageDisk(path: "AdditionalDisks/x.asif", label: "Extra", isInternal: true)
        harness.library.editConfiguration(of: instance, as: .machineKeys) { $0.storageDisks = [main, extra] }

        try await harness.core.removeStorageDisk(
            .id(instance.id), disk: main.id, trashFile: true, consent: .all)

        #expect(instance.configuration.storageDisks?.map(\.id) == [extra.id])
        #expect(
            harness.fileSystem.trashedURLs.contains(
                instance.bundleURL.appendingPathComponent("Disk.asif")))
    }

    @Test("A VM's only disk is refused whichever file backs it")
    func removeSoleAdditionalDiskIsRefused() async throws {
        let harness = makeHarness()
        let extra = StorageDisk(path: "AdditionalDisks/x.asif", label: "Extra", isInternal: true)
        let instance = makeInstance(in: harness) { $0.storageDisks = [extra] }

        let refusal = await commandError {
            try await harness.core.removeStorageDisk(
                .id(instance.id), disk: extra.id, trashFile: true, consent: .all)
        }

        #expect(refusal?.isOperationFailure == true)
        #expect(instance.configuration.storageDisks?.map(\.id) == [extra.id])
        #expect(harness.fileSystem.trashedURLs.isEmpty)
    }

    @Test("A disk left the VM's last while sharing resolves is refused on the far side")
    func removeStorageDiskRefusesBecomingTheSoleDiskDuringTheResolve() async throws {
        let harness = makeHarness()
        let path = externalPath("external.img")
        let external = StorageDisk(path: path, label: "External", isInternal: false)
        let other = StorageDisk(path: "AdditionalDisks/x.asif", label: "Extra", isInternal: true)
        let instance = makeInstance(in: harness) { $0.storageDisks = [external, other] }
        // A second surface removing the other disk while this one's resolve is
        // in flight: trashing this one now would empty the list.
        harness.core.afterSharingResolveForTesting = {
            harness.library.editConfiguration(of: instance, as: .machineKeys) { $0.storageDisks = [external] }
        }

        let refusal = await commandError {
            try await harness.core.removeStorageDisk(
                .id(instance.id), disk: external.id, trashFile: true, consent: .all)
        }

        #expect(refusal?.isOperationFailure == true)
        #expect(harness.fileSystem.trashedURLs.isEmpty)
        #expect(instance.configuration.storageDisks?.map(\.id) == [external.id])
    }

    @Test("A disk detached while sharing resolves is refused, and its file is left alone")
    func removeStorageDiskRefusesADetachDuringTheResolve() async throws {
        let harness = makeHarness()
        let path = externalPath("external.img")
        let disk = StorageDisk(path: path, label: "External", isInternal: false)
        let other = StorageDisk(path: "AdditionalDisks/x.asif", label: "Extra", isInternal: true)
        let instance = makeInstance(in: harness) { $0.storageDisks = [disk, other] }
        // A second surface removing the same row while this one's resolve is in
        // flight: the id this call decided to trash is no longer attached.
        harness.core.afterSharingResolveForTesting = {
            harness.library.editConfiguration(of: instance, as: .machineKeys) { $0.storageDisks = [other] }
        }

        let refusal = await commandError {
            try await harness.core.removeStorageDisk(
                .id(instance.id), disk: disk.id, trashFile: true, consent: .all)
        }

        #expect(refusal?.isOperationFailure == true)
        #expect(harness.fileSystem.trashedURLs.isEmpty)
    }

    // MARK: - Removable media

    @Test("Attaching removable media appends read-only entries and skips duplicates")
    func attachRemovableMediaSkipsDuplicates() throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness)
        let path = externalPath("installer.iso")

        try harness.core.attachRemovableMedia(
            .id(instance.id), paths: [PickedFile(path: path, bookmark: Data([2]))])
        try harness.core.attachRemovableMedia(
            .id(instance.id), paths: [PickedFile(path: path, bookmark: nil)])

        #expect(instance.configuration.removableMedia?.count == 1)
        #expect(instance.configuration.removableMedia?[0].readOnly == true)
        #expect(instance.configuration.removableMedia?[0].bookmark == Data([2]))
    }

    @Test("Creating a removable disk attaches the written file read-write")
    func createRemovableMediaAttaches() async throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness)
        let destination = scratch.url
            .appendingPathComponent("\(UUID().uuidString) Removable Disk.asif")

        try await harness.core.createRemovableMedia(
            .id(instance.id), sizeInGB: 16, destinationURL: destination)

        let item = try #require(instance.configuration.removableMedia?.first)
        #expect(item.path == destination.path(percentEncoded: false))
        #expect(item.readOnly == false)
        #expect(item.label == destination.deletingPathExtension().lastPathComponent)
        #expect(harness.diskImages.lastCreatedSizeInGB == 16)
    }

    @Test("A failed removable-disk write trashes only what the write may have left")
    func createRemovableMediaCleansUpOnlyAfterAWrite() async throws {
        for (error, expectsCleanup) in [
            (DiskImageError.writeFailed(NSError(domain: "t", code: 1)), true),
            (DiskImageError.templateMissing(sizeInGB: 16), false),
        ] {
            let diskImages = MockDiskImageService()
            diskImages.createDiskImageError = error
            let harness = makeHarness(diskImages: diskImages)
            let instance = makeInstance(in: harness)
            let destination = scratch.url
                .appendingPathComponent("\(UUID().uuidString).asif")

            let refusal = await commandError {
                try await harness.core.createRemovableMedia(
                    .id(instance.id), sizeInGB: 16, destinationURL: destination)
            }

            #expect(refusal?.isOperationFailure == true)
            #expect(instance.configuration.removableMedia == nil)
            #expect(harness.fileSystem.trashedURLs.isEmpty != expectsCleanup, "\(error)")
        }
    }

    @Test("R1(c): a Suspend during a live removable-disk creation is refused; an edit is taken and both land")
    func createRemovableMediaHoldsALiveVM() async throws {
        let diskImages = MockDiskImageService()
        diskImages.holdCreateDiskImage()
        let harness = makeHarness(diskImages: diskImages)
        let sessionID = UUID()
        let instance = makeInstance(in: harness, phase: .running(sessionID: sessionID))
        instance.beginSessionContextForTesting()
        let destination = scratch.url
            .appendingPathComponent("\(UUID().uuidString).asif")

        let creation = Task { @MainActor in
            try await harness.core.createRemovableMedia(
                .id(instance.id), sizeInGB: 16, destinationURL: destination)
        }
        try await diskImages.parked.wait { diskImages.isParked }
        #expect(instance.phase.operation?.kind == .creatingRemovableMedia)
        #expect(instance.status == .running)
        let suspend = await commandError { try await harness.core.suspend(.id(instance.id)) }
        #expect(suspend?.isBusy == true)
        let other = externalPath("other.iso")
        try harness.core.attachRemovableMedia(
            .id(instance.id), paths: [PickedFile(path: other, bookmark: nil)])
        #expect(instance.configuration.removableMedia?.map(\.path) == [other])
        #expect(harness.removableMediaDevices.attachCallCount == 0)

        diskImages.resumeCreateDiskImage()
        try await creation.value
        // The reconcile the edit owed runs once the creation lets the VM go.
        try await waitForChange { instance.phase == .running(sessionID: sessionID) }

        let path = destination.path(percentEncoded: false)
        #expect(instance.configuration.removableMedia?.map(\.path) == [other, path])
        // Both attached by the creation's own pass, before it let the VM go;
        // the edit's reconcile found nothing left to do.
        #expect(harness.removableMediaDevices.attachCallCount == 2)
        #expect(harness.removableMediaDevices.detachCallCount == 0)
        #expect(Set(instance.liveRemovableMedia.map(\.path)) == [other, path])
        try await harness.core.suspend(.id(instance.id))
        #expect(instance.phase == .suspended)
    }

    @Test("A guest force-stopped during a removable-disk creation rests stopped with the entry saved")
    func createRemovableMediaOnAGuestForceStoppedMidWrite() async throws {
        let diskImages = MockDiskImageService()
        diskImages.holdCreateDiskImage()
        let harness = makeHarness(diskImages: diskImages)
        let instance = makeInstance(in: harness, phase: .running(sessionID: UUID()))
        instance.beginSessionContextForTesting()
        let destination = scratch.url
            .appendingPathComponent("\(UUID().uuidString).asif")

        let creation = Task { @MainActor in
            try await harness.core.createRemovableMedia(
                .id(instance.id), sizeInGB: 16, destinationURL: destination)
        }
        try await diskImages.parked.wait { diskImages.isParked }
        try await harness.core.stop(
            .id(instance.id), disposition: .force, consent: .all, timeout: nil)
        // The stop is tolerated; the creation still holds the VM.
        #expect(instance.phase.operation?.kind == .creatingRemovableMedia)

        diskImages.resumeCreateDiskImage()
        try await creation.value

        #expect(instance.phase == .stopped)
        #expect(
            instance.configuration.removableMedia?.map(\.path)
                == [destination.path(percentEncoded: false)])
        #expect(harness.removableMediaDevices.attachCallCount == 0)
    }

    @Test("A label or note edit leaves the mount identity alone")
    func removableLabelAndNoteKeepMountIdentity() throws {
        let harness = makeHarness()
        let item = RemovableMediaItem(path: "/tmp/installer.iso", readOnly: true, label: "Original")
        let instance = makeInstance(in: harness) { $0.removableMedia = [item] }

        try harness.core.renameRemovableMedia(.id(instance.id), item: item.id, to: "  Renamed  ")
        try harness.core.setRemovableMediaNotes(
            .id(instance.id), item: item.id, notes: "  from the mirror  ")

        let stored = try #require(instance.configuration.removableMedia?.first)
        #expect(stored.label == "Renamed")
        #expect(stored.notes == "from the mirror")
        // The live diff detaches and reattaches only on a path or read-only
        // change, so neither may move.
        #expect(stored.path == "/tmp/installer.iso")
        #expect(stored.readOnly == true)
    }

    @Test("Ejecting drops the entry and keeps the file")
    func ejectRemovableMedia() throws {
        let harness = makeHarness()
        let item = RemovableMediaItem(path: externalPath("media.iso"), readOnly: true)
        let instance = makeInstance(in: harness) { $0.removableMedia = [item] }

        try harness.core.ejectRemovableMedia(.id(instance.id), item: item.id)

        #expect(instance.configuration.removableMedia == nil)
        #expect(harness.fileSystem.trashedURLs.isEmpty)
    }

    @Test("A suspend issued right after an eject is refused busy until the detach lands")
    func suspendAfterEjectLandsTheDetachFirst() async throws {
        let harness = makeHarness()
        let sessionID = UUID()
        let item = RemovableMediaItem(path: externalPath("media.iso"), readOnly: true)
        let instance = makeInstance(in: harness, phase: .running(sessionID: sessionID)) {
            $0.removableMedia = [item]
        }
        instance.beginSessionContextForTesting()
        instance.recordAttachedMedia(
            RemovableMediaDeviceInfo(id: item.id, path: item.path, readOnly: true), for: sessionID)

        try harness.core.ejectRemovableMedia(.id(instance.id), item: item.id)
        // The eject's reconcile holds the VM, so the save cannot tear the
        // session down under the detach.
        let refusal = await commandError { try await harness.core.suspend(.id(instance.id)) }
        #expect(refusal?.isBusy == true)

        try await waitForChange { instance.phase.operation == nil }
        #expect(harness.removableMediaDevices.detachCallCount == 1)
        #expect(instance.configuration.removableMedia == nil)
        try await harness.core.suspend(.id(instance.id))
        #expect(instance.phase == .suspended)
    }

    @Test("A trashing removal of removable media asks for consent, then trashes the file")
    func removeRemovableMediaTrashesAfterConsent() async throws {
        let harness = makeHarness()
        let path = externalPath("media.iso")
        let item = RemovableMediaItem(path: path, readOnly: true)
        let instance = makeInstance(in: harness) { $0.removableMedia = [item] }

        let refusal = await commandError {
            try await harness.core.removeRemovableMedia(
                .id(instance.id), item: item.id, trashFile: true, consent: .none)
        }
        #expect(refusal?.confirmationPrompt?.kind == .removeAttachment)

        try await harness.core.removeRemovableMedia(
            .id(instance.id), item: item.id, trashFile: true, consent: .all)

        #expect(instance.configuration.removableMedia == nil)
        #expect(harness.fileSystem.trashedURLs == [URL(fileURLWithPath: path)])
    }

    @Test("The bundled Guest Agent installer is detached but never trashed")
    func removeGuestAgentInstallerKeepsTheFile() async throws {
        let agentPath = try #require(KernovaMacOSAgentInfo.installerDiskImageURL)
            .path(percentEncoded: false)
        let harness = makeHarness()
        let item = RemovableMediaItem(
            path: agentPath, readOnly: true, label: KernovaMacOSAgentInfo.diskLabel)
        let instance = makeInstance(in: harness) { $0.removableMedia = [item] }

        let refusal = await commandError {
            try await harness.core.removeRemovableMedia(
                .id(instance.id), item: item.id, trashFile: true, consent: .none)
        }
        #expect(refusal?.confirmationPrompt?.message.contains("isn't deleted") == true)

        try await harness.core.removeRemovableMedia(
            .id(instance.id), item: item.id, trashFile: true, consent: .all)

        #expect(instance.configuration.removableMedia == nil)
        #expect(harness.fileSystem.trashedURLs.isEmpty)
        #expect(FileManager.default.fileExists(atPath: agentPath))
    }

    // MARK: - Shared directories

    @Test("Adding shares appends every pick and skips a path already shared")
    func addSharedDirectoriesSkipsDuplicates() throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness)
        let first = externalPath("one")
        let second = externalPath("two")

        try harness.core.addSharedDirectories(
            .id(instance.id), paths: [PickedFile(path: first, bookmark: Data([1]))])
        try harness.core.addSharedDirectories(
            .id(instance.id),
            paths: [PickedFile(path: first, bookmark: nil), PickedFile(path: second, bookmark: nil)])

        let directories = instance.configuration.sharedDirectories ?? []
        #expect(directories.map(\.path) == [first, second])
        #expect(directories.first?.bookmark == Data([1]))
    }

    @Test("A pick spelling a folder differently is still the folder the VM shares")
    func addSharedDirectoriesComparesFoldersNotSpellings() throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness)
        let folder = externalPath("sites")

        try harness.core.addSharedDirectories(
            .id(instance.id), paths: [PickedFile(path: folder, bookmark: Data([1]))])
        // A trailing separator names the same folder, and the core compares
        // every share in one spelling whichever verb asks.
        try harness.core.addSharedDirectories(
            .id(instance.id), paths: [PickedFile(path: folder + "/", bookmark: nil)])

        let directories = instance.configuration.sharedDirectories ?? []
        #expect(directories.map(\.path) == [folder])
        #expect(directories.first?.bookmark == Data([1]))
    }

    @Test("An empty pick writes nothing")
    func addSharedDirectoriesIgnoresAnEmptyPick() throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness)

        try harness.core.addSharedDirectories(.id(instance.id), paths: [])

        #expect(instance.configuration.sharedDirectories == nil)
    }

    @Test("Removing the last share clears the list rather than leaving it empty")
    func removeSharedDirectoryNilsAnEmptiedList() throws {
        let harness = makeHarness()
        let keeper = SharedDirectory(path: externalPath("keeper"))
        let going = SharedDirectory(path: externalPath("going"))
        let instance = makeInstance(in: harness) { $0.sharedDirectories = [keeper, going] }

        try harness.core.removeSharedDirectory(.id(instance.id), directory: going.id)
        #expect(instance.configuration.sharedDirectories?.map(\.id) == [keeper.id])

        try harness.core.removeSharedDirectory(.id(instance.id), directory: keeper.id)
        #expect(instance.configuration.sharedDirectories == nil)
    }

    @Test("Read-only flips the share named and leaves its siblings alone")
    func setSharedDirectoryReadOnlyTouchesOneEntry() throws {
        let harness = makeHarness()
        let first = SharedDirectory(path: externalPath("first"))
        let second = SharedDirectory(path: externalPath("second"))
        let instance = makeInstance(in: harness) { $0.sharedDirectories = [first, second] }

        try harness.core.setSharedDirectoryReadOnly(
            .id(instance.id), directory: second.id, readOnly: true)

        #expect(instance.configuration.sharedDirectories?.map(\.readOnly) == [false, true])
    }

    @Test("A share the VM no longer carries refuses both edits")
    func sharedDirectoryEditsRefuseAStaleID() async throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness) {
            $0.sharedDirectories = [SharedDirectory(path: externalPath("kept"))]
        }
        let gone = UUID()

        for refusal in [
            await commandError {
                try harness.core.removeSharedDirectory(.id(instance.id), directory: gone)
            },
            await commandError {
                try harness.core.setSharedDirectoryReadOnly(
                    .id(instance.id), directory: gone, readOnly: true)
            },
        ] {
            guard case .operationFailed(let verb, _, _, _) = try #require(refusal) else {
                Issue.record("expected an operation failure, got \(String(describing: refusal))")
                continue
            }
            #expect(verb == .editSharedDirectory)
        }
        #expect(instance.configuration.sharedDirectories?.count == 1)
    }

    @Test("A running VM refuses every share edit — the device set is fixed at boot")
    func runningVMRefusesShareEdits() async throws {
        let harness = makeHarness()
        let directory = SharedDirectory(path: externalPath("kept"))
        let instance = makeInstance(in: harness, phase: .running(sessionID: UUID())) {
            $0.sharedDirectories = [directory]
        }

        for refusal in [
            await commandError {
                try harness.core.addSharedDirectories(
                    .id(instance.id), paths: [PickedFile(path: externalPath("new"), bookmark: nil)])
            },
            await commandError {
                try harness.core.removeSharedDirectory(
                    .id(instance.id), directory: directory.id)
            },
            await commandError {
                try harness.core.setSharedDirectoryReadOnly(
                    .id(instance.id), directory: directory.id, readOnly: true)
            },
        ] {
            guard case .invalidState(_, let current, let allowed, _) = try #require(refusal) else {
                Issue.record("expected an invalid-state refusal, got \(String(describing: refusal))")
                continue
            }
            #expect(current == .running)
            #expect(!allowed.contains(.editSharedDirectory))
        }
        #expect(instance.configuration.sharedDirectories?.map(\.readOnly) == [false])
    }

    // MARK: - Shared directories: a running macOS guest

    /// A folder that exists, so a live swap's validation finds it.
    private func folder(_ suffix: String) throws -> String {
        let path = externalPath(suffix)
        try FileManager.default.createDirectory(
            atPath: path, withIntermediateDirectories: true)
        return path
    }

    /// A running macOS guest booted with `directories`, its session holding
    /// the share its boot built — or, with `serving`, the share given.
    private func makeRunningMacOSGuest(
        in harness: Harness, name: String = "Core VM", sharing directories: [SharedDirectory],
        serving: MacOSDirectoryShare? = nil
    ) throws -> (instance: VMInstance, sessionID: UUID) {
        let sessionID = UUID()
        let instance = makeInstance(
            in: harness, name: name, phase: .running(sessionID: sessionID), guestOS: .macOS
        ) { $0.sharedDirectories = directories.isEmpty ? nil : directories }
        let context = instance.beginSessionContextForTesting()
        if !directories.isEmpty {
            context.directoryShare =
                try serving ?? ConfigurationBuilder.macOSDirectoryShare(for: directories)
        }
        return (instance, sessionID)
    }

    @Test("A running macOS guest with one share takes another live, its device given the list committed")
    func runningMacOSGuestAddsAShareLive() throws {
        let harness = makeHarness()
        let kept = SharedDirectory(path: try folder("kept"))
        let (instance, sessionID) = try makeRunningMacOSGuest(in: harness, sharing: [kept])
        let added = try folder("added")

        try harness.core.addSharedDirectories(
            .id(instance.id), paths: [PickedFile(path: added, bookmark: nil)])

        let directories = try #require(instance.configuration.sharedDirectories)
        #expect(directories.map(\.path) == [kept.path, added])
        let install = try #require(harness.liveShares.installs.last)
        #expect(harness.liveShares.installs.count == 1)
        #expect(install.sessionID == sessionID)
        #expect(install.share.entries.map(\.id) == directories.map(\.id))
        #expect(install.released.isEmpty)
        #expect(instance.sessionContext?.directoryShare == install.share)
    }

    @Test("Removing one of two shares from a running macOS guest swaps live and lets the removed one go")
    func runningMacOSGuestRemovesAShareLive() throws {
        let harness = makeHarness()
        let kept = SharedDirectory(path: try folder("kept"))
        let going = SharedDirectory(path: try folder("going"))
        let (instance, _) = try makeRunningMacOSGuest(in: harness, sharing: [kept, going])

        try harness.core.removeSharedDirectory(.id(instance.id), directory: going.id)
        try harness.core.setSharedDirectoryReadOnly(
            .id(instance.id), directory: kept.id, readOnly: true)

        #expect(instance.configuration.sharedDirectories?.map(\.id) == [kept.id])
        #expect(instance.configuration.sharedDirectories?.first?.readOnly == true)
        #expect(harness.liveShares.installs.map(\.released) == [[going.id], []])
        #expect(harness.liveShares.installs.last?.share.entries.map(\.readOnly) == [true])
    }

    @Test("A folder added live with a bookmark has its scope held under the share's id until removed")
    func liveAddHoldsTheNewSharesScope() throws {
        let harness = makeHarness()
        let kept = SharedDirectory(path: try folder("kept"))
        let (instance, _) = try makeRunningMacOSGuest(in: harness, sharing: [kept])
        let added = URL(fileURLWithPath: try folder("added"))
        let bookmark = try #require(SecurityScopedBookmark.make(for: added))

        try harness.core.addSharedDirectories(
            .id(instance.id),
            paths: [PickedFile(path: added.path(percentEncoded: false), bookmark: bookmark)])

        let share = try #require(instance.configuration.sharedDirectories?.last)
        #expect(share.bookmark == bookmark)
        #expect(harness.liveShares.installs.last?.opened == [share.id])
        #expect(harness.liveShares.heldScopeIDs == [share.id])

        try harness.core.removeSharedDirectory(.id(instance.id), directory: share.id)

        #expect(harness.liveShares.installs.last?.released == [share.id])
        #expect(harness.liveShares.heldScopeIDs.isEmpty)
    }

    /// Two folders of one name: the second is added under its id prefix, and
    /// removing the first renames neither the second in the running guest nor
    /// what a resume rebuilds from the configuration.
    @Test("Removing a share never renames another, live or at the next build")
    func removingAShareKeepsEveryOtherMountName() throws {
        let harness = makeHarness()
        let first = SharedDirectory(path: try folder("a") + "/src")
        try FileManager.default.createDirectory(
            atPath: first.path, withIntermediateDirectories: true)
        let (instance, _) = try makeRunningMacOSGuest(in: harness, sharing: [first])
        let secondPath = try folder("b") + "/src"
        try FileManager.default.createDirectory(
            atPath: secondPath, withIntermediateDirectories: true)

        try harness.core.addSharedDirectories(
            .id(instance.id), paths: [PickedFile(path: secondPath, bookmark: nil)])
        let second = try #require(instance.configuration.sharedDirectories?.last)
        #expect(second.mountName == "\(second.id.uuidString.prefix(8))-src")
        #expect(harness.liveShares.installs.last?.share.entries.map(\.name) == ["src", second.mountName])

        try harness.core.removeSharedDirectory(.id(instance.id), directory: first.id)

        #expect(harness.liveShares.installs.last?.share.entries.map(\.name) == [second.mountName])
        let rebuilt = try ConfigurationBuilder.macOSDirectoryShare(
            for: instance.configuration.sharedDirectories ?? [])
        #expect(rebuilt.entries.map(\.name) == [second.mountName])
    }

    /// The device serves the folder it was built with; a later swap neither
    /// fails on the path the folder left nor re-points the mount at whatever
    /// folder now sits there.
    @Test("A live swap keeps serving a share whose folder moved from its stored path")
    func liveSwapKeepsWhatTheDeviceServes() throws {
        let harness = makeHarness()
        let served = try folder("served")
        for storedPathExists in [false, true] {
            let stored = externalPath("stored")
            if storedPathExists {
                try FileManager.default.createDirectory(
                    atPath: stored, withIntermediateDirectories: true)
            }
            let moved = SharedDirectory(path: stored, mountName: "moved")
            let serving = MacOSDirectoryShare(entries: [
                .init(id: moved.id, name: "moved", url: URL(fileURLWithPath: served), readOnly: false)
            ])
            let (instance, _) = try makeRunningMacOSGuest(
                in: harness, name: "Moved \(storedPathExists)", sharing: [moved], serving: serving)

            try harness.core.addSharedDirectories(
                .id(instance.id), paths: [PickedFile(path: try folder("added"), bookmark: nil)])

            let first = try #require(harness.liveShares.installs.last?.share.entries.first)
            #expect(first == serving.entries[0], "stored path exists: \(storedPathExists)")
        }
    }

    @Test("A folder a live swap cannot share is refused as the argument it is, and nothing is written")
    func liveShareFailingValidationWritesNothing() async throws {
        let harness = makeHarness()
        let kept = SharedDirectory(path: try folder("kept"))
        let (instance, _) = try makeRunningMacOSGuest(in: harness, sharing: [kept])

        let refusal = await commandError {
            try harness.core.addSharedDirectories(
                .id(instance.id),
                paths: [PickedFile(path: externalPath("never-created"), bookmark: nil)])
        }

        guard case .invalidArgument = try #require(refusal) else {
            Issue.record("expected an argument refusal, got \(String(describing: refusal))")
            return
        }
        instance.activity.refreshFromBundle()
        #expect(instance.configuration.sharedDirectories == [kept])
        #expect(harness.liveShares.installs.isEmpty)
    }

    @Test("A running macOS guest's first share and last share are refused by the rule that holds them")
    func runningMacOSGuestRefusesTheFirstAndLastShare() async throws {
        let harness = makeHarness()
        let empty = makeInstance(
            in: harness, name: "Empty", phase: .running(sessionID: UUID()), guestOS: .macOS)
        let only = SharedDirectory(path: try folder("only"))
        let single = makeInstance(
            in: harness, name: "Single", phase: .running(sessionID: UUID()), guestOS: .macOS
        ) { $0.sharedDirectories = [only] }

        for refusal in [
            await commandError {
                try harness.core.addSharedDirectories(
                    .id(empty.id), paths: [PickedFile(path: try folder("first"), bookmark: nil)])
            },
            await commandError {
                try harness.core.removeSharedDirectory(.id(single.id), directory: only.id)
            },
        ] {
            guard case .changeTakesStoppedVM(_, let current, let change) = try #require(refusal)
            else {
                Issue.record("expected the stopped-VM rule, got \(String(describing: refusal))")
                continue
            }
            #expect(current == .running)
            #expect(change == .firstOrLastSharedDirectory)
        }
        let message = try #require(
            await commandError {
                try harness.core.removeSharedDirectory(.id(single.id), directory: only.id)
            }
        ).message
        #expect(
            message
                == "\u{201C}Single\u{201D} is running. Adding the first shared directory or removing the last takes a stopped VM."
        )
        #expect(empty.configuration.sharedDirectories == nil)
        #expect(single.configuration.sharedDirectories == [only])
        #expect(harness.liveShares.installs.isEmpty)
    }

    @Test("A share edit on a suspended macOS guest or a running Linux one is refused by the VM's state")
    func suspendedOrLinuxGuestRefusesShareEdits() async throws {
        let harness = makeHarness()
        let kept = SharedDirectory(path: try folder("kept"))
        let suspended = makeInstance(
            in: harness, name: "Suspended", phase: .suspended, guestOS: .macOS
        ) { $0.sharedDirectories = [kept] }
        try VMInstanceFixture.writeSaveFile(for: suspended)
        let linux = makeInstance(
            in: harness, name: "Linux", phase: .running(sessionID: UUID()), guestOS: .linux
        ) { $0.sharedDirectories = [kept] }

        for instance in [suspended, linux] {
            let refusal = await commandError {
                try harness.core.addSharedDirectories(
                    .id(instance.id), paths: [PickedFile(path: try folder("new"), bookmark: nil)])
            }
            guard case .invalidState(_, _, let allowed, _) = try #require(refusal) else {
                Issue.record("expected an invalid-state refusal, got \(String(describing: refusal))")
                continue
            }
            #expect(!allowed.contains(.editSharedDirectory), "\(instance.name)")
            #expect(instance.configuration.sharedDirectories == [kept], "\(instance.name)")
        }
        #expect(harness.liveShares.installs.isEmpty)
    }

    // MARK: - State gates

    @Test("A running VM refuses a disk edit and takes a removable one")
    func runningVMSplitsTheTwoLists() async throws {
        let harness = makeHarness()
        let disk = StorageDisk(path: "AdditionalDisks/x.asif", label: "Extra", isInternal: true)
        let item = RemovableMediaItem(path: "/tmp/installer.iso", readOnly: true, label: "Old")
        let instance = makeInstance(in: harness, phase: .running(sessionID: UUID())) {
            $0.storageDisks = [disk]
            $0.removableMedia = [item]
        }

        let refusal = await commandError {
            try harness.core.renameStorageDisk(.id(instance.id), disk: disk.id, to: "New")
        }
        guard case .invalidState(_, let current, let allowed, _) = try #require(refusal) else {
            Issue.record("expected an invalid-state refusal")
            return
        }
        #expect(current == .running)
        #expect(!allowed.contains(.editStorageDisk))
        #expect(allowed.contains(.editRemovableMedia))
        #expect(instance.configuration.storageDisks?[0].label == "Extra")

        // Hot-pluggable, so the same edit on the other list goes through.
        try harness.core.renameRemovableMedia(.id(instance.id), item: item.id, to: "New")
        #expect(instance.configuration.removableMedia?[0].label == "New")
    }

    @Test("A Start landing while sharing resolves refuses the disk removal")
    func removeStorageDiskRefusesAStartDuringTheResolve() async throws {
        let harness = makeHarness()
        let path = externalPath("external.img")
        let disk = StorageDisk(path: path, label: "External", isInternal: false)
        let keeper = StorageDisk(path: "AdditionalDisks/k.asif", label: "Keeper", isInternal: true)
        let instance = makeInstance(in: harness) { $0.storageDisks = [disk, keeper] }
        // The removal's sheet leaves the menu key equivalents live, so a Start
        // can land in the suspension the sharing resolve opens — this is that
        // keystroke, landing there deterministically.
        harness.core.afterSharingResolveForTesting = {
            instance.activity.placeForTesting(
                .operating(.bringUp(.guestStart(.starting(recovery: false))), from: .stopped, boundSession: UUID()))
        }

        let refusal = await commandError {
            try await harness.core.removeStorageDisk(
                .id(instance.id), disk: disk.id, trashFile: true, consent: .all)
        }

        // The bring-up holds the VM, and the removal is what the VM takes
        // once it rests again.
        #expect(try #require(refusal).isBusy)
        // Neither the entry nor the file moved: the disk is still the VM's.
        #expect(instance.configuration.storageDisks?.map(\.id) == [disk.id, keeper.id])
        #expect(harness.fileSystem.trashedURLs.isEmpty)
    }

    @Test("A Start landing while sharing resolves refuses the removable-media removal")
    func removeRemovableMediaRefusesAStartDuringTheResolve() async throws {
        let harness = makeHarness()
        let path = externalPath("media.iso")
        let item = RemovableMediaItem(path: path, readOnly: true)
        let instance = makeInstance(in: harness) { $0.removableMedia = [item] }
        // Removable media is hot-pluggable, so the state that refuses is a VM
        // still coming up: no live session to attach to yet.
        harness.core.afterSharingResolveForTesting = {
            instance.activity.placeForTesting(
                .operating(.bringUp(.guestStart(.starting(recovery: false))), from: .stopped, boundSession: UUID()))
        }

        let refusal = await commandError {
            try await harness.core.removeRemovableMedia(
                .id(instance.id), item: item.id, trashFile: true, consent: .all)
        }

        // The bring-up holds the VM, and the removal is what the VM takes
        // once it rests again.
        #expect(try #require(refusal).isBusy)
        #expect(instance.configuration.removableMedia?.map(\.id) == [item.id])
        #expect(harness.fileSystem.trashedURLs.isEmpty)
    }

    @Test("A medium ejected while sharing resolves is refused, and its file is left alone")
    func removeRemovableMediaRefusesADetachDuringTheResolve() async throws {
        let harness = makeHarness()
        let path = externalPath("media.iso")
        let item = RemovableMediaItem(path: path, readOnly: true)
        let instance = makeInstance(in: harness) { $0.removableMedia = [item] }
        // An Eject from the row's own menu, landing while this removal's
        // resolve is in flight.
        harness.core.afterSharingResolveForTesting = {
            harness.library.editConfiguration(of: instance, as: .hotPlugMedia) { $0.removableMedia = nil }
        }

        let refusal = await commandError {
            try await harness.core.removeRemovableMedia(
                .id(instance.id), item: item.id, trashFile: true, consent: .all)
        }

        #expect(refusal?.isOperationFailure == true)
        #expect(harness.fileSystem.trashedURLs.isEmpty)
    }

    @Test("A suspended VM refuses both lists — its saved state pins the device set")
    func suspendedVMRefusesBothLists() async throws {
        let harness = makeHarness()
        let item = RemovableMediaItem(path: "/tmp/installer.iso", readOnly: true, label: "Old")
        let instance = makeInstance(in: harness, phase: .suspended) { $0.removableMedia = [item] }
        try VMInstanceFixture.writeSaveFile(for: instance)

        let refusal = await commandError {
            try harness.core.renameRemovableMedia(.id(instance.id), item: item.id, to: "New")
        }

        guard case .invalidState = try #require(refusal) else {
            Issue.record("expected an invalid-state refusal")
            return
        }
        #expect(instance.configuration.removableMedia?[0].label == "Old")
    }

    @Test("A bundle still being copied refuses every attachment edit as busy")
    func arrivalRefusesEveryEdit() async throws {
        let harness = makeHarness()
        let gate = GatedStep()
        let arrival = harness.library.beginGatedArrival(
            .cloning, named: "Copying", gate: gate)

        let storageRefusal = await commandError {
            try harness.core.setStorageDiskReadOnly(
                .id(arrival.id), disk: UUID(), readOnly: true)
        }
        let removableRefusal = await commandError {
            try harness.core.attachRemovableMedia(
                .id(arrival.id), paths: [PickedFile(path: "/tmp/x.iso", bookmark: nil)])
        }

        #expect(storageRefusal?.isBusy == true)
        #expect(removableRefusal?.isBusy == true)
        #expect(harness.storage.saveConfigurationCallCount == 0)

        gate.release()
        await arrival.settle()
    }

    @Test("A storage edit on a VM being cloned is refused as busy, naming the clone")
    func copyOutRefusesStorageEditButNotRemovableMedia() async throws {
        let harness = makeHarness()
        let disk = StorageDisk(path: "AdditionalDisks/x.asif", label: "Extra", isInternal: true)
        let source = makeInstance(in: harness, name: "Source") { $0.storageDisks = [disk] }
        let hold = DispatchSemaphore(value: 0)
        harness.storage.cloneHold = hold
        let clone = try await harness.core.clone(
            .id(source.id), outcome: .newMachine, waitForOutcome: false)
        try await harness.storage.cloneEntered.wait { harness.storage.cloneVMBundleCallCount == 1 }

        let removeError = try #require(
            await commandError {
                try await harness.core.removeStorageDisk(
                    .id(source.id), disk: disk.id, trashFile: false, consent: .all)
            })
        guard case .busy(let vm, let operation) = removeError else {
            Issue.record("expected a busy refusal, got \(removeError)")
            return
        }
        #expect(vm.id == source.id)
        #expect(operation == "being cloned")
        #expect(
            removeError.message.contains(
                "is busy being cloned. Wait for it to finish, then try again."))

        let attachError = await commandError {
            try harness.core.attachStorageDisks(
                .id(source.id), paths: [PickedFile(path: "/tmp/x.img", bookmark: nil)])
        }
        #expect(attachError?.isBusy == true)
        #expect(source.configuration.storageDisks?.count == 1)

        // Removable media isn't copied by a clone, so it takes an edit unblocked.
        try harness.core.attachRemovableMedia(
            .id(source.id), paths: [PickedFile(path: "/tmp/y.iso", bookmark: nil)])
        #expect(source.configuration.removableMedia?.count == 1)

        hold.signal()
        await harness.library.arrivals.first { $0.id == clone.id }?.settle()
    }

    @Test("An edit naming an attachment that is no longer there is refused, not silently dropped")
    func staleAttachmentIsRefused() async throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness) {
            $0.storageDisks = [
                StorageDisk(path: "AdditionalDisks/x.asif", label: "Extra", isInternal: true)
            ]
        }
        let gone = UUID()

        let renameRefusal = await commandError {
            try harness.core.renameStorageDisk(.id(instance.id), disk: gone, to: "New")
        }
        let notesRefusal = await commandError {
            try harness.core.setRemovableMediaNotes(.id(instance.id), item: gone, notes: "New")
        }
        let removeRefusal = await commandError {
            try await harness.core.removeStorageDisk(
                .id(instance.id), disk: gone, trashFile: false, consent: .all)
        }

        #expect(renameRefusal?.isOperationFailure == true)
        #expect(renameRefusal?.message.contains(instance.name) == true)
        #expect(notesRefusal?.isOperationFailure == true)
        #expect(removeRefusal?.isOperationFailure == true)
        #expect(instance.configuration.storageDisks?.count == 1)
    }

    // MARK: - Guest agent disk

    @Test("Mounting attaches the installer once and reports it present on a second call")
    func mountGuestAgentDiskIsIdempotent() throws {
        let installerPath = try #require(KernovaMacOSAgentInfo.installerDiskImageURL)
            .path(percentEncoded: false)
        let harness = makeHarness()
        let instance = makeInstance(
            in: harness, phase: .running(sessionID: UUID()), guestOS: .macOS)

        #expect(try harness.core.mountGuestAgentDisk(.id(instance.id)) == .attached(.usb))
        #expect(instance.configuration.removableMedia?.map(\.path) == [installerPath])

        #expect(try harness.core.mountGuestAgentDisk(.id(instance.id)) == .alreadyPresent(.usb))
        #expect(instance.configuration.removableMedia?.count == 1)
    }

    @Test("A guest that takes the disk on virtio attaches nothing and says so")
    func mountGuestAgentDiskOnVirtioGuest() throws {
        let harness = makeHarness()
        let instance = makeInstance(
            in: harness, phase: .running(sessionID: UUID()), guestOS: .macOS
        ) {
            $0.installedImage = .macOSRestoreImage(version: "12.0.1", build: "21A559")
        }

        #expect(try harness.core.mountGuestAgentDisk(.id(instance.id)) == .alreadyPresent(.virtio))
        #expect(instance.configuration.removableMedia == nil)
        #expect(instance.configuration.storageDisks == nil)
    }

    @Test("Unmounting drops the installer entry, and an agent handshake does it unasked")
    func unmountGuestAgentDisk() throws {
        let installerPath = try #require(KernovaMacOSAgentInfo.installerDiskImageURL)
            .path(percentEncoded: false)
        let harness = makeHarness()
        let instance = makeInstance(
            in: harness, phase: .running(sessionID: UUID()), guestOS: .macOS
        ) {
            $0.removableMedia = [RemovableMediaItem(path: installerPath, readOnly: true)]
        }

        try harness.core.unmountGuestAgentDisk(.id(instance.id))
        #expect(instance.configuration.removableMedia == nil)

        // The auto-eject the core wires onto the library fires the same detach
        // when the agent it carries handshakes as current.
        try harness.core.mountGuestAgentDisk(.id(instance.id))
        instance.onAgentBecameCurrent?()
        #expect(instance.configuration.removableMedia == nil)
    }

    @Test("An agent handshake during a live snapshot leaves the installer mounted for a later eject")
    func autoEjectWaitsOutAnUnattachableSession() throws {
        let installerPath = try #require(KernovaMacOSAgentInfo.installerDiskImageURL)
            .path(percentEncoded: false)
        let harness = makeHarness()
        let sessionID = UUID()
        let instance = makeInstance(
            in: harness,
            phase: .operating(.capturingSnapshot(.live), from: .running(sessionID: sessionID)),
            guestOS: .macOS
        ) {
            $0.removableMedia = [RemovableMediaItem(path: installerPath, readOnly: true)]
        }
        instance.beginSessionContextForTesting()

        instance.onAgentBecameCurrent?()

        #expect(instance.configuration.removableMedia?.map(\.path) == [installerPath])
        #expect(instance.hasGuestAgentInstallerMounted)
        #expect(harness.removableMediaDevices.detachCallCount == 0)

        instance.activity.placeForTesting(.running(sessionID: sessionID))
        try harness.core.unmountGuestAgentDisk(.id(instance.id))
        #expect(instance.configuration.removableMedia == nil)
    }

    @Test("An agent handshake during a USB attach ejects the installer once the attach ends")
    func autoEjectDuringAnAttachLandsAfterIt() async throws {
        let installerPath = try #require(KernovaMacOSAgentInfo.installerDiskImageURL)
            .path(percentEncoded: false)
        let installer = RemovableMediaItem(path: installerPath, readOnly: true)
        let harness = makeHarness(usbAccessoryService: MockUSBAccessoryService())
        let sessionID = UUID()
        let instance = makeInstance(
            in: harness, phase: .running(sessionID: sessionID), guestOS: .macOS
        ) {
            $0.removableMedia = [installer]
        }
        instance.beginSessionContextForTesting()
        instance.recordAttachedMedia(
            RemovableMediaDeviceInfo(id: installer.id, path: installerPath, readOnly: true),
            for: sessionID)
        let gate = GatedStep()
        let attach = try instance.activity.launch(.attachingUSB(registryID: 7)) { _ in
            try await gate.pass()
            return .rest(.asStarted, ())
        }
        try await gate.waitUntilEntered()

        instance.onAgentBecameCurrent?()
        #expect(instance.configuration.removableMedia == nil)
        #expect(harness.removableMediaDevices.detachCallCount == 0)
        #expect(instance.activity.queuedFollowUpCountForTesting == 1)

        gate.release()
        try await attach.value()
        try await waitForChange { instance.liveRemovableMedia.isEmpty }
        try await waitForChange { instance.phase == .running(sessionID: sessionID) }
        #expect(harness.removableMediaDevices.detachCallCount == 1)
        #expect(instance.phase == .running(sessionID: sessionID))
    }

    @Test("A VM with no live session to look inside refuses the guest agent disk")
    func guestAgentDiskNeedsALiveMacOSGuest() async throws {
        let harness = makeHarness()
        let stopped = makeInstance(in: harness, name: "Stopped", guestOS: .macOS)
        let linux = makeInstance(in: harness, name: "Linux", phase: .running(sessionID: UUID()))

        let stoppedRefusal = await commandError {
            _ = try harness.core.mountGuestAgentDisk(.id(stopped.id))
        }
        let linuxRefusal = await commandError {
            _ = try harness.core.mountGuestAgentDisk(.id(linux.id))
        }

        #expect(stoppedRefusal != nil)
        #expect(linuxRefusal != nil)
        #expect(stopped.configuration.removableMedia == nil)
        #expect(linux.configuration.removableMedia == nil)
    }

    // MARK: - Start-failure recovery

    @Test("A failed VM takes the start-failed removal both gates admit")
    func removeStartFailedAttachmentOnAFailedVM() async throws {
        let harness = makeHarness()
        let path = externalPath("missing.img")
        let disk = StorageDisk(path: path, label: "Scratch", isInternal: false)
        let keeper = StorageDisk(path: "AdditionalDisks/k.asif", label: "Keeper", isInternal: true)
        let instance = makeInstance(in: harness, phase: .failed(message: "Boot failed.")) {
            $0.storageDisks = [disk, keeper]
        }

        // A VM at rest with no saved state can be edited, so neither capability
        // blocks the recovery a failed start offered.
        #expect(harness.core.capabilities.accepts(.editStorageDisks, on: instance))
        #expect(harness.core.capabilities.accepts(.editRemovableMedia, on: instance))

        try await harness.core.removeStartFailedAttachment(
            .id(instance.id),
            attachment: StartFailedAttachment(
                verb: .start, kind: .storageDisk, reason: .attachRefused, id: disk.id,
                label: "Scratch",
                message: "could not open"))

        #expect(instance.configuration.storageDisks?.map(\.id) == [keeper.id])
        // The file the start could not open is left exactly where it is.
        #expect(harness.fileSystem.trashedURLs.isEmpty)
        // The removal is the whole verb: the VM is where the failed start left
        // it, and the start the door runs next is an ordinary one.
        #expect(harness.virtualization.startCallCount == 0)
    }

    @Test("The start-failed removal starts nothing, whatever the start would have asked for")
    func removeStartFailedAttachmentStartsNothing() async throws {
        let harness = makeHarness()
        let disk = StorageDisk(path: externalPath("missing.img"), label: "Scratch", isInternal: false)
        let keeper = StorageDisk(path: "AdditionalDisks/k.asif", label: "Keeper", isInternal: true)
        let instance = makeInstance(
            in: harness, phase: .failed(message: "Boot failed."), guestOS: .macOS
        ) {
            $0.storageDisks = [disk, keeper]
            $0.pendingGuestAccount = GuestAccountIntent(
                fullName: "Ada Lovelace", username: "ada", logsInAutomatically: false,
                enablesRemoteLogin: false)
        }

        // No refusal, though a start of this VM would raise one: the removal
        // asks for nothing a start asks for, so the account is the following
        // start's question and is asked once.
        try await harness.core.removeStartFailedAttachment(
            .id(instance.id),
            attachment: StartFailedAttachment(
                verb: .start, kind: .storageDisk, reason: .attachRefused, id: disk.id,
                label: "Scratch",
                message: "could not open"))

        #expect(instance.configuration.storageDisks?.map(\.id) == [keeper.id])
        #expect(harness.virtualization.startCallCount == 0)
        // Untouched, so the start that follows raises the question itself.
        #expect(instance.configuration.pendingGuestAccount != nil)
    }

    @Test("A start-failed removal naming an entry that is already gone removes nothing")
    func removeStartFailedAttachmentAlreadyGone() async throws {
        let harness = makeHarness()
        let keeper = RemovableMediaItem(path: externalPath("keep.iso"), readOnly: true)
        let instance = makeInstance(in: harness, phase: .failed(message: "Boot failed.")) {
            $0.removableMedia = [keeper]
        }

        try await harness.core.removeStartFailedAttachment(
            .id(instance.id),
            attachment: StartFailedAttachment(
                verb: .start, kind: .removableMedia, reason: .attachRefused, id: UUID(),
                label: "Installer",
                message: "could not open"))

        // What the recovery was for already holds, so it is a quiet no-op — and
        // the list it would have edited is untouched.
        #expect(instance.configuration.removableMedia?.map(\.id) == [keeper.id])
        #expect(instance.status == .error)
    }

    @Test("A start-failed removal that finds its entry gone keeps the saved state")
    func removeStartFailedAttachmentAlreadyGoneKeepsTheSavedState() async throws {
        let harness = makeHarness()
        let keeper = RemovableMediaItem(path: externalPath("keep.iso"), readOnly: true)
        let instance = makeInstance(in: harness, phase: .suspended) { $0.removableMedia = [keeper] }
        try VMInstanceFixture.writeSaveFile(for: instance)

        try await harness.core.removeStartFailedAttachment(
            .id(instance.id),
            attachment: StartFailedAttachment(
                verb: .resume, kind: .removableMedia, reason: .attachRefused, id: UUID(),
                label: "Installer",
                message: "could not open"))

        // A confirmation can land long after the fact, and the slot on disk may
        // be a newer one this recovery knows nothing about.
        #expect(instance.hasSaveFile)
        #expect(instance.isSuspended)
    }

    @Test("A resume-failed removal discards the saved state before it edits the device set")
    func removeStartFailedAttachmentDiscardsTheSavedState() async throws {
        let harness = makeHarness()
        let disk = StorageDisk(path: externalPath("missing.img"), label: "Scratch", isInternal: false)
        let keeper = StorageDisk(path: "AdditionalDisks/k.asif", label: "Keeper", isInternal: true)
        let instance = makeInstance(in: harness, phase: .suspended) {
            $0.storageDisks = [disk, keeper]
        }
        try VMInstanceFixture.writeSaveFile(for: instance)
        // The saved state pins the device set, so the removal would be refused
        // until the discard clears it.
        #expect(!harness.core.capabilities.accepts(.editStorageDisks, on: instance))

        try await harness.core.removeStartFailedAttachment(
            .id(instance.id),
            attachment: StartFailedAttachment(
                verb: .resume, kind: .storageDisk, reason: .attachRefused, id: disk.id,
                label: "Scratch",
                message: "could not open"))

        // The save file goes with the removal, and the VM rests where a VM
        // with nothing to restore belongs, ready for the start the door runs
        // next.
        #expect(!instance.hasSaveFile)
        #expect(instance.phase == .stopped)
        #expect(instance.configuration.storageDisks?.map(\.id) == [keeper.id])
        #expect(harness.virtualization.startCallCount == 0)
    }

    /// The removal lands before the discard, so a discard the file system
    /// turns down leaves the entry gone and the save file on disk — which
    /// still restores when what went was removable media.
    @Test(
        "A discard that fails after the removal names a way out only for a removed storage disk",
        arguments: [StartFailedAttachment.Kind.storageDisk, .removableMedia])
    func aFailedDiscardAfterTheRemovalStatesOnlyWhatIsKnown(
        kind: StartFailedAttachment.Kind
    ) async throws {
        let harness = makeHarness()
        let disk = StorageDisk(path: externalPath("missing.img"), label: "Scratch", isInternal: false)
        let keeper = StorageDisk(path: "AdditionalDisks/k.asif", label: "Keeper", isInternal: true)
        let media = RemovableMediaItem(
            path: externalPath("media.iso"), readOnly: true, label: "Installer")
        let instance = makeInstance(in: harness, phase: .suspended) {
            $0.storageDisks = [disk, keeper]
            $0.removableMedia = [media]
        }
        try VMInstanceFixture.writeSaveFile(for: instance)
        // A bundle directory the save file cannot be removed from.
        let bundlePath = instance.bundleURL.path(percentEncoded: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: bundlePath)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: bundlePath)
        }
        let (id, label) = kind == .storageDisk ? (disk.id, "Scratch") : (media.id, "Installer")

        let error = await commandError {
            try await harness.core.removeStartFailedAttachment(
                .id(instance.id),
                attachment: StartFailedAttachment(
                    verb: .resume, kind: kind, reason: .attachRefused, id: id, label: label,
                    message: "could not open"))
        }

        let message = try #require(error?.message)
        #expect(instance.hasSaveFile)
        #expect(message.contains("but its saved state could not be deleted."))
        switch kind {
        case .storageDisk:
            #expect(instance.configuration.storageDisks?.map(\.id) == [keeper.id])
            #expect(
                message.hasSuffix(
                    "That state can no longer be restored — discard it to start the virtual machine."))
        case .removableMedia:
            #expect((instance.configuration.removableMedia ?? []).isEmpty)
            #expect(message.hasSuffix("but its saved state could not be deleted."))
        }
    }

    @Test("A start-failed removal that refuses leaves the saved state alone")
    func aRefusedStartFailedRemovalKeepsTheSavedState() async throws {
        let harness = makeHarness()
        let sole = StorageDisk(path: externalPath("missing.img"), label: "Scratch", isInternal: false)
        let instance = makeInstance(in: harness, phase: .suspended) { $0.storageDisks = [sole] }
        try VMInstanceFixture.writeSaveFile(for: instance)

        // A VM keeps at least one storage disk, so this removal is refused.
        await #expect(throws: CommandError.self) {
            try await harness.core.removeStartFailedAttachment(
                .id(instance.id),
                attachment: StartFailedAttachment(
                    verb: .resume, kind: .storageDisk, reason: .attachRefused, id: sole.id,
                    label: "Scratch",
                    message: "could not open"))
        }

        #expect(instance.configuration.storageDisks?.map(\.id) == [sole.id])
        // The refusal is raised before the discard, so the session survives a
        // removal that was never going to happen.
        #expect(instance.hasSaveFile)
        #expect(instance.isSuspended)
    }

    /// The alert the recovery is confirmed from is window-modal, so every other
    /// door stays live behind it: the state the click lands in is not the state
    /// the offer was made in, and the discard is the one step nothing can undo.
    @Test(
        "A start-failed removal the VM can no longer take keeps both the saved state and the entry",
        arguments: [
            PhaseFixture.operating(.bringUp(.guestStart(.restoringSavedState)), from: .suspended),
            .operating(.bringUp(.guestStart(.starting(recovery: false))), from: .stopped),
            .settled(.running(sessionID: VMLifecyclePhaseFixtures.session)),
        ])
    func aStartFailedRemovalRefusedByTheVMsStateKeepsEverything(phase: PhaseFixture) async throws {
        let harness = makeHarness()
        let disk = StorageDisk(path: externalPath("missing.img"), label: "Scratch", isInternal: false)
        let keeper = StorageDisk(path: "AdditionalDisks/k.asif", label: "Keeper", isInternal: true)
        let instance = makeInstance(in: harness, phase: .suspended) {
            $0.storageDisks = [disk, keeper]
        }
        try VMInstanceFixture.writeSaveFile(for: instance)
        // A bring-up another door issued while the alert was up — the slot is
        // still on disk, and VZ has not finished loading it.
        let placed = phase.phase
        instance.activity.placeForTesting(placed)

        await #expect(throws: CommandError.self) {
            try await harness.core.removeStartFailedAttachment(
                .id(instance.id),
                attachment: StartFailedAttachment(
                    verb: .resume, kind: .storageDisk, reason: .attachRefused, id: disk.id,
                    label: "Scratch",
                    message: "could not open"))
        }

        #expect(instance.hasSaveFile)
        #expect(instance.configuration.storageDisks?.map(\.id) == [disk.id, keeper.id])
        #expect(instance.phase == placed)
    }

    /// The discard is the last thing the recovery does, so everything that can
    /// still refuse — the configuration write included — refuses with the
    /// session and the entry both intact.
    @Test("A start-failed removal whose configuration write fails keeps the saved state")
    func aStartFailedRemovalWhoseWriteFailsKeepsEverything() async throws {
        let harness = makeHarness()
        let disk = StorageDisk(path: externalPath("missing.img"), label: "Scratch", isInternal: false)
        let keeper = StorageDisk(path: "AdditionalDisks/k.asif", label: "Keeper", isInternal: true)
        let instance = makeInstance(in: harness, phase: .suspended) {
            $0.storageDisks = [disk, keeper]
        }
        try VMInstanceFixture.writeSaveFile(for: instance)
        harness.storage.saveConfigurationError = VMStorageError.bundleNotFound(instance.bundleURL)

        await #expect(throws: CommandError.self) {
            try await harness.core.removeStartFailedAttachment(
                .id(instance.id),
                attachment: StartFailedAttachment(
                    verb: .resume, kind: .storageDisk, reason: .attachRefused, id: disk.id,
                    label: "Scratch",
                    message: "could not open"))
        }

        #expect(instance.hasSaveFile)
        #expect(instance.isSuspended)
    }
}
