import Foundation
import KernovaAgentCore
import KernovaAgentHost
import KernovaCommandModel
import KernovaTestSupport
import KernovaWire
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport

/// The attachment verbs, driven with no view model and no presenter: every
/// edit's happy path, the state gate each refuses on, the consent a trashing
/// removal asks for, and the files that are never trashed however the removal
/// is asked for.
@Suite("VMCommandCore Attachment Tests", .serialized, .caseScoped)
@MainActor
struct VMCommandCoreAttachmentTests {
    private let preferences = makeTestPreferences()
    private let scratch = TestScratchDirectory(prefix: "VMCommandCoreAttachmentTests")

    private typealias Harness = WiredCommandCore.Scripted<MockVirtualizationService>

    private func makeHarness(
        diskImages: MockDiskImageService = MockDiskImageService(),
        usbAccessoryPassthrough: USBAccessoryPassthrough = .unavailable(.needsEntitlement),
        bundleProducts: AppBundleProducts = .testing
    ) -> Harness {
        Harness(
            WiredCommandCore(
                virtualization: MockVirtualizationService(), diskImages: diskImages,
                usbAccessoryPassthrough: usbAccessoryPassthrough, preferences: preferences,
                bundleProducts: bundleProducts))
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

    @Test("A create that failed before writing leaves the destination untouched")
    func createStorageDiskPreWriteFailureTrashesNothing() async throws {
        let diskImages = MockDiskImageService()
        diskImages.createDiskImageError = DiskImageError.templateMissing(sizeInGB: 32)
        let harness = makeHarness(diskImages: diskImages)
        let instance = makeInstance(in: harness)

        let refusal = try await #require(throws: CommandError.self) {
            try await harness.core.createStorageDisk(.id(instance.id), sizeInGB: 32)
        }

        #expect(refusal.isOperationFailure)
        #expect(harness.fileSystem.trashedURLs.isEmpty)
        #expect(harness.fileSystem.removedURLs.isEmpty)
        #expect(instance.configuration.storageDisks == nil)
    }

    @Test("A configuration edit, a Start or a delete during a disk's image write is refused busy")
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
        let edit = try #require(throws: CommandError.self) {
            try harness.core.setConfiguration(
                .id(instance.id), assignments: [ConfigurationEntry(key: "cpus", value: String(cpus + 1))],
                consent: .all)
        }
        #expect(edit.isBusy)
        let start = try await #require(throws: CommandError.self) {
            try await harness.core.start(.id(instance.id), recovery: false, consent: .none)
        }
        #expect(start.isBusy)
        let delete = try await #require(throws: CommandError.self) {
            try await harness.core.delete(
                .id(instance.id), permanently: false, alsoRemoving: [], consent: .all)
        }
        #expect(delete.isBusy)

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

        let refusal = try await #require(throws: CommandError.self) {
            try await harness.core.removeStorageDisk(
                .id(instance.id), disk: external.id, trashFile: true, consent: .none)
        }
        #expect(refusal.confirmationPrompt?.kind == .removeAttachment)
        #expect(refusal.confirmationPrompt?.confirmTitle == "Move to Trash")
        // Refused, so nothing moved.
        #expect(instance.configuration.storageDisks?.count == 2)

        try await harness.core.removeStorageDisk(
            .id(instance.id), disk: external.id, trashFile: true, consent: .all)

        #expect(instance.configuration.storageDisks?.map(\.id) == [keeper.id])
        #expect(harness.fileSystem.trashedURLs == [URL(fileURLWithPath: path)])
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
        let refusal = try await #require(throws: CommandError.self) {
            try await harness.core.removeStorageDisk(
                .id(target.id), disk: disk.id, trashFile: true, consent: .none)
        }
        #expect(refusal.confirmationPrompt?.confirmTitle == "Remove from VM")
        #expect(refusal.confirmationPrompt?.message.contains("Other") == true)

        try await harness.core.removeStorageDisk(
            .id(target.id), disk: disk.id, trashFile: true, consent: .all)

        #expect(target.configuration.storageDisks?.map(\.id) == [keeper.id])
        #expect(harness.fileSystem.trashedURLs.isEmpty)
    }

    @Test(
        "A missing file answers success, and any other trash failure answers the file that stayed",
        arguments: [true, false])
    func removeStorageDiskTrashFailures(isInternal: Bool) async throws {
        let harness = makeHarness()
        let disk = { (name: String) in
            isInternal
                ? StorageDisk(path: "AdditionalDisks/\(name)", label: name, isInternal: true)
                : StorageDisk(path: self.externalPath(name), label: name, isInternal: false)
        }
        let ghost = disk("ghost.img")
        let locked = disk("locked.img")
        let keeper = StorageDisk(path: "AdditionalDisks/k.asif", label: "Keeper", isInternal: true)
        let instance = makeInstance(in: harness) { $0.storageDisks = [ghost, locked, keeper] }

        harness.fileSystem.setTrashError(CocoaError(.fileNoSuchFile))
        try await harness.core.removeStorageDisk(
            .id(instance.id), disk: ghost.id, trashFile: true, consent: .all)

        harness.fileSystem.setTrashError(CocoaError(.fileWriteNoPermission))
        let failure = try await #require(throws: CommandError.self) {
            try await harness.core.removeStorageDisk(
                .id(instance.id), disk: locked.id, trashFile: true, consent: .all)
        }

        // The entry goes either way; the caller is told which file stayed.
        #expect(instance.configuration.storageDisks?.map(\.id) == [keeper.id])
        let path =
            isInternal
            ? instance.bundleURL.appendingPathComponent(locked.path).path(percentEncoded: false)
            : locked.path
        guard case .filesKept(let kept) = failure else {
            Issue.record("expected the files-kept outcome, got \(failure)")
            return
        }
        #expect(kept.removal == .attachment(label: "locked.img", vm: instance.name))
        #expect(kept.files.map(\.path) == [path])
        #expect(failure.message.contains("\u{201C}\(path)\u{201D}"))
        // Told to the caller alone, never again as an unattended failure.
        #expect(harness.failures.isEmpty)
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

        let refusal = try await #require(throws: CommandError.self) {
            try await harness.core.removeStorageDisk(
                .id(instance.id), disk: external.id, trashFile: true, consent: .all)
        }

        #expect(refusal.isOperationFailure)
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

        let refusal = try await #require(throws: CommandError.self) {
            try await harness.core.removeStorageDisk(
                .id(instance.id), disk: disk.id, trashFile: true, consent: .all)
        }

        #expect(refusal.isOperationFailure)
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

            let refusal = try await #require(throws: CommandError.self) {
                try await harness.core.createRemovableMedia(
                    .id(instance.id), sizeInGB: 16, destinationURL: destination)
            }

            #expect(refusal.isOperationFailure)
            #expect(instance.configuration.removableMedia == nil)
            #expect(harness.fileSystem.trashedURLs.isEmpty != expectsCleanup, "\(error)")
        }
    }

    @Test("A Suspend during a live removable-disk creation is refused; an edit is taken and both land")
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
        let suspend = try await #require(throws: CommandError.self) { try await harness.core.suspend(.id(instance.id)) }
        #expect(suspend.isBusy)
        let other = externalPath("other.iso")
        try harness.core.attachRemovableMedia(
            .id(instance.id), paths: [PickedFile(path: other, bookmark: nil)])
        #expect(instance.configuration.removableMedia?.map(\.path) == [other])
        #expect(harness.removableMedia.attachCallCount == 0)

        diskImages.resumeCreateDiskImage()
        try await creation.value
        // The reconcile the edit owed runs once the creation lets the VM go.
        try await waitForChange { instance.phase == .running(sessionID: sessionID) }

        let path = destination.path(percentEncoded: false)
        #expect(instance.configuration.removableMedia?.map(\.path) == [other, path])
        // Both attached by the creation's own pass, before it let the VM go;
        // the edit's reconcile found nothing left to do.
        #expect(harness.removableMedia.attachCallCount == 2)
        #expect(harness.removableMedia.detachCallCount == 0)
        #expect(Set(instance.liveRemovableMedia.map(\.path)) == [other, path])
        try await harness.core.suspend(.id(instance.id))
        #expect(instance.phase == .suspended)
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
        let refusal = try await #require(throws: CommandError.self) { try await harness.core.suspend(.id(instance.id)) }
        #expect(refusal.isBusy)

        try await waitForChange { instance.phase.operation == nil }
        #expect(harness.removableMedia.detachCallCount == 1)
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

        let refusal = try await #require(throws: CommandError.self) {
            try await harness.core.removeRemovableMedia(
                .id(instance.id), item: item.id, trashFile: true, consent: .none)
        }
        #expect(refusal.confirmationPrompt?.kind == .removeAttachment)

        try await harness.core.removeRemovableMedia(
            .id(instance.id), item: item.id, trashFile: true, consent: .all)

        #expect(instance.configuration.removableMedia == nil)
        #expect(harness.fileSystem.trashedURLs == [URL(fileURLWithPath: path)])
    }

    @Test("A removable medium whose file stays answers that file; a missing one answers success")
    func removeRemovableMediaTrashFailures() async throws {
        let harness = makeHarness()
        let ghost = RemovableMediaItem(path: externalPath("ghost.iso"), readOnly: true)
        let locked = RemovableMediaItem(path: externalPath("locked.iso"), readOnly: true)
        let instance = makeInstance(in: harness) { $0.removableMedia = [ghost, locked] }

        harness.fileSystem.setTrashError(CocoaError(.fileNoSuchFile))
        try await harness.core.removeRemovableMedia(
            .id(instance.id), item: ghost.id, trashFile: true, consent: .all)

        harness.fileSystem.setTrashError(CocoaError(.fileWriteNoPermission))
        let failure = try await #require(throws: CommandError.self) {
            try await harness.core.removeRemovableMedia(
                .id(instance.id), item: locked.id, trashFile: true, consent: .all)
        }

        #expect(instance.configuration.removableMedia == nil)
        guard case .filesKept(let kept) = failure else {
            Issue.record("expected the files-kept outcome, got \(failure)")
            return
        }
        #expect(kept.removal == .attachment(label: locked.label, vm: instance.name))
        #expect(kept.files.map(\.path) == [locked.path])
        #expect(harness.failures.isEmpty)
    }

    @Test("The bundled Guest Agent installer is detached but never trashed")
    func removeGuestAgentInstallerKeepsTheFile() async throws {
        let agentPath = try #require(BundledGuestAgents.testing.macOSInstallerDiskImageURL)
            .path(percentEncoded: false)
        let harness = makeHarness()
        let item = RemovableMediaItem(
            path: agentPath, readOnly: true, label: BundledGuestAgents.macOSDiskLabel)
        let instance = makeInstance(in: harness) { $0.removableMedia = [item] }

        let refusal = try await #require(throws: CommandError.self) {
            try await harness.core.removeRemovableMedia(
                .id(instance.id), item: item.id, trashFile: true, consent: .none)
        }
        #expect(refusal.confirmationPrompt?.message.contains("isn't deleted") == true)

        try await harness.core.removeRemovableMedia(
            .id(instance.id), item: item.id, trashFile: true, consent: .all)

        #expect(instance.configuration.removableMedia == nil)
        #expect(harness.fileSystem.trashedURLs.isEmpty)
    }

    // MARK: - Shared directories

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

    @Test("A share the VM no longer carries refuses both edits")
    func sharedDirectoryEditsRefuseAStaleID() async throws {
        let harness = makeHarness()
        let instance = makeInstance(in: harness) {
            $0.sharedDirectories = [SharedDirectory(path: externalPath("kept"))]
        }
        let gone = UUID()

        for refusal in [
            try #require(throws: CommandError.self) {
                try harness.core.removeSharedDirectory(.id(instance.id), directory: gone)
            },
            try #require(throws: CommandError.self) {
                try harness.core.setSharedDirectoryReadOnly(
                    .id(instance.id), directory: gone, readOnly: true)
            },
        ] {
            guard case .operationFailed(let verb, _, _, _) = refusal else {
                Issue.record("expected an operation failure, got \(refusal)")
                continue
            }
            #expect(verb == .editSharedDirectory)
        }
        #expect(instance.configuration.sharedDirectories?.count == 1)
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
    ) throws -> VMInstance {
        let instance = makeInstance(
            in: harness, name: name, phase: .running(sessionID: UUID()), guestOS: .macOS
        ) { $0.sharedDirectories = directories.isEmpty ? nil : directories }
        let context = instance.beginSessionContextForTesting()
        if !directories.isEmpty {
            context.directoryShare =
                try serving ?? MacOSDirectoryShare.make(for: directories)
        }
        return instance
    }

    @Test("A live swap holds what it adds, releases what it drops, and leaves a kept share alone")
    func liveShareSwapHoldsAddedAndReleasesRemoved() throws {
        let harness = makeHarness()
        let kept = SharedDirectory(path: try folder("kept"))
        let going = SharedDirectory(path: try folder("going"))
        let instance = try makeRunningMacOSGuest(in: harness, sharing: [kept, going])
        let device = try #require(LiveShareDevice(of: instance))
        let added = SharedDirectory(path: try folder("added"))
        let next = try MacOSDirectoryShare.make(
            for: [kept, added], serving: device.serving)

        let swap = device.swap(to: next)

        #expect(swap.sessionID == instance.liveSessionID)
        #expect(swap.share == next)
        #expect(swap.held == [added.id])
        #expect(swap.released == [going.id])
    }

    @Test("Removing one of two shares from a running macOS guest swaps live and lets the removed one go")
    func runningMacOSGuestRemovesAShareLive() throws {
        let harness = makeHarness()
        let kept = SharedDirectory(path: try folder("kept"))
        let going = SharedDirectory(path: try folder("going"))
        let instance = try makeRunningMacOSGuest(in: harness, sharing: [kept, going])

        try harness.core.removeSharedDirectory(.id(instance.id), directory: going.id)
        try harness.core.setSharedDirectoryReadOnly(
            .id(instance.id), directory: kept.id, readOnly: true)

        #expect(instance.configuration.sharedDirectories?.map(\.id) == [kept.id])
        #expect(instance.configuration.sharedDirectories?.first?.readOnly == true)
        #expect(instance.sessionContext?.directoryShare?.entries.map(\.id) == [kept.id])
        #expect(instance.sessionContext?.directoryShare?.entries.map(\.readOnly) == [true])
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
        let instance = try makeRunningMacOSGuest(in: harness, sharing: [first])
        let secondPath = try folder("b") + "/src"
        try FileManager.default.createDirectory(
            atPath: secondPath, withIntermediateDirectories: true)

        try harness.core.addSharedDirectories(
            .id(instance.id), paths: [PickedFile(path: secondPath, bookmark: nil)])
        let second = try #require(instance.configuration.sharedDirectories?.last)
        #expect(second.mountName == "\(second.id.uuidString.prefix(8))-src")
        #expect(
            instance.sessionContext?.directoryShare?.entries.map(\.name) == ["src", second.mountName])

        try harness.core.removeSharedDirectory(.id(instance.id), directory: first.id)

        #expect(instance.sessionContext?.directoryShare?.entries.map(\.name) == [second.mountName])
        let rebuilt = try MacOSDirectoryShare.make(
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
            let instance = try makeRunningMacOSGuest(
                in: harness, name: "Moved \(storedPathExists)", sharing: [moved], serving: serving)

            try harness.core.addSharedDirectories(
                .id(instance.id), paths: [PickedFile(path: try folder("added"), bookmark: nil)])

            let first = try #require(instance.sessionContext?.directoryShare?.entries.first)
            #expect(first == serving.entries[0], "stored path exists: \(storedPathExists)")
        }
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
            try #require(throws: CommandError.self) {
                try harness.core.addSharedDirectories(
                    .id(empty.id), paths: [PickedFile(path: try folder("first"), bookmark: nil)])
            },
            try #require(throws: CommandError.self) {
                try harness.core.removeSharedDirectory(.id(single.id), directory: only.id)
            },
        ] {
            guard case .changeTakesStoppedVM(_, let current, let change) = refusal
            else {
                Issue.record("expected the stopped-VM rule, got \(refusal)")
                continue
            }
            #expect(current == .running)
            #expect(change == .firstOrLastSharedDirectory)
        }
        let message = try #require(throws: CommandError.self) {
            try harness.core.removeSharedDirectory(.id(single.id), directory: only.id)
        }.message
        #expect(
            message
                == "\u{201C}Single\u{201D} is running. Adding the first share or removing the last needs the virtual machine stopped."
        )
        #expect(empty.configuration.sharedDirectories == nil)
        #expect(single.configuration.sharedDirectories == [only])
    }

    // MARK: - State gates

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

        let refusal = try await #require(throws: CommandError.self) {
            try await harness.core.removeRemovableMedia(
                .id(instance.id), item: item.id, trashFile: true, consent: .all)
        }

        #expect(refusal.isOperationFailure)
        #expect(harness.fileSystem.trashedURLs.isEmpty)
    }

    // MARK: - Guest agent disk

    @Test("A Linux guest gets the agent's disk, made once and labelled as the guest shows it")
    func mountLinuxAgentDisk() async throws {
        try FileManager.default.createDirectory(at: scratch.url, withIntermediateDirectories: true)
        let agent = scratch.url.appending(path: "kernova-agent")
        try Data(repeating: 0x7F, count: 5000).write(to: agent)
        let cache = GuestAgentDiskCache(
            directory: scratch.url.appending(path: "GuestAgentDisks"), files: LinuxAgentDisk.bundledFiles)
        let harness = makeHarness(
            bundleProducts: AppBundleProducts(
                bundleURL: AppBundleProducts.testing.bundleURL, hostVersion: "1.0", buildNumber: "1",
                guestAgents: .linux(agent: agent, disk: cache)))
        let instance = makeInstance(in: harness, phase: .running(sessionID: UUID()))
        instance.beginSessionContextForTesting()
        instance.attachAgentTransport(AgentHubProbe())

        #expect(try await harness.core.mountGuestAgentDisk(.id(instance.id), awaiting: nil) == .attached(.usb))
        let item = try #require(instance.configuration.removableMedia?.first)
        #expect(instance.configuration.removableMedia?.count == 1)
        #expect(item.path == cache.url.path(percentEncoded: false))
        #expect(item.label == "KERNOVA_AGENT")
        #expect(item.readOnly)
        #expect(instance.hasGuestAgentInstallerMounted)
        let image = try Data(contentsOf: cache.url)
        #expect(image.count % 2048 == 0)
        #expect(String(decoding: image[16 * 2048 + 40..<16 * 2048 + 53], as: UTF8.self) == "KERNOVA_AGENT")

        // The guest gets the VM's own copy of the disk, with the disk's bytes.
        let copy = instance.bundleLayout.guestAgentDiskCopyURL(for: item)
        #expect(try Data(contentsOf: copy) == image)
        try await waitForChange { !instance.liveRemovableMedia.isEmpty }
        #expect(harness.removableMedia.lastAttachedPath == copy.path(percentEncoded: false))
        // An update rewriting the app's disk leaves the VM's copy as it was.
        try Data("a later build's disk".utf8).write(to: cache.url)
        #expect(try Data(contentsOf: copy) == image)

        #expect(try await harness.core.mountGuestAgentDisk(.id(instance.id), awaiting: nil) == .alreadyPresent(.usb))
        // The disk is the app's, so a VM's delete never offers to trash it.
        #expect(await harness.core.externalAttachments(for: instance).isEmpty)

        // An eject takes the entry and the copy.
        instance.onCurrentAgentsArrived?([.login, .system])
        #expect(instance.configuration.removableMedia == nil)
        #expect(!FileManager.default.fileExists(atPath: copy.path(percentEncoded: false)))
    }

    /// A running macOS VM holding an installer entry another build of Kernova
    /// attached: it names that build's DMG, and the bundle holds its copy.
    private func otherBuildsInstaller(in harness: Harness) throws -> (VMInstance, RemovableMediaItem, URL) {
        let item = RemovableMediaItem(
            path: "/Applications/Other Kernova.app/Contents/Resources/KernovaMacOSAgent.dmg", readOnly: true,
            label: "Kernova Guest Agent")
        let instance = makeInstance(in: harness, phase: .running(sessionID: UUID()), guestOS: .macOS) {
            $0.removableMedia = [item]
        }
        instance.beginSessionContextForTesting().hasAgentTransport = true
        let copy = instance.bundleLayout.guestAgentDiskCopyURL(for: item)
        try FileManager.default.createDirectory(
            at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("the other build's disk".utf8).write(to: copy)
        return (instance, item, copy)
    }

    @Test("An entry whose copy the bundle holds is the installer, whichever build attached it")
    func anotherBuildsInstallerIsStillTheInstaller() async throws {
        let harness = makeHarness()
        let (instance, item, _) = try otherBuildsInstaller(in: harness)

        #expect(instance.isGuestAgentInstaller(item))
        #expect(instance.hasGuestAgentInstallerMounted)
        // The other build's DMG is the app's, never offered to the trash.
        #expect(await harness.core.externalAttachments(for: instance).isEmpty)
        #expect(try await harness.core.mountGuestAgentDisk(.id(instance.id), awaiting: nil) == .alreadyPresent(.usb))
    }

    @Test("Unmounting drops the installer entry, and an agent handshake does it unasked")
    func unmountGuestAgentDisk() async throws {
        let installerPath = try #require(BundledGuestAgents.testing.macOSInstallerDiskImageURL)
            .path(percentEncoded: false)
        let harness = makeHarness()
        let instance = makeInstance(
            in: harness, phase: .running(sessionID: UUID()), guestOS: .macOS
        ) {
            $0.removableMedia = [RemovableMediaItem(path: installerPath, readOnly: true)]
        }
        instance.beginSessionContextForTesting().hasAgentTransport = true

        try harness.core.unmountGuestAgentDisk(.id(instance.id))
        #expect(instance.configuration.removableMedia == nil)

        // The eject the core wires onto the library fires the same detach
        // when the agent it waits for connects current.
        try await harness.core.mountGuestAgentDisk(.id(instance.id), awaiting: nil)
        instance.onCurrentAgentsArrived?([.login])
        #expect(instance.configuration.removableMedia == nil)
    }

    // MARK: - What the installer disk waits for

    /// A harness bundling a Linux agent, and a running Linux VM in it whose
    /// session reaches the agent hub.
    private func linuxAgentVM() throws -> (Harness, VMInstance) {
        try FileManager.default.createDirectory(at: scratch.url, withIntermediateDirectories: true)
        let agent = scratch.url.appending(path: "kernova-agent")
        try Data(repeating: 0x7F, count: 64).write(to: agent)
        let cache = GuestAgentDiskCache(
            directory: scratch.url.appending(path: "GuestAgentDisks"), files: LinuxAgentDisk.bundledFiles)
        let harness = makeHarness(
            bundleProducts: AppBundleProducts(
                bundleURL: AppBundleProducts.testing.bundleURL, hostVersion: "1.0", buildNumber: "1",
                guestAgents: .linux(agent: agent, disk: cache)))
        let instance = makeInstance(in: harness, phase: .running(sessionID: UUID()))
        instance.beginSessionContextForTesting()
        instance.attachAgentTransport(AgentHubProbe())
        return (harness, instance)
    }

    @Test("A mount that names no scopes waits for what an install of the guest OS's agent connects")
    func mountDefaultsToTheGuestsScopes() async throws {
        let (linuxHarness, linux) = try linuxAgentVM()
        try await linuxHarness.core.mountGuestAgentDisk(.id(linux.id), awaiting: nil)
        #expect(linux.guestAgentInstallerAwaits == [.login, .system])

        let harness = makeHarness()
        let macOS = makeInstance(in: harness, phase: .running(sessionID: UUID()), guestOS: .macOS)
        macOS.beginSessionContextForTesting().hasAgentTransport = true
        try await harness.core.mountGuestAgentDisk(.id(macOS.id), awaiting: nil)
        #expect(macOS.guestAgentInstallerAwaits == [.login])
        // A macOS install for everyone also brings a system service, which a mount may wait for.
        try await harness.core.mountGuestAgentDisk(.id(macOS.id), awaiting: [.login, .system])
        #expect(macOS.guestAgentInstallerAwaits == [.login, .system])
    }

    @Test("A VM with no live session to look inside refuses the guest agent disk, as does a build without it")
    func guestAgentDiskNeedsALiveSession() async throws {
        let harness = makeHarness()
        let stopped = makeInstance(in: harness, name: "Stopped", guestOS: .macOS)
        let stoppedLinux = makeInstance(in: harness, name: "Stopped Linux")
        // `.testing` bundles no Linux agent.
        let unbundled = makeInstance(in: harness, name: "Linux", phase: .running(sessionID: UUID()))

        for instance in [stopped, stoppedLinux, unbundled] {
            await #expect(throws: CommandError.self) {
                _ = try await harness.core.mountGuestAgentDisk(.id(instance.id), awaiting: nil)
            }
            #expect(instance.configuration.removableMedia == nil)
        }
    }

    // MARK: - Start-failure recovery

    @Test("A failed VM takes the start-failed removal both gates admit")
    func removeStartFailedAttachmentOnAFailedVM() async throws {
        let harness = makeHarness()
        let path = externalPath("missing.img")
        let disk = StorageDisk(path: path, label: "Scratch", isInternal: false)
        let keeper = StorageDisk(path: "AdditionalDisks/k.asif", label: "Keeper", isInternal: true)
        let instance = makeInstance(
            in: harness, phase: .failed(message: "Boot failed."), guestOS: .macOS
        ) {
            $0.storageDisks = [disk, keeper]
            $0.pendingGuestAccount = GuestAccountIntent(
                fullName: "Ada Lovelace", username: "ada", logsInAutomatically: false,
                enablesRemoteLogin: false)
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
        // Untouched, so the start that follows raises the question itself.
        #expect(instance.configuration.pendingGuestAccount != nil)
    }

    /// The removal lands before the discard, so a discard the file system
    /// turns down leaves the entry gone and the save file on disk.
    @Test("A discard that fails after a storage disk's removal names the way out")
    func aFailedDiscardAfterTheRemovalNamesTheWayOut() async throws {
        let harness = makeHarness()
        let disk = StorageDisk(path: externalPath("missing.img"), label: "Scratch", isInternal: false)
        let keeper = StorageDisk(path: "AdditionalDisks/k.asif", label: "Keeper", isInternal: true)
        let instance = makeInstance(in: harness, phase: .suspended) {
            $0.storageDisks = [disk, keeper]
        }
        try VMInstanceFixture.writeSaveFile(for: instance)
        // A bundle directory the save file cannot be removed from.
        let bundlePath = instance.bundleURL.path(percentEncoded: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: bundlePath)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: bundlePath)
        }

        let error = try await #require(throws: CommandError.self) {
            try await harness.core.removeStartFailedAttachment(
                .id(instance.id),
                attachment: StartFailedAttachment(
                    verb: .resume, kind: .storageDisk, reason: .attachRefused, id: disk.id,
                    label: "Scratch", message: "could not open"))
        }

        let message = error.message
        #expect(instance.hasSaveFile)
        #expect(instance.configuration.storageDisks?.map(\.id) == [keeper.id])
        #expect(
            message.hasSuffix(
                "but its saved state could not be deleted. That state can no longer be restored — discard it to start the virtual machine."
            ))
    }

    @Test("A resume-failed removal of removable media keeps the saved state for the restore")
    func removeStartFailedRemovableMediaKeepsTheSavedState() async throws {
        let harness = makeHarness()
        let missing = RemovableMediaItem(path: externalPath("gone.dmg"), readOnly: true)
        let keeper = RemovableMediaItem(path: externalPath("keep.iso"), readOnly: true)
        let instance = makeInstance(in: harness, phase: .suspended) {
            $0.removableMedia = [missing, keeper]
        }
        try VMInstanceFixture.writeSaveFile(for: instance)

        try await harness.core.removeStartFailedAttachment(
            .id(instance.id),
            attachment: StartFailedAttachment(
                verb: .resume, kind: .removableMedia, reason: .notFound, id: missing.id,
                label: missing.label, message: "not found"))

        #expect(instance.configuration.removableMedia?.map(\.id) == [keeper.id])
        #expect(instance.hasSaveFile)
        #expect(instance.isSuspended)
        #expect(harness.virtualization.startCallCount == 0)
    }

    @Test("A resume-failed removal of a shared folder discards the saved state")
    func removeStartFailedSharedFolderDiscardsTheSavedState() async throws {
        let harness = makeHarness()
        let missing = SharedDirectory(path: externalPath("Gone"))
        let keeper = SharedDirectory(path: externalPath("Kept"))
        let instance = makeInstance(in: harness, phase: .suspended) {
            $0.sharedDirectories = [missing, keeper]
        }
        try VMInstanceFixture.writeSaveFile(for: instance)
        #expect(!harness.core.capabilities.accepts(.editSharedDirectories, on: instance))

        try await harness.core.removeStartFailedAttachment(
            .id(instance.id),
            attachment: StartFailedAttachment(
                verb: .resume, kind: .sharedDirectory, reason: .notWritable, id: missing.id,
                label: missing.displayName, message: "not writable"))

        #expect(!instance.hasSaveFile)
        #expect(instance.phase == .stopped)
        #expect(instance.configuration.sharedDirectories?.map(\.id) == [keeper.id])
        #expect(harness.virtualization.startCallCount == 0)
    }

    @Test("A start-failed removal naming a shared folder that is already gone keeps the saved state")
    func removeStartFailedSharedFolderAlreadyGone() async throws {
        let harness = makeHarness()
        let keeper = SharedDirectory(path: externalPath("Kept"))
        let instance = makeInstance(in: harness, phase: .suspended) {
            $0.sharedDirectories = [keeper]
        }
        try VMInstanceFixture.writeSaveFile(for: instance)

        try await harness.core.removeStartFailedAttachment(
            .id(instance.id),
            attachment: StartFailedAttachment(
                verb: .resume, kind: .sharedDirectory, reason: .notFound, id: UUID(),
                label: "Gone", message: "not found"))

        #expect(instance.configuration.sharedDirectories?.map(\.id) == [keeper.id])
        #expect(instance.hasSaveFile)
        #expect(instance.isSuspended)
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
        harness.storage.setSaveConfigurationError(VMStorageError.bundleNotFound(instance.bundleURL))

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
