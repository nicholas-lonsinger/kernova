import Testing
import Foundation
@testable import Kernova

@Suite("VMLibraryViewModel Tests", .serialized)
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
        usbDeviceService: any USBDeviceProviding = MockUSBDeviceService()
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
            fileSystem: fileSystem,
            preferences: preferences
        )
        vm.presenter = presenter
        return (vm, storageService, diskImageService, virtualizationService, usbDeviceService)
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

    // MARK: - Initial State

    @Test("ViewModel starts with empty instances when storage is empty")
    func initialStateEmpty() {
        let (viewModel, _, _, _, _) = makeViewModel()
        #expect(viewModel.instances.isEmpty)
        #expect(viewModel.selectedID == nil)
        #expect(presenter.showCreationWizard == false)
        #expect(presenter.showError == false)
    }

    // MARK: - Load

    @Test("loadVMs auto-selects the first VM")
    func loadVMsAutoSelectsFirst() {
        let storage = MockVMStorageService()
        let config1 = VMConfiguration(name: "First VM", guestOS: .linux, bootMode: .efi)
        let config2 = VMConfiguration(name: "Second VM", guestOS: .linux, bootMode: .efi)
        let url1 = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(config1.id.uuidString).kernova", isDirectory: true)
        let url2 = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(config2.id.uuidString).kernova", isDirectory: true)
        storage.bundles[url1] = config1
        storage.bundles[url2] = config2

        let (viewModel, _, _, _, _) = makeViewModel(storageService: storage)

        #expect(viewModel.instances.count == 2)
        #expect(viewModel.selectedID == viewModel.instances.first?.id)
    }

    @Test("loadVMs preserves valid selection on reload")
    func loadVMsPreservesSelection() {
        let storage = MockVMStorageService()
        let config1 = VMConfiguration(name: "First VM", guestOS: .linux, bootMode: .efi)
        let config2 = VMConfiguration(name: "Second VM", guestOS: .linux, bootMode: .efi)
        let url1 = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(config1.id.uuidString).kernova", isDirectory: true)
        let url2 = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(config2.id.uuidString).kernova", isDirectory: true)
        storage.bundles[url1] = config1
        storage.bundles[url2] = config2

        let (viewModel, _, _, _, _) = makeViewModel(storageService: storage)
        let secondID = viewModel.instances.last?.id
        viewModel.selectedID = secondID

        viewModel.loadVMs()

        #expect(viewModel.selectedID == secondID)
    }

    // MARK: - Selection Persistence

    @Test("selectedID persists to UserDefaults on change")
    func selectedIDPersistsToUserDefaults() {
        let (viewModel, _, _, _, _) = makeViewModel()
        let instance = makeInstance()
        viewModel.instances.append(instance)

        viewModel.selectedID = instance.id

        #expect(preferences.lastSelectedVMID == instance.id)
    }

    @Test("selectedID clears UserDefaults when set to nil")
    func selectedIDClearsUserDefaults() {
        let (viewModel, _, _, _, _) = makeViewModel()
        let instance = makeInstance()
        viewModel.instances.append(instance)
        viewModel.selectedID = instance.id

        viewModel.selectedID = nil

        #expect(preferences.lastSelectedVMID == nil)
    }

    @Test("loadVMs restores selection from UserDefaults when VM still exists")
    func loadVMsRestoresFromUserDefaults() {
        let storage = MockVMStorageService()
        let config1 = VMConfiguration(name: "First VM", guestOS: .linux, bootMode: .efi)
        let config2 = VMConfiguration(name: "Second VM", guestOS: .linux, bootMode: .efi)
        let url1 = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(config1.id.uuidString).kernova", isDirectory: true)
        let url2 = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(config2.id.uuidString).kernova", isDirectory: true)
        storage.bundles[url1] = config1
        storage.bundles[url2] = config2

        // Seed preferences before ViewModel init triggers loadVMs()
        preferences.lastSelectedVMID = config2.id

        let viewModel = VMLibraryViewModel(
            storageService: storage,
            diskImageService: MockDiskImageService(),
            virtualizationService: MockVirtualizationService(),
            installService: MockMacOSInstallService(),
            ipswService: MockIPSWService(),
            preferences: preferences
        )
        viewModel.presenter = presenter

        #expect(viewModel.selectedID == config2.id)
    }

    @Test("loadVMs surfaces error when individual bundles fail to load")
    func loadVMsSurfacesErrorForFailedBundles() {
        let storage = MockVMStorageService()
        // Add a good bundle and a bad bundle
        let goodConfig = VMConfiguration(name: "Good VM", guestOS: .linux, bootMode: .efi)
        let goodURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(goodConfig.id.uuidString).kernova", isDirectory: true)
        storage.bundles[goodURL] = goodConfig

        let badURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("bad-bundle.kernova", isDirectory: true)
        // Register the URL so listVMBundles returns it, but mark it to fail on load
        storage.bundles[badURL] = VMConfiguration(name: "Bad VM", guestOS: .linux, bootMode: .efi)
        storage.loadConfigurationFailURLs = [badURL]

        let (viewModel, _, _, _, _) = makeViewModel(storageService: storage)

        // Good VM loaded, bad VM skipped
        #expect(viewModel.instances.count == 1)
        #expect(viewModel.instances.first?.name == "Good VM")
        // Error surfaced to user about the failed bundle
        #expect(presenter.showError == true)
        #expect(presenter.errorMessage != nil)
    }

    @Test("loadVMs falls back to first VM when stored ID is invalid")
    func loadVMsFallsBackWhenStoredIDInvalid() {
        let storage = MockVMStorageService()
        let config = VMConfiguration(name: "Only VM", guestOS: .linux, bootMode: .efi)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(config.id.uuidString).kernova", isDirectory: true)
        storage.bundles[url] = config

        // Seed preferences with a UUID that doesn't match any VM
        preferences.lastSelectedVMID = UUID()

        let viewModel = VMLibraryViewModel(
            storageService: storage,
            diskImageService: MockDiskImageService(),
            virtualizationService: MockVirtualizationService(),
            installService: MockMacOSInstallService(),
            ipswService: MockIPSWService(),
            preferences: preferences
        )
        viewModel.presenter = presenter

        #expect(viewModel.selectedID == config.id)
    }

    // MARK: - Delete

    @Test("confirmDelete always presents the unified delete sheet")
    func confirmDelete() {
        let (viewModel, _, _, _, _) = makeViewModel()
        let instance = makeInstance()
        viewModel.instances.append(instance)

        viewModel.confirmDelete(instance)

        // Even a VM with no external files routes to the sheet now (it still
        // has its in-bundle main disk to show).
        #expect(presenter.instanceToDelete?.id == instance.id)
        #expect(presenter.showDeleteSheet == true)
    }

    @Test("deleteConfirmed removes instance and clears selection")
    func deleteConfirmed() {
        let (viewModel, storage, _, _, _) = makeViewModel()
        let instance = makeInstance()
        viewModel.instances.append(instance)
        viewModel.selectedID = instance.id

        // Pre-populate mock storage so delete doesn't throw
        storage.bundles[instance.bundleURL] = instance.configuration

        viewModel.deleteConfirmed(instance)

        #expect(viewModel.instances.isEmpty)
        #expect(viewModel.selectedID == nil)
        #expect(presenter.instanceToDelete == nil)
        #expect(storage.deleteVMBundleCallCount == 1)
    }

    @Test("deleteConfirmed selects first remaining instance when deleting selected")
    func deleteConfirmedUpdatesSelection() {
        let (viewModel, storage, _, _, _) = makeViewModel()
        let first = makeInstance(name: "First")
        let second = makeInstance(name: "Second")
        viewModel.instances = [first, second]
        viewModel.selectedID = second.id

        storage.bundles[second.bundleURL] = second.configuration

        viewModel.deleteConfirmed(second)

        #expect(viewModel.instances.count == 1)
        #expect(viewModel.selectedID == first.id)
    }

    @Test("confirmDelete forwards the immediate flag to the delete sheet")
    func confirmDeleteForwardsPermanentlyFlag() {
        let (viewModel, _, _, _, _) = makeViewModel()
        let instance = makeInstance()
        viewModel.instances.append(instance)

        viewModel.confirmDelete(instance)
        #expect(presenter.lastDeleteSheetPermanently == false)

        viewModel.confirmDelete(instance, permanently: true)
        #expect(presenter.lastDeleteSheetPermanently == true)
    }

    @Test("deleteConfirmed permanently hard-deletes the bundle, bypassing the Trash")
    func deleteConfirmedPermanentlyUsesHardDelete() {
        let (viewModel, storage, _, _, _) = makeViewModel()
        let instance = makeInstance()
        viewModel.instances.append(instance)
        viewModel.selectedID = instance.id
        storage.bundles[instance.bundleURL] = instance.configuration

        viewModel.deleteConfirmed(instance, permanently: true)

        #expect(viewModel.instances.isEmpty)
        #expect(viewModel.selectedID == nil)
        // Hard-delete path is taken; the Trash path is not.
        #expect(storage.permanentlyDeleteVMBundleCallCount == 1)
        #expect(storage.deleteVMBundleCallCount == 0)
    }

    @Test("deleteConfirmed permanently deletes the selected external files")
    func deleteConfirmedPermanentlyDeletesExternals() async throws {
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

        let tasks = viewModel.deleteConfirmed(instance, deletingExternalIDs: [diskID], permanently: true)
        for task in tasks { await task.value }

        #expect(tasks.count == 1)
        #expect(viewModel.instances.isEmpty)
        // Hard delete, not trash — mirrors the VM bundle's own disposition.
        #expect(fileSystem.removedURLs == [externalDisk])
        #expect(fileSystem.trashedURLs.isEmpty)
        #expect(!presenter.showError)
    }

    @Test("deleteConfirmed permanently never deletes a shared external even if selected")
    func deleteConfirmedPermanentlyNeverDeletesSharedExternal() async throws {
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

        let tasks = viewModel.deleteConfirmed(target, deletingExternalIDs: [sharedID], permanently: true)
        for task in tasks { await task.value }

        // The shared-file hard-block holds in the immediate path too.
        #expect(tasks.isEmpty)
        #expect(fileSystem.removedURLs.isEmpty)
        #expect(fileSystem.trashedURLs.isEmpty)
        #expect(!presenter.showError)
    }

    @Test("confirmDelete routes to sheet when the VM references external attachments")
    func confirmDeleteRoutesToSheetWithExternals() {
        let (viewModel, _, _, _, _) = makeViewModel()
        let instance = makeInstance()
        instance.configuration.removableMedia = [
            RemovableMediaItem(path: "/tmp/installer.iso", readOnly: true)
        ]
        viewModel.instances.append(instance)

        viewModel.confirmDelete(instance)

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

    @Test("deleteConfirmed never trashes the Guest Agent DMG even if its id is selected")
    func deleteConfirmedNeverTrashesGuestAgentDMG() throws {
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
        let tasks = viewModel.deleteConfirmed(instance, deletingExternalIDs: [agentID])

        try #require(tasks.isEmpty)
        #expect(viewModel.instances.isEmpty)
        #expect(FileManager.default.fileExists(atPath: agentPath))
        #expect(!presenter.showError)
    }

    @Test("deleteConfirmed with no selected externals leaves external files untouched")
    func deleteConfirmedKeepsExternalsByDefault() throws {
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

        let tasks = viewModel.deleteConfirmed(instance)

        #expect(tasks.isEmpty)
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

    @Test("deleteConfirmed trashes the selected external disks and removable media")
    func deleteConfirmedTrashesExternals() async throws {
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

        let tasks = viewModel.deleteConfirmed(instance, deletingExternalIDs: [diskID, isoID])
        for task in tasks { await task.value }

        #expect(tasks.count == 2)
        #expect(viewModel.instances.isEmpty)
        #expect(Set(fileSystem.trashedURLs) == [externalDisk, externalISO])
        #expect(!presenter.showError)
        #expect(presenter.showDeleteSheet == false)
    }

    @Test("deleteConfirmed trashes only the selected external and keeps the rest")
    func deleteConfirmedTrashesOnlySelectedExternal() async throws {
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

        let tasks = viewModel.deleteConfirmed(instance, deletingExternalIDs: [trashedID])
        for task in tasks { await task.value }

        // Only the selected disk is trashed; the unselected one stays put.
        #expect(tasks.count == 1)
        #expect(fileSystem.trashedURLs == [trashedDisk])
        #expect(!presenter.showError)
    }

    @Test("deleteConfirmed never trashes a shared external even if its id is selected")
    func deleteConfirmedNeverTrashesSharedExternal() async throws {
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

        let tasks = viewModel.deleteConfirmed(target, deletingExternalIDs: [sharedID])
        for task in tasks { await task.value }

        // Hard-block: a shared file is never trashed, so the other VM keeps it.
        #expect(tasks.isEmpty)
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

    @Test("deleteConfirmed discards the IPSW resume-data sidecar")
    func deleteConfirmedDiscardsResumeData() {
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

        viewModel.deleteConfirmed(instance)

        #expect(ipswService.discardResumeDataCallCount == 1)
        #expect(
            ipswService.lastDiscardResumeDataURL?.path(percentEncoded: false)
                == destination.path(percentEncoded: false)
        )
        // A move-to-Trash delete discards the partial download to the Trash too.
        #expect(ipswService.lastDiscardResumeDataPermanently == false)
        #expect(viewModel.instances.isEmpty)
    }

    @Test("deleteConfirmed permanently discards the IPSW resume-data immediately too")
    func deleteConfirmedPermanentlyDiscardsResumeDataImmediately() {
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

        viewModel.deleteConfirmed(instance, permanently: true)

        // The whole operation uses one disposition: the partial download is removed
        // immediately, not trashed, matching the bundle and externals.
        #expect(ipswService.discardResumeDataCallCount == 1)
        #expect(ipswService.lastDiscardResumeDataPermanently == true)
        #expect(storage.permanentlyDeleteVMBundleCallCount == 1)
        #expect(viewModel.instances.isEmpty)
    }

    @Test("deleteConfirmed leaves resume-data alone when VM has no install context")
    func deleteConfirmedNoResumeDataForNonInstallVM() {
        let ipswService = MockIPSWService()
        let storage = MockVMStorageService()
        let viewModel = makeViewModelWithIPSW(ipswService: ipswService, storage: storage)
        let instance = makeInstance()
        viewModel.instances.append(instance)
        storage.bundles[instance.bundleURL] = instance.configuration

        viewModel.deleteConfirmed(instance)

        #expect(ipswService.discardResumeDataCallCount == 0)
    }

    @Test("deleteConfirmed swallows missing-file errors for a selected external")
    func deleteConfirmedSwallowsMissingExternals() async {
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

        let tasks = viewModel.deleteConfirmed(instance, deletingExternalIDs: [ghostID])
        for task in tasks { await task.value }

        #expect(viewModel.instances.isEmpty)
        #expect(!presenter.showError)
    }

    @Test("deleteConfirmed permanently swallows missing-file errors for a selected external")
    func deleteConfirmedPermanentlySwallowsMissingExternals() async {
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
        let tasks = viewModel.deleteConfirmed(instance, deletingExternalIDs: [ghostID], permanently: true)
        for task in tasks { await task.value }

        #expect(viewModel.instances.isEmpty)
        #expect(!presenter.showError)
    }

    @Test("deleteConfirmed ignores a repeat confirm for an already-removed VM")
    func deleteConfirmedIgnoresStaleRepeatConfirm() {
        let (viewModel, storage, _, _, _) = makeViewModel()
        let instance = makeInstance()
        viewModel.instances.append(instance)
        storage.bundles[instance.bundleURL] = instance.configuration

        viewModel.deleteConfirmed(instance)
        #expect(storage.deleteVMBundleCallCount == 1)
        #expect(viewModel.instances.isEmpty)

        // A second confirm (e.g. a duplicate queued delete sheet) must not re-run the
        // delete on the now-missing bundle and surface a spurious bundleNotFound error.
        let tasks = viewModel.deleteConfirmed(instance)
        #expect(tasks.isEmpty)
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

    @Test("confirmStartInRecovery routes to the presenter")
    func confirmStartInRecoveryRoutesToPresenter() {
        let (viewModel, _, _, _, _) = makeViewModel()
        let instance = makeInstance()
        viewModel.instances.append(instance)

        viewModel.confirmStartInRecovery(instance)

        #expect(presenter.showRecoveryBootConfirmation)
        #expect(presenter.instanceToRecoveryBoot === instance)
    }

    @Test("startInRecoveryConfirmed starts with the recovery flag set")
    func startInRecoveryConfirmedSetsFlag() async {
        let (viewModel, _, _, virtService, _) = makeViewModel()
        let instance = makeInstance()
        viewModel.instances.append(instance)

        await viewModel.startInRecoveryConfirmed(instance)

        #expect(virtService.startCallCount == 1)
        #expect(virtService.lastStartBootIntoRecovery == true)
    }

    @Test("stop delegates to lifecycle coordinator")
    func stopDelegates() {
        let (viewModel, _, _, virtService, _) = makeViewModel()
        let instance = makeInstance()
        instance.status = .running
        viewModel.instances.append(instance)

        viewModel.stop(instance)

        #expect(virtService.stopCallCount == 1)
        #expect(instance.status == .stopped)
    }

    @Test("forceStop delegates to lifecycle coordinator")
    func forceStopDelegates() async {
        let (viewModel, _, _, virtService, _) = makeViewModel()
        let instance = makeInstance()
        instance.status = .running
        viewModel.instances.append(instance)

        await viewModel.forceStop(instance)

        #expect(virtService.forceStopCallCount == 1)
        #expect(instance.status == .stopped)
    }

    @Test("pause delegates to lifecycle coordinator")
    func pauseDelegates() async {
        let (viewModel, _, _, virtService, _) = makeViewModel()
        let instance = makeInstance()
        instance.status = .running
        viewModel.instances.append(instance)

        await viewModel.pause(instance)

        #expect(virtService.pauseCallCount == 1)
        #expect(instance.status == .paused)
    }

    @Test("resume delegates to lifecycle coordinator")
    func resumeDelegates() async {
        let (viewModel, _, _, virtService, _) = makeViewModel()
        let instance = makeInstance()
        instance.status = .paused
        viewModel.instances.append(instance)

        await viewModel.resume(instance)

        #expect(virtService.resumeCallCount == 1)
        #expect(instance.status == .running)
    }

    @Test("save delegates to lifecycle coordinator")
    func saveDelegates() async {
        let (viewModel, _, _, virtService, _) = makeViewModel()
        let instance = makeInstance()
        instance.status = .running
        viewModel.instances.append(instance)

        await viewModel.save(instance)

        #expect(virtService.saveCallCount == 1)
        #expect(instance.status == .paused)
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
            id: item.id, path: item.path, label: item.label, reason: "Operation not supported")

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
        instance.status = .error  // where a failed start leaves the VM

        let failure = StartFailedAttachment(
            kind: .removableMedia, id: item.id, label: item.label, message: "test")
        await viewModel.removeStartFailedAttachmentAndStart(failure, on: instance)

        #expect(instance.configuration.removableMedia == nil)
        #expect(virtService.startCallCount == 1)
        #expect(instance.status == .running)
        // Detach only — nothing was trashed.
        #expect(fileSystem.trashedURLs.isEmpty)
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
            reason: "Operation not supported")

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
            reason: "Operation not supported")

        await viewModel.start(instance)

        #expect(presenter.startFailedAttachments.count == 1)
        #expect(presenter.startFailedAttachments.first?.kind == .storageDisk)
        #expect(presenter.startFailedAttachments.first?.id == external.id)
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
    func stopPresentsError() {
        let virtService = MockVirtualizationService()
        virtService.stopError = VirtualizationError.noVirtualMachine
        let (viewModel, _, _, _, _) = makeViewModel(virtualizationService: virtService)
        let instance = makeInstance()

        viewModel.stop(instance)

        #expect(presenter.showError == true)
        #expect(presenter.errorMessage != nil)
    }

    // MARK: - Stop Paused Confirmation

    // Note: the `stop()` branch that diverts a *live-paused* instance to the
    // confirmation sheet (status == .paused && virtualMachine != nil) is not
    // directly unit-tested here. Triggering it requires a non-nil
    // VZVirtualMachine, which the existing test infrastructure cannot
    // construct (matching VMInstanceTests.swift:82 / VMStatusSerialConsoleTests.swift:25).
    // The branch is exercised at integration time. Tests below cover the
    // surrounding behavior: resumeAndStop dispatch, error surfacing, and
    // confirming `.running` instances skip the confirmation flow.

    @Test("resumeAndStop dispatches resume then stop")
    func resumeAndStopDispatches() async {
        let (viewModel, _, _, virtService, _) = makeViewModel()
        let instance = makeInstance()
        instance.status = .paused
        viewModel.instances.append(instance)

        await viewModel.resumeAndStop(instance)

        #expect(virtService.resumeCallCount == 1)
        #expect(virtService.stopCallCount == 1)
    }

    @Test("resumeAndStop clears confirmation state after dispatch")
    func resumeAndStopClearsConfirmationState() async {
        let (viewModel, _, _, _, _) = makeViewModel()
        let instance = makeInstance()
        instance.status = .paused
        viewModel.instances.append(instance)

        await viewModel.resumeAndStop(instance)

        #expect(presenter.instanceToStopPaused == nil)
        #expect(presenter.showStopPausedConfirmation == false)
    }

    @Test("forceStopFromPaused dispatches forceStop and clears state")
    func forceStopFromPausedDispatches() async {
        let (viewModel, _, _, virtService, _) = makeViewModel()
        let instance = makeInstance()
        instance.status = .paused
        viewModel.instances.append(instance)

        await viewModel.forceStopFromPaused(instance)

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
        instance.status = .paused

        await viewModel.resumeAndStop(instance)

        #expect(presenter.showError == true)
        #expect(virtService.stopCallCount == 0)
    }

    @Test("stop on running VM still delegates directly without confirmation")
    func stopRunningSkipsConfirmation() {
        let (viewModel, _, _, virtService, _) = makeViewModel()
        let instance = makeInstance()
        instance.status = .running
        viewModel.instances.append(instance)

        viewModel.stop(instance)

        #expect(virtService.stopCallCount == 1)
        #expect(presenter.showStopPausedConfirmation == false)
        #expect(presenter.instanceToStopPaused == nil)
    }

    @Test("pause presents error on service failure")
    func pausePresentsError() async {
        let virtService = MockVirtualizationService()
        virtService.pauseError = VirtualizationError.noVirtualMachine
        let (viewModel, _, _, _, _) = makeViewModel(virtualizationService: virtService)
        let instance = makeInstance()

        await viewModel.pause(instance)

        #expect(presenter.showError == true)
        #expect(presenter.errorMessage != nil)
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

    // MARK: - Save Configuration

    @Test("saveConfiguration persists via storage service")
    func saveConfigurationPersists() {
        let (viewModel, storage, _, _, _) = makeViewModel()
        let instance = makeInstance()

        viewModel.saveConfiguration(for: instance)

        #expect(storage.saveConfigurationCallCount == 1)
    }

    @Test("saveConfiguration presents error on failure")
    func saveConfigurationPresentsError() {
        let (viewModel, storage, _, _, _) = makeViewModel()
        let instance = makeInstance()
        storage.saveConfigurationError = NSError(domain: "test", code: 1)

        viewModel.saveConfiguration(for: instance)

        #expect(presenter.showError == true)
        #expect(presenter.errorMessage != nil)
    }

    // MARK: - trySave / tryForceStop

    @Test("trySave throws on failure")
    func trySaveThrows() async {
        let virtService = MockVirtualizationService()
        virtService.saveError = VirtualizationError.noVirtualMachine
        let (viewModel, _, _, _, _) = makeViewModel(virtualizationService: virtService)
        let instance = makeInstance()

        await #expect(throws: VirtualizationError.self) {
            try await viewModel.trySave(instance)
        }
    }

    @Test("tryForceStop throws on failure")
    func tryForceStopThrows() async {
        let virtService = MockVirtualizationService()
        virtService.forceStopError = VirtualizationError.noVirtualMachine
        let (viewModel, _, _, _, _) = makeViewModel(virtualizationService: virtService)
        let instance = makeInstance()

        await #expect(throws: VirtualizationError.self) {
            try await viewModel.tryForceStop(instance)
        }
    }

    // MARK: - Selected Instance

    @Test("selectedInstance returns the instance matching selectedID")
    func selectedInstance() {
        let (viewModel, _, _, _, _) = makeViewModel()
        let instance = makeInstance()
        viewModel.instances.append(instance)
        viewModel.selectedID = instance.id

        #expect(viewModel.selectedInstance?.id == instance.id)
    }

    @Test("selectedInstance returns nil when no match")
    func selectedInstanceNil() {
        let (viewModel, _, _, _, _) = makeViewModel()
        viewModel.selectedID = UUID()

        #expect(viewModel.selectedInstance == nil)
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
        wizard.ipswSource = .downloadLatest
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
        wizard.ipswSource = .downloadLatest
        wizard.ipswDownloadPath = destination.path(percentEncoded: false)

        await viewModel.createVM(from: wizard)

        let instance = try #require(viewModel.instances.first)
        let context = try #require(instance.configuration.installContext)
        #expect(!context.requestedFreshDownload)
    }

    // MARK: - Reconcile With Disk

    @Test("reconcileWithDisk adds discovered bundles not in memory")
    func reconcileAddsNewBundles() {
        let storage = MockVMStorageService()
        let config = VMConfiguration(name: "Discovered VM", guestOS: .linux, bootMode: .efi)
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(config.id.uuidString).kernova", isDirectory: true)
        storage.bundles[bundleURL] = config

        let (viewModel, _, _, _, _) = makeViewModel(storageService: storage)
        // loadVMs already ran during init, so the instance should be loaded
        // But let's clear and reconcile manually to test the specific method
        viewModel.instances.removeAll()

        viewModel.reconcileWithDisk()

        #expect(viewModel.instances.count == 1)
        #expect(viewModel.instances.first?.name == "Discovered VM")
    }

    @Test("reconcileWithDisk removes stopped VMs whose bundles are gone")
    func reconcileRemovesStoppedVMs() {
        let (viewModel, _, _, _, _) = makeViewModel()
        let instance = makeInstance(name: "Gone VM")
        instance.status = .stopped
        viewModel.instances.append(instance)

        // Storage has no bundles, so instance should be removed
        viewModel.reconcileWithDisk()

        #expect(viewModel.instances.isEmpty)
    }

    @Test("reconcileWithDisk preserves running VMs even if bundle is missing")
    func reconcilePreservesRunningVMs() {
        let (viewModel, _, _, _, _) = makeViewModel()
        let instance = makeInstance(name: "Running VM")
        instance.status = .running
        viewModel.instances.append(instance)

        viewModel.reconcileWithDisk()

        #expect(viewModel.instances.count == 1)
        #expect(viewModel.instances.first?.name == "Running VM")
    }

    @Test("reconcileWithDisk preserves paused VMs even if bundle is missing")
    func reconcilePreservesPausedVMs() {
        let (viewModel, _, _, _, _) = makeViewModel()
        let instance = makeInstance(name: "Paused VM")
        instance.status = .paused
        viewModel.instances.append(instance)

        viewModel.reconcileWithDisk()

        #expect(viewModel.instances.count == 1)
        #expect(viewModel.instances.first?.name == "Paused VM")
    }

    @Test("reconcileWithDisk updates selection when selected stopped VM is removed")
    func reconcileUpdatesSelection() {
        let (viewModel, storage, _, _, _) = makeViewModel()
        let remaining = makeInstance(name: "Remaining")
        let removed = makeInstance(name: "Removed")
        removed.status = .stopped
        viewModel.instances = [remaining, removed]
        viewModel.selectedID = removed.id

        // Only keep the remaining instance's bundle on disk
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(remaining.id.uuidString).kernova", isDirectory: true)
        storage.bundles = [bundleURL: remaining.configuration]

        viewModel.reconcileWithDisk()

        #expect(viewModel.selectedID == remaining.id || viewModel.selectedID != removed.id)
    }

    @Test("reconcileWithDisk presents error when config loading fails")
    func reconcilePresentsErrorForFailedConfigs() {
        let storage = MockVMStorageService()
        let config = VMConfiguration(name: "Good VM", guestOS: .linux, bootMode: .efi)
        let goodURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(config.id.uuidString).kernova", isDirectory: true)
        storage.bundles[goodURL] = config

        // Create viewModel first (no bad bundles yet)
        let (viewModel, _, _, _, _) = makeViewModel(storageService: storage)

        // Introduce the bad bundle after init so it's new to reconcileWithDisk
        let badURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("broken-vm.kernova", isDirectory: true)
        storage.bundles[badURL] = VMConfiguration(name: "Bad VM", guestOS: .linux, bootMode: .efi)
        storage.loadConfigurationFailURLs.insert(badURL)

        presenter.reset()

        viewModel.reconcileWithDisk()

        #expect(presenter.showError == true)
        #expect(presenter.errorMessage?.contains("broken-vm") == true)
        #expect(viewModel.instances.contains { $0.name == "Good VM" })
    }

    @Test("reconcileWithDisk presents error when listing bundles fails")
    func reconcilePresentsErrorForFilesystemFailure() {
        let (viewModel, storage, _, _, _) = makeViewModel()
        presenter.reset()

        storage.listVMBundlesError = VMStorageError.bundleNotFound(
            FileManager.default.temporaryDirectory
        )

        viewModel.reconcileWithDisk()

        #expect(presenter.showError == true)
        #expect(presenter.errorMessage?.contains("VM bundle not found") == true)
    }

    @Test("reconcileWithDisk does not re-present error for already-reported corrupted bundles")
    func reconcileDeduplicatesFailedBundleErrors() {
        let storage = MockVMStorageService()
        let (viewModel, _, _, _, _) = makeViewModel(storageService: storage)

        // Introduce the bad bundle after init so it's new to reconcileWithDisk
        let badURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("broken-vm.kernova", isDirectory: true)
        storage.bundles[badURL] = VMConfiguration(name: "Bad VM", guestOS: .linux, bootMode: .efi)
        storage.loadConfigurationFailURLs.insert(badURL)

        // First reconciliation should present the error
        presenter.reset()
        viewModel.reconcileWithDisk()
        #expect(presenter.showError == true)
        #expect(presenter.errorMessage?.contains("broken-vm") == true)

        // Second reconciliation should NOT re-present the same error
        presenter.reset()
        viewModel.reconcileWithDisk()
        #expect(presenter.showError == false)
        #expect(presenter.errorMessage == nil)
    }

    @Test("reconcileWithDisk suppression is maintained after full reload")
    func reconcileSuppressionMaintainedAfterReload() {
        let storage = MockVMStorageService()
        let badURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("broken-vm.kernova", isDirectory: true)
        storage.bundles[badURL] = VMConfiguration(name: "Bad VM", guestOS: .linux, bootMode: .efi)
        storage.loadConfigurationFailURLs.insert(badURL)

        // loadVMs() in init reports the error and seeds reportedFailedBundles
        let (viewModel, _, _, _, _) = makeViewModel(storageService: storage)
        #expect(presenter.showError == true)
        #expect(presenter.errorMessage?.contains("broken-vm") == true)

        // First reconcile after init is suppressed
        presenter.reset()
        viewModel.reconcileWithDisk()
        #expect(presenter.showError == false)

        // Full reload resets suppression, then re-seeds from its own failures
        viewModel.loadVMs()
        #expect(presenter.showError == true)
        #expect(presenter.errorMessage?.contains("broken-vm") == true)

        // Reconciliation should still be suppressed since loadVMs re-seeded the set
        presenter.reset()
        viewModel.reconcileWithDisk()
        #expect(presenter.showError == false)
    }

    @Test("reconcileWithDisk does not re-present errors already reported by loadVMs")
    func reconcileDoesNotDuplicateLoadVMsErrors() {
        let storage = MockVMStorageService()
        let badURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("broken-vm.kernova", isDirectory: true)
        storage.bundles[badURL] = VMConfiguration(name: "Bad VM", guestOS: .linux, bootMode: .efi)
        storage.loadConfigurationFailURLs.insert(badURL)

        // loadVMs() runs in init and should report the error
        let (viewModel, _, _, _, _) = makeViewModel(storageService: storage)
        #expect(presenter.showError == true)
        #expect(presenter.errorMessage?.contains("broken-vm") == true)

        // Clear the alert state (simulating user dismissing the dialog)
        presenter.reset()

        // First reconcileWithDisk should NOT re-present the same error
        viewModel.reconcileWithDisk()
        #expect(presenter.showError == false)
        #expect(presenter.errorMessage == nil)
    }

    @Test("reconcileWithDisk re-presents error after previously-failed bundle loads successfully")
    func reconcileReReportsAfterBundleRecovery() {
        let storage = MockVMStorageService()
        let (viewModel, _, _, _, _) = makeViewModel(storageService: storage)

        // Introduce the bad bundle after init so it's new to reconcileWithDisk
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("recoverable.kernova", isDirectory: true)
        let config = VMConfiguration(name: "Recoverable VM", guestOS: .linux, bootMode: .efi)
        storage.bundles[bundleURL] = config
        storage.loadConfigurationFailURLs.insert(bundleURL)

        // First reconciliation reports the error
        presenter.reset()
        viewModel.reconcileWithDisk()
        #expect(presenter.showError == true)
        #expect(presenter.errorMessage?.contains("recoverable") == true)

        // "Fix" the bundle by removing it from the fail set
        storage.loadConfigurationFailURLs.remove(bundleURL)

        // Reconciliation succeeds — no error, and the bundle is cleared from reported set
        presenter.reset()
        viewModel.reconcileWithDisk()
        #expect(presenter.showError == false)

        // Re-corrupt it
        storage.loadConfigurationFailURLs.insert(bundleURL)
        // Remove the instance that was added on successful load so reconciliation tries again
        viewModel.instances.removeAll { $0.name == "Recoverable VM" }

        // Should report the error again since it was cleared from the reported set
        viewModel.reconcileWithDisk()
        #expect(presenter.showError == true)
        #expect(presenter.errorMessage?.contains("recoverable") == true)
    }

    // MARK: - Initial Boot status assignment

    @Test("loadVMs assigns .initialBoot when config has installContext")
    func loadVMsAssignsInitialBoot() {
        let storage = MockVMStorageService()
        var config = VMConfiguration(name: "Pending VM", guestOS: .macOS, bootMode: .macOS)
        config.installContext = MacOSInstallContext(
            source: .downloadLatest,
            downloadDestinationPath: "/tmp/restore.ipsw"
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(config.id.uuidString).kernova", isDirectory: true)
        storage.bundles[url] = config

        let (viewModel, _, _, _, _) = makeViewModel(storageService: storage)
        viewModel.loadVMs()

        #expect(viewModel.instances.count == 1)
        #expect(viewModel.instances[0].status == .initialBoot)
    }

    @Test("loadVMs assigns .stopped when no installContext (back-compat)")
    func loadVMsAssignsStoppedWithoutInstallContext() {
        let storage = MockVMStorageService()
        let config = VMConfiguration(name: "Installed VM", guestOS: .linux, bootMode: .efi)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(config.id.uuidString).kernova", isDirectory: true)
        storage.bundles[url] = config

        let (viewModel, _, _, _, _) = makeViewModel(storageService: storage)
        viewModel.loadVMs()

        #expect(viewModel.instances.count == 1)
        #expect(viewModel.instances[0].status == .stopped)
    }

    @Test("reconcileWithDisk removes .initialBoot VMs whose bundles vanish")
    func reconcileRemovesInitialBootVMs() {
        let (viewModel, storage, _, _, _) = makeViewModel()
        var config = VMConfiguration(name: "Pending VM", guestOS: .macOS, bootMode: .macOS)
        config.installContext = MacOSInstallContext(
            source: .localFile, localIPSWPath: "/tmp/foo.ipsw"
        )
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(config.id.uuidString).kernova", isDirectory: true)
        let instance = VMInstance(configuration: config, bundleURL: bundleURL, status: .initialBoot)
        viewModel.instances.append(instance)
        // Bundle is NOT in storage.bundles — simulating an on-disk deletion.

        viewModel.reconcileWithDisk()

        #expect(viewModel.instances.isEmpty)
        // Note: deleteVMBundle is NOT called — reconcile only evicts the in-memory entry.
        #expect(storage.deleteVMBundleCallCount == 0)
    }

    @Test("reconcileWithDisk cancels installTask before evicting an orphaned VM")
    func reconcileCancelsInstallTaskBeforeEviction() async {
        let (viewModel, _, _, _, _) = makeViewModel()
        var config = VMConfiguration(name: "Pending VM", guestOS: .macOS, bootMode: .macOS)
        config.installContext = MacOSInstallContext(
            source: .localFile, localIPSWPath: "/tmp/foo.ipsw"
        )
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(config.id.uuidString).kernova", isDirectory: true)
        let instance = VMInstance(configuration: config, bundleURL: bundleURL, status: .initialBoot)

        // Spawn a long-running install task we can observe getting cancelled.
        let cancelStream = AsyncStream<Void>.makeStream()
        instance.installTask = Task {
            await withTaskCancellationHandler {
                try? await Task.sleep(for: .seconds(60))
            } onCancel: {
                cancelStream.continuation.yield(())
                cancelStream.continuation.finish()
            }
        }
        viewModel.instances.append(instance)
        // Bundle absent from storage → eligible for eviction.

        viewModel.reconcileWithDisk()
        for await _ in cancelStream.stream { break }  // cancel propagated

        #expect(viewModel.instances.isEmpty)
    }

    // MARK: - Cancel Installation

    @Test("cancelInstallation preserves bundle and instance (non-destructive)")
    func cancelInstallationPreservesBundle() async {
        let (viewModel, storage, _, _, _) = makeViewModel()
        let instance = makeInstance(name: "Installing VM")
        instance.configuration.installContext = MacOSInstallContext(
            source: .localFile, localIPSWPath: "/tmp/foo.ipsw"
        )
        instance.status = .installing
        viewModel.instances.append(instance)
        storage.bundles[instance.bundleURL] = instance.configuration

        // Spawn a fake long-running install task we can observe being cancelled.
        let cancelStream = AsyncStream<Void>.makeStream()
        instance.installTask = Task {
            await withTaskCancellationHandler {
                try? await Task.sleep(for: .seconds(60))
            } onCancel: {
                cancelStream.continuation.yield(())
                cancelStream.continuation.finish()
            }
        }

        viewModel.cancelInstallation(instance)
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
        let raceInstaller = CancelRaceInstallService()
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
        instance.status = .initialBoot
        viewModel.instances.append(instance)
        storage.bundles[instance.bundleURL] = instance.configuration

        // Spawn the install + auto-boot pipeline; returns immediately after
        // arming `instance.installTask`.
        await viewModel.start(instance)

        // Wait until the mock install has parked, so the cancel below
        // actually races a running install rather than a not-yet-started one.
        for await _ in raceInstaller.installStartedStream { break }

        viewModel.cancelInstallation(instance)

        // Drain the install task to completion so post-conditions are
        // observable (the catch block runs synchronously after await).
        await instance.installTask?.value

        // The fix routes this case through the cancel outcome: VM is back
        // to .initialBoot, no error dialog, error message cleared.
        #expect(instance.status == .initialBoot)
        #expect(instance.errorMessage == nil)
        #expect(presenter.showError == false)
    }

    @Test("cancelInstallation does not change selection")
    func cancelInstallationKeepsSelection() async {
        let (viewModel, storage, _, _, _) = makeViewModel()
        let first = makeInstance(name: "First")
        let installing = makeInstance(name: "Installing")
        installing.configuration.installContext = MacOSInstallContext(
            source: .localFile, localIPSWPath: "/tmp/foo.ipsw"
        )
        installing.status = .installing
        viewModel.instances = [first, installing]
        viewModel.selectedID = installing.id
        storage.bundles[installing.bundleURL] = installing.configuration

        let cancelStream = AsyncStream<Void>.makeStream()
        installing.installTask = Task {
            await withTaskCancellationHandler {
                try? await Task.sleep(for: .seconds(60))
            } onCancel: {
                cancelStream.continuation.yield(())
                cancelStream.continuation.finish()
            }
        }

        viewModel.cancelInstallation(installing)
        for await _ in cancelStream.stream { break }

        // Both instances remain; selection unchanged.
        #expect(viewModel.instances.count == 2)
        #expect(viewModel.selectedID == installing.id)
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

    // MARK: - Sleep/Wake

    @Test("pauseAllForSleep pauses only running VMs")
    func pauseAllForSleepPausesRunning() async {
        let (viewModel, _, _, virtService, _) = makeViewModel()
        let running1 = makeInstance(name: "Running 1")
        running1.status = .running
        let running2 = makeInstance(name: "Running 2")
        running2.status = .running
        let stopped = makeInstance(name: "Stopped")
        stopped.status = .stopped
        let paused = makeInstance(name: "User Paused")
        paused.status = .paused
        viewModel.instances = [running1, running2, stopped, paused]

        await viewModel.pauseAllForSleep()

        #expect(virtService.pauseCallCount == 2)
        #expect(viewModel.sleepPausedInstanceIDs == Set([running1.id, running2.id]))
        #expect(running1.status == .paused)
        #expect(running2.status == .paused)
        #expect(stopped.status == .stopped)
        #expect(paused.status == .paused)
    }

    @Test("resumeAllAfterWake resumes only sleep-paused VMs")
    func resumeAllAfterWakeResumesOnlySleepPaused() async {
        let (viewModel, _, _, virtService, _) = makeViewModel()
        let sleepPaused = makeInstance(name: "Sleep Paused")
        sleepPaused.status = .paused
        let userPaused = makeInstance(name: "User Paused")
        userPaused.status = .paused
        viewModel.instances = [sleepPaused, userPaused]
        viewModel.sleepPausedInstanceIDs = Set([sleepPaused.id])

        await viewModel.resumeAllAfterWake()

        #expect(virtService.resumeCallCount == 1)
        #expect(sleepPaused.status == .running)
        #expect(userPaused.status == .paused)
        #expect(viewModel.sleepPausedInstanceIDs.isEmpty)
    }

    @Test("pauseAllForSleep handles pause failure gracefully")
    func pauseAllForSleepHandlesError() async {
        let virtService = MockVirtualizationService()
        virtService.pauseError = VirtualizationError.noVirtualMachine
        let (viewModel, _, _, _, _) = makeViewModel(virtualizationService: virtService)
        let running = makeInstance(name: "Running")
        running.status = .running
        viewModel.instances = [running]

        await viewModel.pauseAllForSleep()

        // Error is surfaced to the user
        #expect(presenter.showError == true)
        #expect(presenter.errorMessage?.contains("Running") == true)
        // Failed pause should not track the instance
        #expect(viewModel.sleepPausedInstanceIDs.isEmpty)
    }

    @Test("resumeAllAfterWake clears tracking set even on failure")
    func resumeAllAfterWakeClearsOnError() async {
        let virtService = MockVirtualizationService()
        virtService.resumeError = VirtualizationError.noVirtualMachine
        let (viewModel, _, _, _, _) = makeViewModel(virtualizationService: virtService)
        let instance = makeInstance(name: "Sleep Paused")
        instance.status = .paused
        viewModel.instances = [instance]
        viewModel.sleepPausedInstanceIDs = Set([instance.id])

        await viewModel.resumeAllAfterWake()

        #expect(viewModel.sleepPausedInstanceIDs.isEmpty)
        // Error is surfaced to the user
        #expect(presenter.showError == true)
        #expect(presenter.errorMessage?.contains("Sleep Paused") == true)
    }

    @Test("pauseAllForSleep is no-op when no running VMs")
    func pauseAllForSleepNoOp() async {
        let (viewModel, _, _, virtService, _) = makeViewModel()
        let stopped = makeInstance(name: "Stopped")
        stopped.status = .stopped
        viewModel.instances = [stopped]

        await viewModel.pauseAllForSleep()

        #expect(virtService.pauseCallCount == 0)
        #expect(viewModel.sleepPausedInstanceIDs.isEmpty)
    }

    @Test("resumeAllAfterWake is no-op when no sleep-paused VMs")
    func resumeAllAfterWakeNoOp() async {
        let (viewModel, _, _, virtService, _) = makeViewModel()
        let paused = makeInstance(name: "User Paused")
        paused.status = .paused
        viewModel.instances = [paused]
        // sleepPausedInstanceIDs is empty

        await viewModel.resumeAllAfterWake()

        #expect(virtService.resumeCallCount == 0)
    }

    @Test("pauseAllForSleep skips non-running states")
    func pauseAllForSleepSkipsNonRunning() async {
        let (viewModel, _, _, virtService, _) = makeViewModel()
        let starting = makeInstance(name: "Starting")
        starting.status = .starting
        let saving = makeInstance(name: "Saving")
        saving.status = .saving
        let error = makeInstance(name: "Error")
        error.status = .error
        viewModel.instances = [starting, saving, error]

        await viewModel.pauseAllForSleep()

        #expect(virtService.pauseCallCount == 0)
        #expect(viewModel.sleepPausedInstanceIDs.isEmpty)
    }

    @Test("resumeAllAfterWake skips VMs no longer paused")
    func resumeAllAfterWakeSkipsNonPaused() async {
        let (viewModel, _, _, virtService, _) = makeViewModel()
        let instance = makeInstance(name: "Was Paused")
        instance.status = .stopped  // Status changed between sleep and wake
        viewModel.instances = [instance]
        viewModel.sleepPausedInstanceIDs = Set([instance.id])

        await viewModel.resumeAllAfterWake()

        #expect(virtService.resumeCallCount == 0)
        #expect(viewModel.sleepPausedInstanceIDs.isEmpty)
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
        instance.status = .stopped
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
        instance.status = .stopped
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
        instance.status = .stopped
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
        instance.status = .running
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
        instance.status = .stopped
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
        instance.status = .stopped
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
        instance.status = .stopped
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
        instance.status = .stopped
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

    // MARK: - Cancel Preparing

    @Test("cancelPreparingConfirmed marks the row Cancelling… and keeps it until the copy settles (#496)")
    func cancelPreparingConfirmedMarksCancelling() {
        let (viewModel, _, _, _, _) = makeViewModel()
        let phantom = makeInstance(name: "Cloning VM")
        markPreparing(phantom)
        viewModel.instances.append(phantom)
        viewModel.selectedID = phantom.id

        viewModel.cancelPreparingConfirmed(phantom)

        // The uninterruptible copy is still (notionally) in flight, so the row stays as "Cancelling…";
        // the copy task removes + trashes it once the copy settles.
        #expect(viewModel.instances.count == 1)
        #expect(phantom.preparingState?.isCancelling == true)
        #expect(phantom.preparingState?.displayLabel == "Cancelling\u{2026}")
    }

    @Test("cancelPreparingConfirmed removes the row and trashes after the copy settles (#496)")
    func cancelPreparingConfirmedRemovesAfterCopySettles() async throws {
        let (viewModel, storage, _, _, _) = makeViewModel()
        let source = try makeImportSource(name: "Cancel Me", storage: storage)
        defer { try? FileManager.default.removeItem(at: source.url.deletingLastPathComponent()) }

        _ = viewModel.importVMs(fromDroppedURLs: [source.url])
        let phantom = try #require(viewModel.instances.first { $0.configuration.id == source.config.id })

        viewModel.cancelPreparingConfirmed(phantom)
        await viewModel.awaitPreparingForTesting()

        // Once the copy settles the copy task removes the row (and trashes the bundle via the
        // detached, best-effort trash path exercised by `importVMCopyFailureRemovesPhantom`) —
        // whether the copy finished before or after the cancel, the end state is the same.
        #expect(viewModel.instances.isEmpty)
        #expect(phantom.preparingState == nil)
        #expect(presenter.showError == false)
    }

    @Test("cancelPreparingConfirmed selects remaining instance after the copy settles (#496)")
    func cancelPreparingConfirmedSelectsRemaining() async throws {
        let (viewModel, storage, _, _, _) = makeViewModel()
        let other = makeInstance(name: "Other VM")
        viewModel.instances.append(other)
        let source = try makeImportSource(name: "Cancel Me", storage: storage)
        defer { try? FileManager.default.removeItem(at: source.url.deletingLastPathComponent()) }

        _ = viewModel.importVMs(fromDroppedURLs: [source.url])
        let phantom = try #require(viewModel.instances.first { $0.configuration.id == source.config.id })

        viewModel.cancelPreparingConfirmed(phantom)
        await viewModel.awaitPreparingForTesting()

        #expect(viewModel.instances.count == 1)
        #expect(viewModel.instances.first?.id == other.id)
        #expect(viewModel.selectedID == other.id)
    }

    @Test("confirmCancelPreparing sets state for alert")
    func confirmCancelPreparingSetsState() {
        let (viewModel, _, _, _, _) = makeViewModel()
        let phantom = makeInstance(name: "Cloning VM")
        markPreparing(phantom)
        viewModel.instances.append(phantom)

        viewModel.confirmCancelPreparing(phantom)

        #expect(presenter.showCancelPreparingConfirmation == true)
        #expect(presenter.preparingInstanceToCancel?.id == phantom.id)
    }

    // MARK: - Force Stop Confirmation

    @Test("confirmForceStop sets instance and shows confirmation")
    func confirmForceStop() {
        let (viewModel, _, _, _, _) = makeViewModel()
        let instance = makeInstance()
        instance.status = .running
        viewModel.instances.append(instance)

        viewModel.confirmForceStop(instance)

        #expect(presenter.instanceToForceStop?.id == instance.id)
        #expect(presenter.showForceStopConfirmation == true)
    }

    @Test("forceStopConfirmed delegates to lifecycle")
    func forceStopConfirmed() async {
        let (viewModel, _, _, virtService, _) = makeViewModel()
        let instance = makeInstance()
        instance.status = .running
        viewModel.instances.append(instance)

        await viewModel.forceStopConfirmed(instance)

        #expect(virtService.forceStopCallCount == 1)
        #expect(instance.status == .stopped)
    }

    // MARK: - hasPreparing

    @Test("hasPreparing returns true when an instance is preparing")
    func hasPreparingTrue() {
        let (viewModel, _, _, _, _) = makeViewModel()
        let instance = makeInstance()
        markPreparing(instance)
        viewModel.instances.append(instance)

        #expect(viewModel.hasPreparing == true)
    }

    @Test("hasPreparing returns false when no instances are preparing")
    func hasPreparingFalse() {
        let (viewModel, _, _, _, _) = makeViewModel()
        let instance = makeInstance()
        viewModel.instances.append(instance)

        #expect(viewModel.hasPreparing == false)
    }

    // MARK: - Reconcile With Disk (Preparing)

    @Test("reconcileWithDisk skips when instances are preparing")
    func reconcileSkipsWhenPreparing() {
        let storage = MockVMStorageService()
        let config = VMConfiguration(name: "New VM", guestOS: .linux, bootMode: .efi)
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(config.id.uuidString).kernova", isDirectory: true)
        storage.bundles[bundleURL] = config

        let (viewModel, _, _, _, _) = makeViewModel(storageService: storage)
        viewModel.instances.removeAll()

        // Add a preparing instance
        let preparing = makeInstance(name: "Preparing")
        markPreparing(preparing)
        viewModel.instances.append(preparing)

        viewModel.reconcileWithDisk()

        // Should not have added the disk bundle because hasPreparing is true
        #expect(viewModel.instances.count == 1)
        #expect(viewModel.instances.first?.name == "Preparing")
    }

    @Test("reconcileWithDisk preserves preparing instances from removal")
    func reconcilePreservesPreparingInstances() {
        let (viewModel, _, _, _, _) = makeViewModel()
        let preparing = makeInstance(name: "Preparing VM")
        markPreparing(preparing)
        preparing.status = .stopped
        viewModel.instances.append(preparing)

        // Storage has no bundles — normally this instance would be removed
        // but hasPreparing guard should prevent reconcile from running
        viewModel.reconcileWithDisk()

        #expect(viewModel.instances.count == 1)
        #expect(viewModel.instances.first?.name == "Preparing VM")
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
    func loadVMsAppliesCustomOrder() {
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

        #expect(viewModel.instances.map(\.name) == ["Third", "First", "Second"])
    }

    @Test("loadVMs falls back to createdAt when no custom order exists")
    func loadVMsFallsBackToCreatedAt() {
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

        #expect(viewModel.instances.map(\.name) == ["Older", "Newer"])
    }

    @Test("reconcileWithDisk appends new VMs after custom-ordered ones")
    func reconcileAppendsNewVMs() {
        let storage = MockVMStorageService()
        let config1 = VMConfiguration(
            name: "Existing", guestOS: .linux, bootMode: .efi, createdAt: Date(timeIntervalSince1970: 200))
        let url1 = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(config1.id.uuidString).kernova", isDirectory: true)
        storage.bundles[url1] = config1

        let (viewModel, _, _, _, _) = makeViewModel(storageService: storage)
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

    @Test("deleteConfirmed removes VM from persisted order")
    func deleteRemovesFromOrder() {
        let (viewModel, storage, _, _, _) = makeViewModel()
        let a = makeInstance(name: "A")
        let b = makeInstance(name: "B")
        viewModel.instances = [a, b]
        viewModel.selectedID = b.id
        storage.bundles[b.bundleURL] = b.configuration

        viewModel.deleteConfirmed(b)

        #expect(preferences.vmOrder == [a.id])
    }

    @Test("custom order ignores stale UUIDs not present in loaded VMs")
    func customOrderIgnoresStaleUUIDs() {
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
        instance.status = .running
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
        instance.status = .running
        let installerItem = RemovableMediaItem(path: installerURL.path(percentEncoded: false), readOnly: true)
        instance.configuration.removableMedia = [installerItem]
        instance.liveRemovableMedia = [
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
        instance.status = .running
        viewModel.instances.append(instance)

        viewModel.mountGuestAgentInstaller(on: instance, purpose: .manage)

        #expect(presenter.installerMountedPurpose == .manage)
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
    func onAgentBecameCurrentAutoEjectsInstaller() throws {
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
        let instance = try #require(viewModel.instances.first)

        #expect(viewModel.isGuestAgentInstallerMounted(on: instance))

        // Fire the hook the view model wired in `wirePersistence(for:)` — it
        // must detach the installer regardless of which window is open.
        instance.onAgentBecameCurrent?()

        #expect(!viewModel.isGuestAgentInstallerMounted(on: instance))
        #expect(instance.configuration.removableMedia == nil)
    }

    // MARK: - Live Removable Media Hot-Config

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

    @Test("applyLivePolicy attaches a new removable item when added to the list")
    func liveRemovableAddAttaches() async throws {
        let mock = MockUSBDeviceService()
        let (viewModel, _, _, _, _) = makeViewModel(usbDeviceService: mock)
        let instance = makeInstance()
        instance.status = .running
        viewModel.instances.append(instance)

        let configuredUUID = UUID()
        let old = instance.configuration
        let new = configWithRemovable(old, path: "/tmp/install.iso", readOnly: true, id: configuredUUID)

        viewModel.applyLivePolicy(for: instance, old: old, new: new)

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

    @Test("applyLivePolicy detaches and clears tracking when the only item is removed")
    func liveRemovableRemoveDetaches() async throws {
        let mock = MockUSBDeviceService()
        let (viewModel, _, _, _, _) = makeViewModel(usbDeviceService: mock)
        let instance = makeInstance()
        instance.status = .running
        let id = UUID()
        instance.liveRemovableMedia = [USBDeviceInfo(id: id, path: "/tmp/install.iso", readOnly: true)]
        var old = instance.configuration
        old.removableMedia = [RemovableMediaItem(id: id, path: "/tmp/install.iso", readOnly: true)]
        instance.configuration = old
        viewModel.instances.append(instance)

        var new = old
        new.removableMedia = nil

        viewModel.applyLivePolicy(for: instance, old: old, new: new)

        while !instance.liveRemovableMedia.isEmpty { await Task.yield() }

        #expect(mock.detachCallCount == 1)
        #expect(mock.attachCallCount == 0)
        #expect(instance.liveRemovableMedia.isEmpty)
    }

    @Test("applyLivePolicy swaps the only item: detach old, attach new")
    func liveRemovableSwapDetachesThenAttaches() async throws {
        let mock = MockUSBDeviceService()
        let (viewModel, _, _, _, _) = makeViewModel(usbDeviceService: mock)
        let instance = makeInstance()
        instance.status = .running
        let oldID = UUID()
        instance.liveRemovableMedia = [USBDeviceInfo(id: oldID, path: "/tmp/old.iso", readOnly: true)]
        var old = instance.configuration
        old.removableMedia = [RemovableMediaItem(id: oldID, path: "/tmp/old.iso", readOnly: true)]
        instance.configuration = old
        viewModel.instances.append(instance)

        let newID = UUID()
        var new = old
        new.removableMedia = [RemovableMediaItem(id: newID, path: "/tmp/new.iso", readOnly: true)]

        viewModel.applyLivePolicy(for: instance, old: old, new: new)

        while instance.liveRemovableMedia.first?.path != "/tmp/new.iso" { await Task.yield() }

        #expect(mock.detachCallCount == 1)
        #expect(mock.attachCallCount == 1)
        #expect(mock.lastAttachedPath == "/tmp/new.iso")
        #expect(instance.liveRemovableMedia.count == 1)
        #expect(instance.liveRemovableMedia.first?.id == newID)
    }

    @Test("applyLivePolicy detaches and reattaches on readOnly flip (same id)")
    func liveRemovableReadOnlyFlipReattaches() async throws {
        let mock = MockUSBDeviceService()
        let (viewModel, _, _, _, _) = makeViewModel(usbDeviceService: mock)
        let instance = makeInstance()
        instance.status = .running
        let id = UUID()
        instance.liveRemovableMedia = [USBDeviceInfo(id: id, path: "/tmp/install.iso", readOnly: true)]
        var old = instance.configuration
        old.removableMedia = [RemovableMediaItem(id: id, path: "/tmp/install.iso", readOnly: true)]
        instance.configuration = old
        viewModel.instances.append(instance)

        var new = old
        new.removableMedia = [RemovableMediaItem(id: id, path: "/tmp/install.iso", readOnly: false)]

        viewModel.applyLivePolicy(for: instance, old: old, new: new)

        while instance.liveRemovableMedia.first?.readOnly != false { await Task.yield() }

        #expect(mock.detachCallCount == 1)
        #expect(mock.attachCallCount == 1)
        #expect(mock.lastAttachedReadOnly == false)
    }

    @Test("applyLivePolicy is a no-op when storageDisks change but removableMedia is unchanged")
    func liveRemovableNoopWhenOnlyStorageDisksChange() async throws {
        let mock = MockUSBDeviceService()
        let (viewModel, _, _, _, _) = makeViewModel(usbDeviceService: mock)
        let instance = makeInstance()
        instance.status = .running
        viewModel.instances.append(instance)

        let old = instance.configuration
        var new = old
        new.storageDisks = [
            StorageDisk(path: "Disk.asif", readOnly: false, label: "Main Disk", isInternal: true, kind: .virtio)
        ]

        viewModel.applyLivePolicy(for: instance, old: old, new: new)
        for _ in 0..<5 { await Task.yield() }

        #expect(mock.attachCallCount == 0)
        #expect(mock.detachCallCount == 0)
    }

    @Test("applyLivePolicy is a no-op when VM is stopped, even with media change")
    func liveRemovableNoopWhenStopped() async throws {
        let mock = MockUSBDeviceService()
        let (viewModel, _, _, _, _) = makeViewModel(usbDeviceService: mock)
        let instance = makeInstance()
        instance.status = .stopped
        viewModel.instances.append(instance)

        let old = instance.configuration
        let new = configWithRemovable(old, path: "/tmp/install.iso")

        viewModel.applyLivePolicy(for: instance, old: old, new: new)
        for _ in 0..<5 { await Task.yield() }

        #expect(mock.attachCallCount == 0)
        #expect(mock.detachCallCount == 0)
        #expect(instance.liveRemovableMedia.isEmpty)
    }

    @Test("Live attach failure surfaces error")
    func liveRemovableAttachFailureSurfacesError() async throws {
        let mock = MockUSBDeviceService()
        mock.attachError = USBDeviceError.diskImageNotFound("/tmp/missing.iso")
        let (viewModel, _, _, _, _) = makeViewModel(usbDeviceService: mock)
        let instance = makeInstance()
        instance.status = .running
        viewModel.instances.append(instance)

        let old = instance.configuration
        let new = configWithRemovable(old, path: "/tmp/missing.iso")

        viewModel.applyLivePolicy(for: instance, old: old, new: new)

        while !presenter.showError { await Task.yield() }

        #expect(mock.attachCallCount == 1)
        #expect(presenter.errorMessage != nil)
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
        let (viewModel, _, _, _, _) = makeViewModel(usbDeviceService: mock)
        let instance = makeInstance()
        instance.status = .running
        let oldID = UUID()
        instance.liveRemovableMedia = [USBDeviceInfo(id: oldID, path: "/tmp/old.iso", readOnly: true)]
        var old = instance.configuration
        old.removableMedia = [RemovableMediaItem(id: oldID, path: "/tmp/old.iso", readOnly: true)]
        instance.configuration = old
        viewModel.instances.append(instance)

        let newID = UUID()
        var new = old
        new.removableMedia = [RemovableMediaItem(id: newID, path: "/tmp/new.iso", readOnly: true)]

        viewModel.applyLivePolicy(for: instance, old: old, new: new)

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
        let (viewModel, _, _, _, _) = makeViewModel(usbDeviceService: mock)
        let instance = makeInstance()
        instance.status = .running
        let oldID = UUID()
        instance.liveRemovableMedia = [USBDeviceInfo(id: oldID, path: "/tmp/old.iso", readOnly: true)]
        var old = instance.configuration
        old.removableMedia = [RemovableMediaItem(id: oldID, path: "/tmp/old.iso", readOnly: true)]
        instance.configuration = old
        viewModel.instances.append(instance)

        var new = old
        new.removableMedia = [RemovableMediaItem(path: "/tmp/new.iso", readOnly: true)]

        viewModel.applyLivePolicy(for: instance, old: old, new: new)

        while !presenter.showError { await Task.yield() }
        for _ in 0..<5 { await Task.yield() }

        #expect(mock.detachCallCount == 1)
        // No attach attempted — preventing the device-leak.
        #expect(mock.attachCallCount == 0)
    }

    @Test("Detach noVirtualMachine error bails the reconcile silently")
    func liveRemovableDetachNoVMBails() async throws {
        let mock = MockUSBDeviceService()
        mock.detachError = USBDeviceError.noVirtualMachine
        let (viewModel, _, _, _, _) = makeViewModel(usbDeviceService: mock)
        let instance = makeInstance()
        instance.status = .running
        let oldID = UUID()
        instance.liveRemovableMedia = [USBDeviceInfo(id: oldID, path: "/tmp/old.iso", readOnly: true)]
        var old = instance.configuration
        old.removableMedia = [RemovableMediaItem(id: oldID, path: "/tmp/old.iso", readOnly: true)]
        instance.configuration = old
        viewModel.instances.append(instance)

        var new = old
        new.removableMedia = [RemovableMediaItem(path: "/tmp/new.iso", readOnly: true)]

        viewModel.applyLivePolicy(for: instance, old: old, new: new)
        for _ in 0..<10 { await Task.yield() }

        #expect(mock.detachCallCount == 1)
        #expect(mock.attachCallCount == 0)
        #expect(!presenter.showError)
    }

    @Test("Attach noVirtualMachine error bails the reconcile silently")
    func liveRemovableAttachNoVMBails() async throws {
        let mock = MockUSBDeviceService()
        mock.attachError = USBDeviceError.noVirtualMachine
        let (viewModel, _, _, _, _) = makeViewModel(usbDeviceService: mock)
        let instance = makeInstance()
        instance.status = .running
        viewModel.instances.append(instance)

        let old = instance.configuration
        let new = configWithRemovable(old, path: "/tmp/install.iso")

        viewModel.applyLivePolicy(for: instance, old: old, new: new)
        for _ in 0..<10 { await Task.yield() }

        #expect(mock.attachCallCount == 1)
        #expect(mock.detachCallCount == 0)
        #expect(!presenter.showError)
        #expect(instance.liveRemovableMedia.isEmpty)
    }

    @Test("Reconcile loop bails out when VM stops mid-pass — no spurious error")
    func liveRemovableReconcileBailsOutOnVMStop() async throws {
        let mock = SuspendingMockUSBDeviceService()
        let (viewModel, _, _, _, _) = makeViewModel(usbDeviceService: mock)
        let instance = makeInstance()
        instance.status = .running
        viewModel.instances.append(instance)

        let baseConfig = instance.configuration
        let configA = configWithRemovable(baseConfig, path: "/tmp/A.iso")
        let configB = configWithRemovable(baseConfig, path: "/tmp/B.iso")

        viewModel.applyLivePolicy(for: instance, old: baseConfig, new: configA)
        await mock.waitUntilSuspended()
        // Stop the VM before the suspended attach resolves.
        viewModel.applyLivePolicy(for: instance, old: configA, new: configB)
        instance.status = .stopped

        mock.resumeSuspended()
        for _ in 0..<10 { await Task.yield() }

        #expect(mock.attachCallCount == 1)
        #expect(mock.lastAttachedPath == "/tmp/A.iso")
        #expect(!presenter.showError)
    }

    @Test("Rapid-fire media swaps coalesce — one Task drains to the latest target")
    func liveRemovableRapidFireCoalescesToLatest() async throws {
        let mock = SuspendingMockUSBDeviceService()
        let (viewModel, _, _, _, _) = makeViewModel(usbDeviceService: mock)
        let instance = makeInstance()
        instance.status = .running
        viewModel.instances.append(instance)

        let baseConfig = instance.configuration
        let configA = configWithRemovable(baseConfig, path: "/tmp/A.iso")
        let configB = configWithRemovable(baseConfig, path: "/tmp/B.iso")
        let configC = configWithRemovable(baseConfig, path: "/tmp/C.iso")

        // Three rapid edits before the first attach can complete.
        viewModel.applyLivePolicy(for: instance, old: baseConfig, new: configA)
        await mock.waitUntilSuspended()
        viewModel.applyLivePolicy(for: instance, old: configA, new: configB)
        viewModel.applyLivePolicy(for: instance, old: configB, new: configC)

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
        let main = VMLibraryViewModel.defaultStorageDisks(for: instance)[0]
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
        instance.status = .running
        let idA = UUID()
        let idB = UUID()
        instance.liveRemovableMedia = [
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

        viewModel.applyLivePolicy(for: instance, old: old, new: new)
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
        instance.status = .running
        let id = UUID()
        instance.liveRemovableMedia = [
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

        viewModel.applyLivePolicy(for: instance, old: old, new: new)
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
        instance.status = .running
        let id = UUID()
        instance.liveRemovableMedia = []
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

        viewModel.applyLivePolicy(for: instance, old: old, new: new)
        while !presenter.showError { await Task.yield() }
        for _ in 0..<5 { await Task.yield() }

        // Attach failed → device never mounted → config rolled back to nil.
        #expect(instance.configuration.removableMedia == nil)
    }

    @Test("Failed swap rollback restores the original entry, not the target")
    func liveRemovableRollbackOnSwapFailureRestoresOriginal() async throws {
        struct TransientError: Error {}
        let mock = MockUSBDeviceService()
        mock.detachError = TransientError()
        let (viewModel, _, _, _, _) = makeViewModel(usbDeviceService: mock)
        let instance = makeInstance()
        instance.status = .running
        let id = UUID()
        instance.liveRemovableMedia = [
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

        viewModel.applyLivePolicy(for: instance, old: old, new: new)
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

/// Drives the "cancel raced a non-cancellation error" path in
/// `VMLibraryViewModel.installAndAutoBoot`.
///
/// The mock signals via `installStartedStream` once `install` has parked, so
/// the test can `cancelInstallation` against a known-running install rather
/// than a race-prone "did the task even start yet?" guess. After
/// `Task.isCancelled` flips, the mock throws a non-CancellationError to
/// mimic the production case where a network error reaches the catch before
/// the cancellation propagates (e.g. an IPSW download that errors out at
/// roughly the same instant the user clicked Cancel).
@MainActor
private final class CancelRaceInstallService: MacOSInstallProviding {
    let installStartedStream: AsyncStream<Void>
    private let installStartedContinuation: AsyncStream<Void>.Continuation

    init() {
        let stream = AsyncStream<Void>.makeStream()
        self.installStartedStream = stream.stream
        self.installStartedContinuation = stream.continuation
    }

    func install(
        into instance: VMInstance,
        restoreImageURL: URL,
        progressHandler: @MainActor @Sendable @escaping (Double) -> Void
    ) async throws {
        installStartedContinuation.yield(())
        installStartedContinuation.finish()
        // Park until the surrounding Task is cancelled. `try? await
        // Task.sleep` returns immediately on cancel without propagating
        // the CancellationError, which is what we want — we WANT to throw
        // a *different* error to exercise the race-recovery branch.
        try? await Task.sleep(for: .seconds(60))
        throw IPSWError.downloadFailed(URLError(.badServerResponse))
    }
}

extension Result {
    fileprivate var isFailure: Bool {
        if case .failure = self { return true }
        return false
    }
}
