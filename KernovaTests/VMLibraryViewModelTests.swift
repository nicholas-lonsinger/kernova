import CryptoKit
import Testing
import Foundation
import Virtualization
@testable import Kernova

@Suite("VMLibraryViewModel Tests", .serialized, .admissionGated)
@MainActor
struct VMLibraryViewModelTests {
    private let presenter = MockVMLibraryPresenting()
    /// Isolated, pre-cleaned preferences so selection/order persistence never
    /// touches the real `.standard` domain.
    ///
    /// Fresh per test (the struct is re-instantiated), so each test starts from
    /// an empty suite.
    private let preferences = makeEphemeralPreferences(suiteName: "test.kernova.vmlibrary")
    /// Fresh per test (the struct is re-instantiated).
    ///
    /// Records trash/remove requests so delete flows are asserted on the
    /// recorded URLs instead of real fixture files — nothing ever lands in
    /// the user's Trash.
    private let fileSystem = MockFileSystem()
    private func makeViewModel(
        storageService: MockVMStorageService = MockVMStorageService(),
        diskImageService: MockDiskImageService = MockDiskImageService(),
        virtualizationService: MockVirtualizationService = MockVirtualizationService(),
        usbDeviceService: any USBDeviceProviding = MockUSBDeviceService(),
        linuxImageResolveService: MockLinuxImageResolveService = MockLinuxImageResolveService(),
        downloadService: MockDownloadService = MockDownloadService(),
        downloadsDirectory: URL? = FileManager.default.urls(
            for: .downloadsDirectory, in: .userDomainMask
        ).first,
        vmnetNetworks: MockVmnetNetworkProvider = MockVmnetNetworkProvider(),
        isVMNetworkingEntitled: Bool = true
    ) -> (
        VMLibraryViewModel, MockVMStorageService, MockDiskImageService, MockVirtualizationService,
        any USBDeviceProviding
    ) {
        let vm = VMLibraryViewModel(
            storageService: storageService,
            diskImageService: diskImageService,
            virtualizationService: virtualizationService,
            installService: MockMacOSInstallService(),
            ipswService: MockIPSWService(),
            usbDeviceService: usbDeviceService,
            linuxImageResolveService: linuxImageResolveService,
            downloadService: downloadService,
            fileSystem: fileSystem,
            downloadsDirectory: downloadsDirectory,
            preferences: preferences,
            vmnetNetworks: vmnetNetworks,
            isVMNetworkingEntitled: isVMNetworkingEntitled
        )
        vm.presenter = presenter
        return (vm, storageService, diskImageService, virtualizationService, usbDeviceService)
    }

    /// A view model whose virtualization service holds one lifecycle call
    /// suspended, standing in for the window where a VZ call is still in flight.
    private func makeSuspendingViewModel(
        storage: MockVMStorageService = MockVMStorageService()
    ) -> (VMLibraryViewModel, SuspendingMockVirtualizationService) {
        let suspending = SuspendingMockVirtualizationService()
        let vm = VMLibraryViewModel(
            storageService: storage,
            diskImageService: MockDiskImageService(),
            virtualizationService: suspending,
            installService: MockMacOSInstallService(),
            ipswService: MockIPSWService(),
            usbDeviceService: MockUSBDeviceService(),
            fileSystem: fileSystem,
            preferences: preferences
        )
        vm.presenter = presenter
        return (vm, suspending)
    }

    private func makeInstance(name: String = "Test VM", guestOS: VMGuestOS = .linux) -> VMInstance {
        let config = VMConfiguration(
            name: name,
            guestOS: guestOS,
            bootMode: guestOS == .macOS ? .macOS : .efi
        )
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(config.id.uuidString, isDirectory: true)
        return VMInstance(configuration: config, bundleURL: bundleURL)
    }

    // MARK: - Initial State

    @Test("ViewModel starts with empty instances when storage is empty")
    func initialStateEmpty() async {
        let (viewModel, _, _, _, _) = makeViewModel()
        await viewModel.loadVMs()
        #expect(viewModel.instances.isEmpty)
        #expect(viewModel.selectedID == nil)
        #expect(presenter.showCreationWizard == false)
        #expect(presenter.showError == false)
    }

    // MARK: - Delete

    @Test("requestDelete always presents the unified delete sheet")
    func requestDelete() {
        let (viewModel, _, _, _, _) = makeViewModel()
        let instance = makeInstance()
        viewModel.instances.append(instance)

        viewModel.requestDelete(instance)

        // Even a VM with no external files routes to the sheet now (it still
        // has its in-bundle main disk to show).
        #expect(presenter.instanceToDelete?.id == instance.id)
        #expect(presenter.showDeleteSheet == true)
    }

    @Test("deleteVM removes instance and clears selection")
    func deleteVM() async {
        let (viewModel, storage, _, _, _) = makeViewModel()
        let instance = makeInstance()
        viewModel.instances.append(instance)
        viewModel.selectedID = instance.id

        // Pre-populate mock storage so delete doesn't throw
        storage.bundles[instance.bundleURL] = instance.configuration

        await viewModel.delete(instance)

        #expect(viewModel.instances.isEmpty)
        #expect(viewModel.selectedID == nil)
        #expect(presenter.instanceToDelete == nil)
        #expect(storage.deleteVMBundleCallCount == 1)
    }

    @Test("deleteVM selects first remaining instance when deleting selected")
    func deleteVMUpdatesSelection() async {
        let (viewModel, storage, _, _, _) = makeViewModel()
        let first = makeInstance(name: "First")
        let second = makeInstance(name: "Second")
        viewModel.instances = [first, second]
        viewModel.selectedID = second.id

        storage.bundles[second.bundleURL] = second.configuration

        await viewModel.delete(second)

        #expect(viewModel.instances.count == 1)
        #expect(viewModel.selectedID == first.id)
    }

    @Test("requestDelete forwards the immediate flag to the delete sheet")
    func requestDeleteForwardsPermanentlyFlag() {
        let (viewModel, _, _, _, _) = makeViewModel()
        let instance = makeInstance()
        viewModel.instances.append(instance)

        viewModel.requestDelete(instance)
        #expect(presenter.lastDeleteSheetPermanently == false)

        viewModel.requestDelete(instance, permanently: true)
        #expect(presenter.lastDeleteSheetPermanently == true)
    }

    @Test("deleteVM removes a cold-paused VM without a discard-saved-state pass")
    func deleteVMColdPaused() async {
        let (viewModel, storage, _, _, _) = makeViewModel()
        let instance = makeInstance()
        instance.enter(.suspended)  // no live VM ⇒ cold-paused ("Suspended")
        viewModel.instances.append(instance)
        viewModel.selectedID = instance.id
        storage.bundles[instance.bundleURL] = instance.configuration

        #expect(instance.isColdPaused)
        #expect(instance.canDelete)
        await viewModel.delete(instance)

        // The whole bundle goes, saved state included — no separate discard.
        #expect(viewModel.instances.isEmpty)
        #expect(viewModel.selectedID == nil)
        #expect(storage.deleteVMBundleCallCount == 1)
    }

    @Test("deleteVM refuses a VM that stopped being deletable while the sheet was open")
    func deleteVMRefusesWhenNoLongerDeletable() async {
        let (viewModel, storage, _, _, _) = makeViewModel()
        let instance = makeInstance()
        instance.enter(.suspended)  // Suspended when the sheet opened…
        viewModel.instances.append(instance)
        storage.bundles[instance.bundleURL] = instance.configuration

        // …but a Resume landed via its still-live menu key equivalent before the
        // user clicked Move to Trash.
        instance.enter(.running(sessionID: UUID()))

        await viewModel.delete(instance)

        #expect(viewModel.instances.count == 1)
        #expect(storage.deleteVMBundleCallCount == 0)
    }

    @Test("deleteVM refuses a cold-paused VM whose resume is still in flight")
    func deleteVMRefusesDuringInFlightResume() async throws {
        let storage = MockVMStorageService()
        let (viewModel, suspending) = makeSuspendingViewModel(storage: storage)
        suspending.shouldSuspendOnResume = true
        let instance = makeInstance()
        instance.enter(.suspended)
        viewModel.instances.append(instance)
        storage.bundles[instance.bundleURL] = instance.configuration

        let resume = Task { @MainActor in try await viewModel.lifecycle.resume(instance) }
        await suspending.waitUntilSuspended()

        // A real cold resume holds `.paused` with no live VM while it builds its
        // configuration, so the enablement predicate still reads deletable — only
        // the lifecycle lock can refuse here.
        #expect(instance.isColdPaused)
        #expect(instance.canDelete)

        await viewModel.delete(instance)

        #expect(viewModel.instances.count == 1)
        #expect(storage.deleteVMBundleCallCount == 0)

        suspending.resumeSuspended()
        try await resume.value
    }

    @Test("deleteVM permanently hard-deletes the bundle, bypassing the Trash")
    func deleteVMPermanentlyUsesHardDelete() async {
        let (viewModel, storage, _, _, _) = makeViewModel()
        let instance = makeInstance()
        viewModel.instances.append(instance)
        viewModel.selectedID = instance.id
        storage.bundles[instance.bundleURL] = instance.configuration

        await viewModel.delete(instance, permanently: true)

        #expect(viewModel.instances.isEmpty)
        #expect(viewModel.selectedID == nil)
        // Hard-delete path is taken; the Trash path is not.
        #expect(storage.permanentlyDeleteVMBundleCallCount == 1)
        #expect(storage.deleteVMBundleCallCount == 0)
    }

    @Test("deleteVM permanently deletes the selected external files")
    func deleteVMPermanentlyDeletesExternals() async throws {
        let (viewModel, storage, _, _, _) = makeViewModel()
        let instance = makeInstance()
        let externalDisk = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-external.img")

        let diskID = UUID()
        instance.configuration.storageDisks = [
            StorageDisk(
                id: diskID, path: externalDisk.path(percentEncoded: false),
                readOnly: false, label: "External", isInternal: false, kind: .virtio
            )
        ]
        viewModel.instances.append(instance)
        storage.bundles[instance.bundleURL] = instance.configuration

        await viewModel.delete(instance, deletingExternalIDs: [diskID], permanently: true)

        #expect(viewModel.instances.isEmpty)
        // Hard delete, not trash — mirrors the VM bundle's own disposition.
        #expect(fileSystem.removedURLs == [externalDisk])
        #expect(fileSystem.trashedURLs.isEmpty)
        #expect(!presenter.showError)
    }

    @Test("deleteVM permanently never deletes a shared external even if selected")
    func deleteVMPermanentlyNeverDeletesSharedExternal() async throws {
        let (viewModel, storage, _, _, _) = makeViewModel()
        let sharedDisk = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-shared.img")

        let sharedID = UUID()
        let sharedPath = sharedDisk.path(percentEncoded: false)
        let target = makeInstance(name: "Target")
        target.configuration.storageDisks = [
            StorageDisk(
                id: sharedID, path: sharedPath,
                readOnly: false, label: "Shared", isInternal: false, kind: .virtio
            )
        ]
        let other = makeInstance(name: "Other")
        other.configuration.storageDisks = [
            StorageDisk(
                path: sharedPath, readOnly: false, label: "Shared",
                isInternal: false, kind: .virtio
            )
        ]
        viewModel.instances = [target, other]
        storage.bundles[target.bundleURL] = target.configuration

        await viewModel.delete(target, deletingExternalIDs: [sharedID], permanently: true)

        // The shared-file hard-block holds in the immediate path too.
        #expect(fileSystem.removedURLs.isEmpty)
        #expect(fileSystem.trashedURLs.isEmpty)
        #expect(!presenter.showError)
    }

    @Test("requestDelete routes to sheet when the VM references external attachments")
    func requestDeleteRoutesToSheetWithExternals() {
        let (viewModel, _, _, _, _) = makeViewModel()
        let instance = makeInstance()
        instance.configuration.removableMedia = [
            RemovableMediaItem(path: "/tmp/installer.iso", readOnly: true)
        ]
        viewModel.instances.append(instance)

        viewModel.requestDelete(instance)

        #expect(presenter.instanceToDelete?.id == instance.id)
        #expect(presenter.showDeleteSheet == true)
    }

    @Test("externalAttachments returns external disks and removable media with sharing info")
    func externalAttachmentsLists() {
        let (viewModel, _, _, _, _) = makeViewModel()
        let sharedISO = "/tmp/shared-installer.iso"
        let target = makeInstance(name: "Target")
        target.configuration.storageDisks = [
            StorageDisk(
                path: "Disk.asif", readOnly: false, label: "Main",
                isInternal: true, kind: .virtio
            ),
            StorageDisk(
                path: "/Volumes/External/data.img", readOnly: false, label: "Scratch",
                isInternal: false, kind: .virtio
            ),
        ]
        target.configuration.removableMedia = [
            RemovableMediaItem(path: sharedISO, readOnly: true, label: "Shared ISO")
        ]

        let sharer = makeInstance(name: "Sharer")
        sharer.configuration.removableMedia = [
            RemovableMediaItem(path: sharedISO, readOnly: true, label: "Shared ISO")
        ]
        let unrelated = makeInstance(name: "Unrelated")
        viewModel.instances = [target, sharer, unrelated]

        let attachments = viewModel.externalAttachments(for: target)

        // Internal disks are excluded; the two externals appear in
        // disks-then-media order.
        #expect(attachments.count == 2)
        #expect(attachments[0].kind == .storageDisk)
        #expect(attachments[0].path == "/Volumes/External/data.img")
        #expect(attachments[0].isShared == false)
        #expect(attachments[1].kind == .removableMedia)
        #expect(attachments[1].path == sharedISO)
        #expect(attachments[1].sharedWithVMNames == ["Sharer"])
    }

    @Test("externalAttachmentsResolvingExistence flags isMissing per backing-file existence")
    func externalAttachmentsResolvingExistenceFlagsMissing() async throws {
        let (viewModel, _, _, _, _) = makeViewModel()
        let presentDisk = FileManager.default.temporaryDirectory
            .appendingPathComponent("present-\(UUID().uuidString).img")
        try Data("disk".utf8).write(to: presentDisk)
        defer { try? FileManager.default.removeItem(at: presentDisk) }
        let missingPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString).iso").path

        let instance = makeInstance(name: "Target")
        instance.configuration.storageDisks = [
            StorageDisk(
                path: presentDisk.path, readOnly: false, label: "Present",
                isInternal: false, kind: .virtio
            )
        ]
        instance.configuration.removableMedia = [
            RemovableMediaItem(path: missingPath, readOnly: true, label: "Missing ISO")
        ]
        viewModel.instances = [instance]

        // The synchronous enumeration never touches the filesystem.
        #expect(viewModel.externalAttachments(for: instance).allSatisfy { !$0.isMissing })

        let attachments = await viewModel.externalAttachmentsResolvingExistence(for: instance)
        #expect(attachments.count == 2)
        #expect(attachments[0].path == presentDisk.path)
        #expect(attachments[0].isMissing == false)
        #expect(attachments[1].path == missingPath)
        #expect(attachments[1].isMissing == true)
    }

    @Test("externalAttachments is empty when the VM only has internal disks")
    func externalAttachmentsEmptyForInternalOnly() {
        let (viewModel, _, _, _, _) = makeViewModel()
        let instance = makeInstance()
        instance.configuration.storageDisks = [
            StorageDisk(
                path: "Disk.asif", readOnly: false, label: "Main",
                isInternal: true, kind: .virtio
            )
        ]
        viewModel.instances.append(instance)

        #expect(viewModel.externalAttachments(for: instance).isEmpty)
    }

    @Test("externalAttachments excludes the bundled Guest Agent DMG")
    func externalAttachmentsExcludesGuestAgentDMG() throws {
        let (viewModel, _, _, _, _) = makeViewModel()
        let agentPath = try #require(KernovaMacOSAgentInfo.installerDiskImageURL)
            .path(percentEncoded: false)
        let instance = makeInstance()
        instance.configuration.removableMedia = [
            RemovableMediaItem(path: agentPath, readOnly: true, label: "Kernova Guest Agent"),
            RemovableMediaItem(path: "/Volumes/External/installer.iso", readOnly: true, label: "Installer"),
        ]
        viewModel.instances.append(instance)

        let attachments = viewModel.externalAttachments(for: instance)

        // The app-owned DMG is filtered out; only the user's ISO remains —
        // so it can never be surfaced for, or moved to, the Trash.
        #expect(attachments.count == 1)
        #expect(attachments[0].path == "/Volumes/External/installer.iso")
        #expect(!attachments.contains { $0.path == agentPath })
    }

    @Test("externalAttachments is empty when the only external is the Guest Agent DMG")
    func externalAttachmentsEmptyForGuestAgentOnly() throws {
        let (viewModel, _, _, _, _) = makeViewModel()
        let agentPath = try #require(KernovaMacOSAgentInfo.installerDiskImageURL)
            .path(percentEncoded: false)
        let instance = makeInstance()
        instance.configuration.removableMedia = [
            RemovableMediaItem(path: agentPath, readOnly: true, label: "Kernova Guest Agent")
        ]
        viewModel.instances.append(instance)

        // Empty means the sheet's "Files outside this VM" section is omitted
        // entirely — there is nothing for the user to decide about.
        #expect(viewModel.externalAttachments(for: instance).isEmpty)
    }

    @Test("deleteVM never trashes the Guest Agent DMG even if its id is selected")
    func deleteVMNeverTrashesGuestAgentDMG() async throws {
        let (viewModel, storage, _, _, _) = makeViewModel()
        let agentPath = try #require(KernovaMacOSAgentInfo.installerDiskImageURL)
            .path(percentEncoded: false)
        let agentID = UUID()
        let instance = makeInstance()
        instance.configuration.removableMedia = [
            RemovableMediaItem(id: agentID, path: agentPath, readOnly: true, label: "Kernova Guest Agent")
        ]
        viewModel.instances.append(instance)
        storage.bundles[instance.bundleURL] = instance.configuration

        // Even if a caller passes the agent's id in the trash set, it is
        // excluded by `externalAttachments`, so no task is spawned. Require
        // this *before* awaiting: a regression would otherwise move the real
        // app-bundle DMG to the Trash.
        await viewModel.delete(instance, deletingExternalIDs: [agentID])

        #expect(viewModel.instances.isEmpty)
        #expect(FileManager.default.fileExists(atPath: agentPath))
        #expect(!presenter.showError)
    }

    @Test("deleteVM with no selected externals leaves external files untouched")
    func deleteVMKeepsExternalsByDefault() async throws {
        let (viewModel, storage, _, _, _) = makeViewModel()
        let instance = makeInstance()
        let externalDisk = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-external.img")
        let externalISO = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-installer.iso")

        instance.configuration.storageDisks = [
            StorageDisk(
                path: externalDisk.path(percentEncoded: false),
                readOnly: false, label: "External", isInternal: false, kind: .virtio
            )
        ]
        instance.configuration.removableMedia = [
            RemovableMediaItem(path: externalISO.path(percentEncoded: false), readOnly: true)
        ]
        viewModel.instances.append(instance)
        storage.bundles[instance.bundleURL] = instance.configuration

        await viewModel.delete(instance)

        #expect(viewModel.instances.isEmpty)
        #expect(fileSystem.trashedURLs.isEmpty)
        #expect(fileSystem.removedURLs.isEmpty)
        #expect(!presenter.showError)
    }

    // MARK: - Storage Disk rename / create

    @Test("renameStorageDisk trims, persists the new label, and saves once")
    func renameStorageDiskPersists() {
        let (viewModel, storage, _, _, _) = makeViewModel()
        let instance = makeInstance()
        let disk = StorageDisk(
            path: "AdditionalDisks/x.asif", label: "Original", isInternal: true, kind: .virtio)
        instance.configuration.storageDisks = [disk]

        viewModel.renameStorageDisk(disk, newLabel: "  Renamed  ", on: instance)

        #expect(instance.configuration.storageDisks?[0].label == "Renamed")
        #expect(storage.bundles[instance.bundleURL]?.storageDisks?[0].label == "Renamed")
        #expect(storage.saveConfigurationCallCount == 1)
    }

    @Test("renameStorageDisk ignores an empty / whitespace label and does not save")
    func renameStorageDiskEmptyGuard() {
        let (viewModel, storage, _, _, _) = makeViewModel()
        let instance = makeInstance()
        let disk = StorageDisk(
            path: "AdditionalDisks/x.asif", label: "Original", isInternal: true, kind: .virtio)
        instance.configuration.storageDisks = [disk]

        viewModel.renameStorageDisk(disk, newLabel: "   ", on: instance)

        #expect(instance.configuration.storageDisks?[0].label == "Original")
        #expect(storage.saveConfigurationCallCount == 0)
    }

    @Test("renameStorageDisk is a no-op for an unknown disk id")
    func renameStorageDiskUnknownID() {
        let (viewModel, storage, _, _, _) = makeViewModel()
        let instance = makeInstance()
        instance.configuration.storageDisks = [
            StorageDisk(
                path: "AdditionalDisks/x.asif", label: "Original", isInternal: true, kind: .virtio)
        ]
        let unknown = StorageDisk(
            path: "AdditionalDisks/y.asif", label: "Other", isInternal: true, kind: .virtio)

        viewModel.renameStorageDisk(unknown, newLabel: "New", on: instance)

        #expect(instance.configuration.storageDisks?[0].label == "Original")
        #expect(storage.saveConfigurationCallCount == 0)
    }

    @Test("setStorageDiskNotes trims, persists the note, and saves once")
    func setStorageDiskNotesPersists() {
        let (viewModel, storage, _, _, _) = makeViewModel()
        let instance = makeInstance()
        let disk = StorageDisk(
            path: "AdditionalDisks/x.asif", label: "Data", isInternal: true, kind: .virtio)
        instance.configuration.storageDisks = [disk]

        viewModel.setStorageDiskNotes(disk, notes: "  holds the build cache  ", on: instance)

        #expect(instance.configuration.storageDisks?[0].notes == "holds the build cache")
        #expect(storage.bundles[instance.bundleURL]?.storageDisks?[0].notes == "holds the build cache")
        #expect(storage.saveConfigurationCallCount == 1)
    }

    @Test("setStorageDiskNotes clears an existing note to empty, and saves")
    func setStorageDiskNotesClearsToEmpty() {
        let (viewModel, storage, _, _, _) = makeViewModel()
        let instance = makeInstance()
        var disk = StorageDisk(
            path: "AdditionalDisks/x.asif", label: "Data", isInternal: true, kind: .virtio)
        disk.notes = "before"
        instance.configuration.storageDisks = [disk]

        viewModel.setStorageDiskNotes(disk, notes: "   ", on: instance)

        #expect(instance.configuration.storageDisks?[0].notes == "")
        #expect(storage.saveConfigurationCallCount == 1)
    }

    @Test("setStorageDiskNotes is a no-op when the trimmed note is unchanged")
    func setStorageDiskNotesNoOpUnchanged() {
        let (viewModel, storage, _, _, _) = makeViewModel()
        let instance = makeInstance()
        var disk = StorageDisk(
            path: "AdditionalDisks/x.asif", label: "Data", isInternal: true, kind: .virtio)
        disk.notes = "before"
        instance.configuration.storageDisks = [disk]

        viewModel.setStorageDiskNotes(disk, notes: "before", on: instance)

        #expect(storage.saveConfigurationCallCount == 0)
    }

    @Test("setStorageDiskNotes is a no-op for an unknown disk id")
    func setStorageDiskNotesUnknownID() {
        let (viewModel, storage, _, _, _) = makeViewModel()
        let instance = makeInstance()
        instance.configuration.storageDisks = [
            StorageDisk(path: "AdditionalDisks/x.asif", label: "Data", isInternal: true, kind: .virtio)
        ]
        let unknown = StorageDisk(
            path: "AdditionalDisks/y.asif", label: "Other", isInternal: true, kind: .virtio)

        viewModel.setStorageDiskNotes(unknown, notes: "New", on: instance)

        #expect(instance.configuration.storageDisks?[0].notes == "")
        #expect(storage.saveConfigurationCallCount == 0)
    }

    @Test("setStorageDiskNotes on a nil storageDisks list persists the materialized list")
    func setStorageDiskNotesMaterializesDefaultDisks() {
        let (viewModel, storage, _, _, _) = makeViewModel()
        let instance = makeInstance()
        defer { try? FileManager.default.removeItem(at: instance.bundleURL) }
        let mainDisk = VMCommandCore.defaultStorageDisks(for: instance)[0]

        viewModel.setStorageDiskNotes(mainDisk, notes: "the startup disk", on: instance)

        #expect(instance.configuration.storageDisks?.count == 1)
        #expect(instance.configuration.storageDisks?[0].notes == "the startup disk")
        #expect(storage.bundles[instance.bundleURL]?.storageDisks?[0].notes == "the startup disk")
    }

    @Test("createStorageDisk gives a new disk a collision-free default label")
    func createStorageDiskUniqueLabel() async {
        let (viewModel, _, diskImage, _, _) = makeViewModel()
        let instance = makeInstance()
        defer { try? FileManager.default.removeItem(at: instance.bundleURL) }
        // Pre-seed a disk already using the default "100 GB Disk" label.
        instance.configuration.storageDisks = [
            StorageDisk(
                path: "AdditionalDisks/a.asif", label: "100 GB Disk", isInternal: true,
                kind: .virtio)
        ]

        await viewModel.createStorageDisk(for: instance, sizeInGB: 100).value

        #expect(diskImage.createDiskImageCallCount == 1)
        let disks = instance.configuration.storageDisks ?? []
        #expect(disks.count == 2)
        #expect(disks[1].label == "100 GB Disk 2")
        #expect(disks[1].isInternal)
    }

    // MARK: - Removable media rename

    @Test("renameRemovableMedia trims, persists the new label, and saves once")
    func renameRemovableMediaPersists() {
        let (viewModel, storage, _, _, _) = makeViewModel()
        let instance = makeInstance()
        let item = RemovableMediaItem(path: "/tmp/installer.iso", readOnly: true, label: "Original")
        instance.configuration.removableMedia = [item]

        viewModel.renameRemovableMedia(item, newLabel: "  Renamed  ", on: instance)

        #expect(instance.configuration.removableMedia?[0].label == "Renamed")
        #expect(storage.bundles[instance.bundleURL]?.removableMedia?[0].label == "Renamed")
        #expect(storage.saveConfigurationCallCount == 1)
    }

    @Test("renameRemovableMedia leaves path and readOnly untouched (stays mounted live)")
    func renameRemovableMediaKeepsMountIdentity() {
        let (viewModel, _, _, _, _) = makeViewModel()
        let instance = makeInstance()
        let item = RemovableMediaItem(path: "/tmp/installer.iso", readOnly: true, label: "Original")
        instance.configuration.removableMedia = [item]

        viewModel.renameRemovableMedia(item, newLabel: "Renamed", on: instance)

        // A label-only edit must not change path/readOnly, or the live diff would
        // detach and reattach the medium (ejecting it from the running guest).
        #expect(instance.configuration.removableMedia?[0].path == "/tmp/installer.iso")
        #expect(instance.configuration.removableMedia?[0].readOnly == true)
    }

    @Test("renameRemovableMedia ignores an empty / whitespace label and does not save")
    func renameRemovableMediaEmptyGuard() {
        let (viewModel, storage, _, _, _) = makeViewModel()
        let instance = makeInstance()
        let item = RemovableMediaItem(path: "/tmp/installer.iso", readOnly: true, label: "Original")
        instance.configuration.removableMedia = [item]

        viewModel.renameRemovableMedia(item, newLabel: "   ", on: instance)

        #expect(instance.configuration.removableMedia?[0].label == "Original")
        #expect(storage.saveConfigurationCallCount == 0)
    }

    @Test("renameRemovableMedia is a no-op for an unknown item id")
    func renameRemovableMediaUnknownID() {
        let (viewModel, storage, _, _, _) = makeViewModel()
        let instance = makeInstance()
        instance.configuration.removableMedia = [
            RemovableMediaItem(path: "/tmp/installer.iso", readOnly: true, label: "Original")
        ]
        let unknown = RemovableMediaItem(path: "/tmp/other.iso", readOnly: true, label: "Other")

        viewModel.renameRemovableMedia(unknown, newLabel: "New", on: instance)

        #expect(instance.configuration.removableMedia?[0].label == "Original")
        #expect(storage.saveConfigurationCallCount == 0)
    }

    @Test("setRemovableMediaNotes trims, persists the note, and saves once")
    func setRemovableMediaNotesPersists() {
        let (viewModel, storage, _, _, _) = makeViewModel()
        let instance = makeInstance()
        let item = RemovableMediaItem(path: "/tmp/installer.iso", readOnly: true, label: "Installer")
        instance.configuration.removableMedia = [item]

        viewModel.setRemovableMediaNotes(item, notes: "  from the Ubuntu mirror  ", on: instance)

        #expect(instance.configuration.removableMedia?[0].notes == "from the Ubuntu mirror")
        #expect(
            storage.bundles[instance.bundleURL]?.removableMedia?[0].notes == "from the Ubuntu mirror")
        #expect(storage.saveConfigurationCallCount == 1)
    }

    @Test("setRemovableMediaNotes leaves path and readOnly untouched (stays mounted live)")
    func setRemovableMediaNotesKeepsMountIdentity() {
        let (viewModel, _, _, _, _) = makeViewModel()
        let instance = makeInstance()
        let item = RemovableMediaItem(path: "/tmp/installer.iso", readOnly: true, label: "Installer")
        instance.configuration.removableMedia = [item]

        viewModel.setRemovableMediaNotes(item, notes: "note", on: instance)

        #expect(instance.configuration.removableMedia?[0].path == "/tmp/installer.iso")
        #expect(instance.configuration.removableMedia?[0].readOnly == true)
    }

    @Test("setRemovableMediaNotes clears an existing note to empty, and saves")
    func setRemovableMediaNotesClearsToEmpty() {
        let (viewModel, storage, _, _, _) = makeViewModel()
        let instance = makeInstance()
        var item = RemovableMediaItem(path: "/tmp/installer.iso", readOnly: true, label: "Installer")
        item.notes = "before"
        instance.configuration.removableMedia = [item]

        viewModel.setRemovableMediaNotes(item, notes: "   ", on: instance)

        #expect(instance.configuration.removableMedia?[0].notes == "")
        #expect(storage.saveConfigurationCallCount == 1)
    }

    @Test("setRemovableMediaNotes is a no-op when the trimmed note is unchanged")
    func setRemovableMediaNotesNoOpUnchanged() {
        let (viewModel, storage, _, _, _) = makeViewModel()
        let instance = makeInstance()
        var item = RemovableMediaItem(path: "/tmp/installer.iso", readOnly: true, label: "Installer")
        item.notes = "before"
        instance.configuration.removableMedia = [item]

        viewModel.setRemovableMediaNotes(item, notes: "before", on: instance)

        #expect(storage.saveConfigurationCallCount == 0)
    }

    @Test("setRemovableMediaNotes is a no-op for an unknown item id")
    func setRemovableMediaNotesUnknownID() {
        let (viewModel, storage, _, _, _) = makeViewModel()
        let instance = makeInstance()
        instance.configuration.removableMedia = [
            RemovableMediaItem(path: "/tmp/installer.iso", readOnly: true, label: "Installer")
        ]
        let unknown = RemovableMediaItem(path: "/tmp/other.iso", readOnly: true, label: "Other")

        viewModel.setRemovableMediaNotes(unknown, notes: "New", on: instance)

        #expect(instance.configuration.removableMedia?[0].notes == "")
        #expect(storage.saveConfigurationCallCount == 0)
    }

    @Test("deleteVM trashes the selected external disks and removable media")
    func deleteVMTrashesExternals() async throws {
        let (viewModel, storage, _, _, _) = makeViewModel()
        let instance = makeInstance()
        let externalDisk = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-external.img")
        let externalISO = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-installer.iso")

        let diskID = UUID()
        let isoID = UUID()
        instance.configuration.storageDisks = [
            StorageDisk(
                id: diskID,
                path: externalDisk.path(percentEncoded: false),
                readOnly: false, label: "External", isInternal: false, kind: .virtio
            )
        ]
        instance.configuration.removableMedia = [
            RemovableMediaItem(id: isoID, path: externalISO.path(percentEncoded: false), readOnly: true)
        ]
        viewModel.instances.append(instance)
        storage.bundles[instance.bundleURL] = instance.configuration

        await viewModel.delete(instance, deletingExternalIDs: [diskID, isoID])

        #expect(viewModel.instances.isEmpty)
        #expect(Set(fileSystem.trashedURLs) == [externalDisk, externalISO])
        #expect(!presenter.showError)
        #expect(presenter.showDeleteSheet == false)
    }

    @Test("deleteVM trashes only the selected external and keeps the rest")
    func deleteVMTrashesOnlySelectedExternal() async throws {
        let (viewModel, storage, _, _, _) = makeViewModel()
        let instance = makeInstance()
        let trashedDisk = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-trash.img")
        let keptDisk = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-keep.img")

        let trashedID = UUID()
        let keptID = UUID()
        instance.configuration.storageDisks = [
            StorageDisk(
                id: trashedID, path: trashedDisk.path(percentEncoded: false),
                readOnly: false, label: "Trashed", isInternal: false, kind: .virtio
            ),
            StorageDisk(
                id: keptID, path: keptDisk.path(percentEncoded: false),
                readOnly: false, label: "Kept", isInternal: false, kind: .virtio
            ),
        ]
        viewModel.instances.append(instance)
        storage.bundles[instance.bundleURL] = instance.configuration

        await viewModel.delete(instance, deletingExternalIDs: [trashedID])

        // Only the selected disk is trashed; the unselected one stays put.
        #expect(fileSystem.trashedURLs == [trashedDisk])
        #expect(!presenter.showError)
    }

    @Test("deleteVM never trashes a shared external even if its id is selected")
    func deleteVMNeverTrashesSharedExternal() async throws {
        let (viewModel, storage, _, _, _) = makeViewModel()
        let sharedDisk = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-shared.img")

        let sharedID = UUID()
        let sharedPath = sharedDisk.path(percentEncoded: false)
        let target = makeInstance(name: "Target")
        target.configuration.storageDisks = [
            StorageDisk(
                id: sharedID, path: sharedPath,
                readOnly: false, label: "Shared", isInternal: false, kind: .virtio
            )
        ]
        // A second VM references the same path, marking it shared.
        let other = makeInstance(name: "Other")
        other.configuration.storageDisks = [
            StorageDisk(
                path: sharedPath, readOnly: false, label: "Shared",
                isInternal: false, kind: .virtio
            )
        ]
        viewModel.instances = [target, other]
        storage.bundles[target.bundleURL] = target.configuration

        await viewModel.delete(target, deletingExternalIDs: [sharedID])

        // Hard-block: a shared file is never trashed, so the other VM keeps it.
        #expect(fileSystem.trashedURLs.isEmpty)
        #expect(!presenter.showError)
    }

    @Test("bundledDisks returns the internal disks and excludes externals")
    func bundledDisksListsInternalOnly() {
        let (viewModel, _, _, _, _) = makeViewModel()
        let instance = makeInstance()
        instance.configuration.storageDisks = [
            StorageDisk(path: "Disk.asif", readOnly: false, label: "Main", isInternal: true, kind: .virtio),
            StorageDisk(
                path: "AdditionalDisks/extra.asif", readOnly: false, label: "Extra",
                isInternal: true, kind: .virtio
            ),
            StorageDisk(
                path: "/Volumes/External/data.img", readOnly: false, label: "Scratch",
                isInternal: false, kind: .virtio
            ),
        ]
        viewModel.instances.append(instance)

        let bundled = viewModel.bundledDisks(for: instance)

        #expect(bundled.count == 2)
        #expect(bundled.allSatisfy { $0.isInternal })
        #expect(bundled.map(\.label) == ["Main", "Extra"])
    }

    @Test("bundledDisks falls back to the synthesized main disk when config is nil")
    func bundledDisksFallsBackToMainDisk() {
        let (viewModel, _, _, _, _) = makeViewModel()
        let instance = makeInstance()
        instance.configuration.storageDisks = nil
        viewModel.instances.append(instance)

        let bundled = viewModel.bundledDisks(for: instance)

        #expect(bundled.count == 1)
        #expect(bundled[0].isInternal)
    }

    /// Builds a `VMLibraryViewModel` wired to a caller-supplied `MockIPSWService`.
    ///
    /// The shared `makeViewModel` helper doesn't expose the IPSW service
    /// in its return tuple, so this small builder avoids changing every
    /// existing destructure just to observe resume-data cleanup.
    private func makeViewModelWithIPSW(
        ipswService: MockIPSWService,
        storage: MockVMStorageService
    ) -> VMLibraryViewModel {
        let vm = VMLibraryViewModel(
            storageService: storage,
            diskImageService: MockDiskImageService(),
            virtualizationService: MockVirtualizationService(),
            installService: MockMacOSInstallService(),
            ipswService: ipswService,
            usbDeviceService: MockUSBDeviceService(),
            fileSystem: fileSystem,
            preferences: preferences
        )
        vm.presenter = presenter
        return vm
    }

    @Test(
        "deleteVM discards the IPSW resume-data sidecar",
        arguments: [
            MacOSInstallContext.Source.downloadLatest, .catalogVersion, .customURL,
        ]
    )
    func deleteVMDiscardsResumeData(source: MacOSInstallContext.Source) async {
        // Every source that downloads its image leaves a partial bundle at
        // `downloadDestinationPath`, so deleting the VM has to discard it.
        let ipswService = MockIPSWService()
        let storage = MockVMStorageService()
        let viewModel = makeViewModelWithIPSW(ipswService: ipswService, storage: storage)

        let instance = makeInstance()
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-RestoreImage.ipsw")
        instance.configuration.installContext = MacOSInstallContext(
            source: source,
            downloadDestinationPath: destination.path(percentEncoded: false)
        )
        viewModel.instances.append(instance)
        storage.bundles[instance.bundleURL] = instance.configuration

        await viewModel.delete(instance)

        #expect(ipswService.discardResumeDataCallCount == 1)
        #expect(
            ipswService.lastDiscardResumeDataURL?.path(percentEncoded: false)
                == destination.path(percentEncoded: false)
        )
        // A move-to-Trash delete discards the partial download to the Trash too.
        #expect(ipswService.lastDiscardResumeDataPermanently == false)
        #expect(viewModel.instances.isEmpty)
    }

    @Test("deleteVM permanently discards the IPSW resume-data immediately too")
    func deleteVMPermanentlyDiscardsResumeDataImmediately() async {
        let ipswService = MockIPSWService()
        let storage = MockVMStorageService()
        let viewModel = makeViewModelWithIPSW(ipswService: ipswService, storage: storage)

        let instance = makeInstance()
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-RestoreImage.ipsw")
        instance.configuration.installContext = MacOSInstallContext(
            source: .downloadLatest,
            downloadDestinationPath: destination.path(percentEncoded: false)
        )
        viewModel.instances.append(instance)
        storage.bundles[instance.bundleURL] = instance.configuration

        await viewModel.delete(instance, permanently: true)

        // The whole operation uses one disposition: the partial download is removed
        // immediately, not trashed, matching the bundle and externals.
        #expect(ipswService.discardResumeDataCallCount == 1)
        #expect(ipswService.lastDiscardResumeDataPermanently == true)
        #expect(storage.permanentlyDeleteVMBundleCallCount == 1)
        #expect(viewModel.instances.isEmpty)
    }

    @Test("deleteVM leaves resume-data alone for a local-file install")
    func deleteVMNoResumeDataForLocalFileSource() async {
        let ipswService = MockIPSWService()
        let storage = MockVMStorageService()
        let viewModel = makeViewModelWithIPSW(ipswService: ipswService, storage: storage)

        let instance = makeInstance()
        // A destination path is set so the source — not a nil destination — is
        // what keeps the cleanup from firing.
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-RestoreImage.ipsw")
        instance.configuration.installContext = MacOSInstallContext(
            source: .localFile,
            downloadDestinationPath: destination.path(percentEncoded: false),
            localIPSWPath: "/tmp/UserPicked.ipsw"
        )
        viewModel.instances.append(instance)
        storage.bundles[instance.bundleURL] = instance.configuration

        await viewModel.delete(instance)

        #expect(ipswService.discardResumeDataCallCount == 0)
    }

    @Test("deleteVM leaves resume-data alone when VM has no install context")
    func deleteVMNoResumeDataForNonInstallVM() async {
        let ipswService = MockIPSWService()
        let storage = MockVMStorageService()
        let viewModel = makeViewModelWithIPSW(ipswService: ipswService, storage: storage)
        let instance = makeInstance()
        viewModel.instances.append(instance)
        storage.bundles[instance.bundleURL] = instance.configuration

        await viewModel.delete(instance)

        #expect(ipswService.discardResumeDataCallCount == 0)
    }

    @Test("deleteVM swallows missing-file errors for a selected external")
    func deleteVMSwallowsMissingExternals() async {
        let (viewModel, storage, _, _, _) = makeViewModel()
        fileSystem.trashError = CocoaError(.fileNoSuchFile)
        let instance = makeInstance()
        let ghostID = UUID()
        let ghostPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("kernova-ghost-\(UUID().uuidString).iso")
            .path(percentEncoded: false)
        instance.configuration.removableMedia = [
            RemovableMediaItem(id: ghostID, path: ghostPath, readOnly: true)
        ]
        viewModel.instances.append(instance)
        storage.bundles[instance.bundleURL] = instance.configuration

        await viewModel.delete(instance, deletingExternalIDs: [ghostID])

        #expect(viewModel.instances.isEmpty)
        #expect(!presenter.showError)
    }

    @Test("deleteVM permanently swallows missing-file errors for a selected external")
    func deleteVMPermanentlySwallowsMissingExternals() async {
        let (viewModel, storage, _, _, _) = makeViewModel()
        fileSystem.removeError = CocoaError(.fileNoSuchFile)
        let instance = makeInstance()
        let ghostID = UUID()
        let ghostPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("kernova-ghost-\(UUID().uuidString).iso")
            .path(percentEncoded: false)
        instance.configuration.removableMedia = [
            RemovableMediaItem(id: ghostID, path: ghostPath, readOnly: true)
        ]
        viewModel.instances.append(instance)
        storage.bundles[instance.bundleURL] = instance.configuration

        // removeItem on a vanished file throws the same fileNoSuchFile family as
        // trashItem, so the immediate path must swallow it without an error alert.
        await viewModel.delete(instance, deletingExternalIDs: [ghostID], permanently: true)

        #expect(viewModel.instances.isEmpty)
        #expect(!presenter.showError)
    }

    @Test("deleteVM ignores a repeat confirm for an already-removed VM")
    func deleteVMIgnoresStaleRepeatConfirm() async {
        let (viewModel, storage, _, _, _) = makeViewModel()
        let instance = makeInstance()
        viewModel.instances.append(instance)
        storage.bundles[instance.bundleURL] = instance.configuration

        await viewModel.delete(instance)
        #expect(storage.deleteVMBundleCallCount == 1)
        #expect(viewModel.instances.isEmpty)

        // A second confirm (e.g. a duplicate queued delete sheet) must not re-run the
        // delete on the now-missing bundle and surface a spurious bundleNotFound error.
        await viewModel.delete(instance)
        #expect(storage.deleteVMBundleCallCount == 1)
        #expect(!presenter.showError)
    }

    // MARK: - Lifecycle Delegation

    @Test("start delegates to lifecycle coordinator")
    func startDelegates() async {
        let (viewModel, _, _, virtService, _) = makeViewModel()
        let instance = makeInstance()
        viewModel.instances.append(instance)

        await viewModel.start(instance)

        #expect(virtService.startCallCount == 1)
        #expect(instance.status == .running)
        #expect(virtService.lastStartBootIntoRecovery == false)
    }

    @Test("requestStartInRecovery routes to the presenter")
    func requestStartInRecoveryRoutesToPresenter() {
        let (viewModel, _, _, _, _) = makeViewModel()
        let instance = makeInstance()
        viewModel.instances.append(instance)

        viewModel.requestStartInRecovery(instance)

        #expect(presenter.showRecoveryBootConfirmation)
        #expect(presenter.instanceToRecoveryBoot === instance)
    }

    @Test("startInRecovery starts with the recovery flag set")
    func startInRecoverySetsFlag() async {
        let (viewModel, _, _, virtService, _) = makeViewModel()
        // macOS only: Virtualization.framework has no recovery start option for
        // Linux/EFI guests, and the verb refuses one.
        let instance = makeInstance(guestOS: .macOS)
        viewModel.instances.append(instance)

        await viewModel.start(instance, bootIntoRecovery: true)

        #expect(virtService.startCallCount == 1)
        #expect(virtService.lastStartBootIntoRecovery == true)
    }

    @Test("stop delegates to lifecycle coordinator")
    func stopDelegates() async {
        let (viewModel, _, _, virtService, _) = makeViewModel()
        let instance = makeInstance()
        instance.enter(.running(sessionID: UUID()))
        viewModel.instances.append(instance)

        await viewModel.stop(instance)

        #expect(virtService.stopCallCount == 1)
        #expect(instance.status == .stopped)
    }

    @Test("forceStop delegates to lifecycle coordinator")
    func forceStopDelegates() async {
        let (viewModel, _, _, virtService, _) = makeViewModel()
        let instance = makeInstance()
        instance.enter(.running(sessionID: UUID()))
        viewModel.instances.append(instance)

        await viewModel.forceStop(instance)

        #expect(virtService.forceStopCallCount == 1)
        #expect(instance.status == .stopped)
    }

    @Test("pause delegates to lifecycle coordinator")
    func pauseDelegates() async {
        let (viewModel, _, _, virtService, _) = makeViewModel()
        let instance = makeInstance()
        instance.enter(.running(sessionID: UUID()))
        viewModel.instances.append(instance)

        await viewModel.pause(instance)

        #expect(virtService.pauseCallCount == 1)
        #expect(instance.status == .paused)
    }

    @Test("resume delegates to lifecycle coordinator")
    func resumeDelegates() async {
        let (viewModel, _, _, virtService, _) = makeViewModel()
        let instance = makeInstance()
        instance.enter(.suspended)
        viewModel.instances.append(instance)

        await viewModel.resume(instance)

        #expect(virtService.resumeCallCount == 1)
        #expect(instance.status == .running)
    }

    @Test("start of an inline-display VM asks the presenter to focus the guest display")
    func startRequestsInlineGuestFocus() async {
        let (viewModel, _, _, _, _) = makeViewModel()
        let instance = makeInstance()
        viewModel.instances.append(instance)

        await viewModel.start(instance)

        #expect(presenter.focusGuestDisplayInstances.count == 1)
        #expect(presenter.focusGuestDisplayInstances.last === instance)
    }

    @Test("start of a pop-out VM opens the display window instead of requesting inline focus")
    func startPopOutSkipsInlineGuestFocus() async {
        let (viewModel, _, _, _, _) = makeViewModel()
        let instance = makeInstance()
        instance.configuration.displayPreference = .popOut
        viewModel.instances.append(instance)

        await viewModel.start(instance)

        #expect(presenter.focusGuestDisplayInstances.isEmpty)
    }

    @Test("resume of an inline-display VM asks the presenter to focus the guest display")
    func resumeRequestsInlineGuestFocus() async {
        let (viewModel, _, _, _, _) = makeViewModel()
        let instance = makeInstance()
        instance.enter(.suspended)
        viewModel.instances.append(instance)

        await viewModel.resume(instance)

        #expect(presenter.focusGuestDisplayInstances.count == 1)
        #expect(presenter.focusGuestDisplayInstances.last === instance)
    }

    @Test("resume of a pop-out VM opens the display window instead of requesting inline focus")
    func resumePopOutSkipsInlineGuestFocus() async {
        let (viewModel, _, _, _, _) = makeViewModel()
        let instance = makeInstance()
        instance.enter(.suspended)
        instance.configuration.displayPreference = .popOut
        viewModel.instances.append(instance)

        await viewModel.resume(instance)

        #expect(presenter.focusGuestDisplayInstances.isEmpty)
    }

    /// The inline display renders the selected VM, so surfacing one that is not
    /// selected has to select it first — `focusGuestDisplay` on an unselected VM
    /// only arms a focus the next display-state pass clears, which is how
    /// `open` on an arbitrary VM used to leave the previous one on screen.
    @Test("Surfacing an inline VM's display selects it, whatever was selected before")
    func openSelectsTheVMItSurfaces() async throws {
        let (viewModel, _, _, _, _) = makeViewModel()
        let onScreen = makeInstance(name: "OnScreen")
        let wanted = makeInstance(name: "Wanted")
        wanted.enter(.running(sessionID: UUID()))
        viewModel.instances.append(contentsOf: [onScreen, wanted])
        viewModel.selectedID = onScreen.id

        try viewModel.commands.open(.id(wanted.id))

        #expect(viewModel.selectedID == wanted.id)
        #expect(presenter.focusGuestDisplayInstances.last === wanted)
    }

    /// The inline display lives inside the main window, so an intent surfacing
    /// one on a process that has never opened a window — the headless launch
    /// path — has nowhere to land and used to do nothing at all.
    @Test("Surfacing an inline VM with no window asks for the library, then focuses it")
    func openWithNoWindowRequestsTheLibraryFirst() throws {
        let (viewModel, _, _, _, _) = makeViewModel()
        let wanted = makeInstance(name: "Wanted")
        wanted.enter(.running(sessionID: UUID()))
        viewModel.instances.append(wanted)
        // No main window has been created, which is what leaves `presenter` nil.
        viewModel.presenter = nil
        var libraryRequests = 0
        viewModel.onSurfaceLibrary = { libraryRequests += 1 }

        try viewModel.commands.open(.id(wanted.id))

        #expect(libraryRequests == 1)
        #expect(viewModel.selectedID == wanted.id)

        // Attaching the presenter is what the requested window does on arrival.
        viewModel.presenter = presenter
        #expect(presenter.focusGuestDisplayInstances.last === wanted)
    }

    @Test("A buffered surface request is dropped when its VM leaves before the window arrives")
    func bufferedSurfaceRequestSurvivesAVanishedVM() throws {
        let (viewModel, _, _, _, _) = makeViewModel()
        let wanted = makeInstance(name: "Wanted")
        wanted.enter(.running(sessionID: UUID()))
        viewModel.instances.append(wanted)
        viewModel.presenter = nil
        viewModel.onSurfaceLibrary = {}

        try viewModel.commands.open(.id(wanted.id))
        viewModel.instances.removeAll()
        viewModel.presenter = presenter

        #expect(presenter.focusGuestDisplayInstances.isEmpty)
    }

    @Test("Surfacing a pop-out VM's display leaves the selection where it was")
    func openOfAPopOutVMLeavesTheSelectionAlone() async throws {
        let (viewModel, _, _, _, _) = makeViewModel()
        let onScreen = makeInstance(name: "OnScreen")
        let wanted = makeInstance(name: "Wanted")
        wanted.enter(.running(sessionID: UUID()))
        wanted.configuration.displayPreference = .popOut
        viewModel.instances.append(contentsOf: [onScreen, wanted])
        viewModel.selectedID = onScreen.id

        try viewModel.commands.open(.id(wanted.id))

        #expect(viewModel.selectedID == onScreen.id)
        #expect(presenter.focusGuestDisplayInstances.isEmpty)
    }

    @Test("save delegates to lifecycle coordinator")
    func saveDelegates() async {
        let (viewModel, _, _, virtService, _) = makeViewModel()
        let instance = makeInstance()
        instance.enter(.running(sessionID: UUID()))
        viewModel.instances.append(instance)

        await viewModel.save(instance)

        #expect(virtService.saveCallCount == 1)
        #expect(instance.status == .paused)
    }

    // MARK: - Duplicate Machine ID Boot Guard

    /// Two VMs carrying the given machine identifiers in whichever identity
    /// field `guestOS` uses, both appended to `viewModel`.
    ///
    /// `other` is the one the tests park in a live status; `starting` is the one
    /// they try to boot.
    private func appendMachineIDPair(
        to viewModel: VMLibraryViewModel,
        guestOS: VMGuestOS = .macOS,
        startingID: Data = Data([1, 2, 3]),
        otherID: Data = Data([1, 2, 3])
    ) -> (starting: VMInstance, other: VMInstance) {
        let starting = makeInstance(name: "Starting", guestOS: guestOS)
        let other = makeInstance(name: "Twin", guestOS: guestOS)
        for (instance, identifier) in [(starting, startingID), (other, otherID)] {
            if guestOS == .macOS {
                instance.configuration.machineIdentifierData = identifier
            } else {
                instance.configuration.genericMachineIdentifierData = identifier
            }
        }
        viewModel.instances.append(contentsOf: [starting, other])
        return (starting, other)
    }

    @Test("start is refused while another VM with the same machine ID is running")
    func startBlockedByRunningMachineIDTwin() async {
        let virtService = MockVirtualizationService()
        let (viewModel, _, _, _, _) = makeViewModel(virtualizationService: virtService)
        let (starting, other) = appendMachineIDPair(to: viewModel)
        other.enter(.running(sessionID: UUID()))

        await viewModel.start(starting)

        #expect(virtService.startCallCount == 0)
        #expect(presenter.errorTitle == "Duplicate Machine ID")
        #expect(starting.status == .stopped)
    }

    @Test("start proceeds past a machine ID twin when the guard preference is off")
    func startProceedsWhenDuplicateMachineIDGuardDisabled() async {
        let virtService = MockVirtualizationService()
        let (viewModel, _, _, _, _) = makeViewModel(virtualizationService: virtService)
        let (starting, other) = appendMachineIDPair(to: viewModel)
        other.enter(.running(sessionID: UUID()))
        preferences.blockDuplicateMachineIDBoot = false

        await viewModel.start(starting)

        #expect(virtService.startCallCount == 1)
        #expect(presenter.showError == false)
    }

    @Test("start proceeds when the machine ID twin is stopped")
    func startProceedsWhenMachineIDTwinIsStopped() async {
        let virtService = MockVirtualizationService()
        let (viewModel, _, _, _, _) = makeViewModel(virtualizationService: virtService)
        let (starting, other) = appendMachineIDPair(to: viewModel)
        other.enter(.stopped)

        await viewModel.start(starting)

        #expect(virtService.startCallCount == 1)
        #expect(presenter.showError == false)
    }

    @Test("start is refused while the machine ID twin is live-paused (VZ still holds the identity)")
    func startBlockedByPausedMachineIDTwin() async throws {
        let virtService = MockVirtualizationService()
        let (viewModel, _, _, _, _) = makeViewModel(virtualizationService: virtService)
        let (starting, other) = appendMachineIDPair(to: viewModel)
        other.enter(.livePaused(sessionID: UUID()))

        await viewModel.start(starting)

        #expect(virtService.startCallCount == 0)
        #expect(presenter.errorTitle == "Duplicate Machine ID")
    }

    @Test("start proceeds when the machine ID twin is cold-paused (it holds no VZ identity)")
    func startProceedsWhenMachineIDTwinIsColdPaused() async {
        let virtService = MockVirtualizationService()
        let (viewModel, _, _, _, _) = makeViewModel(virtualizationService: virtService)
        let (starting, other) = appendMachineIDPair(to: viewModel)
        other.enter(.suspended)
        #expect(other.isColdPaused)

        await viewModel.start(starting)

        #expect(virtService.startCallCount == 1)
        #expect(presenter.showError == false)
    }

    @Test("start is refused when both VMs carry their machine ID only as a bundle file")
    func startBlockedByFileOnlyMachineIDTwin() async throws {
        let virtService = MockVirtualizationService()
        let (viewModel, _, _, _, _) = makeViewModel(virtualizationService: virtService)
        let starting = makeInstance(name: "Starting", guestOS: .macOS)
        let other = makeInstance(name: "Twin", guestOS: .macOS)
        // The identifier lives only on disk, exactly as it does in a bundle
        // written before the configuration carried the field.
        for instance in [starting, other] {
            try FileManager.default.createDirectory(
                at: instance.bundleURL, withIntermediateDirectories: true)
            try Data([1, 2, 3]).write(to: instance.machineIdentifierURL)
        }
        defer {
            for instance in [starting, other] {
                try? FileManager.default.removeItem(at: instance.bundleURL)
            }
        }
        viewModel.instances.append(contentsOf: [starting, other])
        other.enter(.running(sessionID: UUID()))

        await viewModel.start(starting)

        #expect(starting.configuration.machineIdentifierData == nil)
        #expect(virtService.startCallCount == 0)
        #expect(presenter.errorTitle == "Duplicate Machine ID")
    }

    @Test("a cold resume is refused while a machine ID twin is running")
    func coldResumeBlockedByRunningMachineIDTwin() async {
        let virtService = MockVirtualizationService()
        let (viewModel, _, _, _, _) = makeViewModel(virtualizationService: virtService)
        let (resuming, other) = appendMachineIDPair(to: viewModel)
        // Cold-paused: paused with no `virtualMachine`, so the resume would build
        // a fresh one and claim the identity.
        resuming.enter(.suspended)
        other.enter(.running(sessionID: UUID()))

        await viewModel.resume(resuming)

        #expect(virtService.resumeCallCount == 0)
        #expect(presenter.errorTitle == "Duplicate Machine ID")
        #expect(resuming.status == .paused)
    }

    @Test("a cold resume proceeds past a machine ID twin when the guard preference is off")
    func coldResumeProceedsWhenDuplicateMachineIDGuardDisabled() async {
        let virtService = MockVirtualizationService()
        let (viewModel, _, _, _, _) = makeViewModel(virtualizationService: virtService)
        let (resuming, other) = appendMachineIDPair(to: viewModel)
        resuming.enter(.suspended)
        other.enter(.running(sessionID: UUID()))
        preferences.blockDuplicateMachineIDBoot = false

        await viewModel.resume(resuming)

        #expect(virtService.resumeCallCount == 1)
        #expect(presenter.showError == false)
    }

    @Test("a hot resume is never refused — the live VM already holds the identity")
    func hotResumeIsNotBlockedByMachineIDTwin() async throws {
        let virtService = MockVirtualizationService()
        let (viewModel, _, _, _, _) = makeViewModel(virtualizationService: virtService)
        let (resuming, other) = appendMachineIDPair(to: viewModel)
        resuming.enter(.livePaused(sessionID: UUID()))
        other.enter(.running(sessionID: UUID()))

        await viewModel.resume(resuming)

        #expect(virtService.resumeCallCount == 1)
        #expect(presenter.showError == false)
    }

    @Test("start proceeds when the running VM's machine ID differs")
    func startProceedsWhenMachineIDsDiffer() async {
        let virtService = MockVirtualizationService()
        let (viewModel, _, _, _, _) = makeViewModel(virtualizationService: virtService)
        let (starting, other) = appendMachineIDPair(to: viewModel, otherID: Data([4, 5, 6]))
        other.enter(.running(sessionID: UUID()))

        await viewModel.start(starting)

        #expect(virtService.startCallCount == 1)
        #expect(presenter.showError == false)
    }

    @Test("start is refused while a Linux VM sharing the generic machine ID is running")
    func startBlockedByRunningGenericMachineIDTwin() async {
        let virtService = MockVirtualizationService()
        let (viewModel, _, _, _, _) = makeViewModel(virtualizationService: virtService)
        let (starting, other) = appendMachineIDPair(to: viewModel, guestOS: .linux)
        other.enter(.running(sessionID: UUID()))

        await viewModel.start(starting)

        #expect(virtService.startCallCount == 0)
        #expect(presenter.errorTitle == "Duplicate Machine ID")
    }

    // MARK: - Duplicate MAC Address Boot Guard

    /// Two VMs carrying the given MAC addresses and network modes, both appended
    /// to `viewModel`.
    ///
    /// `other` is the one the tests park in a live status; `starting` is the one
    /// they try to boot.
    private func appendMACAddressPair(
        to viewModel: VMLibraryViewModel,
        mac: String = "aa:bb:cc:dd:ee:01",
        otherMAC: String = "aa:bb:cc:dd:ee:01",
        mode: VMNetworkMode = .shared,
        otherMode: VMNetworkMode = .shared
    ) -> (starting: VMInstance, other: VMInstance) {
        let starting = makeInstance(name: "Starting")
        let other = makeInstance(name: "Twin")
        starting.configuration.macAddress = mac
        starting.configuration.networkMode = mode
        other.configuration.macAddress = otherMAC
        other.configuration.networkMode = otherMode
        viewModel.instances.append(contentsOf: [starting, other])
        return (starting, other)
    }

    @Test("start is refused while another VM with the same MAC address is running")
    func startBlockedByRunningMACAddressTwin() async {
        let virtService = MockVirtualizationService()
        let (viewModel, _, _, _, _) = makeViewModel(virtualizationService: virtService)
        let (starting, other) = appendMACAddressPair(to: viewModel)
        other.enter(.running(sessionID: UUID()))

        await viewModel.start(starting)

        #expect(virtService.startCallCount == 0)
        #expect(presenter.errorTitle == "Duplicate MAC Address")
        #expect(presenter.errorMessage?.contains("Starting") == true)
        #expect(presenter.errorMessage?.contains("Twin") == true)
        #expect(starting.status == .stopped)
    }

    @Test("start is refused while the MAC address twin is live-paused (it still holds the address)")
    func startBlockedByLivePausedMACAddressTwin() async {
        let virtService = MockVirtualizationService()
        let (viewModel, _, _, _, _) = makeViewModel(virtualizationService: virtService)
        let (starting, other) = appendMACAddressPair(to: viewModel)
        other.enter(.livePaused(sessionID: UUID()))

        await viewModel.start(starting)

        #expect(virtService.startCallCount == 0)
        #expect(presenter.errorTitle == "Duplicate MAC Address")
    }

    @Test("start proceeds when the MAC address twin is stopped")
    func startProceedsWhenMACAddressTwinIsStopped() async {
        let virtService = MockVirtualizationService()
        let (viewModel, _, _, _, _) = makeViewModel(virtualizationService: virtService)
        let (starting, other) = appendMACAddressPair(to: viewModel)
        other.enter(.stopped)

        await viewModel.start(starting)

        #expect(virtService.startCallCount == 1)
        #expect(presenter.showError == false)
    }

    @Test("start proceeds when the MAC address twin runs on a different network mode")
    func startProceedsWhenMACAddressTwinIsOnAnotherMode() async {
        let virtService = MockVirtualizationService()
        let (viewModel, _, _, _, _) = makeViewModel(virtualizationService: virtService)
        let (starting, other) = appendMACAddressPair(
            to: viewModel, mode: .shared, otherMode: .hostOnly)
        other.enter(.running(sessionID: UUID()))

        await viewModel.start(starting)

        #expect(virtService.startCallCount == 1)
        #expect(presenter.showError == false)
    }

    @Test("start is refused for two bridged VMs whichever interface each names")
    func startBlockedByBridgedMACAddressTwinOnAnotherInterface() async {
        let virtService = MockVirtualizationService()
        let (viewModel, _, _, _, _) = makeViewModel(virtualizationService: virtService)
        let (starting, other) = appendMACAddressPair(
            to: viewModel, mode: .bridged, otherMode: .bridged)
        starting.configuration.bridgedInterfaceIdentifier = "en0"
        other.configuration.bridgedInterfaceIdentifier = "en1"
        other.enter(.running(sessionID: UUID()))

        await viewModel.start(starting)

        #expect(virtService.startCallCount == 0)
        #expect(presenter.errorTitle == "Duplicate MAC Address")
    }

    @Test("start proceeds when the starting VM has networking off")
    func startProceedsWhenStartingVMHasNetworkingOff() async {
        let virtService = MockVirtualizationService()
        let (viewModel, _, _, _, _) = makeViewModel(virtualizationService: virtService)
        let (starting, other) = appendMACAddressPair(to: viewModel)
        starting.configuration.networkEnabled = false
        other.enter(.running(sessionID: UUID()))

        await viewModel.start(starting)

        #expect(virtService.startCallCount == 1)
        #expect(presenter.showError == false)
    }

    @Test("start proceeds when the running MAC address twin has networking off")
    func startProceedsWhenMACAddressTwinHasNetworkingOff() async {
        let virtService = MockVirtualizationService()
        let (viewModel, _, _, _, _) = makeViewModel(virtualizationService: virtService)
        let (starting, other) = appendMACAddressPair(to: viewModel)
        other.configuration.networkEnabled = false
        other.enter(.running(sessionID: UUID()))

        await viewModel.start(starting)

        #expect(virtService.startCallCount == 1)
        #expect(presenter.showError == false)
    }

    @Test("start proceeds when the running VM's MAC address differs")
    func startProceedsWhenMACAddressesDiffer() async {
        let virtService = MockVirtualizationService()
        let (viewModel, _, _, _, _) = makeViewModel(virtualizationService: virtService)
        let (starting, other) = appendMACAddressPair(
            to: viewModel, otherMAC: "aa:bb:cc:dd:ee:02")
        other.enter(.running(sessionID: UUID()))

        await viewModel.start(starting)

        #expect(virtService.startCallCount == 1)
        #expect(presenter.showError == false)
    }

    @Test("the boot refusal matches the held MAC address regardless of case")
    func startRefusalIgnoresMACAddressCase() async {
        let virtService = MockVirtualizationService()
        let (viewModel, _, _, _, _) = makeViewModel(virtualizationService: virtService)
        let (starting, other) = appendMACAddressPair(
            to: viewModel, mac: "aa:bb:cc:dd:ee:01", otherMAC: "AA:BB:CC:DD:EE:01")
        other.enter(.running(sessionID: UUID()))

        await viewModel.start(starting)

        #expect(virtService.startCallCount == 0)
        #expect(presenter.errorTitle == "Duplicate MAC Address")
    }

    @Test("a cold resume is refused while a MAC address twin is running")
    func coldResumeBlockedByRunningMACAddressTwin() async {
        let virtService = MockVirtualizationService()
        let (viewModel, _, _, _, _) = makeViewModel(virtualizationService: virtService)
        let (resuming, other) = appendMACAddressPair(to: viewModel)
        resuming.enter(.suspended)
        other.enter(.running(sessionID: UUID()))

        await viewModel.resume(resuming)

        #expect(virtService.resumeCallCount == 0)
        #expect(presenter.errorTitle == "Duplicate MAC Address")
        #expect(resuming.status == .paused)
    }

    @Test("a hot resume is never refused — the live VM already holds the address")
    func hotResumeIsNotBlockedByMACAddressTwin() async {
        let virtService = MockVirtualizationService()
        let (viewModel, _, _, _, _) = makeViewModel(virtualizationService: virtService)
        let (resuming, other) = appendMACAddressPair(to: viewModel)
        resuming.enter(.livePaused(sessionID: UUID()))
        other.enter(.running(sessionID: UUID()))

        await viewModel.resume(resuming)

        #expect(virtService.resumeCallCount == 1)
        #expect(presenter.showError == false)
    }

    @Test("a start that dispatches to macOS guest setup is refused before the installer runs")
    func macOSSetupStartBlockedByRunningMACAddressTwin() async {
        let virtService = MockVirtualizationService()
        let (viewModel, _, _, _, _) = makeViewModel(virtualizationService: virtService)
        let (starting, other) = appendMACAddressPair(to: viewModel)
        starting.configuration.installContext = MacOSInstallContext(
            source: .localFile, localIPSWPath: "/tmp/foo.ipsw")
        starting.enter(.initialBoot)
        other.enter(.running(sessionID: UUID()))

        await viewModel.start(starting)

        // The installer builds and runs its own VZ virtual machine, so the
        // refusal has to land before guest setup is dispatched at all.
        #expect(starting.setupTask == nil)
        #expect(virtService.startCallCount == 0)
        #expect(presenter.errorTitle == "Duplicate MAC Address")
    }

    @Test("a live mode switch onto a MAC address twin's network is refused, changing nothing")
    func liveModeSwitchOntoAMACAddressTwinIsRefused() {
        let (viewModel, _, _, _, _) = makeViewModel()
        let (switching, other) = appendMACAddressPair(
            to: viewModel, mode: .hostOnly, otherMode: .shared)
        // Both run: the start guard allowed it, the modes being different.
        switching.enter(.running(sessionID: UUID()))
        other.enter(.running(sessionID: UUID()))

        let accepted = viewModel.updateConfiguration(of: switching) { $0.networkMode = .shared }

        #expect(accepted == false)
        #expect(switching.configuration.networkMode == .hostOnly)
        #expect(presenter.errorTitle == "Duplicate MAC Address")
    }

    @Test("a stopped VM may take the mode a live MAC address twin is on — its start is the guard")
    func stoppedVMMayTakeALiveMACAddressTwinsMode() {
        let (viewModel, _, _, _, _) = makeViewModel()
        let (switching, other) = appendMACAddressPair(
            to: viewModel, mode: .hostOnly, otherMode: .shared)
        switching.enter(.stopped)
        other.enter(.running(sessionID: UUID()))

        let accepted = viewModel.updateConfiguration(of: switching) { $0.networkMode = .shared }

        #expect(accepted)
        #expect(switching.configuration.networkMode == .shared)
        #expect(presenter.showError == false)
    }

    @Test("a live VM already sharing a network with its twin stays editable")
    func aVMAlreadyInAMACAddressCollisionStaysEditable() {
        let (viewModel, _, _, _, _) = makeViewModel()
        let (switching, other) = appendMACAddressPair(to: viewModel)
        switching.enter(.running(sessionID: UUID()))
        other.enter(.running(sessionID: UUID()))

        let accepted = viewModel.updateConfiguration(of: switching) { $0.memorySizeInGB = 6 }

        #expect(accepted)
        #expect(switching.configuration.memorySizeInGB == 6)
        #expect(presenter.showError == false)
    }

    // MARK: - Duplicate MAC Address Admission

    /// Two on-disk bundles carrying `mac`, in a storage mock — the hand-copied
    /// pair every admission path has to take.
    private func makeStorageWithMACAddressPair(mac: String = "aa:bb:cc:dd:ee:01")
        -> MockVMStorageService
    {
        let storage = MockVMStorageService()
        for name in ["First VM", "Second VM"] {
            var config = VMConfiguration(name: name, guestOS: .linux, bootMode: .efi)
            config.macAddress = mac
            let bundleURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(config.id.uuidString).kernova", isDirectory: true)
            storage.bundles[bundleURL] = config
        }
        return storage
    }

    @Test("loadVMs admits both bundles sharing a MAC address, without an error")
    func loadAdmitsBundlesSharingAMACAddress() async {
        let storage = makeStorageWithMACAddressPair()
        let (viewModel, _, _, _, _) = makeViewModel(storageService: storage)

        await viewModel.loadVMs()

        #expect(viewModel.instances.count == 2)
        #expect(presenter.showError == false)
    }

    @Test("reconcileWithDisk admits a discovered bundle whose MAC address is already held")
    func reconcileAdmitsABundleSharingAMACAddress() {
        let storage = makeStorageWithMACAddressPair()
        let (viewModel, _, _, _, _) = makeViewModel(storageService: storage)

        viewModel.reconcileWithDisk()

        #expect(viewModel.instances.count == 2)
        #expect(presenter.showError == false)
    }

    @Test("vmNamesSharingMACAddress names the other holders, regardless of case")
    func vmNamesSharingMACAddressNamesOtherHolders() {
        let (viewModel, _, _, _, _) = makeViewModel()
        let (starting, _) = appendMACAddressPair(
            to: viewModel, mac: "aa:bb:cc:dd:ee:01", otherMAC: "AA:BB:CC:DD:EE:01")

        #expect(viewModel.vmNamesSharingMACAddress(with: starting) == ["Twin"])
    }

    @Test("vmNamesSharingMACAddress is empty when the address is the VM's alone")
    func vmNamesSharingMACAddressIsEmptyWhenUnique() {
        let (viewModel, _, _, _, _) = makeViewModel()
        let (starting, _) = appendMACAddressPair(
            to: viewModel, otherMAC: "aa:bb:cc:dd:ee:02")

        #expect(viewModel.vmNamesSharingMACAddress(with: starting).isEmpty)
    }

    @Test("vmNamesSharingMACAddress counts a holder whose networking is off")
    func vmNamesSharingMACAddressCountsANetworkingOffHolder() {
        let (viewModel, _, _, _, _) = makeViewModel()
        let (starting, other) = appendMACAddressPair(to: viewModel)
        other.configuration.networkEnabled = false

        #expect(viewModel.vmNamesSharingMACAddress(with: starting) == ["Twin"])
    }

    // MARK: - Match-Window Boot Resolution

    /// Hands `start` a fixed surface, standing in for the window/screen geometry
    /// `AppDelegate` measures.
    @MainActor
    private final class FakeDisplayBootGeometryProvider: DisplayBootGeometryProviding {
        var surface: DisplayBootSurface?
        private(set) var callCount = 0

        init(surface: DisplayBootSurface?) {
            self.surface = surface
        }

        func displayBootSurface(for instance: VMInstance) -> DisplayBootSurface? {
            callCount += 1
            return surface
        }
    }

    /// A VM whose display is sized to its window at every cold start, at the
    /// screen's scale — both defaults.
    private func makeMatchWindowInstance(guestOS: VMGuestOS = .macOS) -> VMInstance {
        makeInstance(guestOS: guestOS)
    }

    private static let retinaSurface = DisplayBootSurface(
        pointSize: CGSize(width: 1400, height: 880), backingScaleFactor: 2)

    @Test("A match-window cold boot persists the computed resolution before starting")
    func matchWindowWritesResolutionBeforeStart() async {
        let (viewModel, storage, _, virtService, _) = makeViewModel()
        let provider = FakeDisplayBootGeometryProvider(surface: Self.retinaSurface)
        viewModel.displayBootGeometryProvider = provider
        let instance = makeMatchWindowInstance()
        viewModel.instances.append(instance)

        await viewModel.start(instance)

        #expect(provider.callCount == 1)
        // The VZ configuration is built inside `start`, so the values must
        // already be on the instance when the service is called.
        #expect(virtService.configurationAtStart?.displayWidth == 2800)
        #expect(virtService.configurationAtStart?.displayHeight == 1760)
        #expect(virtService.configurationAtStart?.displayPPI == DisplayBootSizing.hiDPIPixelsPerInch)
        #expect(instance.configuration.displayWidth == 2800)
        // Persisted, so a later restore sees the same geometry.
        #expect(storage.bundles[instance.bundleURL]?.displayWidth == 2800)
    }

    @Test("A match-window boot with HiDPI off fills the window at 1×")
    func matchWindowAtStandardDensityWhenHiDPIOff() async {
        let (viewModel, _, _, virtService, _) = makeViewModel()
        let provider = FakeDisplayBootGeometryProvider(surface: Self.retinaSurface)
        viewModel.displayBootGeometryProvider = provider
        let instance = makeMatchWindowInstance()
        instance.configuration.displayHiDPI = false
        viewModel.instances.append(instance)

        await viewModel.start(instance)

        // Same points as `matchWindowWritesResolutionBeforeStart`, measured at
        // 1× instead of the surface's 2×.
        #expect(virtService.configurationAtStart?.displayWidth == 1400)
        #expect(virtService.configurationAtStart?.displayHeight == 880)
        #expect(virtService.configurationAtStart?.displayPPI == DisplayBootSizing.standardPixelsPerInch)
    }

    @Test("A Linux match-window boot ignores the screen scale")
    func matchWindowIsOneToOneForLinux() async {
        let (viewModel, _, _, virtService, _) = makeViewModel()
        // Held in a local: the view model's reference is weak.
        let provider = FakeDisplayBootGeometryProvider(surface: Self.retinaSurface)
        viewModel.displayBootGeometryProvider = provider
        let instance = makeMatchWindowInstance(guestOS: .linux)
        viewModel.instances.append(instance)

        await viewModel.start(instance)

        // A virtio scanout has no density channel, so points map to pixels 1:1.
        #expect(virtService.configurationAtStart?.displayWidth == 1400)
        #expect(virtService.configurationAtStart?.displayHeight == 880)
        #expect(virtService.configurationAtStart?.displayPPI == DisplayBootSizing.standardPixelsPerInch)
    }

    @Test("A saved-state VM keeps its resolution so the restore stays valid")
    func matchWindowSkippedWhenSaveFileExists() async throws {
        let (viewModel, _, _, virtService, _) = makeViewModel()
        let provider = FakeDisplayBootGeometryProvider(surface: Self.retinaSurface)
        viewModel.displayBootGeometryProvider = provider
        let instance = makeMatchWindowInstance()
        try FileManager.default.createDirectory(
            at: instance.bundleURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: instance.bundleURL) }
        try Data().write(to: instance.saveFileURL)
        viewModel.instances.append(instance)

        await viewModel.start(instance)

        // The surface is never even measured — the save file settles it.
        #expect(provider.callCount == 0)
        #expect(virtService.configurationAtStart?.displayWidth == 1920)
        #expect(virtService.configurationAtStart?.displayHeight == 1200)
    }

    @Test("A VM with match-window off boots at its configured resolution")
    func matchWindowOffLeavesResolutionAlone() async {
        let (viewModel, _, _, virtService, _) = makeViewModel()
        let provider = FakeDisplayBootGeometryProvider(surface: Self.retinaSurface)
        viewModel.displayBootGeometryProvider = provider
        let instance = makeInstance()
        instance.configuration.displaySizesToWindow = false
        viewModel.instances.append(instance)

        await viewModel.start(instance)

        #expect(provider.callCount == 0)
        #expect(virtService.configurationAtStart?.displayWidth == 1920)
        #expect(virtService.configurationAtStart?.displayHeight == 1200)
    }

    @Test("A match-window resolution that can't be persisted is rolled back before the boot")
    func matchWindowRollsBackWhenPersistFails() async {
        let (viewModel, storage, _, virtService, _) = makeViewModel()
        let provider = FakeDisplayBootGeometryProvider(surface: Self.retinaSurface)
        viewModel.displayBootGeometryProvider = provider
        let instance = makeMatchWindowInstance()
        let original = instance.configuration.displayResolution
        viewModel.instances.append(instance)
        storage.saveConfigurationError = NSError(domain: "test", code: 1)

        await viewModel.start(instance)

        // Booting at a resolution disk never received would invalidate the save
        // file a later suspend writes, so the whole trio reverts.
        #expect(instance.configuration.displayResolution == original)
        #expect(virtService.configurationAtStart?.displayWidth == original.width)
        #expect(virtService.configurationAtStart?.displayHeight == original.height)
        #expect(virtService.configurationAtStart?.displayPPI == original.ppi)
        // The boot is not abandoned over a failed settings write.
        #expect(virtService.startCallCount == 1)
        #expect(instance.status == .running)
    }

    @Test("An unmeasurable surface boots at the configured resolution")
    func matchWindowWithoutSurfaceStillStarts() async {
        let (viewModel, _, _, virtService, _) = makeViewModel()
        let provider = FakeDisplayBootGeometryProvider(surface: nil)
        viewModel.displayBootGeometryProvider = provider
        let instance = makeMatchWindowInstance()
        viewModel.instances.append(instance)

        await viewModel.start(instance)

        #expect(provider.callCount == 1)
        #expect(virtService.startCallCount == 1)
        #expect(instance.status == .running)
        #expect(instance.configuration.displayWidth == 1920)
        #expect(instance.configuration.displayHeight == 1200)
    }

    // MARK: - Error Handling

    @Test("start presents error on service failure")
    func startPresentsError() async {
        let virtService = MockVirtualizationService()
        virtService.startError = VirtualizationError.noVirtualMachine
        let (viewModel, _, _, _, _) = makeViewModel(virtualizationService: virtService)
        let instance = makeInstance()

        await viewModel.start(instance)

        #expect(presenter.showError == true)
        #expect(presenter.errorMessage != nil)
        // A failure with no explanation of its own keeps the generic title.
        #expect(presenter.errorTitle == "Error")
    }

    @Test("start offers removal when a removable media attach fails")
    func startOffersRemovalOnRemovableMediaAttachFailure() async {
        let virtService = MockVirtualizationService()
        let (viewModel, _, _, _, _) = makeViewModel(virtualizationService: virtService)
        let instance = makeInstance()
        let item = RemovableMediaItem(path: "/tmp/stale.iso", readOnly: true, label: "Stale ISO")
        instance.configuration.removableMedia = [item]
        viewModel.instances.append(instance)
        virtService.startError = ConfigurationBuilderError.removableMediaAttachFailed(
            id: item.id, path: item.path, label: item.label,
            underlying: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOTSUP)))

        await viewModel.start(instance)

        // The actionable alert is presented instead of the generic error.
        #expect(presenter.startFailedAttachments.count == 1)
        #expect(presenter.startFailedAttachments.first?.kind == .removableMedia)
        #expect(presenter.startFailedAttachments.first?.id == item.id)
        #expect(presenter.startFailedAttachments.first?.label == "Stale ISO")
        #expect(presenter.errors.isEmpty)
    }

    @Test("removeStartFailedAttachmentAndStart detaches the item and retries the start")
    func removeStartFailedAttachmentAndStartRetries() async {
        let virtService = MockVirtualizationService()
        let (viewModel, _, _, _, _) = makeViewModel(virtualizationService: virtService)
        let instance = makeInstance()
        let item = RemovableMediaItem(path: "/tmp/stale.iso", readOnly: true, label: "Stale ISO")
        instance.configuration.removableMedia = [item]
        viewModel.instances.append(instance)
        instance.enter(.failed(message: "Test failure"))  // where a failed start leaves the VM

        let failure = StartFailedAttachment(
            kind: .removableMedia, id: item.id, label: item.label, message: "test")
        await viewModel.removeStartFailedAttachmentAndStart(failure, on: instance)

        #expect(instance.configuration.removableMedia == nil)
        #expect(virtService.startCallCount == 1)
        #expect(instance.status == .running)
        // Detach only — nothing was trashed.
        #expect(fileSystem.trashedURLs.isEmpty)
    }

    @Test("removeStartFailedAttachmentAndStart discards a saved state it can no longer restore")
    func removeStartFailedAttachmentDiscardsSaveFile() async throws {
        let virtService = MockVirtualizationService()
        let (viewModel, _, _, _, _) = makeViewModel(virtualizationService: virtService)
        let instance = makeInstance()
        let item = RemovableMediaItem(path: "/tmp/stale.iso", readOnly: true, label: "Stale ISO")
        instance.configuration.removableMedia = [item]
        viewModel.instances.append(instance)
        instance.enter(.failed(message: "Test failure"))  // a failed cold resume leaves the VM here, save file intact
        try FileManager.default.createDirectory(
            at: instance.bundleURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: instance.bundleURL) }
        FileManager.default.createFile(
            atPath: instance.saveFileURL.path(percentEncoded: false),
            contents: Data("fake save".utf8))

        let failure = StartFailedAttachment(
            kind: .removableMedia, id: item.id, label: item.label, message: "test")
        await viewModel.removeStartFailedAttachmentAndStart(failure, on: instance)

        // The save restores only into the saved device set, so the confirmed
        // repair discards it and the retried start cold-boots.
        #expect(!instance.hasSaveFile)
        #expect(virtService.startCallCount == 1)
        #expect(instance.status == .running)
    }

    @Test("start keeps the generic error when the main disk attach fails")
    func startMainDiskAttachFailureStaysGeneric() async {
        let virtService = MockVirtualizationService()
        let (viewModel, _, _, _, _) = makeViewModel(virtualizationService: virtService)
        let instance = makeInstance()
        viewModel.instances.append(instance)
        // The synthesized main disk is what a nil storageDisks list resolves to.
        let mainDisk = ConfigurationBuilder.defaultMainDisk(
            layout: VMBundleLayout(bundleURL: instance.bundleURL))
        virtService.startError = ConfigurationBuilderError.storageDiskAttachFailed(
            id: mainDisk.id, path: mainDisk.path, label: mainDisk.label,
            underlying: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOTSUP)))

        await viewModel.start(instance)

        // Removing the boot disk can't fix the VM, so no removal offer.
        #expect(presenter.startFailedAttachments.isEmpty)
        #expect(presenter.showError == true)
    }

    @Test("start offers removal when an external storage disk attach fails")
    func startOffersRemovalOnExternalDiskAttachFailure() async {
        let virtService = MockVirtualizationService()
        let (viewModel, _, _, _, _) = makeViewModel(virtualizationService: virtService)
        let instance = makeInstance()
        let layout = VMBundleLayout(bundleURL: instance.bundleURL)
        let external = StorageDisk(
            id: UUID(), path: "/tmp/gone.img", readOnly: false, label: "External",
            isInternal: false, kind: .virtio)
        instance.configuration.storageDisks = [
            ConfigurationBuilder.defaultMainDisk(layout: layout), external,
        ]
        viewModel.instances.append(instance)
        virtService.startError = ConfigurationBuilderError.storageDiskAttachFailed(
            id: external.id, path: external.path, label: external.label,
            underlying: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOTSUP)))

        await viewModel.start(instance)

        #expect(presenter.startFailedAttachments.count == 1)
        #expect(presenter.startFailedAttachments.first?.kind == .storageDisk)
        #expect(presenter.startFailedAttachments.first?.id == external.id)
        #expect(presenter.errors.isEmpty)
    }

    @Test("start does not offer removal for transient file-lock contention")
    func startDoesNotOfferRemovalForLockContention() async {
        let virtService = MockVirtualizationService()
        let (viewModel, _, _, _, _) = makeViewModel(virtualizationService: virtService)
        let instance = makeInstance()
        let item = RemovableMediaItem(path: "/tmp/shared.iso", readOnly: true, label: "Shared ISO")
        instance.configuration.removableMedia = [item]
        viewModel.instances.append(instance)
        // Contention means the file is fine and a dying VM still holds the
        // lock — offering to detach a working attachment would be wrong.
        virtService.startError = ConfigurationBuilderError.removableMediaAttachFailed(
            id: item.id, path: item.path, label: item.label,
            underlying: NSError(
                domain: VZError.errorDomain,
                code: VZError.Code.invalidVirtualMachineConfiguration.rawValue,
                userInfo: [
                    NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EAGAIN))
                ]))

        await viewModel.start(instance)

        #expect(presenter.startFailedAttachments.isEmpty)
        #expect(presenter.showError == true)
        #expect(instance.configuration.removableMedia?.count == 1)
    }

    @Test("removeStartFailedAttachmentAndStart ignores an already-deleted VM")
    func removeStartFailedAttachmentIgnoresDeletedVM() async {
        let virtService = MockVirtualizationService()
        let (viewModel, _, _, _, _) = makeViewModel(virtualizationService: virtService)
        let instance = makeInstance()
        let item = RemovableMediaItem(path: "/tmp/stale.iso", readOnly: true, label: "Stale ISO")
        instance.configuration.removableMedia = [item]
        // Never added to `instances` — models the VM being deleted while the
        // alert sat queued behind another sheet.

        let failure = StartFailedAttachment(
            kind: .removableMedia, id: item.id, label: item.label, message: "test")
        await viewModel.removeStartFailedAttachmentAndStart(failure, on: instance)

        // No config write to a deleted bundle, and no boot.
        #expect(instance.configuration.removableMedia?.count == 1)
        #expect(virtService.startCallCount == 0)
    }

    @Test("removeStartFailedAttachmentAndStart does not retry when the entry is already gone")
    func removeStartFailedAttachmentSkipsRetryWhenEntryGone() async {
        let virtService = MockVirtualizationService()
        let (viewModel, _, _, _, _) = makeViewModel(virtualizationService: virtService)
        let instance = makeInstance()
        viewModel.instances.append(instance)

        // The user removed it in Settings before confirming the alert. Retrying
        // would re-raise the same failure and re-present this alert forever.
        let failure = StartFailedAttachment(
            kind: .removableMedia, id: UUID(), label: "Stale ISO", message: "test")
        await viewModel.removeStartFailedAttachmentAndStart(failure, on: instance)

        #expect(virtService.startCallCount == 0)
    }

    @Test("start keeps the generic error when the failing media is no longer configured")
    func startStaysGenericWhenMediaNotConfigured() async {
        let virtService = MockVirtualizationService()
        let (viewModel, _, _, _, _) = makeViewModel(virtualizationService: virtService)
        let instance = makeInstance()
        viewModel.instances.append(instance)
        virtService.startError = ConfigurationBuilderError.removableMediaAttachFailed(
            id: UUID(), path: "/tmp/ghost.iso", label: "Ghost",
            underlying: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOTSUP)))

        await viewModel.start(instance)

        // An offer whose action could only no-op is worse than the plain error.
        #expect(presenter.startFailedAttachments.isEmpty)
        #expect(presenter.showError == true)
    }

    // MARK: - Running-VM Limit Explanation

    @Test("start explains the running-VM limit and leaves the VM stopped")
    func startExplainsRunningVMLimit() async {
        let virtService = MockVirtualizationService()
        virtService.startError = makeVMLimitExceededError()
        let (viewModel, _, _, _, _) = makeViewModel(virtualizationService: virtService)
        let instance = makeInstance(name: "Ubuntu")
        viewModel.instances.append(instance)

        await viewModel.start(instance)

        #expect(presenter.errorTitle == "Couldn't Start “Ubuntu”")
        #expect(presenter.errorMessage?.contains("Stop another virtual machine") == true)
        // Transient: nothing red, and no message left behind for the banner.
        #expect(instance.status == .stopped)
        #expect(instance.errorMessage == nil)
    }

    @Test("An install that hits the running-VM limit explains it and stays in .initialBoot")
    func installExplainsRunningVMLimit() async {
        let installService = MockMacOSInstallService()
        installService.installError = makeInstallVMLimitExceededError()
        let storage = MockVMStorageService()
        let viewModel = VMLibraryViewModel(
            storageService: storage,
            diskImageService: MockDiskImageService(),
            virtualizationService: MockVirtualizationService(),
            installService: installService,
            ipswService: MockIPSWService(),
            usbDeviceService: MockUSBDeviceService(),
            fileSystem: fileSystem,
            preferences: preferences
        )
        viewModel.presenter = presenter
        let instance = makeInstance(name: "Sequoia", guestOS: .macOS)
        instance.configuration.installContext = MacOSInstallContext(
            source: .localFile, localIPSWPath: "/tmp/foo.ipsw")
        instance.onUpdateConfiguration = { mutate in mutate(&instance.configuration) }
        instance.enter(.initialBoot)
        viewModel.instances.append(instance)
        storage.bundles[instance.bundleURL] = instance.configuration

        await viewModel.start(instance)
        await instance.setupTask?.value

        #expect(presenter.errorTitle == "Couldn't Install “Sequoia”")
        #expect(presenter.errorMessage?.contains("at most two macOS virtual machines") == true)
        // The verb names the button actually on screen for this VM.
        #expect(presenter.errorMessage?.contains("click Install to try again") == true)
        #expect(instance.status == .initialBoot)
        #expect(instance.errorMessage == nil)
        #expect(instance.setupState == nil)
    }

    @Test("An attachment failure wrapping the limit code still offers removal")
    func attachmentFailureWinsOverLimitExplanation() async {
        let virtService = MockVirtualizationService()
        let (viewModel, _, _, _, _) = makeViewModel(virtualizationService: virtService)
        let instance = makeInstance()
        let item = RemovableMediaItem(path: "/tmp/stale.iso", readOnly: true, label: "Stale ISO")
        instance.configuration.removableMedia = [item]
        viewModel.instances.append(instance)
        virtService.startError = ConfigurationBuilderError.removableMediaAttachFailed(
            id: item.id, path: item.path, label: item.label,
            underlying: makeVMLimitExceededError())

        await viewModel.start(instance)

        // The removal offer is the more actionable surface, and a builder error
        // is permanent regardless of what it wraps.
        #expect(presenter.startFailedAttachments.count == 1)
        #expect(presenter.errors.isEmpty)
    }

    @Test("forceStop presents error on service failure")
    func forceStopPresentsError() async {
        let virtService = MockVirtualizationService()
        virtService.forceStopError = VirtualizationError.noVirtualMachine
        let (viewModel, _, _, _, _) = makeViewModel(virtualizationService: virtService)
        let instance = makeInstance()

        await viewModel.forceStop(instance)

        #expect(presenter.showError == true)
        #expect(presenter.errorMessage != nil)
    }

    @Test("stop presents error on service failure")
    func stopPresentsError() async {
        let virtService = MockVirtualizationService()
        virtService.stopError = VirtualizationError.noVirtualMachine
        let (viewModel, _, _, _, _) = makeViewModel(virtualizationService: virtService)
        let instance = makeInstance()

        await viewModel.stop(instance)

        #expect(presenter.showError == true)
        #expect(presenter.errorMessage != nil)
    }

    // MARK: - Stop Paused Confirmation

    @Test("resumeAndStop dispatches resume then stop")
    func resumeAndStopDispatches() async {
        let (viewModel, _, _, virtService, _) = makeViewModel()
        let instance = makeInstance()
        instance.enter(.suspended)
        viewModel.instances.append(instance)

        await viewModel.resumeAndStop(instance)

        #expect(virtService.resumeCallCount == 1)
        #expect(virtService.stopCallCount == 1)
    }

    @Test("resumeAndStop clears confirmation state after dispatch")
    func resumeAndStopClearsConfirmationState() async {
        let (viewModel, _, _, _, _) = makeViewModel()
        let instance = makeInstance()
        instance.enter(.suspended)
        viewModel.instances.append(instance)

        await viewModel.resumeAndStop(instance)

        #expect(presenter.instanceToStopPaused == nil)
        #expect(presenter.showStopPausedConfirmation == false)
    }

    @Test("forceStopFromPaused dispatches forceStop and clears state")
    func forceStopFromPausedDispatches() async {
        let (viewModel, _, _, virtService, _) = makeViewModel()
        let instance = makeInstance()
        instance.enter(.suspended)
        viewModel.instances.append(instance)

        await viewModel.forceStop(instance)

        #expect(virtService.forceStopCallCount == 1)
        #expect(presenter.instanceToStopPaused == nil)
        #expect(presenter.showStopPausedConfirmation == false)
    }

    @Test("resumeAndStop presents error if resume fails")
    func resumeAndStopPresentsErrorOnResumeFailure() async {
        let virtService = MockVirtualizationService()
        virtService.resumeError = VirtualizationError.noVirtualMachine
        let (viewModel, _, _, _, _) = makeViewModel(virtualizationService: virtService)
        let instance = makeInstance()
        instance.enter(.suspended)

        await viewModel.resumeAndStop(instance)

        #expect(presenter.showError == true)
        #expect(virtService.stopCallCount == 0)
    }

    @Test("stop on running VM still delegates directly without confirmation")
    func stopRunningSkipsConfirmation() async {
        let (viewModel, _, _, virtService, _) = makeViewModel()
        let instance = makeInstance()
        instance.enter(.running(sessionID: UUID()))
        viewModel.instances.append(instance)

        await viewModel.stop(instance)

        #expect(virtService.stopCallCount == 1)
        #expect(presenter.showStopPausedConfirmation == false)
        #expect(presenter.instanceToStopPaused == nil)
    }

    @Test("pause presents error on service failure and leaves the guest running")
    func pausePresentsError() async {
        let virtService = MockVirtualizationService()
        virtService.pauseError = VirtualizationError.noVirtualMachine
        let (viewModel, _, _, _, _) = makeViewModel(virtualizationService: virtService)
        let instance = makeInstance()
        let sessionID = UUID()
        instance.enter(.running(sessionID: sessionID))

        await viewModel.pause(instance)

        #expect(presenter.showError == true)
        #expect(presenter.errorMessage != nil)
        // The pause did not take, so the VM is where it was and still names its
        // session — which is what keeps that session's later events, its
        // teardown hooks and its Ephemeral revert reachable, and keeps Stop and
        // Force Stop offered.
        #expect(instance.phase == .running(sessionID: sessionID))
        #expect(instance.canStop)
        #expect(instance.canForceStop)
    }

    @Test("resume presents error on service failure")
    func resumePresentsError() async {
        let virtService = MockVirtualizationService()
        virtService.resumeError = VirtualizationError.noVirtualMachine
        let (viewModel, _, _, _, _) = makeViewModel(virtualizationService: virtService)
        let instance = makeInstance()

        await viewModel.resume(instance)

        #expect(presenter.showError == true)
        #expect(presenter.errorMessage != nil)
    }

    @Test("save presents error on service failure")
    func savePresentsError() async {
        let virtService = MockVirtualizationService()
        virtService.saveError = VirtualizationError.noVirtualMachine
        let (viewModel, _, _, _, _) = makeViewModel(virtualizationService: virtService)
        let instance = makeInstance()

        await viewModel.save(instance)

        #expect(presenter.showError == true)
        #expect(presenter.errorMessage != nil)
    }

    // MARK: - Address Reservation Release

    /// A VM in the library already holding a reservation slot on its mode's
    /// network — the state a load leaves behind, without going through a scan.
    private func makeReservedInstance(
        in viewModel: VMLibraryViewModel, using vmnet: MockVmnetNetworkProvider,
        mac: String, mode: VMNetworkMode = .shared, name: String = "Test VM",
        rules: [PortForwardingRule] = []
    ) -> VMInstance {
        let instance = makeInstance(name: name)
        instance.configuration.networkEnabled = true
        instance.configuration.networkMode = mode
        instance.configuration.macAddress = mac
        instance.configuration.portForwardingRules = rules
        viewModel.instances.append(instance)
        if let kind = VmnetNetworkKind(mode: mode) {
            vmnet.reserveAddressIfNeeded(for: mac, kind: kind)
        }
        return instance
    }

    @Test("Deleting a VM releases its DHCP reservation slot")
    func deleteReleasesAddressReservation() async {
        let vmnet = MockVmnetNetworkProvider()
        let (viewModel, _, _, _, _) = makeViewModel(vmnetNetworks: vmnet)
        let instance = makeReservedInstance(in: viewModel, using: vmnet, mac: "aa:bb:cc:dd:ee:0f")

        await viewModel.delete(instance)

        #expect(vmnet.releasedMACs.map(\.mac) == ["aa:bb:cc:dd:ee:0f"])
        #expect(vmnet.reservedMACs.isEmpty)
    }

    @Test("A slot another VM still wants survives a delete")
    func deleteKeepsASlotADuplicateMACStillWants() async {
        let vmnet = MockVmnetNetworkProvider()
        let (viewModel, _, _, _, _) = makeViewModel(vmnetNetworks: vmnet)
        let first = makeReservedInstance(in: viewModel, using: vmnet, mac: "aa:bb:cc:dd:ee:0f")
        _ = makeReservedInstance(in: viewModel, using: vmnet, mac: "AA:BB:CC:DD:EE:0F")

        await viewModel.delete(first)

        #expect(vmnet.releasedMACs.isEmpty)
        #expect(vmnet.reservedMACs.map(\.mac) == ["aa:bb:cc:dd:ee:0f"])
    }

    @Test("Editing the MAC releases the retired slot before the new MAC takes one")
    func macAddressChangeReleasesTheRetiredSlotFirst() {
        let vmnet = MockVmnetNetworkProvider()
        let (viewModel, _, _, _, _) = makeViewModel(vmnetNetworks: vmnet)
        let instance = makeReservedInstance(in: viewModel, using: vmnet, mac: "aa:bb:cc:dd:ee:0f")

        viewModel.updateConfiguration(of: instance) { $0.macAddress = "aa:bb:cc:dd:ee:10" }

        // Release first, so the freed slot is the lowest one available and the
        // VM's reserved address does not move.
        #expect(vmnet.releasedMACs.map(\.mac) == ["aa:bb:cc:dd:ee:0f"])
        #expect(vmnet.reservedMACs.map(\.mac) == ["aa:bb:cc:dd:ee:10"])
    }

    @Test("Switching network mode releases the slot on the old kind")
    func modeSwitchReleasesTheOldKindsSlot() {
        let vmnet = MockVmnetNetworkProvider()
        let (viewModel, _, _, _, _) = makeViewModel(vmnetNetworks: vmnet)
        let instance = makeReservedInstance(in: viewModel, using: vmnet, mac: "aa:bb:cc:dd:ee:0f")

        viewModel.updateConfiguration(of: instance) { $0.networkMode = .hostOnly }

        #expect(vmnet.releasedMACs.map(\.kind) == [.shared])
        #expect(vmnet.reservedMACs.map(\.kind) == [.hostOnly])
    }

    @Test("Disabling networking releases the slot")
    func disablingNetworkingReleasesTheSlot() {
        let vmnet = MockVmnetNetworkProvider()
        let (viewModel, _, _, _, _) = makeViewModel(vmnetNetworks: vmnet)
        let instance = makeReservedInstance(in: viewModel, using: vmnet, mac: "aa:bb:cc:dd:ee:0f")

        viewModel.updateConfiguration(of: instance) { $0.networkEnabled = false }

        #expect(vmnet.releasedMACs.map(\.mac) == ["aa:bb:cc:dd:ee:0f"])
        #expect(vmnet.reservedMACs.isEmpty)
    }

    @Test("An unrelated configuration change releases nothing")
    func unrelatedChangeReleasesNothing() {
        let vmnet = MockVmnetNetworkProvider()
        let (viewModel, _, _, _, _) = makeViewModel(vmnetNetworks: vmnet)
        let instance = makeReservedInstance(in: viewModel, using: vmnet, mac: "aa:bb:cc:dd:ee:0f")

        viewModel.updateConfiguration(of: instance) { $0.name = "Renamed" }

        #expect(vmnet.releasedMACs.isEmpty)
        #expect(vmnet.reservedMACs.map(\.mac) == ["aa:bb:cc:dd:ee:0f"])
    }

    @Test("Loading the library frees slots no VM claims")
    func loadFreesSlotsNoVMClaims() async {
        let vmnet = MockVmnetNetworkProvider()
        let storage = MockVMStorageService()
        var config = VMConfiguration(name: "Kept", guestOS: .linux, bootMode: .efi)
        config.networkEnabled = true
        config.networkMode = .shared
        config.macAddress = "aa:bb:cc:dd:ee:0f"
        storage.bundles[
            FileManager.default.temporaryDirectory
                .appendingPathComponent("\(config.id.uuidString).kernova", isDirectory: true)
        ] = config
        let (viewModel, _, _, _, _) = makeViewModel(storageService: storage, vmnetNetworks: vmnet)
        // A slot left behind by a VM trashed while the app was not running.
        vmnet.reserveAddressIfNeeded(for: "aa:bb:cc:dd:ee:99", kind: .shared)

        await viewModel.loadVMs()

        #expect(vmnet.retainedMACs.first(where: { $0.kind == .shared })?.macs == ["aa:bb:cc:dd:ee:0f"])
        #expect(vmnet.retainedMACs.first(where: { $0.kind == .hostOnly })?.macs == [])
        #expect(vmnet.reservedMACs.map(\.mac) == ["aa:bb:cc:dd:ee:0f"])
    }

    @Test("A library that failed to read a bundle frees no slot")
    func loadWithAFailedBundleFreesNothing() async {
        let vmnet = MockVmnetNetworkProvider()
        let storage = MockVMStorageService()
        let config = VMConfiguration(name: "Unreadable", guestOS: .linux, bootMode: .efi)
        let failing = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(config.id.uuidString).kernova", isDirectory: true)
        storage.bundles[failing] = config
        storage.loadConfigurationFailURLs = [failing]
        let (viewModel, _, _, _, _) = makeViewModel(storageService: storage, vmnetNetworks: vmnet)
        vmnet.reserveAddressIfNeeded(for: "aa:bb:cc:dd:ee:99", kind: .shared)

        await viewModel.loadVMs()

        // The failed bundle's VM still exists, so its slot must not be reclaimed.
        #expect(vmnet.retainedMACs.isEmpty)
        #expect(vmnet.reservedMACs.map(\.mac) == ["aa:bb:cc:dd:ee:99"])
    }

    @Test("A reconcile keeps the slot of a VM whose bundle is on disk but unreadable")
    func reconcileKeepsTheSlotOfAnUnreadableBundle() {
        let vmnet = MockVmnetNetworkProvider()
        let storage = MockVMStorageService()
        let (viewModel, _, _, _, _) = makeViewModel(storageService: storage, vmnetNetworks: vmnet)
        let instance = makeReservedInstance(in: viewModel, using: vmnet, mac: "aa:bb:cc:dd:ee:0f")
        // The bundle is still on disk; only its configuration stopped parsing,
        // so the VM leaves the library but has not gone away.
        storage.bundles[instance.bundleURL] = instance.configuration
        storage.loadConfigurationFailURLs = [instance.bundleURL]

        viewModel.reconcileWithDisk()

        #expect(viewModel.instances.isEmpty)
        #expect(vmnet.releasedMACs.isEmpty)
        #expect(vmnet.reservedMACs.map(\.mac) == ["aa:bb:cc:dd:ee:0f"])
    }

    @Test("A reconcile releases the slot of a VM whose bundle is gone")
    func reconcileReleasesTheSlotOfADeletedBundle() {
        let vmnet = MockVmnetNetworkProvider()
        let storage = MockVMStorageService()
        let (viewModel, _, _, _, _) = makeViewModel(storageService: storage, vmnetNetworks: vmnet)
        _ = makeReservedInstance(in: viewModel, using: vmnet, mac: "aa:bb:cc:dd:ee:0f")

        viewModel.reconcileWithDisk()

        #expect(viewModel.instances.isEmpty)
        #expect(vmnet.releasedMACs.map(\.mac) == ["aa:bb:cc:dd:ee:0f"])
    }

    @Test("An unentitled build neither releases nor prunes")
    func unentitledBuildLeavesReservationsAlone() async {
        let vmnet = MockVmnetNetworkProvider()
        let (viewModel, _, _, _, _) = makeViewModel(
            vmnetNetworks: vmnet, isVMNetworkingEntitled: false)
        let instance = makeInstance()
        instance.configuration.networkEnabled = true
        instance.configuration.networkMode = .shared
        instance.configuration.macAddress = "aa:bb:cc:dd:ee:0f"
        viewModel.instances = [instance]

        viewModel.updateConfiguration(of: instance) { $0.macAddress = "aa:bb:cc:dd:ee:10" }
        await viewModel.loadVMs()

        #expect(vmnet.releasedMACs.isEmpty)
        #expect(vmnet.retainedMACs.isEmpty)
    }

    // MARK: - MAC Address Uniqueness

    /// A library holding one VM on `held` and one on `editing`, both on the
    /// shared network — the starting point for every uniqueness assertion.
    private func makeLibrarySharingNoAddress(
        using vmnet: MockVmnetNetworkProvider, held: String, editing: String,
        storage: MockVMStorageService = MockVMStorageService()
    ) -> (VMLibraryViewModel, VMInstance, VMInstance) {
        let (viewModel, _, _, _, _) = makeViewModel(
            storageService: storage, vmnetNetworks: vmnet)
        let holder = makeReservedInstance(in: viewModel, using: vmnet, mac: held, name: "Holder")
        let editor = makeReservedInstance(
            in: viewModel, using: vmnet, mac: editing, name: "Editing VM")
        return (viewModel, holder, editor)
    }

    @Test("A MAC address another VM holds is refused, changing nothing")
    func duplicateMACAddressIsRefused() {
        let vmnet = MockVmnetNetworkProvider()
        let storage = MockVMStorageService()
        let (viewModel, _, editor) = makeLibrarySharingNoAddress(
            using: vmnet, held: "aa:bb:cc:dd:ee:0f", editing: "aa:bb:cc:dd:ee:10",
            storage: storage)

        let accepted = viewModel.updateConfiguration(of: editor) {
            $0.macAddress = "aa:bb:cc:dd:ee:0f"
        }

        #expect(accepted == false)
        #expect(editor.configuration.macAddress == "aa:bb:cc:dd:ee:10")
        #expect(storage.saveConfigurationCallCount == 0)
        #expect(vmnet.releasedMACs.isEmpty)
        #expect(vmnet.declaredForwardingRules.isEmpty)
        #expect(presenter.errorTitle == "MAC Address In Use")
        #expect(presenter.errorMessage?.contains("Holder") == true)
        #expect(presenter.errorMessage?.contains("aa:bb:cc:dd:ee:0f") == true)
    }

    @Test("The refusal matches the held address regardless of case")
    func duplicateMACAddressRefusalIgnoresCase() {
        let vmnet = MockVmnetNetworkProvider()
        let (viewModel, _, editor) = makeLibrarySharingNoAddress(
            using: vmnet, held: "AA:BB:CC:DD:EE:0F", editing: "aa:bb:cc:dd:ee:10")

        let accepted = viewModel.updateConfiguration(of: editor) {
            $0.macAddress = "aa:bb:cc:dd:ee:0f"
        }

        #expect(accepted == false)
        #expect(editor.configuration.macAddress == "aa:bb:cc:dd:ee:10")
    }

    @Test("A VM with networking off still holds its address")
    func aVMWithNetworkingOffStillHoldsItsAddress() {
        let vmnet = MockVmnetNetworkProvider()
        let (viewModel, holder, editor) = makeLibrarySharingNoAddress(
            using: vmnet, held: "aa:bb:cc:dd:ee:0f", editing: "aa:bb:cc:dd:ee:10")
        holder.configuration.networkEnabled = false

        let accepted = viewModel.updateConfiguration(of: editor) {
            $0.macAddress = "aa:bb:cc:dd:ee:0f"
        }

        #expect(accepted == false)
        #expect(editor.configuration.macAddress == "aa:bb:cc:dd:ee:10")
    }

    @Test("A refused mutation drops the fields it also set")
    func aRefusedMutationDropsItsOtherFields() {
        let vmnet = MockVmnetNetworkProvider()
        let (viewModel, _, editor) = makeLibrarySharingNoAddress(
            using: vmnet, held: "aa:bb:cc:dd:ee:0f", editing: "aa:bb:cc:dd:ee:10")

        let accepted = viewModel.updateConfiguration(of: editor) {
            $0.name = "Renamed"
            $0.macAddress = "aa:bb:cc:dd:ee:0f"
        }

        #expect(accepted == false)
        #expect(editor.configuration.name == "Editing VM")
        #expect(editor.configuration.macAddress == "aa:bb:cc:dd:ee:10")
    }

    @Test("A VM keeping an address that arrived shared still accepts other edits")
    func aVMSharingAnAddressFromDiskStillAcceptsEdits() {
        let vmnet = MockVmnetNetworkProvider()
        let (viewModel, _, editor) = makeLibrarySharingNoAddress(
            using: vmnet, held: "aa:bb:cc:dd:ee:0f", editing: "aa:bb:cc:dd:ee:0f")

        // Only a change of address is refused, so a pair that arrived from disk
        // sharing one stays editable in every other respect.
        let accepted = viewModel.updateConfiguration(of: editor) { $0.name = "Renamed" }

        #expect(accepted)
        #expect(editor.configuration.name == "Renamed")
        #expect(!presenter.showError)
    }

    @Test("Moving the holder off an address frees it for another VM")
    func editingTheHolderFreesItsAddress() {
        let vmnet = MockVmnetNetworkProvider()
        let (viewModel, holder, editor) = makeLibrarySharingNoAddress(
            using: vmnet, held: "aa:bb:cc:dd:ee:0f", editing: "aa:bb:cc:dd:ee:10")

        viewModel.updateConfiguration(of: holder) { $0.macAddress = "aa:bb:cc:dd:ee:11" }
        let accepted = viewModel.updateConfiguration(of: editor) {
            $0.macAddress = "aa:bb:cc:dd:ee:0f"
        }

        #expect(accepted)
        #expect(editor.configuration.macAddress == "aa:bb:cc:dd:ee:0f")
        #expect(!presenter.showError)
    }

    @Test("Deleting the holder frees its address for another VM")
    func deletingTheHolderFreesItsAddress() async {
        let vmnet = MockVmnetNetworkProvider()
        let (viewModel, holder, editor) = makeLibrarySharingNoAddress(
            using: vmnet, held: "aa:bb:cc:dd:ee:0f", editing: "aa:bb:cc:dd:ee:10")

        await viewModel.delete(holder)
        let accepted = viewModel.updateConfiguration(of: editor) {
            $0.macAddress = "aa:bb:cc:dd:ee:0f"
        }

        #expect(accepted)
        #expect(editor.configuration.macAddress == "aa:bb:cc:dd:ee:0f")
        #expect(vmnet.reservedMACs.map(\.mac) == ["aa:bb:cc:dd:ee:0f"])
        #expect(!presenter.showError)
    }

    // MARK: - Port Forwarding Sync

    private static let webRule = PortForwardingRule(transport: .tcp, hostPort: 8080, guestPort: 80)
    private static let sshRule = PortForwardingRule(transport: .tcp, hostPort: 2222, guestPort: 22)

    @Test("A configuration change declares a shared VM's forwarding rules")
    func updateConfigurationDeclaresForwardingRules() {
        let vmnet = MockVmnetNetworkProvider()
        let (viewModel, _, _, _, _) = makeViewModel(vmnetNetworks: vmnet)
        let instance = makeInstance()

        viewModel.updateConfiguration(of: instance) {
            $0.networkEnabled = true
            $0.networkMode = .shared
            $0.macAddress = "AA:BB:CC:DD:EE:0F"
            $0.portForwardingRules = [Self.webRule]
        }

        #expect(vmnet.declaredForwardingRules.last?.mac == "aa:bb:cc:dd:ee:0f")
        #expect(vmnet.declaredForwardingRules.last?.rules == [Self.webRule])
    }

    @Test("Switching away from Shared Network withdraws the VM's forwarding rules")
    func modeSwitchWithdrawsForwardingRules() {
        let vmnet = MockVmnetNetworkProvider()
        let (viewModel, _, _, _, _) = makeViewModel(vmnetNetworks: vmnet)
        let instance = makeInstance()
        viewModel.updateConfiguration(of: instance) {
            $0.networkEnabled = true
            $0.networkMode = .shared
            $0.macAddress = "aa:bb:cc:dd:ee:0f"
            $0.portForwardingRules = [Self.webRule]
        }

        viewModel.updateConfiguration(of: instance) { $0.networkMode = .hostOnly }

        #expect(vmnet.declaredForwardingRules.last?.rules.isEmpty == true)
    }

    @Test("Editing the MAC address moves the rules to it and withdraws the old ones")
    func macAddressChangeMovesForwardingRules() {
        let vmnet = MockVmnetNetworkProvider()
        let (viewModel, _, _, _, _) = makeViewModel(vmnetNetworks: vmnet)
        let instance = makeInstance()
        viewModel.updateConfiguration(of: instance) {
            $0.networkEnabled = true
            $0.networkMode = .shared
            $0.macAddress = "aa:bb:cc:dd:ee:0f"
            $0.portForwardingRules = [Self.webRule]
        }

        viewModel.updateConfiguration(of: instance) { $0.macAddress = "aa:bb:cc:dd:ee:10" }

        // The retired address gives up its claim on the host port before the new
        // one declares the same rules, so nothing is dropped as a duplicate.
        #expect(
            vmnet.declaredForwardingRules.suffix(2).map(\.mac)
                == ["aa:bb:cc:dd:ee:0f", "aa:bb:cc:dd:ee:10"])
        #expect(vmnet.declaredForwardingRules.dropLast().last?.rules.isEmpty == true)
        #expect(vmnet.declaredForwardingRules.last?.rules == [Self.webRule])
        #expect(vmnet.reservedMACs.map(\.mac) == ["aa:bb:cc:dd:ee:10"])
    }

    @Test("Deleting a VM withdraws its forwarding rules")
    func deleteWithdrawsForwardingRules() async {
        let vmnet = MockVmnetNetworkProvider()
        let (viewModel, _, _, _, _) = makeViewModel(vmnetNetworks: vmnet)
        let instance = makeInstance()
        instance.configuration.networkEnabled = true
        instance.configuration.networkMode = .shared
        instance.configuration.macAddress = "aa:bb:cc:dd:ee:0f"
        instance.configuration.portForwardingRules = [Self.webRule]
        viewModel.instances = [instance]

        await viewModel.delete(instance)

        #expect(vmnet.declaredForwardingRules.last?.rules.isEmpty == true)
    }

    @Test("A pending rule change recreates the shared network once no VM is on it")
    func pendingRulesRecreateTheNetworkWhenIdle() {
        let vmnet = MockVmnetNetworkProvider()
        vmnet.scriptedPendingKinds = [.shared]
        let (viewModel, _, _, _, _) = makeViewModel(vmnetNetworks: vmnet)
        let instance = makeInstance()
        instance.configuration.networkEnabled = true
        instance.configuration.networkMode = .shared
        instance.configuration.macAddress = "aa:bb:cc:dd:ee:0f"
        viewModel.instances = [instance]

        viewModel.updateConfiguration(of: instance) { $0.portForwardingRules = [Self.webRule] }

        #expect(vmnet.invalidatedKinds == [.shared])
    }

    /// A stopped VM on the app-managed network of `mode`, in a library of its own.
    private func makeNetworkedLibrary(
        mode: VMNetworkMode, vmnet: MockVmnetNetworkProvider
    ) -> (VMLibraryViewModel, VMInstance) {
        let (viewModel, _, _, _, _) = makeViewModel(vmnetNetworks: vmnet)
        let instance = makeInstance()
        instance.configuration.networkEnabled = true
        instance.configuration.networkMode = mode
        instance.configuration.macAddress = "aa:bb:cc:dd:ee:0f"
        viewModel.instances = [instance]
        return (viewModel, instance)
    }

    @Test("A changed MAC recreates the shared network once no VM is on it")
    func macChangeRecreatesTheSharedNetworkWhenIdle() {
        let vmnet = MockVmnetNetworkProvider()
        vmnet.scriptedPendingKinds = [.shared]
        let (viewModel, instance) = makeNetworkedLibrary(mode: .shared, vmnet: vmnet)

        viewModel.updateConfiguration(of: instance) { $0.macAddress = "aa:bb:cc:dd:ee:10" }

        #expect(vmnet.invalidatedKinds == [.shared])
    }

    @Test("A Host Only VM's changed MAC recreates the Host Only network")
    func macChangeRecreatesTheHostOnlyNetwork() {
        let vmnet = MockVmnetNetworkProvider()
        vmnet.scriptedPendingKinds = [.hostOnly]
        let (viewModel, instance) = makeNetworkedLibrary(mode: .hostOnly, vmnet: vmnet)

        viewModel.updateConfiguration(of: instance) { $0.macAddress = "aa:bb:cc:dd:ee:10" }

        #expect(vmnet.invalidatedKinds == [.hostOnly])
    }

    @Test("A mode switch recreates both app-managed networks, each once")
    func modeSwitchRecreatesBothNetworks() {
        let vmnet = MockVmnetNetworkProvider()
        vmnet.scriptedPendingKinds = [.shared, .hostOnly]
        let (viewModel, instance) = makeNetworkedLibrary(mode: .shared, vmnet: vmnet)

        // The slot moves off one network and onto the other, so both carry a
        // reservation set the recreate has to install.
        viewModel.updateConfiguration(of: instance) { $0.networkMode = .hostOnly }

        #expect(Set(vmnet.invalidatedKinds) == [.shared, .hostOnly])
        #expect(vmnet.invalidatedKinds.count == 2)
    }

    @Test("Deleting a VM recreates the network its slot was on")
    func deleteRecreatesTheNetwork() async {
        let vmnet = MockVmnetNetworkProvider()
        vmnet.scriptedPendingKinds = [.shared]
        let (viewModel, instance) = makeNetworkedLibrary(mode: .shared, vmnet: vmnet)

        await viewModel.delete(instance)

        #expect(vmnet.invalidatedKinds == [.shared])
    }

    /// A library holding one shared-network VM per name, wired through the real
    /// load path so each instance carries its persistence hooks.
    private func makeSharedNetworkLibrary(
        named names: [String], vmnet: MockVmnetNetworkProvider
    ) async -> VMLibraryViewModel {
        let storage = MockVMStorageService()
        for name in names {
            var config = VMConfiguration(name: name, guestOS: .linux, bootMode: .efi)
            config.networkMode = .shared
            config.macAddress = VZMACAddress.randomLocallyAdministered().string
            storage.bundles[
                FileManager.default.temporaryDirectory
                    .appendingPathComponent("\(config.id.uuidString).kernova", isDirectory: true)
            ] = config
        }
        let (viewModel, _, _, _, _) = makeViewModel(storageService: storage, vmnetNetworks: vmnet)
        await viewModel.loadVMs()
        return viewModel
    }

    @Test("A live shared-network VM holds the recreate off until its session is torn down")
    func liveSharedVMDefersTheRecreate() async throws {
        let vmnet = MockVmnetNetworkProvider()
        let viewModel = await makeSharedNetworkLibrary(
            named: ["Running VM", "Edited VM"], vmnet: vmnet)
        let running = try #require(viewModel.instances.first { $0.name == "Running VM" })
        let edited = try #require(viewModel.instances.first { $0.name == "Edited VM" })
        running.enter(.running(sessionID: UUID()))
        vmnet.scriptedPendingKinds = [.shared]

        viewModel.updateConfiguration(of: edited) { $0.portForwardingRules = [Self.webRule] }
        #expect(vmnet.invalidatedKinds.isEmpty)

        // Releasing the session's virtual machine is what makes the recreate
        // safe.
        running.tearDownSession(restingAt: .stopped)

        #expect(vmnet.invalidatedKinds == [.shared])
    }

    @Test("A save-suspended VM releases the shared network for a pending rule change")
    func saveSuspendReleasesTheSharedNetwork() async throws {
        let vmnet = MockVmnetNetworkProvider()
        let viewModel = await makeSharedNetworkLibrary(
            named: ["Suspending VM", "Edited VM"], vmnet: vmnet)
        let suspending = try #require(viewModel.instances.first { $0.name == "Suspending VM" })
        let edited = try #require(viewModel.instances.first { $0.name == "Edited VM" })
        suspending.enter(.running(sessionID: UUID()))
        vmnet.scriptedPendingKinds = [.shared]

        viewModel.updateConfiguration(of: edited) { $0.portForwardingRules = [Self.webRule] }
        #expect(vmnet.invalidatedKinds.isEmpty)

        // A save-suspend rests suspended with nothing live, so the rebuild
        // rides the session teardown rather than any phase.
        await viewModel.save(suspending)

        #expect(suspending.status == .paused)
        #expect(vmnet.invalidatedKinds == [.shared])
    }

    @Test("A live switch out of Shared Network frees the network for the pending rebuild")
    func liveSwitchOutOfSharedFreesTheNetwork() async throws {
        let vmnet = MockVmnetNetworkProvider()
        let viewModel = await makeSharedNetworkLibrary(named: ["Running VM"], vmnet: vmnet)
        let running = try #require(viewModel.instances.first)
        running.enter(.running(sessionID: UUID()))
        vmnet.scriptedPendingKinds = [.shared]

        // The rule sync runs while the VM is still on the shared network; only
        // the mode write that follows frees it.
        viewModel.updateConfiguration(of: running) {
            $0.portForwardingRules = [Self.webRule]
        }
        #expect(vmnet.invalidatedKinds.isEmpty)

        viewModel.updateConfiguration(of: running) { $0.networkMode = .hostOnly }

        #expect(vmnet.invalidatedKinds == [.shared])
    }

    @Test("A VM arriving from the library load recreates its materialized network once")
    func loadedVMRecreatesTheMaterializedNetwork() async {
        let vmnet = MockVmnetNetworkProvider()
        vmnet.scriptedPendingKinds = [.shared]

        _ = await makeSharedNetworkLibrary(named: ["First VM", "Second VM"], vmnet: vmnet)

        // Each VM's slot is taken as it loads, but the first recreate leaves the
        // network unmaterialized — nothing pends against one that does not exist.
        #expect(vmnet.invalidatedKinds == [.shared])
    }

    @Test("A live VM holds a reservation recreate off until its session is torn down")
    func liveVMDefersTheReservationRecreate() async throws {
        let vmnet = MockVmnetNetworkProvider()
        let viewModel = await makeSharedNetworkLibrary(
            named: ["Running VM", "Edited VM"], vmnet: vmnet)
        let running = try #require(viewModel.instances.first { $0.name == "Running VM" })
        let edited = try #require(viewModel.instances.first { $0.name == "Edited VM" })
        running.enter(.running(sessionID: UUID()))
        vmnet.scriptedPendingKinds = [.shared]

        viewModel.updateConfiguration(of: edited) { $0.macAddress = "aa:bb:cc:dd:ee:11" }
        #expect(vmnet.invalidatedKinds.isEmpty)

        running.tearDownSession(restingAt: .stopped)

        #expect(vmnet.invalidatedKinds == [.shared])
    }

    @Test("A session torn down from a transitioning status still frees the network")
    func teardownFromATransitioningStatusStillRecreates() async throws {
        let vmnet = MockVmnetNetworkProvider()
        let viewModel = await makeSharedNetworkLibrary(
            named: ["Saving VM", "Edited VM"], vmnet: vmnet)
        let saving = try #require(viewModel.instances.first { $0.name == "Saving VM" })
        let edited = try #require(viewModel.instances.first { $0.name == "Edited VM" })
        saving.enter(.running(sessionID: UUID()))
        vmnet.scriptedPendingKinds = [.shared]

        viewModel.updateConfiguration(of: edited) { $0.macAddress = "aa:bb:cc:dd:ee:11" }
        #expect(vmnet.invalidatedKinds.isEmpty)

        // The teardown hook fires for a VM the scan must skip rather than
        // believe: it released the network in the same call that rested it.
        saving.enter(.saving(sessionID: UUID()))
        saving.tearDownSession(restingAt: .suspended)

        #expect(vmnet.invalidatedKinds == [.shared])
    }

    @Test("Deleting a VM leaves the rules of one sharing its address declared")
    func deleteKeepsADuplicateMACsForwardingRules() async {
        let vmnet = MockVmnetNetworkProvider()
        let (viewModel, _, _, _, _) = makeViewModel(vmnetNetworks: vmnet)
        let deleted = makeReservedInstance(
            in: viewModel, using: vmnet, mac: "aa:bb:cc:dd:ee:0f", name: "Deleted",
            rules: [Self.webRule])
        _ = makeReservedInstance(
            in: viewModel, using: vmnet, mac: "aa:bb:cc:dd:ee:0f", name: "Survivor",
            rules: [Self.sshRule])

        await viewModel.delete(deleted)

        // Rules are keyed on the address, so withdrawing the deleted VM's would
        // disarm the survivor's through the same key.
        #expect(vmnet.declaredForwardingRules.last?.mac == "aa:bb:cc:dd:ee:0f")
        #expect(vmnet.declaredForwardingRules.last?.rules == [Self.sshRule])
    }

    @Test("Editing a MAC leaves the rules of a VM sharing the retired address declared")
    func macAddressChangeKeepsADuplicateMACsForwardingRules() {
        let vmnet = MockVmnetNetworkProvider()
        let (viewModel, _, _, _, _) = makeViewModel(vmnetNetworks: vmnet)
        let edited = makeReservedInstance(
            in: viewModel, using: vmnet, mac: "aa:bb:cc:dd:ee:0f", name: "Edited",
            rules: [Self.webRule])
        _ = makeReservedInstance(
            in: viewModel, using: vmnet, mac: "aa:bb:cc:dd:ee:0f", name: "Survivor",
            rules: [Self.sshRule])

        viewModel.updateConfiguration(of: edited) { $0.macAddress = "aa:bb:cc:dd:ee:10" }

        #expect(
            vmnet.declaredForwardingRules.suffix(2).map(\.mac)
                == ["aa:bb:cc:dd:ee:0f", "aa:bb:cc:dd:ee:10"])
        #expect(vmnet.declaredForwardingRules.dropLast().last?.rules == [Self.sshRule])
        #expect(vmnet.declaredForwardingRules.last?.rules == [Self.webRule])
    }

    // MARK: - trySave / tryForceStop

    @Test("trySave throws on failure")
    func trySaveThrows() async {
        let virtService = MockVirtualizationService()
        virtService.saveError = VirtualizationError.noVirtualMachine
        let (viewModel, _, _, _, _) = makeViewModel(virtualizationService: virtService)
        let instance = makeInstance()
        instance.enter(.running(sessionID: UUID()))
        viewModel.instances.append(instance)

        await #expect(throws: CommandError.self) {
            try await viewModel.trySave(instance)
        }
    }

    @Test("tryForceStop throws on failure")
    func tryForceStopThrows() async {
        let virtService = MockVirtualizationService()
        virtService.forceStopError = VirtualizationError.noVirtualMachine
        let (viewModel, _, _, _, _) = makeViewModel(virtualizationService: virtService)
        let instance = makeInstance()
        instance.enter(.running(sessionID: UUID()))
        viewModel.instances.append(instance)

        await #expect(throws: CommandError.self) {
            try await viewModel.tryForceStop(instance)
        }
    }

    // MARK: - Create VM

    @Test("createVM creates bundle, disk image, and adds instance")
    func createVMAddsInstance() async {
        let (viewModel, storage, diskService, _, _) = makeViewModel()
        let wizard = VMCreationViewModel()
        wizard.selectedOS = .linux
        wizard.selectedBootMode = .efi
        wizard.vmName = "New Linux VM"

        await viewModel.createVM(from: wizard)

        #expect(viewModel.instances.count == 1)
        #expect(viewModel.instances.first?.name == "New Linux VM")
        #expect(storage.createVMBundleCallCount == 1)
        #expect(diskService.createDiskImageCallCount == 1)
    }

    @Test("createVM selects newly created instance")
    func createVMSelectsInstance() async {
        let (viewModel, _, _, _, _) = makeViewModel()
        let wizard = VMCreationViewModel()
        wizard.selectedOS = .linux
        wizard.selectedBootMode = .efi
        wizard.vmName = "Selected VM"

        await viewModel.createVM(from: wizard)

        #expect(viewModel.selectedID == viewModel.instances.first?.id)
    }

    @Test("createVM presents error when bundle creation fails")
    func createVMBundleError() async {
        let storage = MockVMStorageService()
        storage.createVMBundleError = VMStorageError.bundleAlreadyExists(UUID())
        let (viewModel, _, _, _, _) = makeViewModel(storageService: storage)
        let wizard = VMCreationViewModel()
        wizard.selectedOS = .linux
        wizard.selectedBootMode = .efi
        wizard.vmName = "Fail VM"

        let result = await viewModel.createVM(from: wizard)

        #expect(result.isFailure)
        #expect(viewModel.instances.isEmpty)
    }

    @Test("createVM presents error when disk image creation fails")
    func createVMDiskImageError() async {
        let diskService = MockDiskImageService()
        diskService.createDiskImageError = NSError(domain: "test", code: 1)
        let (viewModel, _, _, _, _) = makeViewModel(diskImageService: diskService)
        let wizard = VMCreationViewModel()
        wizard.selectedOS = .linux
        wizard.selectedBootMode = .efi
        wizard.vmName = "Disk Fail VM"

        let result = await viewModel.createVM(from: wizard)

        #expect(result.isFailure)
    }

    @Test("createVM auto-starts the new VM when startAfterCreate is true (default)")
    func createVMAutoStartsByDefault() async {
        let (viewModel, _, _, virtService, _) = makeViewModel()
        let wizard = VMCreationViewModel()
        wizard.selectedOS = .linux
        wizard.selectedBootMode = .efi
        wizard.vmName = "Auto Start VM"
        // startAfterCreate defaults to true

        await viewModel.createVM(from: wizard)

        #expect(viewModel.instances.count == 1)
        #expect(virtService.startCallCount == 1)
        #expect(viewModel.instances.first?.status == .running)
    }

    @Test("createVM does not auto-start when startAfterCreate is false")
    func createVMSkipsAutoStartWhenDisabled() async {
        let (viewModel, _, _, virtService, _) = makeViewModel()
        let wizard = VMCreationViewModel()
        wizard.selectedOS = .linux
        wizard.selectedBootMode = .efi
        wizard.vmName = "Manual Start VM"
        wizard.startAfterCreate = false

        await viewModel.createVM(from: wizard)

        #expect(viewModel.instances.count == 1)
        #expect(virtService.startCallCount == 0)
        // VM should be in its initial post-creation state, not running
        #expect(viewModel.instances.first?.status != .running)
    }

    @Test("createVM does not auto-start when bundle creation fails")
    func createVMNoAutoStartOnBundleError() async {
        let storage = MockVMStorageService()
        storage.createVMBundleError = VMStorageError.bundleAlreadyExists(UUID())
        let (viewModel, _, _, virtService, _) = makeViewModel(storageService: storage)
        let wizard = VMCreationViewModel()
        wizard.selectedOS = .linux
        wizard.selectedBootMode = .efi
        wizard.vmName = "Fail Start VM"
        // startAfterCreate is true by default — but creation fails, so start
        // must not be called.

        await viewModel.createVM(from: wizard)

        #expect(viewModel.instances.isEmpty)
        #expect(virtService.startCallCount == 0)
    }

    @Test("createVM forwards requestedFreshDownload from a wizard that confirmed overwrite")
    func createVMForwardsRequestedFreshDownload() async throws {
        // End-to-end: wizard with macOS / downloadLatest / a destination that
        // already has a file there / overwrite confirmed → the persisted
        // install context on the new VM carries requestedFreshDownload=true,
        // which is what tells the lifecycle coordinator to trash the stale
        // file at first Start.
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("createVMOverwrite-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let destination = temp.appendingPathComponent("RestoreImage.ipsw")
        try Data(repeating: 0x12, count: 256).write(to: destination)

        let (viewModel, _, _, _, _) = makeViewModel()
        let wizard = VMCreationViewModel()
        wizard.selectedOS = .macOS
        wizard.selectedBootMode = .macOS
        wizard.vmName = "Overwrite VM"
        wizard.ipswDownloadPath = destination.path(percentEncoded: false)
        wizard.confirmOverwrite()

        await viewModel.createVM(from: wizard)

        let instance = try #require(viewModel.instances.first)
        let context = try #require(instance.configuration.installContext)
        #expect(context.source == .downloadLatest)
        #expect(context.requestedFreshDownload)
    }

    @Test("createVM leaves requestedFreshDownload false when wizard didn't confirm overwrite")
    func createVMNoOverwriteLeavesFlagFalse() async throws {
        // Same wizard shape but without `confirmOverwrite()` — the persisted
        // context must have requestedFreshDownload=false so the coordinator
        // doesn't trash an unrelated file at first Start.
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("createVMNoOverwrite-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let destination = temp.appendingPathComponent("RestoreImage.ipsw")

        let (viewModel, _, _, _, _) = makeViewModel()
        let wizard = VMCreationViewModel()
        wizard.selectedOS = .macOS
        wizard.selectedBootMode = .macOS
        wizard.vmName = "No-overwrite VM"
        wizard.ipswDownloadPath = destination.path(percentEncoded: false)

        await viewModel.createVM(from: wizard)

        let instance = try #require(viewModel.instances.first)
        let context = try #require(instance.configuration.installContext)
        #expect(!context.requestedFreshDownload)
    }

    // MARK: - Cancel Installation

    @Test("cancelGuestSetup preserves bundle and instance (non-destructive)")
    func cancelGuestSetupPreservesBundle() async {
        let (viewModel, storage, _, _, _) = makeViewModel()
        let instance = makeInstance(name: "Installing VM")
        instance.configuration.installContext = MacOSInstallContext(
            source: .localFile, localIPSWPath: "/tmp/foo.ipsw"
        )
        instance.enter(.installing(sessionID: nil))
        viewModel.instances.append(instance)
        storage.bundles[instance.bundleURL] = instance.configuration

        // Spawn a fake long-running install task we can observe being cancelled.
        let cancelStream = AsyncStream<Void>.makeStream()
        instance.setupTask = Task {
            await withTaskCancellationHandler {
                try? await Task.sleep(for: .seconds(60))
            } onCancel: {
                cancelStream.continuation.yield(())
                cancelStream.continuation.finish()
            }
        }

        viewModel.cancelGuestSetup(instance)
        for await _ in cancelStream.stream { break }

        // Bundle is preserved, instance stays in library, installContext intact.
        #expect(viewModel.instances.count == 1)
        #expect(storage.deleteVMBundleCallCount == 0)
        #expect(instance.configuration.installContext != nil)
    }

    @Test(
        "Install cancel that races a non-CancellationError still returns VM to .initialBoot"
    )
    func cancelRaceWithNonCancelErrorReturnsToInitialBoot() async throws {
        // Production scenario from the same PR as the IPSW size-check fix:
        // the user clicks Cancel during download, but a non-cancel error
        // (e.g. network failure or `.downloadFailed`) reaches the catch
        // before the cancellation propagates. Before this fix, the generic
        // `catch {}` branch saw `Task.isCancelled == true` and silently
        // suppressed the error — leaving the VM in `.error` with no dialog
        // and no path back to `.initialBoot`. The fix normalizes that case
        // to the cancel outcome.
        let raceInstaller = SuspendingMockMacOSInstallService(
            terminalError: DownloadError.downloadFailed(URLError(.badServerResponse)))
        let storage = MockVMStorageService()
        let viewModel = VMLibraryViewModel(
            storageService: storage,
            diskImageService: MockDiskImageService(),
            virtualizationService: MockVirtualizationService(),
            installService: raceInstaller,
            ipswService: MockIPSWService(),
            usbDeviceService: MockUSBDeviceService(),
            preferences: preferences
        )
        viewModel.presenter = presenter
        let instance = makeInstance(name: "Race VM")
        instance.configuration.installContext = MacOSInstallContext(
            source: .localFile, localIPSWPath: "/tmp/foo.ipsw"
        )
        instance.onUpdateConfiguration = { mutate in mutate(&instance.configuration) }
        instance.enter(.initialBoot)
        viewModel.instances.append(instance)
        storage.bundles[instance.bundleURL] = instance.configuration

        // Spawn the install + auto-boot pipeline; returns immediately after
        // arming `instance.setupTask`.
        await viewModel.start(instance)

        // Wait until the mock install has parked, so the cancel below
        // actually races a running install rather than a not-yet-started one.
        for await _ in raceInstaller.installStartedStream { break }

        viewModel.cancelGuestSetup(instance)

        // Drain the install task to completion so post-conditions are
        // observable (the catch block runs synchronously after await).
        await instance.setupTask?.value

        // The fix routes this case through the cancel outcome: VM is back
        // to .initialBoot, no error dialog, error message cleared.
        #expect(instance.status == .initialBoot)
        #expect(instance.errorMessage == nil)
        #expect(presenter.showError == false)
    }

    @Test("cancelGuestSetup does not change selection")
    func cancelGuestSetupKeepsSelection() async {
        let (viewModel, storage, _, _, _) = makeViewModel()
        let first = makeInstance(name: "First")
        let installing = makeInstance(name: "Installing")
        installing.configuration.installContext = MacOSInstallContext(
            source: .localFile, localIPSWPath: "/tmp/foo.ipsw"
        )
        installing.enter(.installing(sessionID: nil))
        viewModel.instances = [first, installing]
        viewModel.selectedID = installing.id
        storage.bundles[installing.bundleURL] = installing.configuration

        let cancelStream = AsyncStream<Void>.makeStream()
        installing.setupTask = Task {
            await withTaskCancellationHandler {
                try? await Task.sleep(for: .seconds(60))
            } onCancel: {
                cancelStream.continuation.yield(())
                cancelStream.continuation.finish()
            }
        }

        viewModel.cancelGuestSetup(installing)
        for await _ in cancelStream.stream { break }

        // Both instances remain; selection unchanged.
        #expect(viewModel.instances.count == 2)
        #expect(viewModel.selectedID == installing.id)
    }

    // MARK: - Pending Linux Image Download

    /// A resolved image nothing on this Mac can already be sitting at, so a
    /// dispatch test never reads a file out of the real Downloads folder.
    ///
    /// The URL is what varies: the destination is named for it, not for the
    /// name the source gives the ISO.
    private func makeUnusedResolvedImage() -> ResolvedLinuxImage {
        makeResolvedLinuxImage(
            isoURLString: "https://mirror.example/kernova-test-\(UUID().uuidString).iso")
    }

    /// A stopped Linux VM with a pending catalog download, registered in
    /// `viewModel` with its configuration persisted.
    private func makePendingLinuxVM(
        in viewModel: VMLibraryViewModel,
        storage: MockVMStorageService,
        destinationPath: String? = nil
    ) -> VMInstance {
        let instance = makeInstance(name: "Debian")
        instance.configuration.linuxInstallContext = LinuxInstallContext(
            source: .catalogEntry(makeLinuxCatalogEntry()), downloadDestinationPath: destinationPath)
        instance.onUpdateConfiguration = { mutate in mutate(&instance.configuration) }
        instance.enter(.initialBoot)
        viewModel.instances.append(instance)
        storage.bundles[instance.bundleURL] = instance.configuration
        return instance
    }

    @Test("A pending Linux image download loads as .initialBoot")
    func initialStatusHonorsLinuxContext() {
        var config = VMConfiguration(name: "Debian", guestOS: .linux, bootMode: .efi)
        config.linuxInstallContext = LinuxInstallContext(source: .catalogEntry(makeLinuxCatalogEntry()))
        let layout = VMBundleLayout(
            bundleURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("\(config.id.uuidString).kernova", isDirectory: true))

        #expect(VMLibrary.initialPhase(for: config, layout: layout) == .initialBoot)
    }

    @Test("createVM persists a catalog pick's download context for Linux")
    func createVMPersistsLinuxDownloadContext() async {
        let (viewModel, _, _, _, _) = makeViewModel()
        let wizard = VMCreationViewModel()
        wizard.selectedOS = .linux
        wizard.selectedBootMode = .efi
        wizard.vmName = "Catalog Linux VM"
        wizard.startAfterCreate = false
        let entry = makeLinuxCatalogEntry()
        wizard.selectLinuxCatalogEntry(entry)

        await viewModel.createVM(from: wizard)

        let created = viewModel.instances.first
        #expect(catalogEntry(of: created?.configuration.linuxInstallContext) == entry)
        // The download is what the VM is waiting on, so it has never booted.
        #expect(created?.status == .initialBoot)
        #expect(created?.configuration.installContext == nil)
    }

    @Test("createVM leaves a local-ISO Linux VM with no download context")
    func createVMLocalISOHasNoLinuxContext() async {
        let (viewModel, _, _, _, _) = makeViewModel()
        let wizard = VMCreationViewModel()
        wizard.selectedOS = .linux
        wizard.selectedBootMode = .efi
        wizard.vmName = "Local ISO VM"
        wizard.startAfterCreate = false
        wizard.selectLocalISO(path: "/tmp/ubuntu.iso", bookmark: nil)

        await viewModel.createVM(from: wizard)

        let created = viewModel.instances.first
        #expect(created?.configuration.linuxInstallContext == nil)
        #expect(created?.status == .stopped)
        #expect(created?.configuration.storageDisks?.count == 2)
    }

    @Test("start routes a pending Linux context through the download pipeline, not a boot")
    func startDispatchesLinuxDownload() async {
        let resolveService = MockLinuxImageResolveService()
        resolveService.resolveResult = makeUnusedResolvedImage()
        resolveService.resolveError = LinuxImageResolveError.noMatchingImage(
            pattern: "debian-13.*-arm64-netinst.iso")
        let virtService = MockVirtualizationService()
        let (viewModel, storage, _, _, _) = makeViewModel(
            virtualizationService: virtService, linuxImageResolveService: resolveService)
        let instance = makePendingLinuxVM(in: viewModel, storage: storage)

        await viewModel.start(instance)
        await instance.setupTask?.value

        #expect(resolveService.resolveCallCount == 1)
        // Never fell through to a normal boot, and the intent survives for the
        // retry Start.
        #expect(virtService.startCallCount == 0)
        #expect(instance.status == .error)
        #expect(instance.configuration.linuxInstallContext != nil)
    }

    @Test("A finished Linux download hands straight off to the boot it was waiting on")
    func startChainsTheBootAfterTheLinuxPipeline() async throws {
        // The pipeline runs the VM through `.installing`, and the Start chained
        // off its success is the one thing that has to survive that: the real
        // service refuses a start from a status failing `canStart`.
        let downloads = FileManager.default.temporaryDirectory
            .appendingPathComponent("linuxAutoBoot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: downloads) }

        let contents = Data("kernova linux image fixture".utf8)
        let digest = SHA256.hash(data: contents).map { String(format: "%02x", $0) }.joined()
        let resolveService = MockLinuxImageResolveService()
        resolveService.resolveResult = makeResolvedLinuxImage(
            sha256: digest, sizeBytes: UInt64(contents.count))
        let downloadService = MockDownloadService()
        downloadService.downloadedContents = contents

        let virtService = MockVirtualizationService()
        let (viewModel, storage, _, _, _) = makeViewModel(
            virtualizationService: virtService, linuxImageResolveService: resolveService,
            downloadService: downloadService, downloadsDirectory: downloads)
        let instance = makePendingLinuxVM(in: viewModel, storage: storage)

        await viewModel.start(instance)
        await instance.setupTask?.value

        #expect(instance.configuration.linuxInstallContext == nil)
        #expect(virtService.startCallCount == 1)
        // The status the pipeline handed the boot, not just that a boot ran.
        #expect(virtService.statusAtStart == .stopped)
        #expect(instance.status == .running)
        #expect(presenter.showError == false)
    }

    @Test("A second Start during a running Linux download is ignored")
    func startDoesNotRestartAnInFlightLinuxDownload() async {
        let resolveService = MockLinuxImageResolveService()
        let (viewModel, storage, _, _, _) = makeViewModel(
            linuxImageResolveService: resolveService)
        let instance = makePendingLinuxVM(in: viewModel, storage: storage)
        instance.setupTask = Task { try? await Task.sleep(for: .seconds(60)) }

        await viewModel.start(instance)

        // Draining whatever task is stored settles the question: a second
        // pipeline would have run to completion here and asked the mirror.
        instance.setupTask?.cancel()
        await instance.setupTask?.value
        #expect(resolveService.resolveCallCount == 0)
    }

    @Test("cancelGuestSetup cancels a Linux download and keeps its context")
    func cancelGuestSetupCancelsLinuxDownload() async {
        let (viewModel, storage, _, _, _) = makeViewModel()
        let instance = makePendingLinuxVM(in: viewModel, storage: storage)
        instance.enter(.installing(sessionID: nil))

        let cancelStream = AsyncStream<Void>.makeStream()
        instance.setupTask = Task {
            await withTaskCancellationHandler {
                try? await Task.sleep(for: .seconds(60))
            } onCancel: {
                cancelStream.continuation.yield(())
                cancelStream.continuation.finish()
            }
        }

        viewModel.cancelGuestSetup(instance)
        for await _ in cancelStream.stream { break }

        #expect(viewModel.instances.count == 1)
        #expect(storage.deleteVMBundleCallCount == 0)
        #expect(instance.configuration.linuxInstallContext != nil)
    }

    @Test("Deleting a VM discards its pending Linux download bundle")
    func deleteDiscardsLinuxResumeData() async {
        let downloadService = MockDownloadService()
        let (viewModel, storage, _, _, _) = makeViewModel(downloadService: downloadService)
        let destination = "/Users/me/Downloads/debian-13.6.0-arm64-netinst.iso"
        let instance = makePendingLinuxVM(
            in: viewModel, storage: storage, destinationPath: destination)

        await viewModel.delete(instance)

        let discarded = downloadService.discardedResumeDataURLs.map {
            $0.path(percentEncoded: false)
        }
        #expect(discarded == [destination])
        #expect(downloadService.lastDiscardResumeDataPermanently == false)
    }

    @Test("A permanent delete disposes of the Linux download bundle the same way")
    func permanentDeleteDiscardsLinuxResumeDataPermanently() async {
        let downloadService = MockDownloadService()
        let (viewModel, storage, _, _, _) = makeViewModel(downloadService: downloadService)
        let instance = makePendingLinuxVM(
            in: viewModel, storage: storage,
            destinationPath: "/Users/me/Downloads/debian-13.6.0-arm64-netinst.iso")

        await viewModel.delete(instance, permanently: true)

        #expect(downloadService.lastDiscardResumeDataPermanently == true)
    }

    @Test("A Linux context with no destination yet has no bundle to discard")
    func deleteWithUnresolvedLinuxDestination() async {
        let downloadService = MockDownloadService()
        let (viewModel, storage, _, _, _) = makeViewModel(downloadService: downloadService)
        let instance = makePendingLinuxVM(in: viewModel, storage: storage)

        await viewModel.delete(instance)

        #expect(downloadService.discardResumeDataCallCount == 0)
    }

    // MARK: - Agent Install Nudge

    @Test("setAgentInstallNudgeDismissed persists in both directions")
    func setAgentInstallNudgeDismissedPersistsBothDirections() {
        let (viewModel, storage, _, _, _) = makeViewModel()
        let instance = makeInstance()
        viewModel.instances.append(instance)

        viewModel.setAgentInstallNudgeDismissed(true, for: instance)
        #expect(instance.configuration.agentInstallNudgeDismissed == true)
        #expect(storage.saveConfigurationCallCount == 1)

        viewModel.setAgentInstallNudgeDismissed(false, for: instance)
        #expect(instance.configuration.agentInstallNudgeDismissed == false)
        #expect(storage.saveConfigurationCallCount == 2)
    }

    @Test("setAgentInstallNudgeDismissed no-ops when unchanged")
    func setAgentInstallNudgeDismissedNoOpsWhenUnchanged() {
        let (viewModel, storage, _, _, _) = makeViewModel()
        let instance = makeInstance()
        viewModel.instances.append(instance)

        // Default is already false; setting false again writes nothing.
        viewModel.setAgentInstallNudgeDismissed(false, for: instance)
        #expect(storage.saveConfigurationCallCount == 0)
    }

    @Test("dismissAgentInstallNudge still sets the flag to true")
    func dismissAgentInstallNudgeSetsTrue() {
        let (viewModel, storage, _, _, _) = makeViewModel()
        let instance = makeInstance()
        viewModel.instances.append(instance)

        viewModel.dismissAgentInstallNudge(for: instance)

        #expect(instance.configuration.agentInstallNudgeDismissed == true)
        #expect(storage.saveConfigurationCallCount == 1)
    }

    @Test("resetAllAgentInstallNudges re-arms every VM and the app-wide preference")
    func resetAllAgentInstallNudgesReArmsEveryVM() {
        let (viewModel, _, _, _, _) = makeViewModel()
        let first = makeInstance(name: "First")
        let second = makeInstance(name: "Second")
        let third = makeInstance(name: "Third")
        first.configuration.agentInstallNudgeDismissed = true
        second.configuration.agentInstallNudgeDismissed = true
        // `third` stays armed to confirm the reset no-ops on already-armed VMs.
        viewModel.instances = [first, second, third]
        viewModel.agentInstallPromptDisabled = true

        viewModel.resetAllAgentInstallNudges()

        #expect(first.configuration.agentInstallNudgeDismissed == false)
        #expect(second.configuration.agentInstallNudgeDismissed == false)
        #expect(third.configuration.agentInstallNudgeDismissed == false)
        #expect(viewModel.agentInstallPromptDisabled == false)
        #expect(preferences.agentInstallPromptDisabled == false)
    }

    @Test("agentInstallPromptDisabled defaults off and persists in both directions")
    func agentInstallPromptDisabledPersistsBothDirections() {
        let (viewModel, _, _, _, _) = makeViewModel()
        #expect(viewModel.agentInstallPromptDisabled == false)

        viewModel.agentInstallPromptDisabled = true
        #expect(preferences.agentInstallPromptDisabled == true)

        viewModel.agentInstallPromptDisabled = false
        #expect(preferences.agentInstallPromptDisabled == false)
    }

    @Test("agentInstallPromptDisabled is seeded from the stored preference")
    func agentInstallPromptDisabledSeededFromPreferences() {
        preferences.agentInstallPromptDisabled = true

        let (viewModel, _, _, _, _) = makeViewModel()

        #expect(viewModel.agentInstallPromptDisabled == true)
    }

    @Test("hasUninterruptibleWork covers transitioning VMs but not settled ones")
    func hasUninterruptibleWorkCoversTransitions() {
        let (viewModel, _, _, _, _) = makeViewModel()
        let instance = makeInstance()
        viewModel.instances = [instance]

        for phase in Self.transitionalPhases {
            instance.enter(phase)
            #expect(viewModel.hasUninterruptibleWork, "\(phase)")
        }
        // Termination save-suspends these, so they must not hold a quit back.
        for phase in [
            VMLifecyclePhase.running(sessionID: UUID()), .livePaused(sessionID: UUID()),
            .suspended, .stopped,
        ] {
            instance.enter(phase)
            #expect(!viewModel.hasUninterruptibleWork, "\(phase)")
        }
    }

    @Test("hasUninterruptibleWork is false for an empty library")
    func hasUninterruptibleWorkIsFalseWhenEmpty() {
        let (viewModel, _, _, _, _) = makeViewModel()
        #expect(!viewModel.hasUninterruptibleWork)
    }

    @Test("hasSaveInFlight covers a saving VM alone")
    func hasSaveInFlightCoversSavingOnly() {
        let (viewModel, _, _, _, _) = makeViewModel()
        let instance = makeInstance()
        viewModel.instances = [instance]

        instance.enter(.saving(sessionID: UUID()))
        #expect(viewModel.hasSaveInFlight)
        // A capture writes files too, so it waits out alongside a suspend.
        instance.enter(.capturingLive(sessionID: UUID()))
        #expect(viewModel.hasSaveInFlight)
        instance.enter(.capturingAtRest)
        #expect(viewModel.hasSaveInFlight)
        // Every other transition is one an explicit quit may terminate through.
        for phase in [
            VMLifecyclePhase.starting(sessionID: UUID()),
            .restoringSavedState(sessionID: UUID()), .revertingToSnapshot,
            .installing(sessionID: UUID()), .running(sessionID: UUID()),
            .livePaused(sessionID: UUID()), .suspended, .stopped,
        ] {
            instance.enter(phase)
            #expect(!viewModel.hasSaveInFlight, "\(phase)")
        }
    }

    @Test("hasSaveInFlight finds a saving VM among settled ones")
    func hasSaveInFlightFindsAnyInstance() {
        let (viewModel, _, _, _, _) = makeViewModel()
        let running = makeInstance()
        running.enter(.running(sessionID: UUID()))
        let saving = makeInstance()
        saving.enter(.saving(sessionID: UUID()))
        viewModel.instances = [running, saving]

        #expect(viewModel.hasSaveInFlight)
    }

    @Test("hasSaveInFlight is false for an empty library")
    func hasSaveInFlightIsFalseWhenEmpty() {
        let (viewModel, _, _, _, _) = makeViewModel()
        #expect(!viewModel.hasSaveInFlight)
    }

    @Test("isBusy is false for a settled VM")
    func isBusyIsFalseWhenSettled() {
        let (viewModel, _, _, _, _) = makeViewModel()
        let instance = makeInstance()
        viewModel.instances = [instance]

        for phase in [
            VMLifecyclePhase.stopped, .running(sessionID: UUID()),
            .livePaused(sessionID: UUID()), .suspended,
        ] {
            instance.enter(phase)
            #expect(!viewModel.isBusy(instance), "\(phase)")
        }
    }

    @Test("isBusy covers a preparing row and every transitioning phase")
    func isBusyCoversPreparingAndTransitions() {
        let (viewModel, _, _, _, _) = makeViewModel()
        let instance = makeInstance()
        viewModel.instances = [instance]

        for phase in Self.transitionalPhases {
            instance.enter(phase)
            #expect(viewModel.isBusy(instance), "\(phase)")
        }

        instance.enter(.stopped)
        instance.preparingState = VMInstance.PreparingState(operation: .cloning, task: Task {})
        #expect(viewModel.isBusy(instance))
    }

    /// The state that motivates the lifecycle term: a pause holds `.running`
    /// until the VZ call returns, so no phase-driven surface can render it —
    /// and a call that never returns stays invisible.
    @Test("isBusy reads true through a settling pause whose phase still says running")
    func isBusyCoversSettlingPause() async throws {
        let (viewModel, suspending) = makeSuspendingViewModel()
        let instance = makeInstance()
        instance.enter(.running(sessionID: UUID()))
        viewModel.instances = [instance]

        let pause = Task { @MainActor in try await viewModel.lifecycle.pause(instance) }
        await suspending.waitUntilSuspended()

        #expect(instance.status == .running)
        #expect(!instance.isTransitioning)
        #expect(viewModel.isBusy(instance))

        suspending.resumeSuspended()
        try await pause.value
        #expect(!viewModel.isBusy(instance))
    }

    @Test("An isBusy wait resolves by observation when a settling pause ends")
    func isBusyWakesAnObservedWait() async throws {
        let (viewModel, suspending) = makeSuspendingViewModel()
        let instance = makeInstance()
        instance.enter(.running(sessionID: UUID()))
        viewModel.instances = [instance]

        let pause = Task { @MainActor in try await viewModel.lifecycle.pause(instance) }
        await suspending.waitUntilSuspended()
        #expect(viewModel.isBusy(instance))

        // Released from a separate task so the wait below arms first, making the
        // resolution an observation wake rather than an already-true predicate.
        Task { @MainActor in suspending.resumeSuspended() }
        try await waitForChange { !viewModel.isBusy(instance) }

        try await pause.value
    }

    @Test("keepInMenuBarOnQuit defaults on and persists in both directions")
    func keepInMenuBarOnQuitPersistsBothDirections() {
        let (viewModel, _, _, _, _) = makeViewModel()
        #expect(viewModel.keepInMenuBarOnQuit == true)

        viewModel.keepInMenuBarOnQuit = false
        #expect(preferences.keepInMenuBarOnQuit == false)

        viewModel.keepInMenuBarOnQuit = true
        #expect(preferences.keepInMenuBarOnQuit == true)
    }

    @Test("keepInMenuBarOnQuit is seeded from the stored preference")
    func keepInMenuBarOnQuitSeededFromPreferences() {
        preferences.keepInMenuBarOnQuit = false

        let (viewModel, _, _, _, _) = makeViewModel()

        #expect(viewModel.keepInMenuBarOnQuit == false)
    }

    @Test("a keepInMenuBarOnQuit change wakes an observer")
    func keepInMenuBarOnQuitWakesObservers() async {
        // The whole reason the preference is mirrored here: `AppDelegate` creates
        // and tears down the status item from an observation, which a bare
        // `UserDefaults` write never wakes.
        let (viewModel, _, _, _, _) = makeViewModel()
        var wakeCount = 0
        let loop = observeRecurring(
            track: { _ = viewModel.keepInMenuBarOnQuit },
            apply: { wakeCount += 1 })

        viewModel.keepInMenuBarOnQuit = false
        for _ in 0..<5 { await Task.yield() }

        #expect(wakeCount == 1)
        loop.cancel()
    }

    /// The app-wide preference overrides the per-VM flag rather than rewriting
    /// it, so each VM reverts to its own choice when the preference goes off.
    @Test("Toggling agentInstallPromptDisabled leaves every per-VM flag alone")
    func agentInstallPromptDisabledLeavesPerVMFlagsAlone() {
        let (viewModel, storage, _, _, _) = makeViewModel()
        let dismissed = makeInstance(name: "Dismissed")
        let armed = makeInstance(name: "Armed")
        dismissed.configuration.agentInstallNudgeDismissed = true
        viewModel.instances = [dismissed, armed]

        viewModel.agentInstallPromptDisabled = true
        viewModel.agentInstallPromptDisabled = false

        #expect(dismissed.configuration.agentInstallNudgeDismissed == true)
        #expect(armed.configuration.agentInstallNudgeDismissed == false)
        #expect(storage.saveConfigurationCallCount == 0)
    }

    // MARK: - Rename

    @Test("renameVMInDetail sets activeRename to detail target")
    func renameVMInDetailSetsDetailTarget() {
        let (viewModel, _, _, _, _) = makeViewModel()
        let instance = makeInstance()
        viewModel.instances.append(instance)

        viewModel.renameVMInDetail(instance)

        #expect(viewModel.activeRename == .detail(instance.id))
    }

    @Test("renameVMInSidebar sets activeRename to sidebar target")
    func renameVMInSidebarSetsSidebarTarget() {
        let (viewModel, _, _, _, _) = makeViewModel()
        let instance = makeInstance()
        viewModel.instances.append(instance)

        viewModel.renameVMInSidebar(instance)

        #expect(viewModel.activeRename == .sidebar(instance.id))
    }

    @Test("commitRename updates name and persists")
    func commitRenameUpdatesName() {
        let (viewModel, storage, _, _, _) = makeViewModel()
        let instance = makeInstance(name: "Old Name")
        viewModel.instances.append(instance)
        viewModel.activeRename = .detail(instance.id)

        viewModel.commitRename(for: instance, newName: "New Name", from: .detail)

        #expect(instance.name == "New Name")
        #expect(viewModel.activeRename == nil)
        #expect(storage.saveConfigurationCallCount == 1)
    }

    @Test("commitRename trims whitespace")
    func commitRenameTrimWhitespace() {
        let (viewModel, _, _, _, _) = makeViewModel()
        let instance = makeInstance(name: "Original")
        viewModel.instances.append(instance)
        viewModel.activeRename = .detail(instance.id)

        viewModel.commitRename(for: instance, newName: "  Trimmed  ", from: .detail)

        #expect(instance.name == "Trimmed")
        #expect(viewModel.activeRename == nil)
    }

    @Test("commitRename rejects empty name and preserves original")
    func commitRenameRejectsEmpty() {
        let (viewModel, storage, _, _, _) = makeViewModel()
        let instance = makeInstance(name: "Keep Me")
        viewModel.instances.append(instance)
        viewModel.activeRename = .detail(instance.id)

        viewModel.commitRename(for: instance, newName: "", from: .detail)

        #expect(instance.name == "Keep Me")
        #expect(viewModel.activeRename == nil)
        #expect(storage.saveConfigurationCallCount == 0)
    }

    @Test("commitRename rejects whitespace-only name and preserves original")
    func commitRenameRejectsWhitespace() {
        let (viewModel, storage, _, _, _) = makeViewModel()
        let instance = makeInstance(name: "Keep Me")
        viewModel.instances.append(instance)
        viewModel.activeRename = .detail(instance.id)

        viewModel.commitRename(for: instance, newName: "   ", from: .detail)

        #expect(instance.name == "Keep Me")
        #expect(viewModel.activeRename == nil)
        #expect(storage.saveConfigurationCallCount == 0)
    }

    @Test("commitRename from a superseded surface commits but keeps the newer rename active")
    func commitRenameFromSupersededSurfaceKeepsNewerRename() {
        let (viewModel, storage, _, _, _) = makeViewModel()
        let instance = makeInstance(name: "Old Name")
        viewModel.instances.append(instance)
        // The sidebar rename was superseded by a detail rename (clicking the
        // settings pane's Name button while the sidebar edit was pending); the
        // sidebar field editor's deferred commit must not wipe the newer
        // detail marker.
        viewModel.activeRename = .detail(instance.id)

        viewModel.commitRename(for: instance, newName: "New Name", from: .sidebar)

        #expect(instance.name == "New Name")
        #expect(viewModel.activeRename == .detail(instance.id))
        #expect(storage.saveConfigurationCallCount == 1)
    }

    @Test("cancelRename clears state without saving")
    func cancelRenameClearsState() {
        let (viewModel, storage, _, _, _) = makeViewModel()
        let instance = makeInstance()
        viewModel.instances.append(instance)
        viewModel.activeRename = .sidebar(instance.id)

        viewModel.cancelRename(for: instance, from: .sidebar)

        #expect(viewModel.activeRename == nil)
        #expect(storage.saveConfigurationCallCount == 0)
    }

    @Test("cancelRename from a superseded surface keeps the newer rename active")
    func cancelRenameFromSupersededSurfaceKeepsNewerRename() {
        let (viewModel, _, _, _, _) = makeViewModel()
        let instance = makeInstance()
        viewModel.instances.append(instance)
        viewModel.activeRename = .detail(instance.id)

        viewModel.cancelRename(for: instance, from: .sidebar)

        #expect(viewModel.activeRename == .detail(instance.id))
    }

    @Test("commitRename for one VM cannot clear another VM's rename marker")
    func commitRenameForOtherVMKeepsMarker() {
        let (viewModel, _, _, _, _) = makeViewModel()
        let renamed = makeInstance(name: "Renamed VM")
        let other = makeInstance(name: "Other VM")
        viewModel.instances.append(contentsOf: [renamed, other])
        // A rename-switch handoff: the marker already moved to the other VM's
        // row when the first row's deferred commit lands.
        viewModel.activeRename = .sidebar(other.id)

        viewModel.commitRename(for: renamed, newName: "New Name", from: .sidebar)

        #expect(renamed.name == "New Name")
        #expect(viewModel.activeRename == .sidebar(other.id))
    }

    // MARK: - Launch Auto-Start

    /// Every mid-operation phase, each with the session identity its own case
    /// admits.
    private static var transitionalPhases: [VMLifecyclePhase] {
        [
            .starting(sessionID: UUID()), .saving(sessionID: UUID()),
            .capturingLive(sessionID: UUID()), .capturingAtRest,
            .restoringSavedState(sessionID: UUID()), .revertingToSnapshot,
            .installing(sessionID: UUID()),
        ]
    }

    /// Marks the instance to start automatically, returning it for chaining.
    @discardableResult
    private func markAutoStart(_ instance: VMInstance) -> VMInstance {
        instance.configuration.startsAutomaticallyOnLaunch = true
        return instance
    }

    /// One row of the launch auto-start decision table.
    struct AutoStartCase: Sendable, CustomStringConvertible {
        let marked: Bool
        let isPreparing: Bool
        let hasPendingSetup: Bool
        let phase: VMLifecyclePhase
        let expected: VMLibraryViewModel.AutoStartStep

        init(
            marked: Bool, preparing: Bool = false, pendingSetup: Bool = false,
            _ phase: VMLifecyclePhase,
            _ expected: VMLibraryViewModel.AutoStartStep
        ) {
            self.marked = marked
            self.isPreparing = preparing
            self.hasPendingSetup = pendingSetup
            self.phase = phase
            self.expected = expected
        }

        var description: String {
            "marked \(marked), preparing \(isPreparing), pendingSetup \(hasPendingSetup), "
                + "\(phase) → \(expected)"
        }
    }

    @Test(
        "autoStartStep decides start, resume, or skip from state",
        arguments: [
            AutoStartCase(marked: true, .stopped, .start),
            AutoStartCase(marked: true, .failed(message: "Boot failed."), .start),
            AutoStartCase(marked: true, .suspended, .resume),
            // A VM that never finished setup would begin an unattended install
            // or image download, so it is skipped despite passing `canStart`.
            AutoStartCase(marked: true, .initialBoot, .skip),
            AutoStartCase(marked: true, pendingSetup: true, .initialBoot, .skip),
            // A failed install leaves the context intact at `.failed`, where
            // `start(_:)` still routes into the installer — the phase alone
            // would read this as an ordinary boot retry.
            AutoStartCase(marked: true, pendingSetup: true, .failed(message: "Install failed."), .skip),
            AutoStartCase(marked: true, pendingSetup: true, .stopped, .skip),
            AutoStartCase(marked: true, preparing: true, .stopped, .skip),
            AutoStartCase(marked: true, .running(sessionID: UUID()), .skip),
            AutoStartCase(marked: true, .starting(sessionID: UUID()), .skip),
            AutoStartCase(marked: true, .saving(sessionID: UUID()), .skip),
            AutoStartCase(marked: true, .revertingToSnapshot, .skip),
            AutoStartCase(marked: true, .installing(sessionID: UUID()), .skip),
            // Live-paused: the VZ object is already in memory, so the launch
            // pass has nothing to bring up.
            AutoStartCase(marked: true, .livePaused(sessionID: UUID()), .skip),
            AutoStartCase(marked: false, .stopped, .skip),
            AutoStartCase(marked: false, .suspended, .skip),
        ])
    func autoStartStepMatrix(testCase: AutoStartCase) {
        #expect(
            VMLibraryViewModel.autoStartStep(
                startsAutomaticallyOnLaunch: testCase.marked,
                isPreparing: testCase.isPreparing,
                hasPendingSetup: testCase.hasPendingSetup,
                phase: testCase.phase) == testCase.expected)
    }

    @Test("macOSVMNamesMarkedForAutoStart lists marked macOS VMs in library order")
    func markedMacOSVMNamesFollowLibraryOrder() {
        let (viewModel, _, _, _, _) = makeViewModel()
        let firstMac = markAutoStart(makeInstance(name: "Mac One", guestOS: .macOS))
        let unmarkedMac = makeInstance(name: "Mac Unmarked", guestOS: .macOS)
        let markedLinux = markAutoStart(makeInstance(name: "Linux Marked"))
        let secondMac = markAutoStart(makeInstance(name: "Mac Two", guestOS: .macOS))
        viewModel.instances = [firstMac, unmarkedMac, markedLinux, secondMac]

        // Linux guests don't count against the macOS cap, and an unmarked macOS
        // VM isn't coming up at launch.
        #expect(viewModel.macOSVMNamesMarkedForAutoStart == ["Mac One", "Mac Two"])
    }

    @Test("startAutomaticVMsForLaunch starts only marked VMs")
    func autoStartStartsOnlyMarked() async {
        let (viewModel, _, _, virtService, _) = makeViewModel()
        let marked1 = markAutoStart(makeInstance(name: "Marked 1"))
        let marked2 = markAutoStart(makeInstance(name: "Marked 2"))
        let unmarked = makeInstance(name: "Unmarked")
        viewModel.instances = [marked1, marked2, unmarked]

        await viewModel.startAutomaticVMsForLaunch()

        #expect(virtService.startCallCount == 2)
        #expect(marked1.status == .running)
        #expect(marked2.status == .running)
        #expect(unmarked.status == .stopped)
    }

    @Test("startAutomaticVMsForLaunch resumes a marked VM with saved state")
    func autoStartResumesColdPaused() async {
        let (viewModel, _, _, virtService, _) = makeViewModel()
        let saved = markAutoStart(makeInstance(name: "Suspended"))
        saved.enter(.suspended)
        viewModel.instances = [saved]

        await viewModel.startAutomaticVMsForLaunch()

        #expect(virtService.resumeCallCount == 1)
        #expect(virtService.startCallCount == 0)
        #expect(saved.status == .running)
    }

    @Test("startAutomaticVMsForLaunch leaves a marked VM awaiting initial boot alone")
    func autoStartSkipsInitialBoot() async {
        let (viewModel, _, _, virtService, _) = makeViewModel()
        let fresh = markAutoStart(makeInstance(name: "Never Booted"))
        fresh.enter(.initialBoot)
        viewModel.instances = [fresh]

        await viewModel.startAutomaticVMsForLaunch()

        #expect(virtService.startCallCount == 0)
        #expect(fresh.status == .initialBoot)
    }

    /// The status reads `.error` — an ordinary boot retry — but the surviving
    /// install context means `start(_:)` would route back into the installer.
    @Test("startAutomaticVMsForLaunch leaves a marked VM whose setup failed alone")
    func autoStartSkipsFailedSetup() async {
        let (viewModel, _, _, virtService, _) = makeViewModel()
        let stalled = markAutoStart(makeInstance(name: "Setup Failed"))
        stalled.configuration.linuxInstallContext = LinuxInstallContext(
            source: .catalogEntry(makeLinuxCatalogEntry()))
        stalled.enter(.failed(message: "Test failure"))
        viewModel.instances = [stalled]

        await viewModel.startAutomaticVMsForLaunch()

        #expect(virtService.startCallCount == 0)
        #expect(stalled.status == .error)
    }

    @Test("startAutomaticVMsForLaunch carries on past a VM that fails to start")
    func autoStartContinuesAfterFailure() async {
        let virtService = MockVirtualizationService()
        virtService.startError = VirtualizationError.noVirtualMachine
        let (viewModel, _, _, _, _) = makeViewModel(virtualizationService: virtService)
        let failing = markAutoStart(makeInstance(name: "Failing"))
        let following = markAutoStart(makeInstance(name: "Following"))
        viewModel.instances = [failing, following]

        await viewModel.startAutomaticVMsForLaunch()

        #expect(virtService.startCallCount == 2)
        #expect(presenter.showError == true)
    }

    @Test("startAutomaticVMsForLaunch leaves a failed restore cold-paused and carries on")
    func autoStartRestoreFailureRestsColdPausedAndContinues() async throws {
        let virtService = MockVirtualizationService()
        virtService.resumeError = VirtualizationError.restoreFailed(
            underlying: NSError(domain: "test", code: 1))
        let (viewModel, _, _, _, _) = makeViewModel(virtualizationService: virtService)
        let suspended = markAutoStart(makeInstance(name: "Suspended"))
        suspended.enter(.suspended)
        try FileManager.default.createDirectory(
            at: suspended.bundleURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: suspended.bundleURL) }
        FileManager.default.createFile(
            atPath: suspended.saveFileURL.path(percentEncoded: false),
            contents: Data("fake save".utf8))
        let following = markAutoStart(makeInstance(name: "Following"))
        viewModel.instances = [suspended, following]

        await viewModel.startAutomaticVMsForLaunch()

        #expect(virtService.resumeCallCount == 1)
        #expect(virtService.startCallCount == 1)
        #expect(suspended.status == .paused)
        #expect(suspended.errorMessage == nil)
        #expect(presenter.showError == true)
    }

    @Test("startAutomaticVMsForLaunch stops between VMs once cancelled")
    func autoStartHonorsCancellation() async {
        let (viewModel, suspending) = makeSuspendingViewModel()
        let first = markAutoStart(makeInstance(name: "First"))
        let second = markAutoStart(makeInstance(name: "Second"))
        viewModel.instances = [first, second]

        let pass = Task { await viewModel.startAutomaticVMsForLaunch() }
        // Suspended inside the first VM's start — the quit lands here.
        await suspending.waitUntilSuspended()
        pass.cancel()
        suspending.shouldSuspendOnStart = false
        suspending.resumeSuspended()
        await pass.value

        #expect(first.status == .running)
        #expect(second.status == .stopped)
    }

    @Test("startAutomaticVMsForLaunch skips a VM that left the library mid-pass")
    func autoStartSkipsInstanceRemovedMidPass() async {
        let (viewModel, suspending) = makeSuspendingViewModel()
        let first = markAutoStart(makeInstance(name: "First"))
        let second = markAutoStart(makeInstance(name: "Second"))
        viewModel.instances = [first, second]

        let pass = Task { await viewModel.startAutomaticVMsForLaunch() }
        // Deleted while the first VM is still booting, so the pass's snapshot
        // holds an instance the library no longer has.
        await suspending.waitUntilSuspended()
        viewModel.instances = [first]
        suspending.shouldSuspendOnStart = false
        suspending.resumeSuspended()
        await pass.value

        #expect(first.status == .running)
        #expect(second.status == .stopped)
    }

    @Test("startAutomaticVMsForLaunch does nothing when no VM is marked")
    func autoStartNoOpWhenNothingMarked() async {
        let (viewModel, _, _, virtService, _) = makeViewModel()
        viewModel.instances = [makeInstance(name: "Unmarked")]

        await viewModel.startAutomaticVMsForLaunch()

        #expect(virtService.startCallCount == 0)
        #expect(virtService.resumeCallCount == 0)
    }

    // MARK: - Import

    /// Builds a `.kernova`-shaped source bundle URL under a per-call-unique temp parent.
    ///
    /// The parent keeps parallel tests from colliding. Registers the configuration with
    /// `storage` so the mocked `loadConfiguration(from:)` succeeds. When `createOnDisk` is true
    /// (the default), also creates the directory on disk — `importVM` copies real files via
    /// `FileManager`, so tests exercising a successful copy need an actual source directory;
    /// tests modeling a missing/never-copied source (duplicate-UUID short-circuit,
    /// copy-failure) pass `false` and have nothing to clean up. Callers that do create on disk
    /// must remove the returned URL's *parent* directory (`url.deletingLastPathComponent()`),
    /// not just the leaf `.kernova` directory this returns.
    private func makeImportSource(
        name: String, storage: MockVMStorageService, createOnDisk: Bool = true
    ) throws -> (url: URL, config: VMConfiguration) {
        let config = VMConfiguration(name: name, guestOS: .linux, bootMode: .efi)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImportSource-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("\(name).kernova", isDirectory: true)
        if createOnDisk {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        storage.bundles[url] = config
        return (url, config)
    }

    @Test("importVM imports a single bundle and adds a non-preparing instance")
    func importVMSingleBundle() async throws {
        let (viewModel, storage, _, _, _) = makeViewModel()
        let source = try makeImportSource(name: "Imported VM", storage: storage)
        defer { try? FileManager.default.removeItem(at: source.url.deletingLastPathComponent()) }

        _ = viewModel.importVMs(fromDroppedURLs: [source.url])
        await viewModel.awaitPreparingForTesting()

        #expect(viewModel.instances.count == 1)
        let imported = viewModel.instances.first
        #expect(imported?.configuration.id == source.config.id)
        #expect(imported?.isPreparing == false)
        #expect(viewModel.selectedID == imported?.id)
        if let imported {
            #expect(FileManager.default.fileExists(atPath: imported.bundleURL.path(percentEncoded: false)))
        }
        #expect(presenter.showError == false)
    }

    /// Auto-start runs a guest with no user action, so it is local intent rather
    /// than something a bundle carries in from elsewhere.
    @Test("Importing a bundle pre-marked to start automatically clears the flag")
    func importClearsAutoStartFlag() async throws {
        let (viewModel, storage, _, _, _) = makeViewModel()
        let source = try makeImportSource(name: "Pre-marked VM", storage: storage)
        defer { try? FileManager.default.removeItem(at: source.url.deletingLastPathComponent()) }
        var marked = source.config
        marked.startsAutomaticallyOnLaunch = true
        storage.bundles[source.url] = marked

        _ = viewModel.importVMs(fromDroppedURLs: [source.url])
        await viewModel.awaitPreparingForTesting()

        let imported = try #require(viewModel.instances.first)
        #expect(imported.configuration.startsAutomaticallyOnLaunch == false)
        // …and the cleared flag reached the imported bundle, not just the row.
        #expect(storage.bundles[imported.bundleURL]?.startsAutomaticallyOnLaunch == false)
    }

    @Test("importVMs imports every bundle in a multi-select batch (#444)")
    func importVMsBatchImportsAll() async throws {
        let (viewModel, storage, _, _, _) = makeViewModel()
        let sources = try [
            makeImportSource(name: "Batch VM 1", storage: storage),
            makeImportSource(name: "Batch VM 2", storage: storage),
            makeImportSource(name: "Batch VM 3", storage: storage),
        ]
        defer {
            for source in sources {
                try? FileManager.default.removeItem(at: source.url.deletingLastPathComponent())
            }
        }

        _ = viewModel.importVMs(fromDroppedURLs: sources.map(\.url))
        await viewModel.awaitPreparingForTesting()

        // Pre-fix, a synchronous loop over `importVM` only imported the first bundle and
        // rejected the rest with a "preparing operation in progress" error.
        #expect(viewModel.instances.count == 3)
        let importedIDs = Set(viewModel.instances.map(\.configuration.id))
        #expect(importedIDs == Set(sources.map(\.config.id)))
        #expect(viewModel.instances.allSatisfy { !$0.isPreparing })
        #expect(presenter.showError == false)
    }

    @Test("importVMs batch with two identically-named bundles reserves distinct destinations (#487)")
    func importVMsBatchDuplicateFilenamesImportsBoth() async throws {
        let (viewModel, storage, _, _, _) = makeViewModel()
        // Two sources with the same leaf name but distinct parents (and distinct UUIDs).
        let first = try makeImportSource(name: "Same Name", storage: storage)
        let second = try makeImportSource(name: "Same Name", storage: storage)
        defer {
            try? FileManager.default.removeItem(at: first.url.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: second.url.deletingLastPathComponent())
        }

        _ = viewModel.importVMs(fromDroppedURLs: [first.url, second.url])
        await viewModel.awaitPreparingForTesting()

        // The second bundle's destination must not collide with the first's — reservation consults
        // in-flight phantoms in `instances`, not just on-disk state, so the not-yet-copied first
        // phantom is visible to the second's collision check (pre-fix, `fileExists` alone missed it).
        #expect(viewModel.instances.count == 2)
        let names = Set(viewModel.instances.map { $0.bundleURL.lastPathComponent })
        #expect(names == ["Same Name.kernova", "Same Name 2.kernova"])
        #expect(presenter.showError == false)
    }

    @Test("importVM selects the existing instance when a VM with the same UUID is already in the library")
    func importVMDuplicateUUIDSelectsExisting() async throws {
        let (viewModel, storage, _, _, _) = makeViewModel()
        let existing = makeInstance(name: "Existing VM")
        viewModel.instances.append(existing)

        // Source lives elsewhere on disk (never copied — the duplicate-UUID short-circuit
        // returns before the copy) but shares the same config UUID.
        let source = try makeImportSource(
            name: existing.configuration.name, storage: storage, createOnDisk: false)
        storage.bundles[source.url] = existing.configuration

        _ = viewModel.importVMs(fromDroppedURLs: [source.url])
        await viewModel.awaitPreparingForTesting()

        #expect(viewModel.instances.count == 1)
    }

    @Test("importVM selects the existing instance when the source is already inside the VMs directory")
    func importVMSourceAlreadyInVMsDirectory() async throws {
        let (viewModel, storage, _, _, _) = makeViewModel()
        let vmsDir = try storage.vmsDirectory
        let config = VMConfiguration(name: "Already There", guestOS: .linux, bootMode: .efi)
        let bundleURL = vmsDir.appendingPathComponent("\(config.id.uuidString).kernova", isDirectory: true)
        storage.bundles[bundleURL] = config
        let existing = VMInstance(configuration: config, bundleURL: bundleURL)
        viewModel.instances.append(existing)

        _ = viewModel.importVMs(fromDroppedURLs: [bundleURL])
        await viewModel.awaitPreparingForTesting()

        #expect(viewModel.instances.count == 1)
        #expect(viewModel.selectedID == existing.id)
    }

    @Test("importVMs batch with a duplicate in the middle still imports the surrounding bundles")
    func importVMsBatchWithDuplicateInMiddle() async throws {
        let (viewModel, storage, _, _, _) = makeViewModel()
        let existing = makeInstance(name: "Already Imported")
        viewModel.instances.append(existing)

        let first = try makeImportSource(name: "Batch VM 1", storage: storage)
        let duplicate = try makeImportSource(
            name: existing.configuration.name, storage: storage, createOnDisk: false)
        storage.bundles[duplicate.url] = existing.configuration
        let third = try makeImportSource(name: "Batch VM 3", storage: storage)
        defer {
            try? FileManager.default.removeItem(at: first.url.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: third.url.deletingLastPathComponent())
        }

        _ = viewModel.importVMs(fromDroppedURLs: [first.url, duplicate.url, third.url])
        await viewModel.awaitPreparingForTesting()

        // The duplicate is a synchronous no-op (select-existing) that must not stall the batch.
        #expect(viewModel.instances.count == 3)
        let importedIDs = Set(viewModel.instances.map(\.configuration.id))
        #expect(importedIDs == [existing.configuration.id, first.config.id, third.config.id])
        #expect(presenter.showError == false)
        #expect(viewModel.selectedID == third.config.id)
    }

    @Test("importVM removes the phantom and surfaces an error when the copy fails")
    func importVMCopyFailureRemovesPhantom() async throws {
        let (viewModel, storage, _, _, _) = makeViewModel()
        // Registered with the mock but never created on disk, so the real `FileManager.copyItem`
        // fails with "no such file."
        let source = try makeImportSource(name: "Missing Source", storage: storage, createOnDisk: false)

        _ = viewModel.importVMs(fromDroppedURLs: [source.url])
        await viewModel.awaitPreparingForTesting()

        #expect(viewModel.instances.isEmpty)
        #expect(presenter.showError == true)
        #expect(presenter.errorMessage != nil)
    }

    @Test("importVMs batch continues past a single failed import")
    func importVMsBatchContinuesAfterFailure() async throws {
        let (viewModel, storage, _, _, _) = makeViewModel()
        let first = try makeImportSource(name: "Batch VM 1", storage: storage)
        let failing = try makeImportSource(name: "Missing Source", storage: storage, createOnDisk: false)
        let third = try makeImportSource(name: "Batch VM 3", storage: storage)
        defer {
            try? FileManager.default.removeItem(at: first.url.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: third.url.deletingLastPathComponent())
        }

        _ = viewModel.importVMs(fromDroppedURLs: [first.url, failing.url, third.url])
        await viewModel.awaitPreparingForTesting()

        #expect(viewModel.instances.count == 2)
        let importedIDs = Set(viewModel.instances.map(\.configuration.id))
        #expect(importedIDs == [first.config.id, third.config.id])
        #expect(presenter.showError == true)
    }

    @Test("importVM proceeds while a clone is preparing (#487 — import/clone can't collide)")
    func importVMProceedsWhileCloning() async throws {
        let (viewModel, storage, _, _, _) = makeViewModel()
        let existing = makeInstance(name: "Cloning VM")
        markPreparing(existing)
        viewModel.instances.append(existing)

        let source = try makeImportSource(name: "Concurrent Import", storage: storage)
        defer { try? FileManager.default.removeItem(at: source.url.deletingLastPathComponent()) }

        _ = viewModel.importVMs(fromDroppedURLs: [source.url])
        await viewModel.awaitPreparingForTesting()

        #expect(viewModel.instances.count == 2)
        #expect(viewModel.instances.contains { $0.configuration.id == source.config.id })
        #expect(presenter.showError == false)
    }

    @Test("importVMs(fromDroppedURLs:) — two overlapping triggers both import without collision (#487)")
    func importVMsOverlappingTriggersAllImportWithoutCollision() async throws {
        let (viewModel, storage, _, _, _) = makeViewModel()
        let firstBatch = try [
            makeImportSource(name: "Trigger A VM 1", storage: storage),
            makeImportSource(name: "Trigger A VM 2", storage: storage),
        ]
        let secondBatch = try [
            makeImportSource(name: "Trigger B VM", storage: storage)
        ]
        let allSources = firstBatch + secondBatch
        defer {
            for source in allSources {
                try? FileManager.default.removeItem(at: source.url.deletingLastPathComponent())
            }
        }

        // Two independent triggers (e.g. a drag-and-drop batch and a Finder double-click)
        // firing back-to-back, mirroring SidebarViewController's acceptImport and
        // AppDelegate's application(_:open:) both calling importVMs(fromDroppedURLs:).
        _ = viewModel.importVMs(fromDroppedURLs: firstBatch.map(\.url))
        _ = viewModel.importVMs(fromDroppedURLs: secondBatch.map(\.url))

        await viewModel.awaitPreparingForTesting()

        // The second trigger reserves synchronously against the first trigger's already-registered
        // phantoms in `instances`, so every bundle imports with a distinct destination — no
        // collision and no waiting behind the other batch's copies.
        #expect(viewModel.instances.count == allSources.count)
        let importedIDs = Set(viewModel.instances.map(\.configuration.id))
        #expect(importedIDs == Set(allSources.map(\.config.id)))
        #expect(viewModel.instances.allSatisfy { !$0.isPreparing })
        #expect(presenter.showError == false)
    }

    @Test("registerPhantom preserves selection of an instance the user is already watching prepare (#487)")
    func registerPhantomPreservesSelectionOfPreparingInstance() async throws {
        let (viewModel, storage, _, _, _) = makeViewModel()
        let preparing = makeInstance(name: "Already Preparing")
        markPreparing(preparing, operation: .cloning)
        viewModel.instances.append(preparing)
        viewModel.selectedID = preparing.id

        let source = try makeImportSource(name: "Concurrent Import", storage: storage)
        defer { try? FileManager.default.removeItem(at: source.url.deletingLastPathComponent()) }

        _ = viewModel.importVMs(fromDroppedURLs: [source.url])
        await viewModel.awaitPreparingForTesting()

        // A second, unrelated import shouldn't steal the sidebar's focus from the
        // instance the user is already watching prepare.
        #expect(viewModel.selectedID == preparing.id)
        #expect(viewModel.instances.count == 2)
    }

    // MARK: - Clone

    /// Helper to mark an instance as preparing with a no-op task.
    private func markPreparing(_ instance: VMInstance, operation: VMInstance.PreparingOperation = .cloning) {
        instance.preparingState = VMInstance.PreparingState(operation: operation, task: Task {})
    }

    @Test("cloneVM creates phantom row immediately with preparingState")
    func cloneVMCreatesPhantomRow() {
        let (viewModel, storage, _, _, _) = makeViewModel()
        let instance = makeInstance(name: "Original")
        instance.enter(.stopped)
        viewModel.instances.append(instance)
        storage.bundles[instance.bundleURL] = instance.configuration

        viewModel.cloneVM(instance)

        #expect(viewModel.instances.count == 2)
        let phantom = viewModel.instances.first { $0.id != instance.id }
        #expect(phantom != nil)
        #expect(phantom?.isPreparing == true)
        #expect(phantom?.preparingState?.operation == .cloning)
        #expect(phantom?.name == "Original Copy")
        #expect(viewModel.selectedID == phantom?.id)
    }

    @Test("cloneVM transitions phantom to real on success")
    func cloneVMTransitionsPhantom() async {
        let (viewModel, storage, _, _, _) = makeViewModel()
        let instance = makeInstance(name: "Original")
        instance.enter(.stopped)
        viewModel.instances.append(instance)
        storage.bundles[instance.bundleURL] = instance.configuration

        viewModel.cloneVM(instance)

        let phantom = viewModel.instances.first { $0.id != instance.id }
        #expect(phantom != nil)

        // Wait for the preparing task to complete
        await phantom?.preparingState?.task.value

        #expect(phantom?.isPreparing == false)
        #expect(phantom?.preparingState == nil)
        #expect(viewModel.instances.count == 2)
        #expect(storage.cloneVMBundleCallCount == 1)
    }

    @Test("cloneVM removes phantom on storage error and selects remaining instance")
    func cloneVMRemovesPhantomOnError() async {
        let storage = MockVMStorageService()
        storage.cloneVMBundleError = VMStorageError.bundleAlreadyExists(UUID())
        let (viewModel, _, _, _, _) = makeViewModel(storageService: storage)
        let instance = makeInstance(name: "Fail Clone")
        instance.enter(.stopped)
        viewModel.instances.append(instance)

        viewModel.cloneVM(instance)

        // Phantom was created
        let phantom = viewModel.instances.first { $0.id != instance.id }
        #expect(phantom != nil)

        // Wait for the task to complete (and fail)
        await phantom?.preparingState?.task.value

        #expect(viewModel.instances.count == 1)
        #expect(viewModel.instances.first?.id == instance.id)
        #expect(viewModel.selectedID == instance.id)
        #expect(presenter.showError == true)
        #expect(presenter.errorMessage != nil)
    }

    @Test("cloneVM is skipped when VM is running")
    func cloneVMSkippedWhenRunning() {
        let (viewModel, storage, _, _, _) = makeViewModel()
        let instance = makeInstance(name: "Running VM")
        instance.enter(.running(sessionID: UUID()))
        viewModel.instances.append(instance)

        viewModel.cloneVM(instance)

        #expect(viewModel.instances.count == 1)
        #expect(storage.cloneVMBundleCallCount == 0)
    }

    @Test("cloneVM proceeds while an import is preparing (#487 — clone/import can't collide)")
    func cloneVMProceedsWhileImportPreparing() async {
        let (viewModel, storage, _, _, _) = makeViewModel()
        let existing = makeInstance(name: "Importing")
        markPreparing(existing, operation: .importing)
        let instance = makeInstance(name: "Source")
        instance.enter(.stopped)
        viewModel.instances = [existing, instance]
        storage.bundles[instance.bundleURL] = instance.configuration

        viewModel.cloneVM(instance)

        let phantom = viewModel.instances.first { $0.id != existing.id && $0.id != instance.id }
        #expect(phantom != nil)

        // Wait for the preparing task to complete
        await phantom?.preparingState?.task.value

        #expect(viewModel.instances.count == 3)
        #expect(presenter.showError == false)
    }

    @Test("cloneVM proceeds while another clone is preparing (#487 — UUID-named bundles can't collide)")
    func cloneVMProceedsWhileAnotherCloneIsPreparing() async {
        let (viewModel, storage, _, _, _) = makeViewModel()
        let existing = makeInstance(name: "Cloning")
        markPreparing(existing, operation: .cloning)
        let instance = makeInstance(name: "Source")
        instance.enter(.stopped)
        viewModel.instances = [existing, instance]
        storage.bundles[instance.bundleURL] = instance.configuration

        viewModel.cloneVM(instance)

        let phantom = viewModel.instances.first { $0.id != existing.id && $0.id != instance.id }
        #expect(phantom != nil)

        await phantom?.preparingState?.task.value

        #expect(viewModel.instances.count == 3)
        #expect(presenter.showError == false)
    }

    @Test("cloneVM increments name when Copy already exists")
    func cloneVMIncrementsName() {
        let (viewModel, storage, _, _, _) = makeViewModel()
        let instance = makeInstance(name: "VM")
        instance.enter(.stopped)
        let copyInstance = makeInstance(name: "VM Copy")
        viewModel.instances = [instance, copyInstance]
        storage.bundles[instance.bundleURL] = instance.configuration

        viewModel.cloneVM(instance)

        let cloned = viewModel.instances.first { $0.id != instance.id && $0.id != copyInstance.id }
        #expect(cloned?.name == "VM Copy 2")
    }

    @Test("cloneVM remaps internal additional disk path to its regenerated id and copies the file")
    func cloneVMRemapsAdditionalDiskPath() async throws {
        let (viewModel, storage, _, _, _) = makeViewModel()

        // Build a source bundle on disk with a real additional-disk file
        // living at `AdditionalDisks/<source-disk-id>.asif`.
        let instance = makeInstance(name: "Original")
        instance.enter(.stopped)
        let sourceDiskID = UUID()
        let sourceLayout = VMBundleLayout(bundleURL: instance.bundleURL)
        let fm = FileManager.default
        try fm.createDirectory(at: sourceLayout.additionalDisksDirectoryURL, withIntermediateDirectories: true)
        let sourceDiskFile = sourceLayout.additionalDiskURL(id: sourceDiskID)
        try Data("disk-bytes".utf8).write(to: sourceDiskFile)
        defer { try? fm.removeItem(at: instance.bundleURL) }

        instance.configuration.storageDisks = [
            StorageDisk(path: "Disk.asif", isInternal: true),
            StorageDisk(
                id: sourceDiskID,
                path: "AdditionalDisks/\(sourceDiskID.uuidString).asif",
                label: "Extra",
                isInternal: true
            ),
        ]
        viewModel.instances.append(instance)
        storage.bundles[instance.bundleURL] = instance.configuration

        viewModel.cloneVM(instance)

        let phantom = viewModel.instances.first { $0.id != instance.id }
        #expect(phantom != nil)
        await phantom?.preparingState?.task.value
        defer { phantom.map { try? fm.removeItem(at: $0.bundleURL) } }

        let clonedDisks = phantom?.configuration.storageDisks ?? []
        guard let extra = clonedDisks.first(where: { $0.path.hasPrefix("AdditionalDisks/") }) else {
            Issue.record("Cloned configuration is missing the additional disk")
            return
        }

        // The path must point at the regenerated id, not the source's id,
        // and the copied file must exist at exactly that resolved location.
        #expect(extra.id != sourceDiskID)
        #expect(extra.path == "AdditionalDisks/\(extra.id.uuidString).asif")
        if let phantom {
            let resolved = phantom.bundleURL.appendingPathComponent(extra.path)
            #expect(fm.fileExists(atPath: resolved.path(percentEncoded: false)))
        }
    }

    // MARK: - Clone Machine Identity

    /// The identifier every clone-identity source VM starts out carrying.
    private static let sourceMachineID = Data([1, 2, 3])

    /// A stopped source VM carrying `machineID` in whichever identity field
    /// `guestOS` uses, appended to `viewModel` and registered with `storage` so
    /// the clone's copy task can run to completion.
    ///
    /// Passing `nil` leaves the identity field empty, and the bundle directory is
    /// never created, so the source has no identifier file to fall back on either.
    private func appendCloneSource(
        to viewModel: VMLibraryViewModel, storage: MockVMStorageService, guestOS: VMGuestOS,
        machineID: Data? = sourceMachineID
    ) -> VMInstance {
        let instance = makeInstance(name: "Original", guestOS: guestOS)
        instance.enter(.stopped)
        if guestOS == .macOS {
            instance.configuration.machineIdentifierData = machineID
        } else {
            instance.configuration.genericMachineIdentifierData = machineID
        }
        viewModel.instances.append(instance)
        storage.bundles[instance.bundleURL] = instance.configuration
        return instance
    }

    /// The identity field `guestOS` uses, read off the clone `viewModel`
    /// produced from `source` once its copy task has settled.
    private func clonedMachineID(
        of source: VMInstance, in viewModel: VMLibraryViewModel, guestOS: VMGuestOS
    ) async -> Data? {
        let clone = viewModel.instances.first { $0.id != source.id }
        await clone?.preparingState?.task.value
        return guestOS == .macOS
            ? clone?.configuration.machineIdentifierData
            : clone?.configuration.genericMachineIdentifierData
    }

    @Test("cloneVM gives a macOS clone a fresh machine ID by default")
    func cloneVMGeneratesNewMachineIDByDefault() async {
        let (viewModel, storage, _, _, _) = makeViewModel()
        let source = appendCloneSource(to: viewModel, storage: storage, guestOS: .macOS)

        viewModel.cloneVM(source)
        let clonedID = await clonedMachineID(of: source, in: viewModel, guestOS: .macOS)

        #expect(clonedID != nil)
        #expect(clonedID != Self.sourceMachineID)
        #expect(storage.lastCloneFilesToCopy?.contains("MachineIdentifier") == false)
    }

    @Test("cloneVM keeps the source machine ID when the preference is off")
    func cloneVMKeepsMachineIDWhenPreferenceOff() async {
        let (viewModel, storage, _, _, _) = makeViewModel()
        preferences.cloneGeneratesNewMachineID = false
        let source = appendCloneSource(to: viewModel, storage: storage, guestOS: .macOS)

        viewModel.cloneVM(source)
        let clonedID = await clonedMachineID(of: source, in: viewModel, guestOS: .macOS)

        #expect(clonedID == Self.sourceMachineID)
        // The identifier file has to travel with the bundle, not just the config.
        #expect(storage.lastCloneFilesToCopy?.contains("MachineIdentifier") == true)
    }

    @Test("cloneVM's explicit generateNewMachineID beats the preference")
    func cloneVMExplicitFlagOverridesPreference() async {
        let (viewModel, storage, _, _, _) = makeViewModel()
        let source = appendCloneSource(to: viewModel, storage: storage, guestOS: .macOS)

        // Preference left at its `true` default — the argument decides.
        viewModel.cloneVM(source, generateNewMachineID: false)
        let clonedID = await clonedMachineID(of: source, in: viewModel, guestOS: .macOS)

        #expect(clonedID == Self.sourceMachineID)
        #expect(storage.lastCloneFilesToCopy?.contains("MachineIdentifier") == true)
    }

    @Test("cloneVMWithOppositeMachineIdentity keeps the ID under the default preference")
    func cloneVMWithOppositeMachineIdentityKeepsIDByDefault() async {
        let (viewModel, storage, _, _, _) = makeViewModel()
        let source = appendCloneSource(to: viewModel, storage: storage, guestOS: .macOS)

        viewModel.cloneVMWithOppositeMachineIdentity(source)
        let clonedID = await clonedMachineID(of: source, in: viewModel, guestOS: .macOS)

        #expect(clonedID == Self.sourceMachineID)
    }

    @Test("cloneVMWithOppositeMachineIdentity generates a new ID when the preference keeps it")
    func cloneVMWithOppositeMachineIdentityGeneratesIDWhenPreferenceOff() async {
        let (viewModel, storage, _, _, _) = makeViewModel()
        preferences.cloneGeneratesNewMachineID = false
        let source = appendCloneSource(to: viewModel, storage: storage, guestOS: .macOS)

        viewModel.cloneVMWithOppositeMachineIdentity(source)
        let clonedID = await clonedMachineID(of: source, in: viewModel, guestOS: .macOS)

        #expect(clonedID != nil)
        #expect(clonedID != Self.sourceMachineID)
    }

    @Test("cloneVM regenerates an EFI clone's generic machine ID by default")
    func cloneVMGeneratesNewGenericMachineIDByDefault() async {
        let (viewModel, storage, _, _, _) = makeViewModel()
        let source = appendCloneSource(to: viewModel, storage: storage, guestOS: .linux)

        viewModel.cloneVM(source)
        let clonedID = await clonedMachineID(of: source, in: viewModel, guestOS: .linux)

        #expect(clonedID != nil)
        #expect(clonedID != Self.sourceMachineID)
    }

    @Test("cloneVM keeps an EFI clone's generic machine ID when the preference is off")
    func cloneVMKeepsGenericMachineIDWhenPreferenceOff() async {
        let (viewModel, storage, _, _, _) = makeViewModel()
        preferences.cloneGeneratesNewMachineID = false
        let source = appendCloneSource(to: viewModel, storage: storage, guestOS: .linux)

        viewModel.cloneVM(source)
        let clonedID = await clonedMachineID(of: source, in: viewModel, guestOS: .linux)

        #expect(clonedID == Self.sourceMachineID)
    }

    @Test("a keep-mode clone of a macOS VM with no identity at all mints one")
    func cloneVMKeepModeMintsMissingMachineID() async {
        let (viewModel, storage, _, _, _) = makeViewModel()
        preferences.cloneGeneratesNewMachineID = false
        let source = appendCloneSource(
            to: viewModel, storage: storage, guestOS: .macOS, machineID: nil)

        viewModel.cloneVM(source)
        let clonedID = await clonedMachineID(of: source, in: viewModel, guestOS: .macOS)

        #expect(source.effectiveMachineIdentifierData == nil)
        #expect(clonedID != nil)
    }

    @Test("a keep-mode clone of an EFI VM with no generic identity mints one")
    func cloneVMKeepModeMintsMissingGenericMachineID() async {
        let (viewModel, storage, _, _, _) = makeViewModel()
        preferences.cloneGeneratesNewMachineID = false
        let source = appendCloneSource(
            to: viewModel, storage: storage, guestOS: .linux, machineID: nil)

        viewModel.cloneVM(source)
        let clonedID = await clonedMachineID(of: source, in: viewModel, guestOS: .linux)

        #expect(source.configuration.genericMachineIdentifierData == nil)
        #expect(clonedID != nil)
    }

    @Test("a keep-mode clone leaves a file-only macOS identity to the bundle copy")
    func cloneVMKeepModeLeavesFileOnlyMachineIDToTheCopy() async throws {
        let (viewModel, storage, _, _, _) = makeViewModel()
        preferences.cloneGeneratesNewMachineID = false
        let source = appendCloneSource(
            to: viewModel, storage: storage, guestOS: .macOS, machineID: nil)
        try FileManager.default.createDirectory(
            at: source.bundleURL, withIntermediateDirectories: true)
        try Self.sourceMachineID.write(to: source.machineIdentifierURL)
        defer { try? FileManager.default.removeItem(at: source.bundleURL) }

        viewModel.cloneVM(source)
        let clonedID = await clonedMachineID(of: source, in: viewModel, guestOS: .macOS)

        // Nothing minted into the configuration: the copied file is the identity.
        #expect(clonedID == nil)
        #expect(storage.lastCloneFilesToCopy?.contains("MachineIdentifier") == true)
    }

    // MARK: - Cancel Preparing

    @Test("cancelPreparingVerb marks the row Cancelling… and keeps it until the copy settles (#496)")
    func cancelPreparingVerbMarksCancelling() {
        let (viewModel, _, _, _, _) = makeViewModel()
        let phantom = makeInstance(name: "Cloning VM")
        markPreparing(phantom)
        viewModel.instances.append(phantom)
        viewModel.selectedID = phantom.id

        viewModel.cancelPreparing(phantom)

        // The uninterruptible copy is still (notionally) in flight, so the row stays as "Cancelling…";
        // the copy task removes + trashes it once the copy settles.
        #expect(viewModel.instances.count == 1)
        #expect(phantom.preparingState?.isCancelling == true)
        #expect(phantom.preparingState?.displayLabel == "Cancelling\u{2026}")
    }

    @Test("cancelPreparingVerb removes the row and trashes after the copy settles (#496)")
    func cancelPreparingVerbRemovesAfterCopySettles() async throws {
        let (viewModel, storage, _, _, _) = makeViewModel()
        let source = try makeImportSource(name: "Cancel Me", storage: storage)
        defer { try? FileManager.default.removeItem(at: source.url.deletingLastPathComponent()) }

        _ = viewModel.importVMs(fromDroppedURLs: [source.url])
        let phantom = try #require(viewModel.instances.first { $0.configuration.id == source.config.id })

        viewModel.cancelPreparing(phantom)
        await viewModel.awaitPreparingForTesting()

        // Once the copy settles the copy task removes the row (and trashes the bundle via the
        // detached, best-effort trash path exercised by `importVMCopyFailureRemovesPhantom`) —
        // whether the copy finished before or after the cancel, the end state is the same.
        #expect(viewModel.instances.isEmpty)
        #expect(phantom.preparingState == nil)
        #expect(presenter.showError == false)
    }

    @Test("cancelPreparingVerb selects remaining instance after the copy settles (#496)")
    func cancelPreparingVerbSelectsRemaining() async throws {
        let (viewModel, storage, _, _, _) = makeViewModel()
        let other = makeInstance(name: "Other VM")
        viewModel.instances.append(other)
        let source = try makeImportSource(name: "Cancel Me", storage: storage)
        defer { try? FileManager.default.removeItem(at: source.url.deletingLastPathComponent()) }

        _ = viewModel.importVMs(fromDroppedURLs: [source.url])
        let phantom = try #require(viewModel.instances.first { $0.configuration.id == source.config.id })

        viewModel.cancelPreparing(phantom)
        await viewModel.awaitPreparingForTesting()

        #expect(viewModel.instances.count == 1)
        #expect(viewModel.instances.first?.id == other.id)
        #expect(viewModel.selectedID == other.id)
    }

    @Test("requestCancelPreparing sets state for alert")
    func requestCancelPreparingSetsState() {
        let (viewModel, _, _, _, _) = makeViewModel()
        let phantom = makeInstance(name: "Cloning VM")
        markPreparing(phantom)
        viewModel.instances.append(phantom)

        viewModel.requestCancelPreparing(phantom)

        #expect(presenter.showCancelPreparingConfirmation == true)
        #expect(presenter.preparingInstanceToCancel?.id == phantom.id)
    }

    // MARK: - Force Stop Confirmation

    @Test("requestForceStop sets instance and shows confirmation")
    func requestForceStop() {
        let (viewModel, _, _, _, _) = makeViewModel()
        let instance = makeInstance()
        instance.enter(.running(sessionID: UUID()))
        viewModel.instances.append(instance)

        viewModel.requestForceStop(instance)

        #expect(presenter.instanceToForceStop?.id == instance.id)
        #expect(presenter.showForceStopConfirmation == true)
    }

    @Test("forceStopVerb delegates to lifecycle")
    func forceStopVerb() async {
        let (viewModel, _, _, virtService, _) = makeViewModel()
        let instance = makeInstance()
        instance.enter(.running(sessionID: UUID()))
        viewModel.instances.append(instance)

        await viewModel.forceStop(instance)

        #expect(virtService.forceStopCallCount == 1)
        #expect(instance.status == .stopped)
    }

    // MARK: - Reorder

    @Test("moveVM reorders instances and persists order to UserDefaults")
    func moveVMReordersAndPersists() {
        let (viewModel, _, _, _, _) = makeViewModel()
        let a = makeInstance(name: "A")
        let b = makeInstance(name: "B")
        let c = makeInstance(name: "C")
        viewModel.instances = [a, b, c]

        viewModel.moveVM(fromOffsets: IndexSet(integer: 2), toOffset: 0)

        #expect(viewModel.instances.map(\.name) == ["C", "A", "B"])
        #expect(preferences.vmOrder == [c.id, a.id, b.id])
    }

    @Test("loadVMs applies custom order from UserDefaults")
    func loadVMsAppliesCustomOrder() async {
        let storage = MockVMStorageService()
        let config1 = VMConfiguration(
            name: "First", guestOS: .linux, bootMode: .efi, createdAt: Date(timeIntervalSince1970: 100))
        let config2 = VMConfiguration(
            name: "Second", guestOS: .linux, bootMode: .efi, createdAt: Date(timeIntervalSince1970: 200))
        let config3 = VMConfiguration(
            name: "Third", guestOS: .linux, bootMode: .efi, createdAt: Date(timeIntervalSince1970: 300))
        let url1 = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(config1.id.uuidString).kernova", isDirectory: true)
        let url2 = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(config2.id.uuidString).kernova", isDirectory: true)
        let url3 = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(config3.id.uuidString).kernova", isDirectory: true)
        storage.bundles[url1] = config1
        storage.bundles[url2] = config2
        storage.bundles[url3] = config3

        // Set custom order: Third, First, Second
        preferences.vmOrder = [config3.id, config1.id, config2.id]

        let viewModel = VMLibraryViewModel(
            storageService: storage,
            diskImageService: MockDiskImageService(),
            virtualizationService: MockVirtualizationService(),
            installService: MockMacOSInstallService(),
            ipswService: MockIPSWService(),
            preferences: preferences
        )
        viewModel.presenter = presenter
        await viewModel.loadVMs()

        #expect(viewModel.instances.map(\.name) == ["Third", "First", "Second"])
    }

    @Test("loadVMs falls back to createdAt when no custom order exists")
    func loadVMsFallsBackToCreatedAt() async {
        let storage = MockVMStorageService()
        let config1 = VMConfiguration(
            name: "Older", guestOS: .linux, bootMode: .efi, createdAt: Date(timeIntervalSince1970: 100))
        let config2 = VMConfiguration(
            name: "Newer", guestOS: .linux, bootMode: .efi, createdAt: Date(timeIntervalSince1970: 200))
        let url1 = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(config1.id.uuidString).kernova", isDirectory: true)
        let url2 = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(config2.id.uuidString).kernova", isDirectory: true)
        storage.bundles[url1] = config1
        storage.bundles[url2] = config2

        let (viewModel, _, _, _, _) = makeViewModel(storageService: storage)
        await viewModel.loadVMs()

        #expect(viewModel.instances.map(\.name) == ["Older", "Newer"])
    }

    @Test("reconcileWithDisk appends new VMs after custom-ordered ones")
    func reconcileAppendsNewVMs() async {
        let storage = MockVMStorageService()
        let config1 = VMConfiguration(
            name: "Existing", guestOS: .linux, bootMode: .efi, createdAt: Date(timeIntervalSince1970: 200))
        let url1 = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(config1.id.uuidString).kernova", isDirectory: true)
        storage.bundles[url1] = config1

        let (viewModel, _, _, _, _) = makeViewModel(storageService: storage)
        await viewModel.loadVMs()
        #expect(viewModel.instances.count == 1)

        // Simulate a new VM appearing on disk
        let config2 = VMConfiguration(
            name: "Discovered", guestOS: .linux, bootMode: .efi, createdAt: Date(timeIntervalSince1970: 100))
        let url2 = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(config2.id.uuidString).kernova", isDirectory: true)
        storage.bundles[url2] = config2

        viewModel.reconcileWithDisk()

        #expect(viewModel.instances.count == 2)
        // Existing VM should stay first (it's in customOrder), Discovered appends at end
        #expect(viewModel.instances.first?.name == "Existing")
        #expect(viewModel.instances.last?.name == "Discovered")
    }

    @Test("deleteVM removes VM from persisted order")
    func deleteRemovesFromOrder() async {
        let (viewModel, storage, _, _, _) = makeViewModel()
        let a = makeInstance(name: "A")
        let b = makeInstance(name: "B")
        viewModel.instances = [a, b]
        viewModel.selectedID = b.id
        storage.bundles[b.bundleURL] = b.configuration

        await viewModel.delete(b)

        #expect(preferences.vmOrder == [a.id])
    }

    @Test("custom order ignores stale UUIDs not present in loaded VMs")
    func customOrderIgnoresStaleUUIDs() async {
        let storage = MockVMStorageService()
        let config = VMConfiguration(name: "Only VM", guestOS: .linux, bootMode: .efi)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(config.id.uuidString).kernova", isDirectory: true)
        storage.bundles[url] = config

        // Set custom order with a stale UUID followed by the real one
        let staleID = UUID()
        preferences.vmOrder = [staleID, config.id]

        let viewModel = VMLibraryViewModel(
            storageService: storage,
            diskImageService: MockDiskImageService(),
            virtualizationService: MockVirtualizationService(),
            installService: MockMacOSInstallService(),
            ipswService: MockIPSWService(),
            preferences: preferences
        )
        viewModel.presenter = presenter
        await viewModel.loadVMs()

        #expect(viewModel.instances.count == 1)
        #expect(viewModel.instances.first?.name == "Only VM")
    }

    // MARK: - Guest Agent Installer

    @Test("mountGuestAgentInstaller appends DMG to removableMedia and shows alert")
    func mountGuestAgentInstallerAppendsAndShowsAlert() async throws {
        let installerURL = try #require(KernovaMacOSAgentInfo.installerDiskImageURL)
        let mock = MockUSBDeviceService()
        let (viewModel, _, _, _, _) = makeViewModel(usbDeviceService: mock)
        let instance = makeInstance()
        instance.enter(.running(sessionID: UUID()))
        instance.beginSessionContext()
        viewModel.instances.append(instance)

        viewModel.mountGuestAgentInstaller(on: instance)

        // Alert is set synchronously; reconcile attach is async.
        #expect(presenter.showInstallerMountedAlert == true)
        #expect(presenter.installerMountedVMName == instance.name)
        #expect(presenter.installerMountedPurpose == .install)
        #expect(instance.configuration.removableMedia?.count == 1)
        #expect(instance.configuration.removableMedia?.first?.path == installerURL.path(percentEncoded: false))

        while instance.liveRemovableMedia.isEmpty { await Task.yield() }

        #expect(mock.attachCallCount == 1)
        #expect(mock.lastAttachedReadOnly == true)
    }

    @Test("mountGuestAgentInstaller is a no-op when DMG already in removableMedia, but still surfaces alert")
    func mountGuestAgentInstallerAlreadyMountedSurfacesAlert() throws {
        let installerURL = try #require(KernovaMacOSAgentInfo.installerDiskImageURL)
        let mock = MockUSBDeviceService()
        let (viewModel, _, _, _, _) = makeViewModel(usbDeviceService: mock)
        let instance = makeInstance()
        instance.configuration.removableMedia = [
            RemovableMediaItem(path: installerURL.path(percentEncoded: false), readOnly: true)
        ]
        viewModel.instances.append(instance)

        viewModel.mountGuestAgentInstaller(on: instance)

        #expect(mock.attachCallCount == 0)
        #expect(presenter.showInstallerMountedAlert == true)
        #expect(presenter.installerMountedVMName == instance.name)
        // List unchanged
        #expect(instance.configuration.removableMedia?.count == 1)
    }

    @Test("unmountGuestAgentInstaller is no-op when DMG not in removableMedia")
    func unmountGuestAgentInstallerNoOpWhenNotPresent() async throws {
        _ = try #require(KernovaMacOSAgentInfo.installerDiskImageURL)
        let mock = MockUSBDeviceService()
        let (viewModel, _, _, _, _) = makeViewModel(usbDeviceService: mock)
        let instance = makeInstance()
        // List has an unrelated item only
        let unrelated = RemovableMediaItem(path: "/some/other/disk.img", readOnly: false)
        instance.configuration.removableMedia = [unrelated]
        viewModel.instances.append(instance)

        viewModel.unmountGuestAgentInstaller(from: instance)
        await Task.yield()

        #expect(mock.detachCallCount == 0)
        #expect(instance.configuration.removableMedia?.count == 1)
        #expect(instance.configuration.removableMedia?.first?.path == unrelated.path)
    }

    @Test("unmountGuestAgentInstaller removes DMG entry and triggers detach")
    func unmountGuestAgentInstallerRemovesEntry() async throws {
        let installerURL = try #require(KernovaMacOSAgentInfo.installerDiskImageURL)
        let mock = MockUSBDeviceService()
        let (viewModel, _, _, _, _) = makeViewModel(usbDeviceService: mock)
        let instance = makeInstance()
        instance.enter(.running(sessionID: UUID()))
        instance.beginSessionContext()
        let installerItem = RemovableMediaItem(path: installerURL.path(percentEncoded: false), readOnly: true)
        instance.configuration.removableMedia = [installerItem]
        instance.sessionContext?.liveRemovableMedia = [
            USBDeviceInfo(id: installerItem.id, path: installerItem.path, readOnly: installerItem.readOnly)
        ]
        viewModel.instances.append(instance)

        viewModel.unmountGuestAgentInstaller(from: instance)

        while !instance.liveRemovableMedia.isEmpty { await Task.yield() }

        #expect(mock.detachCallCount == 1)
        #expect(instance.configuration.removableMedia == nil)
    }

    @Test("mountGuestAgentInstaller forwards the .manage purpose to the alert")
    func mountGuestAgentInstallerManagePurpose() throws {
        _ = try #require(KernovaMacOSAgentInfo.installerDiskImageURL)
        let (viewModel, _, _, _, _) = makeViewModel()
        let instance = makeInstance()
        instance.enter(.running(sessionID: UUID()))
        viewModel.instances.append(instance)

        viewModel.mountGuestAgentInstaller(on: instance, purpose: .manage)

        #expect(presenter.installerMountedPurpose == .manage)
        #expect(presenter.installerMountedDelivery == .usb)
    }

    @Test("mountGuestAgentInstaller attaches nothing for a guest that takes the disk on virtio")
    func mountGuestAgentInstallerVirtioAttachesNothing() async throws {
        _ = try #require(KernovaMacOSAgentInfo.installerDiskImageURL)
        let mock = MockUSBDeviceService()
        let (viewModel, _, _, _, _) = makeViewModel(usbDeviceService: mock)
        let instance = makeInstance(guestOS: .macOS)
        instance.configuration.installedImage = .macOSRestoreImage(version: "12.0.1", build: "21A559")
        instance.enter(.running(sessionID: UUID()))
        viewModel.instances.append(instance)

        viewModel.mountGuestAgentInstaller(on: instance)
        await Task.yield()

        #expect(presenter.showInstallerMountedAlert == true)
        #expect(presenter.installerMountedDelivery == .virtio)
        // The disk rides in on `storageDevices` at boot, so neither the
        // removable-media list nor the persisted disk list may grow.
        #expect(instance.configuration.removableMedia == nil)
        #expect(instance.configuration.storageDisks == nil)
        #expect(mock.attachCallCount == 0)
        #expect(!viewModel.isGuestAgentInstallerMounted(on: instance))
    }

    @Test("A virtio-delivery guest still ejects a USB disk left over from an earlier session")
    func virtioGuestStillEjectsStaleUSBDisk() async throws {
        let installerURL = try #require(KernovaMacOSAgentInfo.installerDiskImageURL)
        let mock = MockUSBDeviceService()
        let (viewModel, _, _, _, _) = makeViewModel(usbDeviceService: mock)
        let instance = makeInstance(guestOS: .macOS)
        instance.configuration.installedImage = .macOSRestoreImage(version: "12.0.1", build: "21A559")
        instance.enter(.running(sessionID: UUID()))
        instance.beginSessionContext()
        let installerItem = RemovableMediaItem(
            path: installerURL.path(percentEncoded: false), readOnly: true)
        instance.configuration.removableMedia = [installerItem]
        instance.sessionContext?.liveRemovableMedia = [
            USBDeviceInfo(id: installerItem.id, path: installerItem.path, readOnly: installerItem.readOnly)
        ]
        viewModel.instances.append(instance)

        viewModel.unmountGuestAgentInstaller(from: instance)

        while !instance.liveRemovableMedia.isEmpty { await Task.yield() }

        #expect(mock.detachCallCount == 1)
        #expect(instance.configuration.removableMedia == nil)
    }

    @Test("isGuestAgentInstallerMounted reflects whether the bundled DMG is attached")
    func isGuestAgentInstallerMountedReflectsState() throws {
        let installerURL = try #require(KernovaMacOSAgentInfo.installerDiskImageURL)
        let (viewModel, _, _, _, _) = makeViewModel()
        let instance = makeInstance()
        viewModel.instances.append(instance)

        #expect(!viewModel.isGuestAgentInstallerMounted(on: instance))

        instance.configuration.removableMedia = [
            RemovableMediaItem(path: installerURL.path(percentEncoded: false), readOnly: true)
        ]
        #expect(viewModel.isGuestAgentInstallerMounted(on: instance))

        // An unrelated removable item must not count as the installer.
        instance.configuration.removableMedia = [
            RemovableMediaItem(path: "/some/other/disk.img", readOnly: false)
        ]
        #expect(!viewModel.isGuestAgentInstallerMounted(on: instance))
    }

    @Test("onAgentBecameCurrent (wired by loadVMs) auto-ejects the installer disk")
    func onAgentBecameCurrentAutoEjectsInstaller() async throws {
        let installerURL = try #require(KernovaMacOSAgentInfo.installerDiskImageURL)
        let storage = MockVMStorageService()
        var config = VMConfiguration(name: "Wired VM", guestOS: .linux, bootMode: .efi)
        config.removableMedia = [
            RemovableMediaItem(path: installerURL.path(percentEncoded: false), readOnly: true)
        ]
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(config.id.uuidString).kernova", isDirectory: true)
        storage.bundles[url] = config
        let (viewModel, _, _, _, _) = makeViewModel(storageService: storage)
        await viewModel.loadVMs()
        let instance = try #require(viewModel.instances.first)

        #expect(viewModel.isGuestAgentInstallerMounted(on: instance))

        // Fire the hook the view model wired in `wirePersistence(for:)` — it
        // must detach the installer regardless of which window is open.
        instance.onAgentBecameCurrent?()

        #expect(!viewModel.isGuestAgentInstallerMounted(on: instance))
        #expect(instance.configuration.removableMedia == nil)
    }

    // MARK: - Storage Disk Helpers

    @Test("removeStorageDisk with trashFile=false removes the entry without touching the file")
    func removeStorageDiskKeepsFile() {
        let (viewModel, _, _, _, _) = makeViewModel()
        let instance = makeInstance()
        let mainDisk = StorageDisk(
            path: "Disk.asif", readOnly: false, label: "Main Disk",
            isInternal: true, kind: .virtio
        )
        let extra = StorageDisk(
            path: "AdditionalDisks/\(UUID().uuidString).asif",
            readOnly: false, label: "Extra", isInternal: true, kind: .virtio
        )
        instance.configuration.storageDisks = [mainDisk, extra]
        viewModel.instances.append(instance)

        viewModel.removeStorageDisk(extra, from: instance, trashFile: false)

        let disks = instance.configuration.storageDisks ?? []
        #expect(disks.count == 1)
        #expect(disks.first?.id == mainDisk.id)
        // No presentError side effect — no file op was attempted.
        #expect(!presenter.showError)
    }

    @Test("removeStorageDisk on external disk with trashFile=true trashes the host file")
    func removeStorageDiskExternalTrashesFile() async throws {
        let (viewModel, _, _, _, _) = makeViewModel()
        let instance = makeInstance()
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-external.img")

        let external = StorageDisk(
            path: destination.path(percentEncoded: false),
            readOnly: false, label: "External", isInternal: false, kind: .virtio
        )
        instance.configuration.storageDisks = [external]
        viewModel.instances.append(instance)

        await viewModel.removeStorageDisk(external, from: instance, trashFile: true)?.value

        #expect(instance.configuration.storageDisks == nil)
        #expect(fileSystem.trashedURLs == [destination])
        #expect(!presenter.showError)
    }

    @Test("removeStorageDisk on external disk with trashFile=false leaves the host file alone")
    func removeStorageDiskExternalKeepsFile() throws {
        let (viewModel, _, _, _, _) = makeViewModel()
        let instance = makeInstance()
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-external.img")

        let external = StorageDisk(
            path: destination.path(percentEncoded: false),
            readOnly: false, label: "External", isInternal: false, kind: .virtio
        )
        instance.configuration.storageDisks = [external]
        viewModel.instances.append(instance)

        viewModel.removeStorageDisk(external, from: instance, trashFile: false)

        #expect(instance.configuration.storageDisks == nil)
        #expect(fileSystem.trashedURLs.isEmpty)
        #expect(!presenter.showError)
    }

    @Test("removeStorageDisk with trashFile=true swallows missing-file errors")
    func removeStorageDiskMissingFileSwallows() async {
        // A user can race delete-in-Finder against the confirmation alert,
        // or an external disk's source can be moved between sessions.
        // trashItem failing with `.fileNoSuchFile` should not raise an
        // error alert — there's nothing actionable for the user.
        let (viewModel, _, _, _, _) = makeViewModel()
        fileSystem.trashError = CocoaError(.fileNoSuchFile)
        let instance = makeInstance()
        let ghostPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("kernova-ghost-\(UUID().uuidString).img")
            .path(percentEncoded: false)
        let ghost = StorageDisk(
            path: ghostPath,
            readOnly: false, label: "Ghost", isInternal: false, kind: .virtio
        )
        instance.configuration.storageDisks = [ghost]
        viewModel.instances.append(instance)

        await viewModel.removeStorageDisk(ghost, from: instance, trashFile: true)?.value

        #expect(instance.configuration.storageDisks == nil)
        #expect(!presenter.showError)
    }

    @Test("removeRemovableMedia with trashFile=false removes the entry without touching the file")
    func removeRemovableMediaKeepsFile() throws {
        let (viewModel, _, _, _, _) = makeViewModel()
        let instance = makeInstance()
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-media.iso")

        let item = RemovableMediaItem(
            path: destination.path(percentEncoded: false), readOnly: true)
        instance.configuration.removableMedia = [item]
        viewModel.instances.append(instance)

        viewModel.removeRemovableMedia(item, from: instance, trashFile: false)

        #expect(instance.configuration.removableMedia == nil)
        #expect(fileSystem.trashedURLs.isEmpty)
        #expect(!presenter.showError)
    }

    @Test("removeRemovableMedia with trashFile=true trashes the host file")
    func removeRemovableMediaTrashesFile() async throws {
        let (viewModel, _, _, _, _) = makeViewModel()
        let instance = makeInstance()
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-media.iso")

        let item = RemovableMediaItem(
            path: destination.path(percentEncoded: false), readOnly: true)
        instance.configuration.removableMedia = [item]
        viewModel.instances.append(instance)

        await viewModel.removeRemovableMedia(item, from: instance, trashFile: true)?.value

        #expect(instance.configuration.removableMedia == nil)
        #expect(fileSystem.trashedURLs == [destination])
        #expect(!presenter.showError)
    }

    @Test("removeRemovableMedia with trashFile=true swallows missing-file errors")
    func removeRemovableMediaMissingFileSwallows() async {
        let (viewModel, _, _, _, _) = makeViewModel()
        fileSystem.trashError = CocoaError(.fileNoSuchFile)
        let instance = makeInstance()
        let ghostPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("kernova-ghost-\(UUID().uuidString).iso")
            .path(percentEncoded: false)
        let item = RemovableMediaItem(path: ghostPath, readOnly: true)
        instance.configuration.removableMedia = [item]
        viewModel.instances.append(instance)

        await viewModel.removeRemovableMedia(item, from: instance, trashFile: true)?.value

        #expect(instance.configuration.removableMedia == nil)
        #expect(!presenter.showError)
    }

    @Test("removeStorageDisk with trashFile=true surfaces non-missing-file trash failures")
    func removeStorageDiskTrashFailureSurfacesError() async {
        let (viewModel, _, _, _, _) = makeViewModel()
        fileSystem.trashError = CocoaError(.fileWriteNoPermission)
        let instance = makeInstance()
        let external = StorageDisk(
            path: FileManager.default.temporaryDirectory
                .appendingPathComponent("\(UUID().uuidString)-external.img")
                .path(percentEncoded: false),
            readOnly: false, label: "External", isInternal: false, kind: .virtio
        )
        instance.configuration.storageDisks = [external]
        viewModel.instances.append(instance)

        await viewModel.removeStorageDisk(external, from: instance, trashFile: true)?.value

        // The entry is still removed, and the failure is surfaced as an alert
        // (unlike the swallowed missing-file case above).
        #expect(instance.configuration.storageDisks == nil)
        #expect(presenter.showError == true)
    }

    @Test("removeStorageDisk with trashFile=true keeps a file shared with another VM")
    func removeStorageDiskKeepsSharedFile() throws {
        let (viewModel, _, _, _, _) = makeViewModel()
        let shared = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-shared.img")
        let sharedPath = shared.path(percentEncoded: false)

        let target = makeInstance(name: "Target")
        let disk = StorageDisk(
            path: sharedPath, readOnly: false, label: "Shared", isInternal: false, kind: .virtio)
        target.configuration.storageDisks = [disk]
        let other = makeInstance(name: "Other")
        other.configuration.storageDisks = [
            StorageDisk(path: sharedPath, readOnly: false, label: "Shared", isInternal: false, kind: .virtio)
        ]
        viewModel.instances = [target, other]

        // Even asked to trash, a file another VM still references is kept: no
        // trash task is spawned and no trash request reaches the file system.
        let task = viewModel.removeStorageDisk(disk, from: target, trashFile: true)
        #expect(task == nil)
        #expect(target.configuration.storageDisks == nil)
        #expect(fileSystem.trashedURLs.isEmpty)
        #expect(!presenter.showError)
    }

    @Test("removeRemovableMedia with trashFile=true keeps a file shared with another VM")
    func removeRemovableMediaKeepsSharedFile() throws {
        let (viewModel, _, _, _, _) = makeViewModel()
        let shared = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-shared.iso")
        let sharedPath = shared.path(percentEncoded: false)

        let target = makeInstance(name: "Target")
        let item = RemovableMediaItem(path: sharedPath, readOnly: true)
        target.configuration.removableMedia = [item]
        let other = makeInstance(name: "Other")
        other.configuration.removableMedia = [RemovableMediaItem(path: sharedPath, readOnly: true)]
        viewModel.instances = [target, other]

        let task = viewModel.removeRemovableMedia(item, from: target, trashFile: true)
        #expect(task == nil)
        #expect(target.configuration.removableMedia == nil)
        #expect(fileSystem.trashedURLs.isEmpty)
        #expect(!presenter.showError)
    }

    @Test("removeRemovableMedia with trashFile=true never trashes the Guest Agent DMG")
    func removeRemovableMediaNeverTrashesGuestAgent() throws {
        let (viewModel, _, _, _, _) = makeViewModel()
        let agentPath = try #require(KernovaMacOSAgentInfo.installerDiskImageURL)
            .path(percentEncoded: false)
        let instance = makeInstance()
        let item = RemovableMediaItem(path: agentPath, readOnly: true, label: "Kernova Guest Agent")
        instance.configuration.removableMedia = [item]
        viewModel.instances.append(instance)

        // No trash task is spawned for the app-owned DMG (guard returns nil
        // before any detached trash), and the bundled file is left intact.
        let task = viewModel.removeRemovableMedia(item, from: instance, trashFile: true)
        #expect(task == nil)
        #expect(instance.configuration.removableMedia == nil)
        #expect(FileManager.default.fileExists(atPath: agentPath))
        #expect(!presenter.showError)
    }

    @Test("sharingVMNames lists other VMs referencing a path and excludes the instance")
    func sharingVMNamesDetectsAndExcludes() throws {
        let (viewModel, _, _, _, _) = makeViewModel()
        let sharedPath = "/Volumes/External/shared.img"
        let target = makeInstance(name: "Target")
        target.configuration.storageDisks = [
            StorageDisk(path: sharedPath, readOnly: false, label: "S", isInternal: false, kind: .virtio)
        ]
        let diskSharer = makeInstance(name: "DiskSharer")
        diskSharer.configuration.storageDisks = [
            StorageDisk(path: sharedPath, readOnly: false, label: "S", isInternal: false, kind: .virtio)
        ]
        let mediaSharer = makeInstance(name: "MediaSharer")
        mediaSharer.configuration.removableMedia = [RemovableMediaItem(path: sharedPath, readOnly: true)]
        let unrelated = makeInstance(name: "Unrelated")
        viewModel.instances = [target, diskSharer, mediaSharer, unrelated]

        let names = viewModel.sharingVMNames(forPath: sharedPath, excluding: target)
        #expect(Set(names) == ["DiskSharer", "MediaSharer"])

        // A unique path is shared with no one.
        #expect(viewModel.sharingVMNames(forPath: "/Volumes/External/unique.img", excluding: target).isEmpty)
    }

    @Test("sharingVMNames ignores internal (bundle-relative) disks")
    func sharingVMNamesIgnoresInternalDisks() {
        let (viewModel, _, _, _, _) = makeViewModel()
        let a = makeInstance(name: "A")
        a.configuration.storageDisks = [
            StorageDisk(path: "Disk.asif", readOnly: false, label: "Main", isInternal: true, kind: .virtio)
        ]
        let b = makeInstance(name: "B")
        b.configuration.storageDisks = [
            StorageDisk(path: "Disk.asif", readOnly: false, label: "Main", isInternal: true, kind: .virtio)
        ]
        viewModel.instances = [a, b]
        // Same relative path, but both are bundle-internal → not shared.
        #expect(viewModel.sharingVMNames(forPath: "Disk.asif", excluding: a).isEmpty)
    }

    @Test("isGuestAgentInstaller matches the bundled DMG path only")
    func isGuestAgentInstallerMatches() throws {
        let (viewModel, _, _, _, _) = makeViewModel()
        let agentPath = try #require(KernovaMacOSAgentInfo.installerDiskImageURL)
            .path(percentEncoded: false)
        #expect(viewModel.isGuestAgentInstaller(RemovableMediaItem(path: agentPath, readOnly: true)))
        #expect(!viewModel.isGuestAgentInstaller(RemovableMediaItem(path: "/tmp/other.iso", readOnly: true)))
    }

    @Test("isMainDisk identifies the synthesized main disk, not additional internal disks")
    func isMainDiskIdentifiesMain() {
        let (viewModel, _, _, _, _) = makeViewModel()
        let instance = makeInstance()
        viewModel.instances.append(instance)
        let main = VMCommandCore.defaultStorageDisks(for: instance)[0]
        let extra = StorageDisk(
            path: "AdditionalDisks/extra.asif", readOnly: false, label: "Extra",
            isInternal: true, kind: .virtio)
        #expect(viewModel.isMainDisk(main, of: instance))
        #expect(!viewModel.isMainDisk(extra, of: instance))

        // Cloned VMs regenerate every disk id, so identity must be matched by
        // bundle-relative path, not id: a main disk with a fresh UUID but the
        // canonical "Disk.asif" path is still the main disk.
        let mainWithFreshID = StorageDisk(
            id: UUID(), path: main.path, readOnly: false, label: "Main Disk",
            isInternal: true, kind: .virtio)
        #expect(mainWithFreshID.id != main.id)
        #expect(viewModel.isMainDisk(mainWithFreshID, of: instance))
    }

    @Test("createStorageDisk appends an internal virtio disk with the expected fields")
    func createStorageDiskAppends() async throws {
        let (viewModel, _, diskService, _, _) = makeViewModel()
        let instance = makeInstance()
        viewModel.instances.append(instance)

        // The viewmodel creates a real directory inside `instance.bundleURL`,
        // so set up a unique scratch bundle and clean it up.
        try FileManager.default.createDirectory(at: instance.bundleURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: instance.bundleURL) }

        viewModel.createStorageDisk(for: instance, sizeInGB: 32)

        // The disk-creation Task is async; spin until the config materializes.
        while instance.configuration.storageDisks == nil { await Task.yield() }

        let disks = instance.configuration.storageDisks ?? []
        // Pre-existing default main disk + the newly-created one.
        #expect(disks.count == 2)

        let newDisk = try #require(disks.last)
        #expect(newDisk.isInternal == true)
        #expect(newDisk.kind == .virtio)
        #expect(newDisk.readOnly == false)
        #expect(newDisk.path.hasPrefix("AdditionalDisks/"))
        #expect(newDisk.path.hasSuffix(".asif"))
        #expect(newDisk.label == "32 GB Disk")

        #expect(diskService.createDiskImageCallCount == 1)
        #expect(diskService.lastCreatedSizeInGB == 32)
        #expect(!presenter.showError)
    }

    @Test("createRemovableMedia appends an external item with the chosen path and read-write default")
    func createRemovableMediaAppends() async throws {
        let (viewModel, _, diskService, _, _) = makeViewModel()
        let instance = makeInstance()
        viewModel.instances.append(instance)

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString) Removable Disk.asif")

        viewModel.createRemovableMedia(for: instance, sizeInGB: 16, destinationURL: destination)

        while instance.configuration.removableMedia == nil { await Task.yield() }

        let media = instance.configuration.removableMedia ?? []
        #expect(media.count == 1)

        let item = try #require(media.first)
        // Removable media is always external — no `isInternal` flag exists on the
        // model. The stored path is the absolute host path the user picked.
        #expect(item.path == destination.path(percentEncoded: false))
        #expect(item.readOnly == false)
        #expect(item.label == destination.deletingPathExtension().lastPathComponent)

        #expect(diskService.createDiskImageCallCount == 1)
        #expect(diskService.lastCreatedSizeInGB == 16)
        #expect(!presenter.showError)
    }

    @Test("createRemovableMedia surfaces errors and leaves the list unchanged")
    func createRemovableMediaErrorIsSurfaced() async throws {
        let diskService = MockDiskImageService()
        diskService.createDiskImageError = NSError(domain: "test", code: 1)
        let (viewModel, _, _, _, _) = makeViewModel(diskImageService: diskService)
        let instance = makeInstance()
        viewModel.instances.append(instance)

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).asif")

        viewModel.createRemovableMedia(for: instance, sizeInGB: 16, destinationURL: destination)

        while !presenter.showError { await Task.yield() }

        #expect(instance.configuration.removableMedia == nil)
        #expect(diskService.createDiskImageCallCount == 1)
    }

    @Test("createRemovableMedia trashes the destination when DiskImageError.writeFailed is thrown")
    func createRemovableMediaWriteFailedTrashesFile() async throws {
        let diskService = MockDiskImageService()
        // `.writeFailed` signals the write phase started — the destination file
        // may exist as a partial write, so the catch path must attempt cleanup.
        diskService.createDiskImageError = DiskImageError.writeFailed(
            NSError(domain: "test", code: 1))
        let (viewModel, _, _, _, _) = makeViewModel(diskImageService: diskService)
        let instance = makeInstance()
        viewModel.instances.append(instance)

        // Stand in for the partial file `createDiskImage` would have left.
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).asif")

        viewModel.createRemovableMedia(for: instance, sizeInGB: 16, destinationURL: destination)

        while !presenter.showError { await Task.yield() }

        // The partial file was handed to the Trash seam.
        #expect(fileSystem.trashedURLs == [destination])
        #expect(instance.configuration.removableMedia == nil)
    }

    @Test("createRemovableMedia leaves an unrelated pre-existing file alone on pre-write failure")
    func createRemovableMediaPreWriteFailureLeavesFileAlone() async throws {
        let diskService = MockDiskImageService()
        // `.templateMissing` throws before any byte is written. The user may have
        // pointed the save panel at a pre-existing file they confirmed "Replace"
        // on — we must not trash it when the write never started.
        diskService.createDiskImageError = DiskImageError.templateMissing(sizeInGB: 16)
        let (viewModel, _, _, _, _) = makeViewModel(diskImageService: diskService)
        let instance = makeInstance()
        viewModel.instances.append(instance)

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).asif")

        viewModel.createRemovableMedia(for: instance, sizeInGB: 16, destinationURL: destination)

        while !presenter.showError { await Task.yield() }

        // Pre-existing file is intact — no trash request was made.
        #expect(fileSystem.trashedURLs.isEmpty)
        #expect(instance.configuration.removableMedia == nil)
    }

    // MARK: - Reconcile Rollback

    @Test("Reorder-only removableMedia change triggers no detach/attach")
    func liveRemovableReorderIsNoOp() async throws {
        let mock = MockUSBDeviceService()
        let (viewModel, _, _, _, _) = makeViewModel(usbDeviceService: mock)
        let instance = makeInstance()
        instance.enter(.running(sessionID: UUID()))
        instance.beginSessionContext()
        let idA = UUID()
        let idB = UUID()
        instance.sessionContext?.liveRemovableMedia = [
            USBDeviceInfo(id: idA, path: "/tmp/a.iso", readOnly: true),
            USBDeviceInfo(id: idB, path: "/tmp/b.iso", readOnly: true),
        ]
        var old = instance.configuration
        old.removableMedia = [
            RemovableMediaItem(id: idA, path: "/tmp/a.iso", readOnly: true),
            RemovableMediaItem(id: idB, path: "/tmp/b.iso", readOnly: true),
        ]
        instance.configuration = old
        viewModel.instances.append(instance)

        var new = old
        new.removableMedia = [
            // Swapped order; identical items.
            RemovableMediaItem(id: idB, path: "/tmp/b.iso", readOnly: true),
            RemovableMediaItem(id: idA, path: "/tmp/a.iso", readOnly: true),
        ]

        viewModel.library.applyLivePolicy(for: instance, old: old, new: new)
        // Drain whatever the reconcile Task may have scheduled.
        for _ in 0..<20 { await Task.yield() }

        #expect(mock.detachCallCount == 0)
        #expect(mock.attachCallCount == 0)
        #expect(instance.liveRemovableMedia.count == 2)
        #expect(!presenter.showError)
    }

    @Test("Failed detach rolls config back to live state (item stays attached)")
    func liveRemovableRollbackOnDetachFailure() async throws {
        struct TransientError: Error {}
        let mock = MockUSBDeviceService()
        mock.detachError = TransientError()
        let (viewModel, _, _, _, _) = makeViewModel(usbDeviceService: mock)
        let instance = makeInstance()
        instance.enter(.running(sessionID: UUID()))
        instance.beginSessionContext()
        let id = UUID()
        instance.sessionContext?.liveRemovableMedia = [
            USBDeviceInfo(id: id, path: "/tmp/old.iso", readOnly: true)
        ]
        var old = instance.configuration
        old.removableMedia = [
            RemovableMediaItem(id: id, path: "/tmp/old.iso", readOnly: true)
        ]
        instance.configuration = old
        viewModel.instances.append(instance)

        // Simulate `updateConfiguration` having already persisted the
        // user's removal intent — config says "no media", live still has it.
        var new = old
        new.removableMedia = nil
        instance.configuration = new

        viewModel.library.applyLivePolicy(for: instance, old: old, new: new)
        while !presenter.showError { await Task.yield() }
        for _ in 0..<5 { await Task.yield() }

        // Detach failed → device still mounted → config must reflect that.
        let rolled = try #require(instance.configuration.removableMedia)
        #expect(rolled.count == 1)
        #expect(rolled.first?.id == id)
        #expect(rolled.first?.path == "/tmp/old.iso")
        #expect(rolled.first?.readOnly == true)
    }

    @Test("Failed attach rolls config back to live state (entry strips from config)")
    func liveRemovableRollbackOnAttachFailure() async throws {
        struct TransientError: Error {}
        let mock = MockUSBDeviceService()
        mock.attachError = TransientError()
        let (viewModel, _, _, _, _) = makeViewModel(usbDeviceService: mock)
        let instance = makeInstance()
        instance.enter(.running(sessionID: UUID()))
        instance.beginSessionContext()
        let id = UUID()
        instance.sessionContext?.liveRemovableMedia = []
        var old = instance.configuration
        old.removableMedia = nil
        instance.configuration = old
        viewModel.instances.append(instance)

        // The user added a removable item; updateConfiguration already
        // persisted it before applyLivePolicy fired.
        var new = old
        new.removableMedia = [
            RemovableMediaItem(id: id, path: "/tmp/missing.iso", readOnly: true)
        ]
        instance.configuration = new

        viewModel.library.applyLivePolicy(for: instance, old: old, new: new)
        while !presenter.showError { await Task.yield() }
        for _ in 0..<5 { await Task.yield() }

        // Attach failed → device never mounted → config rolled back to nil.
        #expect(instance.configuration.removableMedia == nil)
    }

    @Test("Failed swap rollback preserves the entry's label and note")
    func liveRemovableRollbackOnSwapFailurePreservesLabelAndNotes() async throws {
        struct TransientError: Error {}
        let mock = MockUSBDeviceService()
        mock.detachError = TransientError()
        let (viewModel, _, _, _, _) = makeViewModel(usbDeviceService: mock)
        let instance = makeInstance()
        instance.enter(.running(sessionID: UUID()))
        instance.beginSessionContext()
        let id = UUID()
        instance.sessionContext?.liveRemovableMedia = [
            USBDeviceInfo(id: id, path: "/tmp/old.iso", readOnly: true)
        ]
        var oldItem = RemovableMediaItem(id: id, path: "/tmp/old.iso", readOnly: true, label: "Installer")
        oldItem.notes = "from the Ubuntu mirror"
        var old = instance.configuration
        old.removableMedia = [oldItem]
        instance.configuration = old
        viewModel.instances.append(instance)

        // Same id, different path (path swap) — and `updateConfiguration` has
        // already persisted the target, carrying the label and note forward
        // since only the path/readOnly changed.
        var newItem = oldItem
        newItem.path = "/tmp/new.iso"
        var new = old
        new.removableMedia = [newItem]
        instance.configuration = new

        viewModel.library.applyLivePolicy(for: instance, old: old, new: new)
        while !presenter.showError { await Task.yield() }
        for _ in 0..<5 { await Task.yield() }

        // Swap failed → the rolled-back entry must still carry the persisted
        // label and note, not a bare reconstruction from path/readOnly alone.
        let rolled = try #require(instance.configuration.removableMedia)
        #expect(rolled.first?.label == "Installer")
        #expect(rolled.first?.notes == "from the Ubuntu mirror")
    }

    @Test("Failed swap rollback restores the original entry, not the target")
    func liveRemovableRollbackOnSwapFailureRestoresOriginal() async throws {
        struct TransientError: Error {}
        let mock = MockUSBDeviceService()
        mock.detachError = TransientError()
        let (viewModel, _, _, _, _) = makeViewModel(usbDeviceService: mock)
        let instance = makeInstance()
        instance.enter(.running(sessionID: UUID()))
        instance.beginSessionContext()
        let id = UUID()
        instance.sessionContext?.liveRemovableMedia = [
            USBDeviceInfo(id: id, path: "/tmp/old.iso", readOnly: true)
        ]
        var old = instance.configuration
        old.removableMedia = [
            RemovableMediaItem(id: id, path: "/tmp/old.iso", readOnly: true)
        ]
        instance.configuration = old
        viewModel.instances.append(instance)

        // Same id, different path (path swap) — and `updateConfiguration`
        // has already persisted the target.
        var new = old
        new.removableMedia = [
            RemovableMediaItem(id: id, path: "/tmp/new.iso", readOnly: true)
        ]
        instance.configuration = new

        viewModel.library.applyLivePolicy(for: instance, old: old, new: new)
        while !presenter.showError { await Task.yield() }
        for _ in 0..<5 { await Task.yield() }

        let rolled = try #require(instance.configuration.removableMedia)
        #expect(rolled.count == 1)
        #expect(rolled.first?.id == id)
        // Critical: path is the ORIGINAL one, not the failed-swap target.
        #expect(rolled.first?.path == "/tmp/old.iso")
    }

    @Test("removeStorageDisk on synthetic main disk leaves storageDisks empty")
    func removeSyntheticMainDiskClearsList() {
        // Regression test: with a non-deterministic synthesized UUID, the
        // remove path would no-op the entry removal (UUID mismatch between
        // binding and removeStorageDisk's own re-synthesis) while still
        // trashing `Disk.asif` — bricking the VM.
        let (viewModel, _, _, _, _) = makeViewModel()
        let instance = makeInstance()
        instance.configuration.storageDisks = nil
        viewModel.instances.append(instance)

        let layout = VMBundleLayout(bundleURL: instance.bundleURL)
        let synthetic = ConfigurationBuilder.defaultMainDisk(layout: layout)

        viewModel.removeStorageDisk(synthetic, from: instance, trashFile: false)

        // Either nil (the empty-collapses-to-nil persistence) or empty.
        let surviving = instance.configuration.storageDisks ?? []
        #expect(surviving.isEmpty)
    }
}

// MARK: - Test helpers

extension Result {
    fileprivate var isFailure: Bool {
        if case .failure = self { return true }
        return false
    }
}
