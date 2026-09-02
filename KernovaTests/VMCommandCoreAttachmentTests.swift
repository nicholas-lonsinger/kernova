import Foundation
import KernovaKit
import Testing

@testable import Kernova

/// The attachment verbs, driven with no view model and no presenter: every
/// edit's happy path, the state gate each refuses on, the consent a trashing
/// removal asks for, and the files that are never trashed however the removal
/// is asked for.
@Suite("VMCommandCore Attachment Tests", .serialized, .admissionGated)
@MainActor
struct VMCommandCoreAttachmentTests {
    private let preferences = makeEphemeralPreferences(
        suiteName: "test.kernova.commandcore.attachments")

    private struct Harness {
        let core: VMCommandCore
        let library: VMLibrary
        let storage: MockVMStorageService
        let diskImages: MockDiskImageService
        let fileSystem: MockFileSystem
        let usbDevices: MockUSBDeviceService
    }

    private func makeHarness(diskImages: MockDiskImageService = MockDiskImageService()) -> Harness {
        let storage = MockVMStorageService()
        let snapshots = MockVMSnapshotStore()
        let fileSystem = MockFileSystem()
        let usbDevices = MockUSBDeviceService()
        let lifecycle = VMLifecycleCoordinator(
            virtualizationService: MockVirtualizationService(),
            installService: MockMacOSInstallService(),
            ipswService: MockIPSWService(),
            usbDeviceService: usbDevices,
            linuxImageResolveService: MockLinuxImageResolveService(),
            downloadService: MockDownloadService(),
            fileSystem: fileSystem
        )
        let library = VMLibrary(
            storageService: storage,
            snapshotStore: snapshots,
            lifecycle: lifecycle,
            fileSystem: fileSystem,
            preferences: preferences,
            vmnetNetworks: MockVmnetNetworkProvider(),
            isVMNetworkingEntitled: true
        )
        let core = VMCommandCore(
            library: library,
            lifecycle: lifecycle,
            storageService: storage,
            snapshotStore: snapshots,
            diskImageService: diskImages,
            fileSystem: fileSystem,
            preferences: preferences
        )
        return Harness(
            core: core, library: library, storage: storage, diskImages: diskImages,
            fileSystem: fileSystem, usbDevices: usbDevices)
    }

    @discardableResult
    private func makeInstance(
        in harness: Harness, name: String = "Core VM", phase: VMLifecyclePhase = .stopped,
        guestOS: VMGuestOS = .linux
    ) -> VMInstance {
        RegisteredVMInstanceFixture.register(
            name: name, phase: phase, guestOS: guestOS, library: harness.library,
            storage: harness.storage, preferences: preferences)
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
        FileManager.default.temporaryDirectory
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
        let instance = makeInstance(in: harness)
        defer { try? FileManager.default.removeItem(at: instance.bundleURL) }
        instance.configuration.storageDisks = [
            StorageDisk(
                path: "AdditionalDisks/a.asif", label: "100 GB Disk", isInternal: true,
                kind: .virtio)
        ]

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

    @Test("A failed disk write trashes what it may have left and leaves the list alone")
    func createStorageDiskWriteFailureCleansUp() async throws {
        let diskImages = MockDiskImageService()
        diskImages.createDiskImageError = DiskImageError.writeFailed(NSError(domain: "t", code: 1))
        let harness = makeHarness(diskImages: diskImages)
        let instance = makeInstance(in: harness)
        defer { try? FileManager.default.removeItem(at: instance.bundleURL) }

        let refusal = await commandError {
            try await harness.core.createStorageDisk(.id(instance.id), sizeInGB: 32)
        }

        #expect(refusal?.isOperationFailure == true)
        #expect(harness.fileSystem.trashedURLs.count == 1)
        #expect(instance.configuration.storageDisks == nil)
    }

    @Test("A create that failed before writing leaves the destination untouched")
    func createStorageDiskPreWriteFailureTrashesNothing() async throws {
        let diskImages = MockDiskImageService()
        diskImages.createDiskImageError = DiskImageError.templateMissing(sizeInGB: 32)
        let harness = makeHarness(diskImages: diskImages)
        let instance = makeInstance(in: harness)
        defer { try? FileManager.default.removeItem(at: instance.bundleURL) }

        let refusal = await commandError {
            try await harness.core.createStorageDisk(.id(instance.id), sizeInGB: 32)
        }

        #expect(refusal?.isOperationFailure == true)
        #expect(harness.fileSystem.trashedURLs.isEmpty)
        #expect(instance.configuration.storageDisks == nil)
    }

    // MARK: - Storage: label, note, read-only, order

    @Test("A rename trims the label, persists it, and saves once")
    func renameStorageDiskPersists() throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness)
        let disk = StorageDisk(
            path: "AdditionalDisks/x.asif", label: "Original", isInternal: true, kind: .virtio)
        instance.configuration.storageDisks = [disk]
        harness.storage.saveConfigurationCallCount = 0

        try harness.core.renameStorageDisk(.id(instance.id), disk: disk.id, to: "  Renamed  ")

        #expect(instance.configuration.storageDisks?[0].label == "Renamed")
        #expect(harness.storage.bundles[instance.bundleURL]?.storageDisks?[0].label == "Renamed")
        #expect(harness.storage.saveConfigurationCallCount == 1)
    }

    @Test("An empty rename is ignored and saves nothing")
    func renameStorageDiskEmptyIsIgnored() throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness)
        let disk = StorageDisk(
            path: "AdditionalDisks/x.asif", label: "Original", isInternal: true, kind: .virtio)
        instance.configuration.storageDisks = [disk]
        harness.storage.saveConfigurationCallCount = 0

        try harness.core.renameStorageDisk(.id(instance.id), disk: disk.id, to: "   ")

        #expect(instance.configuration.storageDisks?[0].label == "Original")
        #expect(harness.storage.saveConfigurationCallCount == 0)
    }

    @Test("A note is trimmed, an empty one clears it, and an unchanged one saves nothing")
    func storageDiskNotes() throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness)
        let disk = StorageDisk(
            path: "AdditionalDisks/x.asif", label: "Data", isInternal: true, kind: .virtio)
        instance.configuration.storageDisks = [disk]
        harness.storage.saveConfigurationCallCount = 0

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
        harness.storage.saveConfigurationCallCount = 0

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
        let instance = makeInstance(in: harness)
        let disk = StorageDisk(
            path: "AdditionalDisks/x.asif", label: "Data", isInternal: true, kind: .virtio)
        instance.configuration.storageDisks = [disk]

        try harness.core.setStorageDiskReadOnly(.id(instance.id), disk: disk.id, readOnly: true)

        #expect(instance.configuration.storageDisks?[0].readOnly == true)
    }

    @Test("A reorder ranks the disks it names and keeps the rest behind them")
    func reorderStorageDisks() throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness)
        let first = StorageDisk(path: "AdditionalDisks/a.asif", label: "A", isInternal: true)
        let second = StorageDisk(path: "AdditionalDisks/b.asif", label: "B", isInternal: true)
        let unnamed = StorageDisk(path: "AdditionalDisks/c.asif", label: "C", isInternal: true)
        instance.configuration.storageDisks = [first, second, unnamed]

        try harness.core.reorderStorageDisks(.id(instance.id), order: [second.id, first.id])

        #expect(instance.configuration.storageDisks?.map(\.label) == ["B", "A", "C"])
    }

    // MARK: - Storage: removal

    @Test("A removal that keeps the file drops the entry and touches nothing on disk")
    func removeStorageDiskKeepingTheFile() async throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness)
        let main = StorageDisk(path: "Disk.asif", label: "Main Disk", isInternal: true)
        let extra = StorageDisk(path: "AdditionalDisks/x.asif", label: "Extra", isInternal: true)
        instance.configuration.storageDisks = [main, extra]

        try await harness.core.removeStorageDisk(
            .id(instance.id), disk: extra.id, trashFile: false, confirmed: false)

        #expect(instance.configuration.storageDisks?.map(\.id) == [main.id])
        #expect(harness.fileSystem.trashedURLs.isEmpty)
    }

    @Test("A trashing removal asks for consent, then trashes the external file")
    func removeStorageDiskTrashesAfterConsent() async throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness)
        let path = externalPath("external.img")
        let external = StorageDisk(path: path, label: "External", isInternal: false)
        let keeper = StorageDisk(path: "AdditionalDisks/k.asif", label: "Keeper", isInternal: true)
        instance.configuration.storageDisks = [external, keeper]

        let refusal = await commandError {
            try await harness.core.removeStorageDisk(
                .id(instance.id), disk: external.id, trashFile: true, confirmed: false)
        }
        #expect(refusal?.confirmationPrompt?.kind == .removeAttachment)
        #expect(refusal?.confirmationPrompt?.confirmTitle == "Move to Trash")
        // Refused, so nothing moved.
        #expect(instance.configuration.storageDisks?.count == 2)

        try await harness.core.removeStorageDisk(
            .id(instance.id), disk: external.id, trashFile: true, confirmed: true)

        #expect(instance.configuration.storageDisks?.map(\.id) == [keeper.id])
        #expect(harness.fileSystem.trashedURLs == [URL(fileURLWithPath: path)])
    }

    @Test("A trashing removal of an in-bundle disk resolves the file against the bundle")
    func removeInternalStorageDiskTrashesInsideTheBundle() async throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness)
        let internalDisk = StorageDisk(
            path: "AdditionalDisks/x.asif", label: "Extra", isInternal: true)
        let keeper = StorageDisk(path: "AdditionalDisks/k.asif", label: "Keeper", isInternal: true)
        instance.configuration.storageDisks = [internalDisk, keeper]

        try await harness.core.removeStorageDisk(
            .id(instance.id), disk: internalDisk.id, trashFile: true, confirmed: true)

        #expect(
            harness.fileSystem.trashedURLs
                == [instance.bundleURL.appendingPathComponent("AdditionalDisks/x.asif")])
    }

    @Test("A file another VM still references is kept, however the removal is asked for")
    func removeStorageDiskKeepsASharedFile() async throws {
        let harness = makeHarness()
        let target = makeInstance(in: harness, name: "Target")
        let other = makeInstance(in: harness, name: "Other")
        let path = externalPath("shared.img")
        let disk = StorageDisk(path: path, label: "Shared", isInternal: false)
        let keeper = StorageDisk(path: "AdditionalDisks/k.asif", label: "Keeper", isInternal: true)
        target.configuration.storageDisks = [disk, keeper]
        other.configuration.storageDisks = [StorageDisk(path: path, label: "Shared")]

        // A shared file is offered detach-only, so that is what confirming does.
        let refusal = await commandError {
            try await harness.core.removeStorageDisk(
                .id(target.id), disk: disk.id, trashFile: true, confirmed: false)
        }
        #expect(refusal?.confirmationPrompt?.confirmTitle == "Remove from VM")
        #expect(refusal?.confirmationPrompt?.message.contains("Other") == true)

        try await harness.core.removeStorageDisk(
            .id(target.id), disk: disk.id, trashFile: true, confirmed: true)

        #expect(target.configuration.storageDisks?.map(\.id) == [keeper.id])
        #expect(harness.fileSystem.trashedURLs.isEmpty)
    }

    @Test("A missing file is swallowed, and any other trash failure is reported")
    func removeStorageDiskTrashFailures() async throws {
        let harness = makeHarness()
        var failures: [CommandError] = []
        harness.core.onFailure = { failure, _ in failures.append(failure) }
        let instance = makeInstance(in: harness)
        let ghost = StorageDisk(path: externalPath("ghost.img"), label: "Ghost")
        let doomed = StorageDisk(path: externalPath("locked.img"), label: "Locked")
        let keeper = StorageDisk(path: "AdditionalDisks/k.asif", label: "Keeper", isInternal: true)
        instance.configuration.storageDisks = [ghost, doomed, keeper]

        harness.fileSystem.trashError = CocoaError(.fileNoSuchFile)
        try await harness.core.removeStorageDisk(
            .id(instance.id), disk: ghost.id, trashFile: true, confirmed: true)
        #expect(failures.isEmpty)

        harness.fileSystem.trashError = CocoaError(.fileWriteNoPermission)
        try await harness.core.removeStorageDisk(
            .id(instance.id), disk: doomed.id, trashFile: true, confirmed: true)

        // The entry goes either way; only the second failure is worth telling
        // the user about.
        #expect(instance.configuration.storageDisks?.map(\.id) == [keeper.id])
        #expect(failures.count == 1)
        #expect(failures.first?.isOperationFailure == true)
    }

    @Test("The synthesized main disk is a VM's only disk, so its removal is refused")
    func removeSyntheticMainDiskIsRefused() async throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness)
        instance.configuration.storageDisks = nil
        let synthetic = StorageDisk.mainDisk(
            layout: VMBundleLayout(bundleURL: instance.bundleURL))

        let refusal = await commandError {
            try await harness.core.removeStorageDisk(
                .id(instance.id), disk: synthetic.id, trashFile: true, confirmed: true)
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
        instance.configuration.storageDisks = [main, extra]

        try await harness.core.removeStorageDisk(
            .id(instance.id), disk: main.id, trashFile: true, confirmed: true)

        #expect(instance.configuration.storageDisks?.map(\.id) == [extra.id])
        #expect(
            harness.fileSystem.trashedURLs.contains(
                instance.bundleURL.appendingPathComponent("Disk.asif")))
    }

    @Test("A VM's only disk is refused whichever file backs it")
    func removeSoleAdditionalDiskIsRefused() async throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness)
        let extra = StorageDisk(path: "AdditionalDisks/x.asif", label: "Extra", isInternal: true)
        instance.configuration.storageDisks = [extra]

        let refusal = await commandError {
            try await harness.core.removeStorageDisk(
                .id(instance.id), disk: extra.id, trashFile: true, confirmed: true)
        }

        #expect(refusal?.isOperationFailure == true)
        #expect(instance.configuration.storageDisks?.map(\.id) == [extra.id])
        #expect(harness.fileSystem.trashedURLs.isEmpty)
    }

    @Test("A disk left the VM's last while sharing resolves is refused on the far side")
    func removeStorageDiskRefusesBecomingTheSoleDiskDuringTheResolve() async throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness)
        let path = externalPath("external.img")
        let external = StorageDisk(path: path, label: "External", isInternal: false)
        let other = StorageDisk(path: "AdditionalDisks/x.asif", label: "Extra", isInternal: true)
        instance.configuration.storageDisks = [external, other]
        // A second surface removing the other disk while this one's resolve is
        // in flight: trashing this one now would empty the list.
        harness.core.afterSharingResolveForTesting = {
            instance.configuration.storageDisks = [external]
        }

        let refusal = await commandError {
            try await harness.core.removeStorageDisk(
                .id(instance.id), disk: external.id, trashFile: true, confirmed: true)
        }

        #expect(refusal?.isOperationFailure == true)
        #expect(harness.fileSystem.trashedURLs.isEmpty)
        #expect(instance.configuration.storageDisks?.map(\.id) == [external.id])
    }

    @Test("A disk detached while sharing resolves is refused, and its file is left alone")
    func removeStorageDiskRefusesADetachDuringTheResolve() async throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness)
        let path = externalPath("external.img")
        let disk = StorageDisk(path: path, label: "External", isInternal: false)
        let other = StorageDisk(path: "AdditionalDisks/x.asif", label: "Extra", isInternal: true)
        instance.configuration.storageDisks = [disk, other]
        // A second surface removing the same row while this one's resolve is in
        // flight: the id this call decided to trash is no longer attached.
        harness.core.afterSharingResolveForTesting = {
            instance.configuration.storageDisks = [other]
        }

        let refusal = await commandError {
            try await harness.core.removeStorageDisk(
                .id(instance.id), disk: disk.id, trashFile: true, confirmed: true)
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
        let destination = FileManager.default.temporaryDirectory
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
            let destination = FileManager.default.temporaryDirectory
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

    @Test("A VM that starts saving during the disk write keeps the file and reports the refusal")
    func createRemovableMediaRefusedWhenTheVMBecomesUnattachable() async throws {
        let diskImages = MockDiskImageService()
        diskImages.holdCreateDiskImage()
        let harness = makeHarness(diskImages: diskImages)
        let sessionID = UUID()
        let instance = makeInstance(in: harness, phase: .running(sessionID: sessionID))
        instance.beginSessionContext()
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).asif")

        let creation = Task { @MainActor in
            await commandError {
                try await harness.core.createRemovableMedia(
                    .id(instance.id), sizeInGB: 16, destinationURL: destination)
            }
        }
        try await diskImages.parked.wait { diskImages.isParked }
        instance.enter(.saving(sessionID: sessionID))
        diskImages.resumeCreateDiskImage()
        let refusal = await creation.value

        #expect(refusal?.isOperationFailure == true)
        #expect(instance.configuration.removableMedia == nil)
        #expect(harness.storage.saveConfigurationCallCount == 0)
        // The file at the user's chosen path is theirs to keep.
        #expect(harness.fileSystem.trashedURLs.isEmpty)
    }

    @Test("A label or note edit leaves the mount identity alone")
    func removableLabelAndNoteKeepMountIdentity() throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness)
        let item = RemovableMediaItem(path: "/tmp/installer.iso", readOnly: true, label: "Original")
        instance.configuration.removableMedia = [item]

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
        let instance = makeInstance(in: harness)
        let item = RemovableMediaItem(path: externalPath("media.iso"), readOnly: true)
        instance.configuration.removableMedia = [item]

        try harness.core.ejectRemovableMedia(.id(instance.id), item: item.id)

        #expect(instance.configuration.removableMedia == nil)
        #expect(harness.fileSystem.trashedURLs.isEmpty)
    }

    @Test("A suspend issued right after an eject lands the detach before the save")
    func suspendAfterEjectLandsTheDetachFirst() async throws {
        let harness = makeHarness()
        let sessionID = UUID()
        let instance = makeInstance(in: harness, phase: .running(sessionID: sessionID))
        instance.beginSessionContext()
        let item = RemovableMediaItem(path: externalPath("media.iso"), readOnly: true)
        instance.configuration.removableMedia = [item]
        instance.recordAttachedMedia(
            USBDeviceInfo(id: item.id, path: item.path, readOnly: true), for: sessionID)

        try harness.core.ejectRemovableMedia(.id(instance.id), item: item.id)
        try await harness.core.suspend(.id(instance.id))

        // A save that ran first would have torn the session down under the
        // queued detach, which would then have been dropped as stale.
        #expect(harness.usbDevices.detachCallCount == 1)
        #expect(instance.configuration.removableMedia == nil)
        #expect(instance.phase == .suspended)
    }

    @Test("A trashing removal of removable media asks for consent, then trashes the file")
    func removeRemovableMediaTrashesAfterConsent() async throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness)
        let path = externalPath("media.iso")
        let item = RemovableMediaItem(path: path, readOnly: true)
        instance.configuration.removableMedia = [item]

        let refusal = await commandError {
            try await harness.core.removeRemovableMedia(
                .id(instance.id), item: item.id, trashFile: true, confirmed: false)
        }
        #expect(refusal?.confirmationPrompt?.kind == .removeAttachment)

        try await harness.core.removeRemovableMedia(
            .id(instance.id), item: item.id, trashFile: true, confirmed: true)

        #expect(instance.configuration.removableMedia == nil)
        #expect(harness.fileSystem.trashedURLs == [URL(fileURLWithPath: path)])
    }

    @Test("The bundled Guest Agent installer is detached but never trashed")
    func removeGuestAgentInstallerKeepsTheFile() async throws {
        let agentPath = try #require(KernovaMacOSAgentInfo.installerDiskImageURL)
            .path(percentEncoded: false)
        let harness = makeHarness()
        let instance = makeInstance(in: harness)
        let item = RemovableMediaItem(
            path: agentPath, readOnly: true, label: KernovaMacOSAgentInfo.diskLabel)
        instance.configuration.removableMedia = [item]

        let refusal = await commandError {
            try await harness.core.removeRemovableMedia(
                .id(instance.id), item: item.id, trashFile: true, confirmed: false)
        }
        #expect(refusal?.confirmationPrompt?.message.contains("isn't deleted") == true)

        try await harness.core.removeRemovableMedia(
            .id(instance.id), item: item.id, trashFile: true, confirmed: true)

        #expect(instance.configuration.removableMedia == nil)
        #expect(harness.fileSystem.trashedURLs.isEmpty)
        #expect(FileManager.default.fileExists(atPath: agentPath))
    }

    // MARK: - State gates

    @Test("A running VM refuses a disk edit and takes a removable one")
    func runningVMSplitsTheTwoLists() async throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, phase: .running(sessionID: UUID()))
        let disk = StorageDisk(path: "AdditionalDisks/x.asif", label: "Extra", isInternal: true)
        let item = RemovableMediaItem(path: "/tmp/installer.iso", readOnly: true, label: "Old")
        instance.configuration.storageDisks = [disk]
        instance.configuration.removableMedia = [item]

        let refusal = await commandError {
            try harness.core.renameStorageDisk(.id(instance.id), disk: disk.id, to: "New")
        }
        guard case .invalidState(_, let current, let allowed) = try #require(refusal) else {
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
        let instance = makeInstance(in: harness)
        let path = externalPath("external.img")
        let disk = StorageDisk(path: path, label: "External", isInternal: false)
        let keeper = StorageDisk(path: "AdditionalDisks/k.asif", label: "Keeper", isInternal: true)
        instance.configuration.storageDisks = [disk, keeper]
        // The removal's sheet leaves the menu key equivalents live, so a Start
        // can land in the suspension the sharing resolve opens — this is that
        // keystroke, landing there deterministically.
        harness.core.afterSharingResolveForTesting = {
            instance.enter(.starting(sessionID: UUID()))
        }

        let refusal = await commandError {
            try await harness.core.removeStorageDisk(
                .id(instance.id), disk: disk.id, trashFile: true, confirmed: true)
        }

        guard case .invalidState = try #require(refusal) else {
            Issue.record("expected an invalid-state refusal")
            return
        }
        // Neither the entry nor the file moved: the disk is still the VM's.
        #expect(instance.configuration.storageDisks?.map(\.id) == [disk.id, keeper.id])
        #expect(harness.fileSystem.trashedURLs.isEmpty)
    }

    @Test("A Start landing while sharing resolves refuses the removable-media removal")
    func removeRemovableMediaRefusesAStartDuringTheResolve() async throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness)
        let path = externalPath("media.iso")
        let item = RemovableMediaItem(path: path, readOnly: true)
        instance.configuration.removableMedia = [item]
        // Removable media is hot-pluggable, so the state that refuses is a VM
        // still coming up: no live session to attach to yet.
        harness.core.afterSharingResolveForTesting = {
            instance.enter(.starting(sessionID: UUID()))
        }

        let refusal = await commandError {
            try await harness.core.removeRemovableMedia(
                .id(instance.id), item: item.id, trashFile: true, confirmed: true)
        }

        guard case .invalidState = try #require(refusal) else {
            Issue.record("expected an invalid-state refusal")
            return
        }
        #expect(instance.configuration.removableMedia?.map(\.id) == [item.id])
        #expect(harness.fileSystem.trashedURLs.isEmpty)
    }

    @Test("A medium ejected while sharing resolves is refused, and its file is left alone")
    func removeRemovableMediaRefusesADetachDuringTheResolve() async throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness)
        let path = externalPath("media.iso")
        let item = RemovableMediaItem(path: path, readOnly: true)
        instance.configuration.removableMedia = [item]
        // An Eject from the row's own menu, landing while this removal's
        // resolve is in flight.
        harness.core.afterSharingResolveForTesting = {
            instance.configuration.removableMedia = nil
        }

        let refusal = await commandError {
            try await harness.core.removeRemovableMedia(
                .id(instance.id), item: item.id, trashFile: true, confirmed: true)
        }

        #expect(refusal?.isOperationFailure == true)
        #expect(harness.fileSystem.trashedURLs.isEmpty)
    }

    @Test("A suspended VM refuses both lists — its saved state pins the device set")
    func suspendedVMRefusesBothLists() async throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, phase: .suspended)
        let item = RemovableMediaItem(path: "/tmp/installer.iso", readOnly: true, label: "Old")
        instance.configuration.removableMedia = [item]

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
    func preparingVMRefusesEveryEdit() async throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness)
        let disk = StorageDisk(path: "AdditionalDisks/x.asif", label: "Extra", isInternal: true)
        instance.configuration.storageDisks = [disk]
        let task = Task {}
        defer { task.cancel() }
        instance.preparingState = VMInstance.PreparingState(operation: .cloning(sourceID: UUID()), task: task)

        let storageRefusal = await commandError {
            try harness.core.setStorageDiskReadOnly(
                .id(instance.id), disk: disk.id, readOnly: true)
        }
        let removableRefusal = await commandError {
            try harness.core.attachRemovableMedia(
                .id(instance.id), paths: [PickedFile(path: "/tmp/x.iso", bookmark: nil)])
        }

        #expect(storageRefusal?.isBusy == true)
        #expect(removableRefusal?.isBusy == true)
        #expect(instance.configuration.storageDisks?[0].readOnly == false)
    }

    @Test("A storage edit on a VM being cloned is refused as busy, naming the clone")
    func cloneInFlightRefusesStorageEditButNotRemovableMedia() async throws {
        let harness = makeHarness()
        let source = makeInstance(in: harness, name: "Source")
        let disk = StorageDisk(path: "AdditionalDisks/x.asif", label: "Extra", isInternal: true)
        source.configuration.storageDisks = [disk]
        let phantom = makeInstance(in: harness, name: "Source Copy")
        let task = Task {}
        defer { task.cancel() }
        phantom.preparingState = VMInstance.PreparingState(
            operation: .cloning(sourceID: source.id), task: task)

        let removeError = try #require(
            await commandError {
                try await harness.core.removeStorageDisk(
                    .id(source.id), disk: disk.id, trashFile: false, confirmed: true)
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
    }

    @Test("An edit naming an attachment that is no longer there is refused, not silently dropped")
    func staleAttachmentIsRefused() async throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness)
        instance.configuration.storageDisks = [
            StorageDisk(path: "AdditionalDisks/x.asif", label: "Extra", isInternal: true)
        ]
        let gone = UUID()

        let renameRefusal = await commandError {
            try harness.core.renameStorageDisk(.id(instance.id), disk: gone, to: "New")
        }
        let notesRefusal = await commandError {
            try harness.core.setRemovableMediaNotes(.id(instance.id), item: gone, notes: "New")
        }
        let removeRefusal = await commandError {
            try await harness.core.removeStorageDisk(
                .id(instance.id), disk: gone, trashFile: false, confirmed: true)
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
            in: harness, phase: .running(sessionID: UUID()), guestOS: .macOS)
        instance.configuration.installedImage = .macOSRestoreImage(
            version: "12.0.1", build: "21A559")

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
            in: harness, phase: .running(sessionID: UUID()), guestOS: .macOS)
        instance.configuration.removableMedia = [
            RemovableMediaItem(path: installerPath, readOnly: true)
        ]

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
            in: harness, phase: .capturingLive(sessionID: sessionID), guestOS: .macOS)
        instance.beginSessionContext()
        instance.configuration.removableMedia = [
            RemovableMediaItem(path: installerPath, readOnly: true)
        ]

        instance.onAgentBecameCurrent?()

        #expect(instance.configuration.removableMedia?.map(\.path) == [installerPath])
        #expect(harness.core.isGuestAgentInstallerMounted(on: instance))
        #expect(harness.usbDevices.detachCallCount == 0)

        instance.enter(.running(sessionID: sessionID))
        try harness.core.unmountGuestAgentDisk(.id(instance.id))
        #expect(instance.configuration.removableMedia == nil)
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
        let instance = makeInstance(in: harness, phase: .failed(message: "Boot failed."))
        let path = externalPath("missing.img")
        let disk = StorageDisk(path: path, label: "Scratch", isInternal: false)
        let keeper = StorageDisk(path: "AdditionalDisks/k.asif", label: "Keeper", isInternal: true)
        instance.configuration.storageDisks = [disk, keeper]

        // `.failed` satisfies `canEditSettings`, so neither new capability
        // blocks the recovery a failed start offered.
        #expect(harness.core.capabilities.accepts(.editStorageDisks, on: instance))
        #expect(harness.core.capabilities.accepts(.editRemovableMedia, on: instance))

        await harness.core.removeStartFailedAttachmentAndStart(
            StartFailedAttachment(
                kind: .storageDisk, id: disk.id, label: "Scratch", message: "could not open"),
            on: instance)

        #expect(instance.configuration.storageDisks?.map(\.id) == [keeper.id])
        // The file the start could not open is left exactly where it is.
        #expect(harness.fileSystem.trashedURLs.isEmpty)
    }

    @Test("A start-failed removal naming an entry that is already gone retries nothing")
    func removeStartFailedAttachmentAlreadyGone() async throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, phase: .failed(message: "Boot failed."))

        await harness.core.removeStartFailedAttachmentAndStart(
            StartFailedAttachment(
                kind: .removableMedia, id: UUID(), label: "Installer", message: "could not open"),
            on: instance)

        #expect(instance.status == .error)
    }
}
