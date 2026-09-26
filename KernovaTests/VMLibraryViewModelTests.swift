import CryptoKit
import Foundation
import KernovaKit
import KernovaTestSupport
import Testing
import Virtualization

@testable import Kernova

@Suite("VMLibraryViewModel Tests", .serialized, .admissionGated)
@MainActor
struct VMLibraryViewModelTests {
    private let presenter = MockVMLibraryPresenting()
    /// Fresh per test (the struct is re-instantiated), so each test starts from
    /// an empty store.
    private let preferences = makeTestPreferences()
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
        removableMediaDeviceService: any RemovableMediaAttaching = MockRemovableMediaDeviceService(),
        linuxImageResolveService: MockLinuxImageResolveService = MockLinuxImageResolveService(),
        downloadService: MockDownloadService = MockDownloadService(),
        downloadsDirectory: URL? = nil,
        vmnetNetworks: MockVmnetNetworkProvider = MockVmnetNetworkProvider()
    ) -> (
        VMLibraryViewModel, MockVMStorageService, MockDiskImageService, MockVirtualizationService,
        any RemovableMediaAttaching
    ) {
        let vm = VMLibraryViewModel(
            storageService: storageService,
            diskImageService: diskImageService,
            virtualizationService: virtualizationService,
            installService: MockMacOSInstallService(),
            ipswService: MockIPSWService(),
            removableMediaDeviceService: removableMediaDeviceService,
            linuxImageResolveService: linuxImageResolveService,
            downloadService: downloadService,
            fileSystem: fileSystem,
            downloadsDirectory: downloadsDirectory,
            preferences: preferences,
            vmnetNetworks: vmnetNetworks,
            arpTable: ScriptedARPTable(),
            entitlements: .entitled
        )
        vm.presenter = presenter
        return (vm, storageService, diskImageService, virtualizationService, removableMediaDeviceService)
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
            removableMediaDeviceService: MockRemovableMediaDeviceService(),
            fileSystem: fileSystem,
            downloadsDirectory: nil,
            preferences: preferences,
            vmnetNetworks: MockVmnetNetworkProvider(), arpTable: ScriptedARPTable(), entitlements: .entitled
        )
        vm.presenter = presenter
        return (vm, suspending)
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
        let instance = VMInstanceFixture.make()
        viewModel.library.admitForTesting(instance)

        viewModel.requestDelete(instance)

        // Even a VM with no external files routes to the sheet now (it still
        // has its in-bundle main disk to show).
        #expect(presenter.instanceToDelete?.id == instance.id)
        #expect(presenter.showDeleteSheet == true)
    }

    @Test("deleteVM removes instance and clears selection")
    func deleteVM() async {
        let (viewModel, storage, _, _, _) = makeViewModel()
        let instance = VMInstanceFixture.make()
        viewModel.library.admitForTesting(instance)
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
        let first = VMInstanceFixture.make(name: "First")
        let second = VMInstanceFixture.make(name: "Second")
        viewModel.library.admitForTesting([first, second])
        viewModel.selectedID = second.id

        storage.bundles[second.bundleURL] = second.configuration

        await viewModel.delete(second)

        #expect(viewModel.instances.count == 1)
        #expect(viewModel.selectedID == first.id)
    }

    @Test("requestDelete forwards the immediate flag to the delete sheet")
    func requestDeleteForwardsPermanentlyFlag() {
        let (viewModel, _, _, _, _) = makeViewModel()
        let instance = VMInstanceFixture.make()
        viewModel.library.admitForTesting(instance)

        viewModel.requestDelete(instance)
        #expect(presenter.lastDeleteSheetPermanently == false)

        viewModel.requestDelete(instance, permanently: true)
        #expect(presenter.lastDeleteSheetPermanently == true)
    }

    @Test("deleteVM removes a cold-paused VM without a discard-saved-state pass")
    func deleteVMColdPaused() async {
        let (viewModel, storage, _, _, _) = makeViewModel()
        let instance = VMInstanceFixture.make()
        instance.activity.placeForTesting(.suspended)  // no live VM ⇒ cold-paused ("Suspended")
        viewModel.library.admitForTesting(instance)
        viewModel.selectedID = instance.id
        storage.bundles[instance.bundleURL] = instance.configuration

        #expect(instance.isColdPaused)
        #expect(instance.activity.admits(.operation(.deleting)))
        await viewModel.delete(instance)

        // The whole bundle goes, saved state included — no separate discard.
        #expect(viewModel.instances.isEmpty)
        #expect(viewModel.selectedID == nil)
        #expect(storage.deleteVMBundleCallCount == 1)
    }

    @Test("deleteVM refuses a VM that stopped being deletable while the sheet was open")
    func deleteVMRefusesWhenNoLongerDeletable() async {
        let (viewModel, storage, _, _, _) = makeViewModel()
        let instance = VMInstanceFixture.make()
        instance.activity.placeForTesting(.suspended)  // Suspended when the sheet opened…
        viewModel.library.admitForTesting(instance)
        storage.bundles[instance.bundleURL] = instance.configuration

        // …but a Resume landed via its still-live menu key equivalent before the
        // user clicked Move to Trash.
        instance.activity.placeForTesting(.running(sessionID: UUID()))

        await viewModel.delete(instance)

        #expect(viewModel.instances.count == 1)
        #expect(storage.deleteVMBundleCallCount == 0)
    }

    @Test("deleteVM refuses a VM whose cold resume is still restoring it")
    func deleteVMRefusesWhileRestoring() async throws {
        let storage = MockVMStorageService()
        let (viewModel, suspending) = makeSuspendingViewModel(storage: storage)
        let instance = VMInstanceFixture.make()
        instance.activity.placeForTesting(.suspended)
        defer { VMInstanceFixture.removeBundle(of: instance) }
        try VMInstanceFixture.writeSaveFile(for: instance)
        viewModel.library.admitForTesting(instance)
        storage.bundles[instance.bundleURL] = instance.configuration

        let resume = Task { @MainActor in
            try await viewModel.lifecycle.start(instance, .restoringSavedState)
        }
        await suspending.waitUntilSuspended()

        // The restore holds the VM for the whole of the configuration build, so
        // the capability gate is what refuses here — the bundle this would
        // trash is the one the restore is reading.
        #expect(instance.status == .restoring)
        #expect(!instance.activity.admits(.operation(.deleting)))

        await viewModel.delete(instance)

        #expect(viewModel.instances.count == 1)
        #expect(storage.deleteVMBundleCallCount == 0)

        suspending.resumeSuspended()
        _ = try await resume.value
    }

    @Test("deleteVM permanently hard-deletes the bundle, bypassing the Trash")
    func deleteVMPermanentlyUsesHardDelete() async {
        let (viewModel, storage, _, _, _) = makeViewModel()
        let instance = VMInstanceFixture.make()
        viewModel.library.admitForTesting(instance)
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
        let externalDisk = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-external.img")

        let diskID = UUID()
        let instance = VMInstanceFixture.make {
            $0.storageDisks = [
                StorageDisk(
                    id: diskID, path: externalDisk.path(percentEncoded: false),
                    readOnly: false, label: "External", isInternal: false, kind: .virtio
                )
            ]
        }
        viewModel.library.admitForTesting(instance)
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
        let target = VMInstanceFixture.make(name: "Target") {
            $0.storageDisks = [
                StorageDisk(
                    id: sharedID, path: sharedPath,
                    readOnly: false, label: "Shared", isInternal: false, kind: .virtio
                )
            ]
        }
        let other = VMInstanceFixture.make(name: "Other") {
            $0.storageDisks = [
                StorageDisk(
                    path: sharedPath, readOnly: false, label: "Shared",
                    isInternal: false, kind: .virtio
                )
            ]
        }
        viewModel.library.admitForTesting([target, other])
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
        let instance = VMInstanceFixture.make {
            $0.removableMedia = [RemovableMediaItem(path: "/tmp/installer.iso", readOnly: true)]
        }
        viewModel.library.admitForTesting(instance)

        viewModel.requestDelete(instance)

        #expect(presenter.instanceToDelete?.id == instance.id)
        #expect(presenter.showDeleteSheet == true)
    }

    @Test("externalAttachments returns external disks and removable media with sharing info")
    func externalAttachmentsLists() async {
        let (viewModel, _, _, _, _) = makeViewModel()
        let sharedISO = "/tmp/shared-installer.iso"
        let target = VMInstanceFixture.make(name: "Target") {
            $0.storageDisks = [
                StorageDisk(
                    path: "Disk.asif", readOnly: false, label: "Main",
                    isInternal: true, kind: .virtio
                ),
                StorageDisk(
                    path: "/Volumes/External/data.img", readOnly: false, label: "Scratch",
                    isInternal: false, kind: .virtio
                ),
            ]
            $0.removableMedia = [
                RemovableMediaItem(path: sharedISO, readOnly: true, label: "Shared ISO")
            ]
        }

        let sharer = VMInstanceFixture.make(name: "Sharer") {
            $0.removableMedia = [
                RemovableMediaItem(path: sharedISO, readOnly: true, label: "Shared ISO")
            ]
        }
        let unrelated = VMInstanceFixture.make(name: "Unrelated")
        viewModel.library.admitForTesting([target, sharer, unrelated])

        let attachments = await viewModel.externalAttachments(for: target)

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

    @Test("externalAttachments lists a Linux VM's kernel and initrd")
    func externalAttachmentsIncludeKernelAndInitrd() async {
        let (viewModel, _, _, _, _) = makeViewModel()
        let target = VMInstanceFixture.make(name: "Linux") {
            $0.kernelPath = "/Users/me/vmlinuz"
            $0.initrdPath = "/Users/me/initrd.img"
        }
        viewModel.library.admitForTesting([target])

        let attachments = await viewModel.externalAttachments(for: target)
        #expect(attachments.map(\.kind) == [.kernel, .initrd])
        #expect(attachments.map(\.label) == ["Kernel", "Initial RAM Disk"])
        #expect(attachments.allSatisfy { !$0.isShared })
    }

    @Test("A kernel a sibling VM also boots from is reported as shared")
    func externalAttachmentsMarkSharedKernel() async {
        let (viewModel, _, _, _, _) = makeViewModel()
        let kernelPath = "/Users/me/vmlinuz"
        let target = VMInstanceFixture.make(name: "Original") { $0.kernelPath = kernelPath }
        let clone = VMInstanceFixture.make(name: "Clone") { $0.kernelPath = kernelPath }
        viewModel.library.admitForTesting([target, clone])

        let attachments = await viewModel.externalAttachments(for: target)
        #expect(attachments.count == 1)
        #expect(attachments.first?.kind == .kernel)
        #expect(attachments.first?.sharedWithVMNames == ["Clone"])
    }

    @Test("externalAttachments never offers a shared directory")
    func externalAttachmentsExcludeSharedDirectories() async {
        let (viewModel, _, _, _, _) = makeViewModel()
        let target = VMInstanceFixture.make(name: "Sharer") {
            $0.sharedDirectories = [SharedDirectory(path: "/Users/me/Projects")]
        }
        viewModel.library.admitForTesting([target])

        #expect(await viewModel.externalAttachments(for: target).isEmpty)
    }

    @Test("externalAttachments flags isMissing per backing-file existence")
    func externalAttachmentsFlagMissing() async throws {
        let (viewModel, _, _, _, _) = makeViewModel()
        let presentDisk = FileManager.default.temporaryDirectory
            .appendingPathComponent("present-\(UUID().uuidString).img")
        try Data("disk".utf8).write(to: presentDisk)
        defer { try? FileManager.default.removeItem(at: presentDisk) }
        let missingPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString).iso").path

        let instance = VMInstanceFixture.make(name: "Target") {
            $0.storageDisks = [
                StorageDisk(
                    path: presentDisk.path, readOnly: false, label: "Present",
                    isInternal: false, kind: .virtio
                )
            ]
            $0.removableMedia = [
                RemovableMediaItem(path: missingPath, readOnly: true, label: "Missing ISO")
            ]
        }
        viewModel.library.admitForTesting([instance])

        let attachments = await viewModel.externalAttachments(for: instance)
        #expect(attachments.count == 2)
        #expect(attachments[0].path == presentDisk.path)
        #expect(attachments[0].isMissing == false)
        #expect(attachments[1].path == missingPath)
        #expect(attachments[1].isMissing == true)
    }

    @Test("externalAttachments is empty when the VM only has internal disks")
    func externalAttachmentsEmptyForInternalOnly() async {
        let (viewModel, _, _, _, _) = makeViewModel()
        let instance = VMInstanceFixture.make {
            $0.storageDisks = [
                StorageDisk(
                    path: "Disk.asif", readOnly: false, label: "Main",
                    isInternal: true, kind: .virtio
                )
            ]
        }
        viewModel.library.admitForTesting(instance)

        #expect(await viewModel.externalAttachments(for: instance).isEmpty)
    }

    @Test("externalAttachments excludes the bundled Guest Agent DMG")
    func externalAttachmentsExcludesGuestAgentDMG() async throws {
        let (viewModel, _, _, _, _) = makeViewModel()
        let agentPath = try #require(KernovaMacOSAgentInfo.installerDiskImageURL)
            .path(percentEncoded: false)
        let instance = VMInstanceFixture.make {
            $0.removableMedia = [
                RemovableMediaItem(path: agentPath, readOnly: true, label: "Kernova Guest Agent"),
                RemovableMediaItem(
                    path: "/Volumes/External/installer.iso", readOnly: true, label: "Installer"),
            ]
        }
        viewModel.library.admitForTesting(instance)

        let attachments = await viewModel.externalAttachments(for: instance)

        // The app-owned DMG is filtered out; only the user's ISO remains —
        // so it can never be surfaced for, or moved to, the Trash.
        #expect(attachments.count == 1)
        #expect(attachments[0].path == "/Volumes/External/installer.iso")
        #expect(!attachments.contains { $0.path == agentPath })
    }

    @Test("externalAttachments is empty when the only external is the Guest Agent DMG")
    func externalAttachmentsEmptyForGuestAgentOnly() async throws {
        let (viewModel, _, _, _, _) = makeViewModel()
        let agentPath = try #require(KernovaMacOSAgentInfo.installerDiskImageURL)
            .path(percentEncoded: false)
        let instance = VMInstanceFixture.make {
            $0.removableMedia = [
                RemovableMediaItem(path: agentPath, readOnly: true, label: "Kernova Guest Agent")
            ]
        }
        viewModel.library.admitForTesting(instance)

        // Empty means the sheet's "Files outside this VM" section is omitted
        // entirely — there is nothing for the user to decide about.
        #expect(await viewModel.externalAttachments(for: instance).isEmpty)
    }

    @Test("deleteVM never trashes the Guest Agent DMG even if its id is selected")
    func deleteVMNeverTrashesGuestAgentDMG() async throws {
        let (viewModel, storage, _, _, _) = makeViewModel()
        let agentPath = try #require(KernovaMacOSAgentInfo.installerDiskImageURL)
            .path(percentEncoded: false)
        let agentID = UUID()
        let instance = VMInstanceFixture.make {
            $0.removableMedia = [
                RemovableMediaItem(
                    id: agentID, path: agentPath, readOnly: true, label: "Kernova Guest Agent")
            ]
        }
        viewModel.library.admitForTesting(instance)
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
        let externalDisk = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-external.img")
        let externalISO = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-installer.iso")

        let instance = VMInstanceFixture.make {
            $0.storageDisks = [
                StorageDisk(
                    path: externalDisk.path(percentEncoded: false),
                    readOnly: false, label: "External", isInternal: false, kind: .virtio
                )
            ]
            $0.removableMedia = [
                RemovableMediaItem(path: externalISO.path(percentEncoded: false), readOnly: true)
            ]
        }
        viewModel.library.admitForTesting(instance)
        storage.bundles[instance.bundleURL] = instance.configuration

        await viewModel.delete(instance)

        #expect(viewModel.instances.isEmpty)
        #expect(fileSystem.trashedURLs.isEmpty)
        #expect(fileSystem.removedURLs.isEmpty)
        #expect(!presenter.showError)
    }

    // MARK: - Delete Externals

    @Test("deleteVM trashes the selected external disks and removable media")
    func deleteVMTrashesExternals() async throws {
        let (viewModel, storage, _, _, _) = makeViewModel()
        let externalDisk = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-external.img")
        let externalISO = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-installer.iso")

        let diskID = UUID()
        let isoID = UUID()
        let instance = VMInstanceFixture.make {
            $0.storageDisks = [
                StorageDisk(
                    id: diskID,
                    path: externalDisk.path(percentEncoded: false),
                    readOnly: false, label: "External", isInternal: false, kind: .virtio
                )
            ]
            $0.removableMedia = [
                RemovableMediaItem(
                    id: isoID, path: externalISO.path(percentEncoded: false), readOnly: true)
            ]
        }
        viewModel.library.admitForTesting(instance)
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
        let trashedDisk = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-trash.img")
        let keptDisk = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-keep.img")

        let trashedID = UUID()
        let keptID = UUID()
        let instance = VMInstanceFixture.make {
            $0.storageDisks = [
                StorageDisk(
                    id: trashedID, path: trashedDisk.path(percentEncoded: false),
                    readOnly: false, label: "Trashed", isInternal: false, kind: .virtio
                ),
                StorageDisk(
                    id: keptID, path: keptDisk.path(percentEncoded: false),
                    readOnly: false, label: "Kept", isInternal: false, kind: .virtio
                ),
            ]
        }
        viewModel.library.admitForTesting(instance)
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
        let target = VMInstanceFixture.make(name: "Target") {
            $0.storageDisks = [
                StorageDisk(
                    id: sharedID, path: sharedPath,
                    readOnly: false, label: "Shared", isInternal: false, kind: .virtio
                )
            ]
        }
        // A second VM references the same path, marking it shared.
        let other = VMInstanceFixture.make(name: "Other") {
            $0.storageDisks = [
                StorageDisk(
                    path: sharedPath, readOnly: false, label: "Shared",
                    isInternal: false, kind: .virtio
                )
            ]
        }
        viewModel.library.admitForTesting([target, other])
        storage.bundles[target.bundleURL] = target.configuration

        await viewModel.delete(target, deletingExternalIDs: [sharedID])

        // Hard-block: a shared file is never trashed, so the other VM keeps it.
        #expect(fileSystem.trashedURLs.isEmpty)
        #expect(!presenter.showError)
    }

    @Test("deleteVM never trashes a file a sibling names in a different path form")
    func deleteVMNeverTrashesSharedExternalAcrossPathForms() async throws {
        let (viewModel, storage, _, _, _) = makeViewModel()
        let sharedDisk = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "\(UUID().uuidString)-Cafe\u{0301}.img".precomposedStringWithCanonicalMapping)

        let sharedID = UUID()
        let sharedPath = sharedDisk.path(percentEncoded: false)
        let target = VMInstanceFixture.make(name: "Target") {
            $0.storageDisks = [
                StorageDisk(
                    id: sharedID, path: sharedPath,
                    readOnly: false, label: "Shared", isInternal: false, kind: .virtio
                )
            ]
        }
        // The sibling stores the decomposed form APFS reports for the same
        // name — a divergence a boot's path healing writes on its own.
        let other = VMInstanceFixture.make(name: "Other") {
            $0.storageDisks = [
                StorageDisk(
                    path: sharedPath.decomposedStringWithCanonicalMapping, readOnly: false,
                    label: "Shared", isInternal: false, kind: .virtio
                )
            ]
        }
        viewModel.library.admitForTesting([target, other])
        storage.bundles[target.bundleURL] = target.configuration

        await viewModel.delete(target, deletingExternalIDs: [sharedID])

        // One file, two spellings: the hard-block still holds.
        #expect(fileSystem.trashedURLs.isEmpty)
        #expect(!presenter.showError)
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
            removableMediaDeviceService: MockRemovableMediaDeviceService(),
            fileSystem: fileSystem,
            downloadsDirectory: nil,
            preferences: preferences,
            vmnetNetworks: MockVmnetNetworkProvider(), arpTable: ScriptedARPTable(), entitlements: .entitled
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

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-RestoreImage.ipsw")
        let instance = VMInstanceFixture.make {
            $0.installContext = MacOSInstallContext(
                source: source,
                downloadDestinationPath: destination.path(percentEncoded: false)
            )
        }
        viewModel.library.admitForTesting(instance)
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

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-RestoreImage.ipsw")
        let instance = VMInstanceFixture.make {
            $0.installContext = MacOSInstallContext(
                source: .downloadLatest,
                downloadDestinationPath: destination.path(percentEncoded: false)
            )
        }
        viewModel.library.admitForTesting(instance)
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

        // A destination path is set so the source — not a nil destination — is
        // what keeps the cleanup from firing.
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-RestoreImage.ipsw")
        let instance = VMInstanceFixture.make {
            $0.installContext = MacOSInstallContext(
                source: .localFile,
                downloadDestinationPath: destination.path(percentEncoded: false),
                localIPSWPath: "/tmp/UserPicked.ipsw"
            )
        }
        viewModel.library.admitForTesting(instance)
        storage.bundles[instance.bundleURL] = instance.configuration

        await viewModel.delete(instance)

        #expect(ipswService.discardResumeDataCallCount == 0)
    }

    @Test("deleteVM leaves resume-data alone when VM has no install context")
    func deleteVMNoResumeDataForNonInstallVM() async {
        let ipswService = MockIPSWService()
        let storage = MockVMStorageService()
        let viewModel = makeViewModelWithIPSW(ipswService: ipswService, storage: storage)
        let instance = VMInstanceFixture.make()
        viewModel.library.admitForTesting(instance)
        storage.bundles[instance.bundleURL] = instance.configuration

        await viewModel.delete(instance)

        #expect(ipswService.discardResumeDataCallCount == 0)
    }

    @Test("deleteVM swallows missing-file errors for a selected external")
    func deleteVMSwallowsMissingExternals() async {
        let (viewModel, storage, _, _, _) = makeViewModel()
        fileSystem.trashError = CocoaError(.fileNoSuchFile)
        let ghostID = UUID()
        let ghostPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("kernova-ghost-\(UUID().uuidString).iso")
            .path(percentEncoded: false)
        let instance = VMInstanceFixture.make {
            $0.removableMedia = [RemovableMediaItem(id: ghostID, path: ghostPath, readOnly: true)]
        }
        viewModel.library.admitForTesting(instance)
        storage.bundles[instance.bundleURL] = instance.configuration

        await viewModel.delete(instance, deletingExternalIDs: [ghostID])

        #expect(viewModel.instances.isEmpty)
        #expect(!presenter.showError)
    }

    @Test("deleteVM permanently swallows missing-file errors for a selected external")
    func deleteVMPermanentlySwallowsMissingExternals() async {
        let (viewModel, storage, _, _, _) = makeViewModel()
        fileSystem.removeError = CocoaError(.fileNoSuchFile)
        let ghostID = UUID()
        let ghostPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("kernova-ghost-\(UUID().uuidString).iso")
            .path(percentEncoded: false)
        let instance = VMInstanceFixture.make {
            $0.removableMedia = [RemovableMediaItem(id: ghostID, path: ghostPath, readOnly: true)]
        }
        viewModel.library.admitForTesting(instance)
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
        let instance = VMInstanceFixture.make()
        viewModel.library.admitForTesting(instance)
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

    @Test("The command core's quit reaches the adapter hook the app delegate answers")
    func quitVerbReachesTheQuitHook() async throws {
        let (viewModel, _, _, _, _) = makeViewModel()
        let quits = QuitHookRecorder()
        // What `AppDelegate` answers with `AppTerminationController.requestFullQuit()`.
        viewModel.onRequestQuit = { quits.record() }

        viewModel.commands.quit()

        try await quits.gate.wait { quits.count == 1 }
        #expect(quits.count == 1)
    }

    @Test("Showing a VM in the Finder goes through the facade to the delegate's hook")
    func showInFinderReachesTheFinderHook() {
        let (viewModel, _, _, _, _) = makeViewModel()
        let instance = VMInstanceFixture.make(name: "Filed")
        viewModel.library.admitForTesting(instance)
        var revealed: [URL] = []
        // What `AppDelegate` answers with `activateFileViewerSelecting`.
        viewModel.onRevealInFinder = { revealed.append($0.bundleURL) }

        viewModel.showVMInFinder(instance)

        #expect(revealed == [instance.bundleURL])
        #expect(!presenter.showError)
    }

    @Test("start delegates to lifecycle coordinator")
    func startDelegates() async {
        let (viewModel, _, _, virtService, _) = makeViewModel()
        let instance = VMInstanceFixture.make()
        viewModel.library.admitForTesting(instance)

        await viewModel.start(instance)

        #expect(virtService.startCallCount == 1)
        #expect(instance.status == .running)
        #expect(virtService.lastStartBootIntoRecovery == false)
    }

    @Test("requestStartInRecovery routes to the presenter")
    func requestStartInRecoveryRoutesToPresenter() {
        let (viewModel, _, _, _, _) = makeViewModel()
        let instance = VMInstanceFixture.make()
        viewModel.library.admitForTesting(instance)

        viewModel.requestStartInRecovery(instance)

        #expect(presenter.showRecoveryBootConfirmation)
        #expect(presenter.instanceToRecoveryBoot === instance)
    }

    @Test("startInRecovery starts with the recovery flag set")
    func startInRecoverySetsFlag() async {
        let (viewModel, _, _, virtService, _) = makeViewModel()
        // macOS only: Virtualization.framework has no recovery start option for
        // Linux/EFI guests, and the verb refuses one.
        let instance = VMInstanceFixture.make(guestOS: .macOS)
        viewModel.library.admitForTesting(instance)

        await viewModel.start(instance, bootIntoRecovery: true)

        #expect(virtService.startCallCount == 1)
        #expect(virtService.lastStartBootIntoRecovery == true)
    }

    @Test("stop delegates to lifecycle coordinator")
    func stopDelegates() async {
        let (viewModel, _, _, virtService, _) = makeViewModel()
        let instance = VMInstanceFixture.make()
        instance.activity.placeForTesting(.running(sessionID: UUID()))
        viewModel.library.admitForTesting(instance)

        await viewModel.stop(instance)

        #expect(virtService.stopCallCount == 1)
        #expect(instance.status == .stopped)
    }

    @Test("forceStop delegates to lifecycle coordinator")
    func forceStopDelegates() async {
        let (viewModel, _, _, virtService, _) = makeViewModel()
        let instance = VMInstanceFixture.make()
        instance.activity.placeForTesting(.running(sessionID: UUID()))
        viewModel.library.admitForTesting(instance)

        await viewModel.forceStop(instance)

        #expect(virtService.forceStopCallCount == 1)
        #expect(instance.status == .stopped)
    }

    @Test("pause delegates to lifecycle coordinator")
    func pauseDelegates() async {
        let (viewModel, _, _, virtService, _) = makeViewModel()
        let instance = VMInstanceFixture.make()
        instance.activity.placeForTesting(.running(sessionID: UUID()))
        viewModel.library.admitForTesting(instance)

        await viewModel.pause(instance)

        #expect(virtService.pauseCallCount == 1)
        #expect(instance.status == .paused)
    }

    @Test("resume delegates to lifecycle coordinator")
    func resumeDelegates() async throws {
        let (viewModel, _, _, virtService, _) = makeViewModel()
        let instance = VMInstanceFixture.make()
        instance.activity.placeForTesting(.suspended)
        defer { VMInstanceFixture.removeBundle(of: instance) }
        try VMInstanceFixture.writeSaveFile(for: instance)
        viewModel.library.admitForTesting(instance)

        await viewModel.resume(instance)

        // A cold resume is the restore bring-up, run through `start`.
        #expect(virtService.lastStartRoute == .restoredSavedState)
        #expect(instance.status == .running)
    }

    @Test("start of an inline-display VM focuses the guest display without asking for the library")
    func startRequestsInlineGuestFocus() async {
        let (viewModel, _, _, _, _) = makeViewModel()
        let instance = VMInstanceFixture.make()
        viewModel.library.admitForTesting(instance)
        var libraryRequests = 0
        viewModel.onSurfaceLibrary = { libraryRequests += 1 }

        await viewModel.start(instance)

        #expect(presenter.focusGuestDisplayInstances.count == 1)
        #expect(presenter.focusGuestDisplayInstances.last === instance)
        #expect(libraryRequests == 0)
    }

    /// A start with no window yet — an automation verb on a headless process —
    /// still selects the VM and buffers its focus for whenever the user opens
    /// the library, but does not open it for them.
    @Test("start of an inline-display VM with no window buffers its focus and asks for no library")
    func startWithNoWindowBuffersFocusWithoutTheLibrary() async {
        let (viewModel, _, _, _, _) = makeViewModel()
        let instance = VMInstanceFixture.make()
        viewModel.library.admitForTesting(instance)
        viewModel.presenter = nil
        var libraryRequests = 0
        viewModel.onSurfaceLibrary = { libraryRequests += 1 }

        await viewModel.start(instance)

        #expect(libraryRequests == 0)
        #expect(viewModel.selectedID == instance.id)
        viewModel.presenter = presenter
        #expect(presenter.focusGuestDisplayInstances.last === instance)
    }

    /// A detached VM's window belongs to the bring-up's own readying, decided
    /// from the app's posture — the door asks for nothing but the inline focus
    /// it can give.
    @Test("start of a pop-out VM requests no inline focus")
    func startPopOutSkipsInlineGuestFocus() async {
        let (viewModel, _, _, _, _) = makeViewModel()
        let instance = VMInstanceFixture.make(hostState: VMHostState(displayPreference: .popOut))
        viewModel.library.admitForTesting(instance)

        await viewModel.start(instance)

        #expect(presenter.focusGuestDisplayInstances.isEmpty)
    }

    @Test("resume of an inline-display VM focuses the guest display without asking for the library")
    func resumeRequestsInlineGuestFocus() async {
        let (viewModel, _, _, _, _) = makeViewModel()
        let instance = VMInstanceFixture.make()
        instance.activity.placeForTesting(.suspended)
        viewModel.library.admitForTesting(instance)
        var libraryRequests = 0
        viewModel.onSurfaceLibrary = { libraryRequests += 1 }

        await viewModel.resume(instance)

        #expect(presenter.focusGuestDisplayInstances.count == 1)
        #expect(presenter.focusGuestDisplayInstances.last === instance)
        #expect(libraryRequests == 0)
    }

    @Test("resume of a pop-out VM requests no inline focus, as start does")
    func resumePopOutSkipsInlineGuestFocus() async {
        let (viewModel, _, _, _, _) = makeViewModel()
        let instance = VMInstanceFixture.make(hostState: VMHostState(displayPreference: .popOut))
        instance.activity.placeForTesting(.suspended)
        viewModel.library.admitForTesting(instance)

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
        let onScreen = VMInstanceFixture.make(name: "OnScreen")
        let wanted = VMInstanceFixture.make(name: "Wanted")
        wanted.activity.placeForTesting(.running(sessionID: UUID()))
        viewModel.library.admitForTesting([onScreen, wanted])
        viewModel.selectedID = onScreen.id

        try viewModel.commands.open(.id(wanted.id))

        #expect(viewModel.selectedID == wanted.id)
        #expect(presenter.focusGuestDisplayInstances.last === wanted)
    }

    /// The inline display lives inside the library window, so focusing it in a
    /// window that is buried, miniaturized, or on another Space surfaces
    /// nothing a person can see — `focusGuestDisplay` only moves the first
    /// responder.
    @Test("Surfacing an inline VM asks for the library even with a window attached")
    func openOfAnInlineVMAlwaysAsksForTheLibrary() throws {
        let (viewModel, _, _, _, _) = makeViewModel()
        let wanted = VMInstanceFixture.make(name: "Wanted")
        wanted.activity.placeForTesting(.running(sessionID: UUID()))
        viewModel.library.admitForTesting(wanted)
        // `makeViewModel` attaches the presenter, standing in for a window that
        // exists — the case that used to skip the request.
        var libraryRequests = 0
        viewModel.onSurfaceLibrary = { libraryRequests += 1 }

        try viewModel.commands.open(.id(wanted.id))

        #expect(libraryRequests == 1)
        #expect(presenter.focusGuestDisplayInstances.last === wanted)
    }

    @Test("Surfacing a pop-out VM's display asks for no library window")
    func openOfAPopOutVMAsksForNoLibrary() throws {
        let (viewModel, _, _, _, _) = makeViewModel()
        let wanted = VMInstanceFixture.make(name: "Wanted", hostState: VMHostState(displayPreference: .popOut))
        wanted.activity.placeForTesting(.running(sessionID: UUID()))
        viewModel.library.admitForTesting(wanted)
        var libraryRequests = 0
        viewModel.onSurfaceLibrary = { libraryRequests += 1 }

        try viewModel.commands.open(.id(wanted.id))

        #expect(libraryRequests == 0)
    }

    /// The inline display lives inside the main window, so an intent surfacing
    /// one on a process that has never opened a window — the headless launch
    /// path — has nowhere to land and used to do nothing at all.
    @Test("Surfacing an inline VM with no window asks for the library, then focuses it")
    func openWithNoWindowRequestsTheLibraryFirst() throws {
        let (viewModel, _, _, _, _) = makeViewModel()
        let wanted = VMInstanceFixture.make(name: "Wanted")
        wanted.activity.placeForTesting(.running(sessionID: UUID()))
        viewModel.library.admitForTesting(wanted)
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

    @Test("Revealing a stopped VM selects it and asks for the library window")
    func revealSelectsAndAsksForTheLibrary() throws {
        let (viewModel, _, _, _, _) = makeViewModel()
        let onScreen = VMInstanceFixture.make(name: "OnScreen")
        let wanted = VMInstanceFixture.make(name: "Wanted")
        viewModel.library.admitForTesting([onScreen, wanted])
        viewModel.selectedID = onScreen.id
        var libraryRequests = 0
        viewModel.onSurfaceLibrary = { libraryRequests += 1 }

        // A stopped VM has no display, which is the whole difference from open.
        try viewModel.commands.reveal(.id(wanted.id))

        #expect(viewModel.selectedID == wanted.id)
        #expect(libraryRequests == 1)
        #expect(presenter.focusGuestDisplayInstances.isEmpty)
    }

    @Test("Revealing a VM with no window yet asks for the library the same way")
    func revealWithNoWindowAsksForTheLibrary() throws {
        let (viewModel, _, _, _, _) = makeViewModel()
        let wanted = VMInstanceFixture.make(name: "Wanted")
        viewModel.library.admitForTesting(wanted)
        // No main window has been created, which is what leaves `presenter` nil.
        viewModel.presenter = nil
        var libraryRequests = 0
        viewModel.onSurfaceLibrary = { libraryRequests += 1 }

        try viewModel.commands.reveal(.id(wanted.id))

        #expect(viewModel.selectedID == wanted.id)
        #expect(libraryRequests == 1)
    }

    @Test("Revealing a running VM focuses its display, not just its library row")
    func revealOfARunningVMSurfacesTheDisplay() throws {
        let (viewModel, _, _, _, _) = makeViewModel()
        let wanted = VMInstanceFixture.make(name: "Wanted")
        wanted.activity.placeForTesting(.running(sessionID: UUID()))
        viewModel.library.admitForTesting(wanted)
        var libraryRequests = 0
        viewModel.onSurfaceLibrary = { libraryRequests += 1 }

        try viewModel.commands.reveal(.id(wanted.id))

        // The library window carries the inline display, so it is asked for
        // either way; the focus is what separates this from a bare reveal.
        #expect(presenter.focusGuestDisplayInstances.last === wanted)
        #expect(libraryRequests == 1)
    }

    /// A suspended VM still has a display — the window shows what its saved
    /// state left on screen — so the reveal opens the window rather than
    /// dropping the person on a library row.
    @Test("Revealing a suspended pop-out VM opens its display window")
    func revealOfASuspendedPopOutVMOpensItsWindow() throws {
        let (viewModel, _, _, _, _) = makeViewModel()
        let wanted = VMInstanceFixture.make(name: "Wanted", hostState: VMHostState(displayPreference: .popOut))
        wanted.activity.placeForTesting(.suspended)
        viewModel.library.admitForTesting(wanted)
        var displayWindows: [VMInstance] = []
        viewModel.onOpenDisplayWindow = { displayWindows.append($0) }
        var libraryRequests = 0
        viewModel.onSurfaceLibrary = { libraryRequests += 1 }

        try viewModel.commands.reveal(.id(wanted.id))

        #expect(displayWindows.map(\.id) == [wanted.id])
        #expect(libraryRequests == 0)
    }

    @Test("Revealing a suspended inline VM lands on its library row and focuses it")
    func revealOfASuspendedInlineVMLandsInTheLibrary() throws {
        let (viewModel, _, _, _, _) = makeViewModel()
        let wanted = VMInstanceFixture.make(name: "Wanted")
        wanted.activity.placeForTesting(.suspended)
        viewModel.library.admitForTesting(wanted)
        var displayWindows = 0
        viewModel.onOpenDisplayWindow = { _ in displayWindows += 1 }
        var libraryRequests = 0
        viewModel.onSurfaceLibrary = { libraryRequests += 1 }

        try viewModel.commands.reveal(.id(wanted.id))

        #expect(displayWindows == 0)
        #expect(libraryRequests == 1)
        #expect(viewModel.selectedID == wanted.id)
        #expect(presenter.focusGuestDisplayInstances.last === wanted)
    }

    @Test("A buffered surface request is dropped when its VM leaves before the window arrives")
    func bufferedSurfaceRequestSurvivesAVanishedVM() throws {
        let (viewModel, _, _, _, _) = makeViewModel()
        let wanted = VMInstanceFixture.make(name: "Wanted")
        wanted.activity.placeForTesting(.running(sessionID: UUID()))
        viewModel.library.admitForTesting(wanted)
        viewModel.presenter = nil
        viewModel.onSurfaceLibrary = {}

        try viewModel.commands.open(.id(wanted.id))
        viewModel.library.evict(wanted)
        viewModel.presenter = presenter

        #expect(presenter.focusGuestDisplayInstances.isEmpty)
    }

    @Test("Surfacing a pop-out VM's display leaves the selection where it was")
    func openOfAPopOutVMLeavesTheSelectionAlone() async throws {
        let (viewModel, _, _, _, _) = makeViewModel()
        let onScreen = VMInstanceFixture.make(name: "OnScreen")
        let wanted = VMInstanceFixture.make(name: "Wanted", hostState: VMHostState(displayPreference: .popOut))
        wanted.activity.placeForTesting(.running(sessionID: UUID()))
        viewModel.library.admitForTesting([onScreen, wanted])
        viewModel.selectedID = onScreen.id

        try viewModel.commands.open(.id(wanted.id))

        #expect(viewModel.selectedID == onScreen.id)
        #expect(presenter.focusGuestDisplayInstances.isEmpty)
    }

    @Test("save delegates to lifecycle coordinator")
    func saveDelegates() async {
        let (viewModel, _, _, virtService, _) = makeViewModel()
        let instance = VMInstanceFixture.make()
        instance.activity.placeForTesting(.running(sessionID: UUID()))
        viewModel.library.admitForTesting(instance)

        await viewModel.save(instance)

        #expect(virtService.saveCallCount == 1)
        #expect(instance.status == .paused)
    }

    // MARK: - Duplicate Machine ID Boot Guard

    /// Adds `instances` to `viewModel` wired to its library, as a load would —
    /// the identity refusal every bring-up passes reads its peers through that
    /// wiring, and an unwired VM has none.
    private func wire(_ instances: [VMInstance], into viewModel: VMLibraryViewModel) {
        for instance in instances { viewModel.library.wireHooks(for: instance) }
        viewModel.library.admitForTesting(instances)
    }

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
        func makeTwin(_ name: String, identifier: Data) -> VMInstance {
            VMInstanceFixture.make(name: name, guestOS: guestOS) {
                if guestOS == .macOS {
                    $0.machineIdentifierData = identifier
                } else {
                    $0.genericMachineIdentifierData = identifier
                }
            }
        }
        let starting = makeTwin("Starting", identifier: startingID)
        let other = makeTwin("Twin", identifier: otherID)
        wire([starting, other], into: viewModel)
        return (starting, other)
    }

    @Test("start is refused while another VM with the same machine ID is running")
    func startBlockedByRunningMachineIDTwin() async {
        let virtService = MockVirtualizationService()
        let (viewModel, _, _, _, _) = makeViewModel(virtualizationService: virtService)
        let (starting, other) = appendMachineIDPair(to: viewModel)
        other.activity.placeForTesting(.running(sessionID: UUID()))

        await viewModel.start(starting)

        // Refused at admission, before the service was reached.
        #expect(virtService.startCallCount == 0)
        #expect(presenter.errorTitle == "Duplicate Machine ID")
        #expect(starting.status == .stopped)
    }

    @Test("start proceeds past a machine ID twin when the guard preference is off")
    func startProceedsWhenDuplicateMachineIDGuardDisabled() async {
        let virtService = MockVirtualizationService()
        let (viewModel, _, _, _, _) = makeViewModel(virtualizationService: virtService)
        let (starting, other) = appendMachineIDPair(to: viewModel)
        other.activity.placeForTesting(.running(sessionID: UUID()))
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
        other.activity.placeForTesting(.stopped)

        await viewModel.start(starting)

        #expect(virtService.startCallCount == 1)
        #expect(presenter.showError == false)
    }

    @Test("start is refused while the machine ID twin is live-paused (VZ still holds the identity)")
    func startBlockedByPausedMachineIDTwin() async throws {
        let virtService = MockVirtualizationService()
        let (viewModel, _, _, _, _) = makeViewModel(virtualizationService: virtService)
        let (starting, other) = appendMachineIDPair(to: viewModel)
        other.activity.placeForTesting(.livePaused(sessionID: UUID()))

        await viewModel.start(starting)

        // Refused at admission, before the service was reached.
        #expect(virtService.startCallCount == 0)
        #expect(presenter.errorTitle == "Duplicate Machine ID")
        #expect(starting.status == .stopped)
    }

    @Test("start proceeds when the machine ID twin is cold-paused (it holds no VZ identity)")
    func startProceedsWhenMachineIDTwinIsColdPaused() async {
        let virtService = MockVirtualizationService()
        let (viewModel, _, _, _, _) = makeViewModel(virtualizationService: virtService)
        let (starting, other) = appendMachineIDPair(to: viewModel)
        other.activity.placeForTesting(.suspended)
        #expect(other.isColdPaused)

        await viewModel.start(starting)

        #expect(virtService.startCallCount == 1)
        #expect(presenter.showError == false)
    }

    @Test("start is refused when both VMs carry their machine ID only as a bundle file")
    func startBlockedByFileOnlyMachineIDTwin() async throws {
        let virtService = MockVirtualizationService()
        let (viewModel, _, _, _, _) = makeViewModel(virtualizationService: virtService)
        let starting = VMInstanceFixture.make(name: "Starting", guestOS: .macOS)
        let other = VMInstanceFixture.make(name: "Twin", guestOS: .macOS)
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
        wire([starting, other], into: viewModel)
        other.activity.placeForTesting(.running(sessionID: UUID()))

        await viewModel.start(starting)

        #expect(starting.configuration.machineIdentifierData == nil)
        // Refused at admission, before the service was reached.
        #expect(virtService.startCallCount == 0)
        #expect(presenter.errorTitle == "Duplicate Machine ID")
        #expect(starting.status == .stopped)
    }

    @Test("a cold resume is refused while a machine ID twin is running")
    func coldResumeBlockedByRunningMachineIDTwin() async throws {
        let virtService = MockVirtualizationService()
        let (viewModel, _, _, _, _) = makeViewModel(virtualizationService: virtService)
        let (resuming, other) = appendMachineIDPair(to: viewModel)
        // Cold-paused: paused with no `virtualMachine`, so the resume would build
        // a fresh one and claim the identity.
        resuming.activity.placeForTesting(.suspended)
        defer { VMInstanceFixture.removeBundle(of: resuming) }
        try VMInstanceFixture.writeSaveFile(for: resuming)
        other.activity.placeForTesting(.running(sessionID: UUID()))

        await viewModel.resume(resuming)

        // Refused at admission: the restore never reached the service.
        #expect(virtService.startCallCount == 0)
        #expect(presenter.errorTitle == "Duplicate Machine ID")
        #expect(resuming.phase == .suspended)
        #expect(resuming.hasSaveFile)
    }

    @Test("a cold resume proceeds past a machine ID twin when the guard preference is off")
    func coldResumeProceedsWhenDuplicateMachineIDGuardDisabled() async throws {
        let virtService = MockVirtualizationService()
        let (viewModel, _, _, _, _) = makeViewModel(virtualizationService: virtService)
        let (resuming, other) = appendMachineIDPair(to: viewModel)
        resuming.activity.placeForTesting(.suspended)
        defer { VMInstanceFixture.removeBundle(of: resuming) }
        try VMInstanceFixture.writeSaveFile(for: resuming)
        other.activity.placeForTesting(.running(sessionID: UUID()))
        preferences.blockDuplicateMachineIDBoot = false

        await viewModel.resume(resuming)

        #expect(virtService.lastStartRoute == .restoredSavedState)
        #expect(presenter.showError == false)
    }

    @Test("a hot resume is never refused — the live VM already holds the identity")
    func hotResumeIsNotBlockedByMachineIDTwin() async throws {
        let virtService = MockVirtualizationService()
        let (viewModel, _, _, _, _) = makeViewModel(virtualizationService: virtService)
        let (resuming, other) = appendMachineIDPair(to: viewModel)
        resuming.activity.placeForTesting(.livePaused(sessionID: UUID()))
        other.activity.placeForTesting(.running(sessionID: UUID()))

        await viewModel.resume(resuming)

        #expect(virtService.resumeCallCount == 1)
        #expect(presenter.showError == false)
    }

    @Test("start proceeds when the running VM's machine ID differs")
    func startProceedsWhenMachineIDsDiffer() async {
        let virtService = MockVirtualizationService()
        let (viewModel, _, _, _, _) = makeViewModel(virtualizationService: virtService)
        let (starting, other) = appendMachineIDPair(to: viewModel, otherID: Data([4, 5, 6]))
        other.activity.placeForTesting(.running(sessionID: UUID()))

        await viewModel.start(starting)

        #expect(virtService.startCallCount == 1)
        #expect(presenter.showError == false)
    }

    @Test("start is refused while a Linux VM sharing the generic machine ID is running")
    func startBlockedByRunningGenericMachineIDTwin() async {
        let virtService = MockVirtualizationService()
        let (viewModel, _, _, _, _) = makeViewModel(virtualizationService: virtService)
        let (starting, other) = appendMachineIDPair(to: viewModel, guestOS: .linux)
        other.activity.placeForTesting(.running(sessionID: UUID()))

        await viewModel.start(starting)

        // Refused at admission, before the service was reached.
        #expect(virtService.startCallCount == 0)
        #expect(presenter.errorTitle == "Duplicate Machine ID")
        #expect(starting.status == .stopped)
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
        otherMode: VMNetworkMode = .shared,
        mutateStarting: (inout VMConfiguration) -> Void = { _ in },
        mutateOther: (inout VMConfiguration) -> Void = { _ in }
    ) -> (starting: VMInstance, other: VMInstance) {
        let starting = VMInstanceFixture.make(name: "Starting") {
            $0.macAddress = mac
            $0.networkMode = mode
            mutateStarting(&$0)
        }
        let other = VMInstanceFixture.make(name: "Twin") {
            $0.macAddress = otherMAC
            $0.networkMode = otherMode
            mutateOther(&$0)
        }
        wire([starting, other], into: viewModel)
        return (starting, other)
    }

    @Test("start is refused while another VM with the same MAC address is running")
    func startBlockedByRunningMACAddressTwin() async {
        let virtService = MockVirtualizationService()
        let (viewModel, _, _, _, _) = makeViewModel(virtualizationService: virtService)
        let (starting, other) = appendMACAddressPair(to: viewModel)
        other.activity.placeForTesting(.running(sessionID: UUID()))

        await viewModel.start(starting)

        // Refused at admission, before the service was reached.
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
        other.activity.placeForTesting(.livePaused(sessionID: UUID()))

        await viewModel.start(starting)

        // Refused at admission, before the service was reached.
        #expect(virtService.startCallCount == 0)
        #expect(presenter.errorTitle == "Duplicate MAC Address")
        #expect(starting.status == .stopped)
    }

    @Test("start proceeds when the MAC address twin is stopped")
    func startProceedsWhenMACAddressTwinIsStopped() async {
        let virtService = MockVirtualizationService()
        let (viewModel, _, _, _, _) = makeViewModel(virtualizationService: virtService)
        let (starting, other) = appendMACAddressPair(to: viewModel)
        other.activity.placeForTesting(.stopped)

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
        other.activity.placeForTesting(.running(sessionID: UUID()))

        await viewModel.start(starting)

        #expect(virtService.startCallCount == 1)
        #expect(presenter.showError == false)
    }

    @Test("start is refused for two bridged VMs whichever interface each names")
    func startBlockedByBridgedMACAddressTwinOnAnotherInterface() async {
        let virtService = MockVirtualizationService()
        let (viewModel, _, _, _, _) = makeViewModel(virtualizationService: virtService)
        let (starting, other) = appendMACAddressPair(
            to: viewModel, mode: .bridged, otherMode: .bridged,
            mutateStarting: { $0.bridgedInterfaceIdentifier = "en0" },
            mutateOther: { $0.bridgedInterfaceIdentifier = "en1" })
        other.activity.placeForTesting(.running(sessionID: UUID()))

        await viewModel.start(starting)

        // Refused at admission, before the service was reached.
        #expect(virtService.startCallCount == 0)
        #expect(presenter.errorTitle == "Duplicate MAC Address")
        #expect(starting.status == .stopped)
    }

    @Test("start proceeds when the starting VM has networking off")
    func startProceedsWhenStartingVMHasNetworkingOff() async {
        let virtService = MockVirtualizationService()
        let (viewModel, _, _, _, _) = makeViewModel(virtualizationService: virtService)
        let (starting, other) = appendMACAddressPair(
            to: viewModel, mutateStarting: { $0.networkEnabled = false })
        other.activity.placeForTesting(.running(sessionID: UUID()))

        await viewModel.start(starting)

        #expect(virtService.startCallCount == 1)
        #expect(presenter.showError == false)
    }

    @Test("start proceeds when the running MAC address twin has networking off")
    func startProceedsWhenMACAddressTwinHasNetworkingOff() async {
        let virtService = MockVirtualizationService()
        let (viewModel, _, _, _, _) = makeViewModel(virtualizationService: virtService)
        let (starting, other) = appendMACAddressPair(
            to: viewModel, mutateOther: { $0.networkEnabled = false })
        other.activity.placeForTesting(.running(sessionID: UUID()))

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
        other.activity.placeForTesting(.running(sessionID: UUID()))

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
        other.activity.placeForTesting(.running(sessionID: UUID()))

        await viewModel.start(starting)

        // Refused at admission, before the service was reached.
        #expect(virtService.startCallCount == 0)
        #expect(presenter.errorTitle == "Duplicate MAC Address")
        #expect(starting.status == .stopped)
    }

    @Test("a cold resume is refused while a MAC address twin is running")
    func coldResumeBlockedByRunningMACAddressTwin() async throws {
        let virtService = MockVirtualizationService()
        let (viewModel, _, _, _, _) = makeViewModel(virtualizationService: virtService)
        let (resuming, other) = appendMACAddressPair(to: viewModel)
        resuming.activity.placeForTesting(.suspended)
        defer { VMInstanceFixture.removeBundle(of: resuming) }
        try VMInstanceFixture.writeSaveFile(for: resuming)
        other.activity.placeForTesting(.running(sessionID: UUID()))

        await viewModel.resume(resuming)

        // Refused at admission: the restore never reached the service.
        #expect(virtService.startCallCount == 0)
        #expect(presenter.errorTitle == "Duplicate MAC Address")
        #expect(resuming.phase == .suspended)
        #expect(resuming.hasSaveFile)
    }

    @Test("a hot resume is never refused — the live VM already holds the address")
    func hotResumeIsNotBlockedByMACAddressTwin() async {
        let virtService = MockVirtualizationService()
        let (viewModel, _, _, _, _) = makeViewModel(virtualizationService: virtService)
        let (resuming, other) = appendMACAddressPair(to: viewModel)
        resuming.activity.placeForTesting(.livePaused(sessionID: UUID()))
        other.activity.placeForTesting(.running(sessionID: UUID()))

        await viewModel.resume(resuming)

        #expect(virtService.resumeCallCount == 1)
        #expect(presenter.showError == false)
    }

    @Test("a start that dispatches to macOS guest setup is refused before the installer runs")
    func macOSSetupStartBlockedByRunningMACAddressTwin() async {
        let virtService = MockVirtualizationService()
        let (viewModel, _, _, _, _) = makeViewModel(virtualizationService: virtService)
        let (starting, other) = appendMACAddressPair(
            to: viewModel,
            mutateStarting: {
                $0.installContext = MacOSInstallContext(
                    source: .localFile, localIPSWPath: "/tmp/foo.ipsw")
            })
        starting.activity.placeForTesting(.initialBoot)
        other.activity.placeForTesting(.running(sessionID: UUID()))

        await viewModel.start(starting)
        await starting.setupOperationTask?.value

        // The installer builds and runs its own VZ virtual machine, so the
        // refusal lands where the setup pipeline leaves rest, before the
        // installer runs.
        #expect(starting.status == .initialBoot)
        #expect(virtService.startCallCount == 0)
        #expect(presenter.errorTitle == "Duplicate MAC Address")
    }

    @Test("a live mode switch onto a MAC address twin's network is refused, changing nothing")
    func liveModeSwitchOntoAMACAddressTwinIsRefused() {
        let (viewModel, _, _, _, _) = makeViewModel()
        let (switching, other) = appendMACAddressPair(
            to: viewModel, mode: .hostOnly, otherMode: .shared)
        // Both run: the start guard allowed it, the modes being different.
        switching.activity.placeForTesting(.running(sessionID: UUID()))
        other.activity.placeForTesting(.running(sessionID: UUID()))

        let accepted = viewModel.library.updateConfiguration(of: switching) {
            $0.networkMode = .shared
        }

        #expect(accepted.refusedForMACAddress)
        #expect(switching.configuration.networkMode == .hostOnly)
        #expect(presenter.errorTitle == "Duplicate MAC Address")
    }

    @Test("a stopped VM may take the mode a live MAC address twin is on — its start is the guard")
    func stoppedVMMayTakeALiveMACAddressTwinsMode() {
        let (viewModel, _, _, _, _) = makeViewModel()
        let (switching, other) = appendMACAddressPair(
            to: viewModel, mode: .hostOnly, otherMode: .shared)
        switching.activity.placeForTesting(.stopped)
        other.activity.placeForTesting(.running(sessionID: UUID()))

        let accepted = viewModel.library.updateConfiguration(of: switching) {
            $0.networkMode = .shared
        }

        #expect(accepted.landed)
        #expect(switching.configuration.networkMode == .shared)
        #expect(presenter.showError == false)
    }

    @Test("a live VM already sharing a network with its twin stays editable")
    func aVMAlreadyInAMACAddressCollisionStaysEditable() {
        let (viewModel, _, _, _, _) = makeViewModel()
        let (switching, other) = appendMACAddressPair(to: viewModel)
        switching.activity.placeForTesting(.running(sessionID: UUID()))
        other.activity.placeForTesting(.running(sessionID: UUID()))

        let accepted = viewModel.library.updateConfiguration(of: switching) {
            $0.memorySizeInGB = 6
        }

        #expect(accepted.landed)
        #expect(switching.configuration.memorySizeInGB == 6)
        #expect(presenter.showError == false)
    }

    // MARK: - Configuration forward

    /// A VM in the view model's library, which is what lets the forward's verb
    /// resolve it.
    private func registerConfigurationVM(
        in viewModel: VMLibraryViewModel, storage: MockVMStorageService,
        phase: VMLifecyclePhase = .stopped, mutate: (inout VMConfiguration) -> Void = { _ in }
    ) -> VMInstance {
        let instance = VMInstanceFixture.make(phase: phase, mutate: mutate)
        viewModel.library.register(instance, storage: storage)
        return instance
    }

    /// A CPU count the guest takes that is not `config`'s own.
    private func movedCPUCount(_ config: VMConfiguration) -> Int {
        config.cpuCount == config.guestOS.minCPUCount ? config.cpuCount + 1 : config.cpuCount - 1
    }

    @Test("the configuration forward hands a consent refusal back without presenting it")
    func setConfigurationForwardReturnsConsentWithoutPresenting() throws {
        let (viewModel, storage, _, _, _) = makeViewModel()
        let instance = registerConfigurationVM(in: viewModel, storage: storage) {
            $0.clipboardSharingEnabled = true
            $0.clipboardPassthroughEnabled = false
        }

        let outcome = viewModel.setConfiguration(
            [VMConfigurationKeyRegistry.clipboardPassthrough.assigning(true)], on: instance)

        guard case .consentRequired(let prompt) = outcome else {
            Issue.record("expected consentRequired, got \(outcome)")
            return
        }
        #expect(prompt == ClipboardPassthroughConsent.prompt(vmName: instance.name))
        #expect(presenter.errors.isEmpty)
        #expect(!instance.configuration.clipboardPassthroughEnabled)

        let confirmed = viewModel.setConfiguration(
            [VMConfigurationKeyRegistry.clipboardPassthrough.assigning(true)], on: instance,
            confirmed: true)
        #expect(confirmed == .applied)
        #expect(instance.configuration.clipboardPassthroughEnabled)
    }

    @Test("the configuration forward presents a refusal, naming the setting it refused")
    func setConfigurationForwardPresentsARefusal() {
        let (viewModel, storage, _, _, _) = makeViewModel()
        let instance = registerConfigurationVM(
            in: viewModel, storage: storage, phase: .running(sessionID: UUID()))
        let before = instance.configuration

        let outcome = viewModel.setConfiguration(
            [VMConfigurationKeyRegistry.cpus.assigning(String(movedCPUCount(before)))],
            on: instance)

        #expect(outcome == .refused)
        #expect(instance.configuration == before)
        #expect(presenter.errorTitles == ["Error"])
        #expect(presenter.errors.count == 1)
        #expect(presenter.errors.first?.contains("cpus") == true)
    }

    @Test("the configuration forward leaves a failed save to the library's own alert")
    func setConfigurationForwardLeavesAFailedSaveToTheLibrary() {
        let (viewModel, storage, _, _, _) = makeViewModel()
        let instance = registerConfigurationVM(in: viewModel, storage: storage)
        storage.saveConfigurationError = CocoaError(.fileWriteNoPermission)
        let before = instance.configuration

        let outcome = viewModel.setConfiguration(
            [VMConfigurationKeyRegistry.cpus.assigning(String(movedCPUCount(before)))],
            on: instance)

        #expect(outcome == .refused)
        #expect(instance.configuration == before)
        // The library presented the failure it hit; the forward adds nothing.
        #expect(presenter.errors.count == 1)
    }

    // MARK: - Removable media on a live-but-unattachable session

    /// A registered VM holding one removable-media entry, in `phase` with a
    /// session context — the shape a save or live snapshot leaves behind.
    private func appendVMWithMedia(
        to viewModel: VMLibraryViewModel, storage: MockVMStorageService, in phase: VMLifecyclePhase
    ) -> VMInstance {
        let instance = VMInstanceFixture.make(name: "Media VM", files: storage.files) {
            $0.removableMedia = [RemovableMediaItem(path: "/tmp/media.iso", readOnly: true)]
        }
        instance.activity.placeForTesting(phase)
        if instance.liveSessionID != nil {
            instance.beginSessionContext()
        }
        viewModel.library.admitForTesting(instance)
        return instance
    }

    @Test("a media edit is refused whole while the VM is saving, changing nothing")
    func mediaEditIsRefusedWhileSaving() {
        let (viewModel, storage, _, _, _) = makeViewModel()
        let instance = appendVMWithMedia(
            to: viewModel, storage: storage, in: .operating(.saving, from: .running(sessionID: UUID())))

        let accepted = viewModel.library.updateConfiguration(of: instance) {
            $0.removableMedia = nil
        }

        #expect(accepted.refusedForSession)
        #expect(instance.configuration.removableMedia?.count == 1)
        #expect(storage.saveConfigurationCallCount == 0)
        #expect(presenter.showError == false)
    }

    @Test("a media edit is refused whole while the VM is capturing a live snapshot")
    func mediaEditIsRefusedWhileCapturingLive() {
        let (viewModel, storage, _, _, _) = makeViewModel()
        let instance = appendVMWithMedia(
            to: viewModel, storage: storage,
            in: .operating(.capturingSnapshot(.live), from: .running(sessionID: UUID())))

        let accepted = viewModel.library.updateConfiguration(of: instance) {
            $0.removableMedia = nil
            $0.memorySizeInGB = 6
        }

        #expect(accepted.refusedForSession)
        #expect(instance.configuration.removableMedia?.count == 1)
        #expect(instance.configuration.memorySizeInGB != 6)
        #expect(storage.saveConfigurationCallCount == 0)
        #expect(presenter.showError == false)
    }

    @Test("an edit leaving the media list alone is accepted while capturing a live snapshot")
    func nonMediaEditIsAcceptedWhileCapturingLive() {
        let (viewModel, storage, _, _, _) = makeViewModel()
        let instance = appendVMWithMedia(
            to: viewModel, storage: storage,
            in: .operating(.capturingSnapshot(.live), from: .running(sessionID: UUID())))

        let accepted = viewModel.library.updateConfiguration(of: instance) {
            $0.memorySizeInGB = 6
        }

        #expect(accepted.landed)
        #expect(instance.configuration.memorySizeInGB == 6)
        #expect(instance.configuration.removableMedia?.count == 1)
        #expect(storage.saveConfigurationCallCount == 1)
    }

    @Test("a VM with no session takes a media edit — it persists for the next start")
    func mediaEditIsAcceptedWithoutASession() {
        for phase in [VMLifecyclePhase.stopped, .suspended] {
            let (viewModel, storage, _, _, _) = makeViewModel()
            let instance = appendVMWithMedia(to: viewModel, storage: storage, in: phase)

            let accepted = viewModel.library.updateConfiguration(of: instance) {
                $0.removableMedia = nil
            }

            #expect(accepted.landed, "\(phase)")
            #expect(instance.configuration.removableMedia == nil, "\(phase)")
            #expect(storage.saveConfigurationCallCount == 1, "\(phase)")
        }
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
            storage.bundles[VMInstanceFixture.bundleURL(for: config.id)] = config
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
        let (starting, _) = appendMACAddressPair(
            to: viewModel, mutateOther: { $0.networkEnabled = false })

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
    private func makeMatchWindowInstance(
        guestOS: VMGuestOS = .macOS, files: InMemoryVMBundleFiles = InMemoryVMBundleFiles(),
        mutate: (inout VMConfiguration) -> Void = { _ in }
    ) -> VMInstance {
        VMInstanceFixture.make(guestOS: guestOS, files: files, mutate: mutate)
    }

    private static let retinaSurface = DisplayBootSurface(
        pointSize: CGSize(width: 1400, height: 880), backingScaleFactor: 2)

    @Test("A match-window cold boot persists the computed resolution before starting")
    func matchWindowWritesResolutionBeforeStart() async {
        let (viewModel, storage, _, virtService, _) = makeViewModel()
        let provider = FakeDisplayBootGeometryProvider(surface: Self.retinaSurface)
        viewModel.displayBootGeometryProvider = provider
        let instance = makeMatchWindowInstance(files: storage.files)
        viewModel.library.admitForTesting(instance)

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
        let instance = makeMatchWindowInstance { $0.displayHiDPI = false }
        viewModel.library.admitForTesting(instance)

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
        viewModel.library.admitForTesting(instance)

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
        try Data().write(to: instance.bundle.saveFileURL)
        viewModel.library.admitForTesting(instance)

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
        let instance = VMInstanceFixture.make { $0.displaySizesToWindow = false }
        viewModel.library.admitForTesting(instance)

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
        let instance = makeMatchWindowInstance(files: storage.files)
        let original = instance.configuration.displayResolution
        viewModel.library.admitForTesting(instance)
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
        viewModel.library.admitForTesting(instance)

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
        let instance = VMInstanceFixture.make()

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
        let item = RemovableMediaItem(path: "/tmp/stale.iso", readOnly: true, label: "Stale ISO")
        let instance = VMInstanceFixture.make { $0.removableMedia = [item] }
        viewModel.library.admitForTesting(instance)
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

    /// A launch that came up headless runs its auto-start pass with no window,
    /// so a failure's recovery has to survive the wait for one instead of
    /// flattening into a message no alert can act on.
    @Test("A start failure raised with no window buffers the failure, not its text")
    func startFailureWithNoWindowBuffersTheRecovery() async {
        let virtService = MockVirtualizationService()
        let (viewModel, _, _, _, _) = makeViewModel(virtualizationService: virtService)
        let item = RemovableMediaItem(path: "/tmp/stale.iso", readOnly: true, label: "Stale ISO")
        let instance = VMInstanceFixture.make { $0.removableMedia = [item] }
        viewModel.library.admitForTesting(instance)
        virtService.startError = ConfigurationBuilderError.removableMediaAttachFailed(
            id: item.id, path: item.path, label: item.label,
            underlying: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOTSUP)))
        // No main window has been created, which is what leaves `presenter` nil.
        viewModel.presenter = nil

        await viewModel.start(instance)

        #expect(viewModel.bufferedStartFailureCount == 1)
        #expect(presenter.startFailedAttachments.isEmpty)

        // Attaching the presenter is what the window does on arrival.
        viewModel.presenter = presenter

        #expect(presenter.startFailedAttachments.count == 1)
        #expect(presenter.startFailedAttachments.first?.kind == .removableMedia)
        #expect(presenter.startFailedAttachments.first?.id == item.id)
        #expect(presenter.startFailedAttachmentInstances.last === instance)
        #expect(presenter.errors.isEmpty)
        #expect(viewModel.bufferedStartFailureCount == 0)
    }

    @Test("A buffered start failure is dropped when its VM leaves before the window arrives")
    func bufferedStartFailureIsDroppedWhenItsVMLeaves() async {
        let virtService = MockVirtualizationService()
        let (viewModel, _, _, _, _) = makeViewModel(virtualizationService: virtService)
        let item = RemovableMediaItem(path: "/tmp/stale.iso", readOnly: true, label: "Stale ISO")
        let instance = VMInstanceFixture.make { $0.removableMedia = [item] }
        viewModel.library.admitForTesting(instance)
        virtService.startError = ConfigurationBuilderError.removableMediaAttachFailed(
            id: item.id, path: item.path, label: item.label,
            underlying: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOTSUP)))
        viewModel.presenter = nil

        await viewModel.start(instance)
        viewModel.library.evict(instance)
        viewModel.presenter = presenter

        // Nothing is left for the recovery to detach from.
        #expect(presenter.startFailedAttachments.isEmpty)
        #expect(presenter.errors.isEmpty)
        #expect(viewModel.bufferedStartFailureCount == 0)
    }

    /// A guest cap or a duplicate identity refuses a start with only a message,
    /// and a headless launch has to report that as surely as a missing disk.
    @Test("A start failure carrying no recovery is counted, then drains as a plain alert")
    func plainStartFailureWithNoWindowIsCountedAndDrainsAsAnAlert() async {
        let virtService = MockVirtualizationService()
        virtService.startError = VirtualizationError.noVirtualMachine
        let (viewModel, _, _, _, _) = makeViewModel(virtualizationService: virtService)
        let instance = VMInstanceFixture.make()
        viewModel.library.admitForTesting(instance)
        viewModel.presenter = nil

        await viewModel.start(instance)

        #expect(presenter.errors.isEmpty)
        #expect(viewModel.bufferedStartFailureCount == 1)

        viewModel.presenter = presenter

        #expect(presenter.errors.count == 1)
        #expect(presenter.startFailedAttachments.isEmpty)
        #expect(viewModel.bufferedStartFailureCount == 0)
    }

    @Test("A failure raised by something other than a start is buffered but not counted")
    func nonStartFailureWithNoWindowIsNotCounted() async {
        let virtService = MockVirtualizationService()
        virtService.stopError = VirtualizationError.noVirtualMachine
        let (viewModel, _, _, _, _) = makeViewModel(virtualizationService: virtService)
        let instance = VMInstanceFixture.make()
        instance.activity.placeForTesting(.running(sessionID: UUID()))
        viewModel.library.admitForTesting(instance)
        viewModel.presenter = nil

        await viewModel.stop(instance)

        #expect(viewModel.bufferedStartFailureCount == 0)

        viewModel.presenter = presenter

        #expect(presenter.errors.count == 1)
    }

    @Test("removeStartFailedAttachmentAndStart detaches the item and retries the start")
    func removeStartFailedAttachmentAndStartRetries() async {
        let virtService = MockVirtualizationService()
        let (viewModel, _, _, _, _) = makeViewModel(virtualizationService: virtService)
        let item = RemovableMediaItem(path: "/tmp/stale.iso", readOnly: true, label: "Stale ISO")
        let instance = VMInstanceFixture.make { $0.removableMedia = [item] }
        viewModel.library.admitForTesting(instance)
        instance.activity.placeForTesting(.failed(message: "Test failure"))  // where a failed start leaves the VM

        let failure = StartFailedAttachment(
            verb: .start, kind: .removableMedia, reason: .attachRefused, id: item.id,
            label: item.label, message: "test")
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
        let item = RemovableMediaItem(path: "/tmp/stale.iso", readOnly: true, label: "Stale ISO")
        let instance = VMInstanceFixture.make { $0.removableMedia = [item] }
        viewModel.library.admitForTesting(instance)
        // A failed cold resume leaves the VM here, save file intact.
        instance.activity.placeForTesting(.failed(message: "Test failure"))
        try FileManager.default.createDirectory(
            at: instance.bundleURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: instance.bundleURL) }
        FileManager.default.createFile(
            atPath: instance.bundle.saveFileURL.path(percentEncoded: false),
            contents: Data("fake save".utf8))

        let failure = StartFailedAttachment(
            verb: .start, kind: .removableMedia, reason: .attachRefused, id: item.id,
            label: item.label, message: "test")
        await viewModel.removeStartFailedAttachmentAndStart(failure, on: instance)

        // The save restores only into the saved device set, so the confirmed
        // repair discards it and the retried start cold-boots.
        #expect(!instance.hasSaveFile)
        #expect(virtService.startCallCount == 1)
        #expect(instance.status == .running)
    }

    @Test("start keeps the generic error when the VM's only disk fails to attach")
    func startSoleDiskAttachFailureStaysGeneric() async {
        let virtService = MockVirtualizationService()
        let (viewModel, _, _, _, _) = makeViewModel(virtualizationService: virtService)
        let instance = VMInstanceFixture.make()
        viewModel.library.admitForTesting(instance)
        // The synthesized main disk is what a nil storageDisks list resolves to.
        let mainDisk = StorageDisk.mainDisk(
            layout: VMBundleLayout(bundleURL: instance.bundleURL))
        virtService.startError = ConfigurationBuilderError.storageDiskAttachFailed(
            id: mainDisk.id, path: mainDisk.path, label: mainDisk.label,
            underlying: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOTSUP)))

        await viewModel.start(instance)

        // Removing the VM's only disk leaves nothing to start, so no removal offer.
        #expect(presenter.startFailedAttachments.isEmpty)
        #expect(presenter.showError == true)
    }

    /// A fixture VM whose storage list `storageDisks` builds against the bundle
    /// the VM will own.
    private func makeInstanceWithDisks(
        phase: VMLifecyclePhase = .stopped,
        storageDisks: (VMBundleLayout) -> [StorageDisk]
    ) -> VMInstance {
        VMInstanceFixture.make(phase: phase) { config in
            config.storageDisks = storageDisks(
                VMBundleLayout(bundleURL: VMInstanceFixture.bundleURL(for: config.id)))
        }
    }

    @Test("Disk.asif failing to attach keeps the bare alert even when the VM has a sibling disk")
    func mainDiskAttachFailureWithASiblingIsNotOffered() async {
        let virtService = MockVirtualizationService()
        let (viewModel, _, _, _, _) = makeViewModel(virtualizationService: virtService)
        let extra = StorageDisk(
            path: "AdditionalDisks/extra.asif", readOnly: false, label: "Extra",
            isInternal: true, kind: .virtio)
        let instance = makeInstanceWithDisks { [StorageDisk.mainDisk(layout: $0), extra] }
        let mainDisk = StorageDisk.mainDisk(layout: VMBundleLayout(bundleURL: instance.bundleURL))
        viewModel.library.admitForTesting(instance)
        virtService.startError = ConfigurationBuilderError.storageDiskAttachFailed(
            id: mainDisk.id, path: mainDisk.path, label: mainDisk.label,
            underlying: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOTSUP)))

        await viewModel.start(instance)

        // The sibling clears the sole-disk rule, and the internal rule is what
        // turns the offer back: nothing re-creates `Disk.asif`'s entry.
        #expect(presenter.startFailedAttachments.isEmpty)
        #expect(presenter.showError == true)
    }

    @Test("start offers removal when an external storage disk attach fails")
    func startOffersRemovalOnExternalDiskAttachFailure() async {
        let virtService = MockVirtualizationService()
        let (viewModel, _, _, _, _) = makeViewModel(virtualizationService: virtService)
        let external = StorageDisk(
            id: UUID(), path: "/tmp/gone.img", readOnly: false, label: "External",
            isInternal: false, kind: .virtio)
        let instance = makeInstanceWithDisks { [StorageDisk.mainDisk(layout: $0), external] }
        viewModel.library.admitForTesting(instance)
        virtService.startError = ConfigurationBuilderError.storageDiskAttachFailed(
            id: external.id, path: external.path, label: external.label,
            underlying: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOTSUP)))

        await viewModel.start(instance)

        #expect(presenter.startFailedAttachments.count == 1)
        #expect(presenter.startFailedAttachments.first?.kind == .storageDisk)
        #expect(presenter.startFailedAttachments.first?.id == external.id)
        #expect(presenter.errors.isEmpty)
    }

    /// The ways one entry can be unusable that are not a refused attach. A file
    /// deleted or a volume ejected is the likeliest of them, and the VM it
    /// leaves behind is the same one, with the same entry to remove.
    enum UnusableAttachment: CaseIterable, Sendable {
        case notFound
        case pathIsDirectory
        case notWritable

        func storageDisk(id: UUID, path: String, label: String) -> ConfigurationBuilderError {
            switch self {
            case .notFound: .storageDiskNotFound(id: id, path: path, label: label)
            case .pathIsDirectory: .storageDiskPathIsDirectory(id: id, path: path, label: label)
            case .notWritable: .storageDiskNotWritable(id: id, path: path, label: label)
            }
        }

        func removableMedia(id: UUID, path: String, label: String) -> ConfigurationBuilderError {
            switch self {
            case .notFound: .removableMediaNotFound(id: id, path: path, label: label)
            case .pathIsDirectory:
                .removableMediaPathIsDirectory(id: id, path: path, label: label)
            case .notWritable: .removableMediaNotWritable(id: id, path: path, label: label)
            }
        }

        /// What the alert says was found, which is each error's own words rather
        /// than a guess at a cause.
        var statedInTheMessage: String {
            switch self {
            case .notFound: "not found at"
            case .pathIsDirectory: "is a directory, not a file"
            case .notWritable: "is not writable"
            }
        }
    }

    @Test(
        "A start offers the removal however the disk turned out to be unusable",
        arguments: UnusableAttachment.allCases)
    func startOffersRemovalForEveryUnusableDisk(way: UnusableAttachment) async {
        let virtService = MockVirtualizationService()
        let (viewModel, _, _, _, _) = makeViewModel(virtualizationService: virtService)
        let external = StorageDisk(
            id: UUID(), path: "/tmp/gone.img", readOnly: false, label: "External",
            isInternal: false, kind: .virtio)
        let instance = makeInstanceWithDisks { [StorageDisk.mainDisk(layout: $0), external] }
        viewModel.library.admitForTesting(instance)
        virtService.startError = way.storageDisk(
            id: external.id, path: external.path, label: external.label)

        await viewModel.start(instance)

        #expect(presenter.startFailedAttachments.count == 1, "\(way)")
        #expect(presenter.startFailedAttachments.first?.kind == .storageDisk, "\(way)")
        #expect(presenter.startFailedAttachments.first?.id == external.id, "\(way)")
        #expect(presenter.startFailedAttachments.first?.verb == .start, "\(way)")
        #expect(
            presenter.startFailedAttachments.first?.message.contains(way.statedInTheMessage) == true,
            "\(way)")
        #expect(presenter.errors.isEmpty, "\(way)")
    }

    @Test(
        "A resume offers the removal however the medium turned out to be unusable",
        arguments: UnusableAttachment.allCases)
    func resumeOffersRemovalForEveryUnusableMedium(way: UnusableAttachment) async throws {
        let virtService = MockVirtualizationService()
        let (viewModel, _, _, _, _) = makeViewModel(virtualizationService: virtService)
        let item = RemovableMediaItem(path: "/tmp/stale.iso", readOnly: true, label: "Stale ISO")
        let instance = VMInstanceFixture.make(phase: .suspended) { $0.removableMedia = [item] }
        defer { VMInstanceFixture.removeBundle(of: instance) }
        try VMInstanceFixture.writeSaveFile(for: instance)
        viewModel.library.admitForTesting(instance)
        // A resume restoring a saved state assembles the same configuration a
        // boot does, so it fails over the same entry.
        virtService.restoreError = way.removableMedia(
            id: item.id, path: item.path, label: item.label)

        await viewModel.resume(instance)

        #expect(presenter.startFailedAttachments.count == 1, "\(way)")
        #expect(presenter.startFailedAttachments.first?.kind == .removableMedia, "\(way)")
        #expect(presenter.startFailedAttachments.first?.id == item.id, "\(way)")
        #expect(presenter.startFailedAttachments.first?.verb == .resume, "\(way)")
        #expect(
            presenter.startFailedAttachments.first?.message.contains(way.statedInTheMessage) == true,
            "\(way)")
        #expect(presenter.errors.isEmpty, "\(way)")
    }

    /// The removal is irreversible for a bundle-internal entry: nothing
    /// re-creates one, so a Return on "Remove and Start" would cost the user the
    /// disk's entry for good — and an EFI VM built from a local ISO carries
    /// `Disk.asif` beside its installer, so the sole-disk rule does not cover it.
    @Test(
        "An internal disk is never offered for removal, sibling or not",
        arguments: UnusableAttachment.allCases, [VMVerb.start, .resume])
    func internalDiskWithASiblingIsNeverOffered(
        way: UnusableAttachment, verb: VMVerb
    ) async throws {
        let virtService = MockVirtualizationService()
        let (viewModel, _, _, _, _) = makeViewModel(virtualizationService: virtService)
        let installer = StorageDisk(
            id: UUID(), path: "/tmp/ubuntu.iso", readOnly: true, label: "ubuntu",
            isInternal: false, kind: .virtio)
        let instance = makeInstanceWithDisks(phase: verb == .resume ? .suspended : .stopped) {
            [installer, StorageDisk.mainDisk(layout: $0)]
        }
        defer { VMInstanceFixture.removeBundle(of: instance) }
        if verb == .resume { try VMInstanceFixture.writeSaveFile(for: instance) }
        let mainDisk = StorageDisk.mainDisk(layout: VMBundleLayout(bundleURL: instance.bundleURL))
        viewModel.library.admitForTesting(instance)
        let failure = way.storageDisk(
            id: mainDisk.id, path: mainDisk.path, label: mainDisk.label)

        if verb == .resume {
            virtService.restoreError = failure
            await viewModel.resume(instance)
        } else {
            virtService.startError = failure
            await viewModel.start(instance)
        }

        #expect(presenter.startFailedAttachments.isEmpty, "\(way) / \(verb)")
        #expect(presenter.showError == true, "\(way) / \(verb)")
        // The entry the user would have lost is still there.
        #expect(instance.configuration.storageDisks?.contains { $0.id == mainDisk.id } == true)
    }

    /// The same rule reaches an in-bundle disk the user created: `createStorageDisk`
    /// writes a new file under a new identity rather than re-adopting this one,
    /// so its entry is no more recoverable than `Disk.asif`'s.
    @Test("An internal disk the user added is not offered either")
    func internalAdditionalDiskIsNotOffered() async {
        let virtService = MockVirtualizationService()
        let (viewModel, _, _, _, _) = makeViewModel(virtualizationService: virtService)
        let extra = StorageDisk(
            id: UUID(), path: "AdditionalDisks/\(UUID().uuidString).asif", readOnly: false,
            label: "20 GB Disk", isInternal: true, kind: .virtio)
        let instance = makeInstanceWithDisks { [StorageDisk.mainDisk(layout: $0), extra] }
        viewModel.library.admitForTesting(instance)
        virtService.startError = ConfigurationBuilderError.storageDiskNotFound(
            id: extra.id, path: extra.path, label: extra.label)

        await viewModel.start(instance)

        #expect(presenter.startFailedAttachments.isEmpty)
        #expect(presenter.showError == true)
    }

    @Test("A missing sole disk keeps the bare alert — removing it leaves nothing to start")
    func startSoleDiskNotFoundStaysGeneric() async {
        let virtService = MockVirtualizationService()
        let (viewModel, _, _, _, _) = makeViewModel(virtualizationService: virtService)
        let instance = VMInstanceFixture.make()
        viewModel.library.admitForTesting(instance)
        let mainDisk = StorageDisk.mainDisk(layout: VMBundleLayout(bundleURL: instance.bundleURL))
        virtService.startError = ConfigurationBuilderError.storageDiskNotFound(
            id: mainDisk.id, path: mainDisk.path, label: mainDisk.label)

        await viewModel.start(instance)

        #expect(presenter.startFailedAttachments.isEmpty)
        #expect(presenter.showError == true)
    }

    @Test("A builder failure naming an entry the VM no longer carries keeps the bare alert")
    func startWithoutTheNamedEntryStaysGeneric() async {
        let virtService = MockVirtualizationService()
        let (viewModel, _, _, _, _) = makeViewModel(virtualizationService: virtService)
        let instance = VMInstanceFixture.make()
        viewModel.library.admitForTesting(instance)
        // No removable media on the VM at all: an offer whose removal could
        // only no-op leaves a button that appears to do nothing.
        virtService.startError = ConfigurationBuilderError.removableMediaNotFound(
            id: UUID(), path: "/tmp/gone.iso", label: "Gone")

        await viewModel.start(instance)

        #expect(presenter.startFailedAttachments.isEmpty)
        #expect(presenter.showError == true)
    }

    @Test("start does not offer removal for transient file-lock contention")
    func startDoesNotOfferRemovalForLockContention() async {
        let virtService = MockVirtualizationService()
        let (viewModel, _, _, _, _) = makeViewModel(virtualizationService: virtService)
        let item = RemovableMediaItem(path: "/tmp/shared.iso", readOnly: true, label: "Shared ISO")
        let instance = VMInstanceFixture.make { $0.removableMedia = [item] }
        viewModel.library.admitForTesting(instance)
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
        let item = RemovableMediaItem(path: "/tmp/stale.iso", readOnly: true, label: "Stale ISO")
        let instance = VMInstanceFixture.make { $0.removableMedia = [item] }
        // Never added to `instances` — models the VM being deleted while the
        // alert sat queued behind another sheet.

        let failure = StartFailedAttachment(
            verb: .start, kind: .removableMedia, reason: .attachRefused, id: item.id,
            label: item.label, message: "test")
        await viewModel.removeStartFailedAttachmentAndStart(failure, on: instance)

        // No config write to a deleted bundle, and no boot.
        #expect(instance.configuration.removableMedia?.count == 1)
        #expect(virtService.startCallCount == 0)
    }

    @Test("removeStartFailedAttachmentAndStart starts the VM when the entry is already gone")
    func removeStartFailedAttachmentStartsWhenEntryGone() async {
        let virtService = MockVirtualizationService()
        let (viewModel, _, _, _, _) = makeViewModel(virtualizationService: virtService)
        let instance = VMInstanceFixture.make()
        viewModel.library.admitForTesting(instance)
        instance.activity.placeForTesting(.failed(message: "Test failure"))

        // The user removed it in Settings before confirming the alert, so what
        // the recovery was for already holds and the click is the Start.
        let failure = StartFailedAttachment(
            verb: .start, kind: .removableMedia, reason: .attachRefused, id: UUID(),
            label: "Stale ISO", message: "test")
        await viewModel.removeStartFailedAttachmentAndStart(failure, on: instance)

        #expect(virtService.startCallCount == 1)
        #expect(instance.status == .running)
    }

    @Test("start keeps the generic error when the failing media is no longer configured")
    func startStaysGenericWhenMediaNotConfigured() async {
        let virtService = MockVirtualizationService()
        let (viewModel, _, _, _, _) = makeViewModel(virtualizationService: virtService)
        let instance = VMInstanceFixture.make()
        viewModel.library.admitForTesting(instance)
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
        let instance = VMInstanceFixture.make(name: "Ubuntu")
        viewModel.library.admitForTesting(instance)

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
            removableMediaDeviceService: MockRemovableMediaDeviceService(),
            fileSystem: fileSystem,
            downloadsDirectory: nil,
            preferences: preferences,
            vmnetNetworks: MockVmnetNetworkProvider(), arpTable: ScriptedARPTable(), entitlements: .entitled
        )
        viewModel.presenter = presenter
        let instance = VMInstanceFixture.make(name: "Sequoia", guestOS: .macOS) {
            $0.installContext = MacOSInstallContext(
                source: .localFile, localIPSWPath: "/tmp/foo.ipsw")
        }
        instance.activity.placeForTesting(.initialBoot)
        viewModel.library.register(instance, storage: storage)

        await viewModel.start(instance)
        await instance.setupOperationTask?.value

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
        let item = RemovableMediaItem(path: "/tmp/stale.iso", readOnly: true, label: "Stale ISO")
        let instance = VMInstanceFixture.make { $0.removableMedia = [item] }
        viewModel.library.admitForTesting(instance)
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
        let instance = VMInstanceFixture.make()

        await viewModel.forceStop(instance)

        #expect(presenter.showError == true)
        #expect(presenter.errorMessage != nil)
    }

    @Test("stop presents error on service failure")
    func stopPresentsError() async {
        let virtService = MockVirtualizationService()
        virtService.stopError = VirtualizationError.noVirtualMachine
        let (viewModel, _, _, _, _) = makeViewModel(virtualizationService: virtService)
        let instance = VMInstanceFixture.make()

        await viewModel.stop(instance)

        #expect(presenter.showError == true)
        #expect(presenter.errorMessage != nil)
    }

    // MARK: - Stop Paused Confirmation

    @Test("resumeAndStop dispatches resume then stop")
    func resumeAndStopDispatches() async throws {
        let (viewModel, _, _, virtService, _) = makeViewModel()
        let instance = VMInstanceFixture.make()
        instance.activity.placeForTesting(.suspended)
        defer { VMInstanceFixture.removeBundle(of: instance) }
        try VMInstanceFixture.writeSaveFile(for: instance)
        viewModel.library.admitForTesting(instance)

        await viewModel.resumeAndStop(instance)

        #expect(virtService.lastStartRoute == .restoredSavedState)
        #expect(virtService.stopCallCount == 1)
    }

    @Test("resumeAndStop clears confirmation state after dispatch")
    func resumeAndStopClearsConfirmationState() async {
        let (viewModel, _, _, _, _) = makeViewModel()
        let instance = VMInstanceFixture.make()
        instance.activity.placeForTesting(.suspended)
        viewModel.library.admitForTesting(instance)

        await viewModel.resumeAndStop(instance)

        #expect(presenter.instanceToStopPaused == nil)
        #expect(presenter.showStopPausedConfirmation == false)
    }

    @Test("forceStopFromPaused dispatches forceStop and clears state")
    func forceStopFromPausedDispatches() async {
        let (viewModel, _, _, virtService, _) = makeViewModel()
        let instance = VMInstanceFixture.make()
        // The phase the stop-paused sheet's Force Stop alternative fires in:
        // a guest still in memory, which VZ takes a termination from.
        instance.activity.placeForTesting(.livePaused(sessionID: UUID()))
        viewModel.library.admitForTesting(instance)

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
        let instance = VMInstanceFixture.make()
        instance.activity.placeForTesting(.suspended)

        await viewModel.resumeAndStop(instance)

        #expect(presenter.showError == true)
        #expect(virtService.stopCallCount == 0)
    }

    @Test("stop on running VM still delegates directly without confirmation")
    func stopRunningSkipsConfirmation() async {
        let (viewModel, _, _, virtService, _) = makeViewModel()
        let instance = VMInstanceFixture.make()
        instance.activity.placeForTesting(.running(sessionID: UUID()))
        viewModel.library.admitForTesting(instance)

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
        let instance = VMInstanceFixture.make()
        let sessionID = UUID()
        instance.activity.placeForTesting(.running(sessionID: sessionID))

        await viewModel.pause(instance)

        #expect(presenter.showError == true)
        #expect(presenter.errorMessage != nil)
        // The pause did not take, so the VM is where it was and still names its
        // session — which is what keeps that session's later events, its
        // teardown hooks and its Ephemeral revert reachable, and keeps Stop and
        // Force Stop offered.
        #expect(instance.phase == .running(sessionID: sessionID))
        #expect(instance.activity.admits(.sessionAction(.requestStop)))
        #expect(instance.activity.admits(.sessionAction(.forceStop)))
    }

    @Test("resume presents error on service failure")
    func resumePresentsError() async {
        let virtService = MockVirtualizationService()
        virtService.resumeError = VirtualizationError.noVirtualMachine
        let (viewModel, _, _, _, _) = makeViewModel(virtualizationService: virtService)
        let instance = VMInstanceFixture.make()

        await viewModel.resume(instance)

        #expect(presenter.showError == true)
        #expect(presenter.errorMessage != nil)
    }

    @Test("save presents error on service failure")
    func savePresentsError() async {
        let virtService = MockVirtualizationService()
        virtService.saveError = VirtualizationError.noVirtualMachine
        let (viewModel, _, _, _, _) = makeViewModel(virtualizationService: virtService)
        let instance = VMInstanceFixture.make()

        await viewModel.save(instance)

        #expect(presenter.showError == true)
        #expect(presenter.errorMessage != nil)
    }

    /// `saveMachineStateTo` writes the slot in place, so a suspend that threw
    /// left however far VZ got — and a relaunch would offer that as a resumable
    /// session.
    @Test("A suspend that failed leaves no half-written slot behind")
    func aFailedSuspendLeavesNoSlot() async throws {
        let virtService = MockVirtualizationService()
        virtService.saveError = VirtualizationError.noVirtualMachine
        let (viewModel, _, _, _, _) = makeViewModel(virtualizationService: virtService)
        let instance = VMInstanceFixture.make()
        instance.activity.placeForTesting(.running(sessionID: UUID()))
        defer { VMInstanceFixture.removeBundle(of: instance) }
        try VMInstanceFixture.writeSaveFile(for: instance)
        viewModel.library.admitForTesting(instance)

        await viewModel.save(instance)

        #expect(!instance.hasSaveFile)
        #expect(instance.status == .error)
        #expect(!instance.activity.admits(.resume))
    }

    // MARK: - Networked instances

    /// A VM in the library on `mac` in `mode` — the state a load leaves
    /// behind, without going through a scan.
    private func makeNetworkedInstance(
        in viewModel: VMLibraryViewModel, using vmnet: MockVmnetNetworkProvider,
        mac: String, mode: VMNetworkMode = .shared, name: String = "Test VM"
    ) -> VMInstance {
        let instance = VMInstanceFixture.make(name: name) {
            $0.networkEnabled = true
            $0.networkMode = mode
            $0.macAddress = mac
        }
        viewModel.library.admitForTesting(instance)
        return instance
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
        let holder = makeNetworkedInstance(in: viewModel, using: vmnet, mac: held, name: "Holder")
        let editor = makeNetworkedInstance(
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

        let accepted = viewModel.library.updateConfiguration(of: editor) {
            $0.macAddress = "aa:bb:cc:dd:ee:0f"
        }

        #expect(accepted.refusedForMACAddress)
        #expect(editor.configuration.macAddress == "aa:bb:cc:dd:ee:10")
        #expect(storage.saveConfigurationCallCount == 0)
        #expect(presenter.errorTitle == "MAC Address In Use")
        #expect(presenter.errorMessage?.contains("Holder") == true)
        #expect(presenter.errorMessage?.contains("aa:bb:cc:dd:ee:0f") == true)
    }

    @Test("The refusal matches the held address regardless of case")
    func duplicateMACAddressRefusalIgnoresCase() {
        let vmnet = MockVmnetNetworkProvider()
        let (viewModel, _, editor) = makeLibrarySharingNoAddress(
            using: vmnet, held: "AA:BB:CC:DD:EE:0F", editing: "aa:bb:cc:dd:ee:10")

        let accepted = viewModel.library.updateConfiguration(of: editor) {
            $0.macAddress = "aa:bb:cc:dd:ee:0f"
        }

        #expect(accepted.refusedForMACAddress)
        #expect(editor.configuration.macAddress == "aa:bb:cc:dd:ee:10")
    }

    @Test("A VM with networking off still holds its address")
    func aVMWithNetworkingOffStillHoldsItsAddress() {
        let vmnet = MockVmnetNetworkProvider()
        let (viewModel, holder, editor) = makeLibrarySharingNoAddress(
            using: vmnet, held: "aa:bb:cc:dd:ee:0f", editing: "aa:bb:cc:dd:ee:10")
        viewModel.library.editConfiguration(of: holder) { $0.networkEnabled = false }

        let accepted = viewModel.library.updateConfiguration(of: editor) {
            $0.macAddress = "aa:bb:cc:dd:ee:0f"
        }

        #expect(accepted.refusedForMACAddress)
        #expect(editor.configuration.macAddress == "aa:bb:cc:dd:ee:10")
    }

    @Test("A refused mutation drops the fields it also set")
    func aRefusedMutationDropsItsOtherFields() {
        let vmnet = MockVmnetNetworkProvider()
        let (viewModel, _, editor) = makeLibrarySharingNoAddress(
            using: vmnet, held: "aa:bb:cc:dd:ee:0f", editing: "aa:bb:cc:dd:ee:10")

        let accepted = viewModel.library.updateConfiguration(of: editor) {
            $0.name = "Renamed"
            $0.macAddress = "aa:bb:cc:dd:ee:0f"
        }

        #expect(accepted.refusedForMACAddress)
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
        let accepted = viewModel.library.updateConfiguration(of: editor) {
            $0.name = "Renamed"
        }

        #expect(accepted.landed)
        #expect(editor.configuration.name == "Renamed")
        #expect(!presenter.showError)
    }

    @Test("Moving the holder off an address frees it for another VM")
    func editingTheHolderFreesItsAddress() {
        let vmnet = MockVmnetNetworkProvider()
        let (viewModel, holder, editor) = makeLibrarySharingNoAddress(
            using: vmnet, held: "aa:bb:cc:dd:ee:0f", editing: "aa:bb:cc:dd:ee:10")

        viewModel.library.updateConfiguration(of: holder) {
            $0.macAddress = "aa:bb:cc:dd:ee:11"
        }
        let accepted = viewModel.library.updateConfiguration(of: editor) {
            $0.macAddress = "aa:bb:cc:dd:ee:0f"
        }

        #expect(accepted.landed)
        #expect(editor.configuration.macAddress == "aa:bb:cc:dd:ee:0f")
        #expect(!presenter.showError)
    }

    @Test("Deleting the holder frees its address for another VM")
    func deletingTheHolderFreesItsAddress() async {
        let vmnet = MockVmnetNetworkProvider()
        let (viewModel, holder, editor) = makeLibrarySharingNoAddress(
            using: vmnet, held: "aa:bb:cc:dd:ee:0f", editing: "aa:bb:cc:dd:ee:10")

        await viewModel.delete(holder)
        let accepted = viewModel.library.updateConfiguration(of: editor) {
            $0.macAddress = "aa:bb:cc:dd:ee:0f"
        }

        #expect(accepted.landed)
        #expect(editor.configuration.macAddress == "aa:bb:cc:dd:ee:0f")
        #expect(!presenter.showError)
    }

    // MARK: - trySave / tryForceStop

    @Test("trySave throws on failure")
    func trySaveThrows() async {
        let virtService = MockVirtualizationService()
        virtService.saveError = VirtualizationError.noVirtualMachine
        let (viewModel, _, _, _, _) = makeViewModel(virtualizationService: virtService)
        let instance = VMInstanceFixture.make()
        instance.activity.placeForTesting(.running(sessionID: UUID()))
        viewModel.library.admitForTesting(instance)

        await #expect(throws: CommandError.self) {
            try await viewModel.trySave(instance)
        }
    }

    @Test("tryForceStop throws on failure")
    func tryForceStopThrows() async {
        let virtService = MockVirtualizationService()
        virtService.forceStopError = VirtualizationError.noVirtualMachine
        let (viewModel, _, _, _, _) = makeViewModel(virtualizationService: virtService)
        let instance = VMInstanceFixture.make()
        instance.activity.placeForTesting(.running(sessionID: UUID()))
        viewModel.library.admitForTesting(instance)

        await #expect(throws: CommandError.self) {
            try await viewModel.tryForceStop(instance)
        }
    }

    // MARK: - Create VM

    /// A wizard filled in for the simplest Linux EFI VM, which every create
    /// test varies from.
    private func makeCreationWizard(
        name: String, startAfterCreate: Bool = true
    ) -> VMCreationViewModel {
        let wizard = VMCreationViewModel()
        wizard.selectedOS = .linux
        wizard.selectedBootMode = .efi
        wizard.vmName = name
        wizard.startAfterCreate = startAfterCreate
        return wizard
    }

    /// A wizard filled in for a macOS VM whose image can be provisioned, with
    /// the account toggle on and the form filled.
    private func makeAccountCreationWizard(name: String) -> VMCreationViewModel {
        let wizard = VMCreationViewModel()
        wizard.vmName = name
        wizard.startAfterCreate = false
        wizard.selectCatalogEntry(makeCatalogEntry(version: "27.0", build: "27A100"))
        wizard.unattendedSetupEnabled = true
        wizard.guestAccountFullName = "Ada Lovelace"
        wizard.guestAccountUsername = "ada"
        wizard.guestAccountPassword = "analytical-engine"
        wizard.guestAccountVerifyPassword = "analytical-engine"
        return wizard
    }

    @available(macOS 27.0, *)
    @Test("createVM persists the account without its password, leaving the start to ask")
    func createVMPersistsTheAccountWithoutThePassword() async throws {
        let (viewModel, _, _, _, _) = makeViewModel()
        let wizard = makeAccountCreationWizard(name: "Provisioned VM")

        try viewModel.createVM(from: wizard)
        await viewModel.awaitArrivalsForTesting()

        let created = try #require(viewModel.instances.first)
        // The four non-secret values are the bundle's; the password is not, so
        // a start that this create did not chain has a question to ask.
        #expect(created.configuration.pendingGuestAccount?.username == "ada")
        #expect(created.configuration.pendingGuestAccount?.fullName == "Ada Lovelace")
        // The password went to the verb, which holds it apart from the bundle —
        // so the VM owes no answer even though the account is still unspent.
        #expect(wizard.guestAccountPasswordForCreate == "analytical-engine")
        #expect(!viewModel.capabilities.owesGuestAccountAnswer(created))
    }

    @Test("createVM answers nothing when the wizard is creating no account")
    func createVMAnswersNothingWithoutAnAccount() async throws {
        let (viewModel, _, _, _, _) = makeViewModel()
        let wizard = makeCreationWizard(name: "Plain VM", startAfterCreate: false)

        try viewModel.createVM(from: wizard)
        await viewModel.awaitArrivalsForTesting()

        let created = try #require(viewModel.instances.first)
        #expect(created.configuration.pendingGuestAccount == nil)
        #expect(!viewModel.capabilities.owesGuestAccountAnswer(created))
        #expect(wizard.guestAccountPasswordForCreate == nil)
    }

    @Test("createVM registers a creating arrival before anything is written")
    func createVMRegistersAnArrival() async throws {
        let (viewModel, storage, diskService, _, _) = makeViewModel()
        let wizard = makeCreationWizard(name: "New Linux VM", startAfterCreate: false)

        try viewModel.createVM(from: wizard)

        #expect(viewModel.instances.isEmpty)
        let arrival = try #require(viewModel.arrivals.first)
        #expect(viewModel.entries.count == 1)
        #expect(arrival.name == "New Linux VM")
        #expect(arrival.kind == .creating)
        #expect(arrival.displayLabel == "Creating\u{2026}")
        #expect(viewModel.selectedID == arrival.id)
        // The row exists before the bundle does.
        #expect(storage.createVMBundleCallCount == 0)
        #expect(diskService.createDiskImageCallCount == 0)

        await viewModel.awaitArrivalsForTesting()
    }

    @Test("createVM settles its arrival into a real VM")
    func createVMSettlesTheArrival() async throws {
        let (viewModel, storage, diskService, _, _) = makeViewModel()
        let wizard = makeCreationWizard(name: "New Linux VM", startAfterCreate: false)

        try viewModel.createVM(from: wizard)
        await viewModel.awaitArrivalsForTesting()

        #expect(viewModel.instances.count == 1)
        let created = try #require(viewModel.instances.first)
        #expect(created.name == "New Linux VM")
        #expect(viewModel.arrivals.isEmpty)
        #expect(storage.createVMBundleCallCount == 1)
        #expect(diskService.createDiskImageCallCount == 1)
        #expect(diskService.lastCreatedSizeInGB == wizard.diskSizeInGB)
    }

    @Test("reconcileWithDisk leaves a creating row alone until its write settles")
    func createVMSurvivesReconcile() async throws {
        let (viewModel, _, _, _, _) = makeViewModel()
        let wizard = makeCreationWizard(name: "Gated VM", startAfterCreate: false)

        try viewModel.createVM(from: wizard)
        // The bundle is not listed yet — it is under the staging directory —
        // and the row is no VM a reconcile could evict.
        viewModel.reconcileWithDisk()

        #expect(viewModel.entries.count == 1)

        await viewModel.awaitArrivalsForTesting()

        #expect(viewModel.instances.count == 1)
    }

    @Test("createVM removes the row and discards the staged tree when the bundle write fails")
    func createVMBundleWriteFailure() async throws {
        let storage = MockVMStorageService()
        storage.createVMBundleError = VMStorageError.bundleAlreadyExists(
            URL(filePath: "/tmp/occupied.kernova"))
        let (viewModel, _, _, virtService, _) = makeViewModel(storageService: storage)
        let wizard = makeCreationWizard(name: "Fail VM")

        try viewModel.createVM(from: wizard)
        await viewModel.awaitArrivalsForTesting()

        #expect(viewModel.entries.isEmpty)
        // The failed write never left staging, so that is what is discarded —
        // outright, being app-internal.
        let staged = try #require(storage.stagedBundleURLs.last)
        #expect(storage.discardedStagedURLs == [staged])
        #expect(fileSystem.trashedURLs.isEmpty)
        #expect(presenter.showError == true)
        // Nothing was written, so nothing is started.
        #expect(virtService.startCallCount == 0)
    }

    @Test("createVM reports a failed disk image as a create failure and cleans up")
    func createVMDiskImageFailure() async throws {
        let diskService = MockDiskImageService()
        diskService.createDiskImageError = NSError(domain: "test", code: 1)
        let (viewModel, storage, _, virtService, _) = makeViewModel(diskImageService: diskService)
        let wizard = makeCreationWizard(name: "Disk Fail VM")

        try viewModel.createVM(from: wizard)
        await viewModel.awaitArrivalsForTesting()

        // The half-written bundle goes with the row, and it never left staging,
        // so nothing the watcher can enumerate held a disk-less VM.
        #expect(viewModel.entries.isEmpty)
        let staged = try #require(storage.stagedBundleURLs.last)
        #expect(storage.discardedStagedURLs == [staged])
        #expect(virtService.startCallCount == 0)
        #expect(presenter.showError == true)
    }

    @Test("createVM starts the new VM when the wizard asked for it")
    func createVMAutoStarts() async throws {
        let (viewModel, _, _, virtService, _) = makeViewModel()
        let wizard = makeCreationWizard(name: "Auto Start VM")

        try viewModel.createVM(from: wizard)
        await viewModel.awaitArrivalsForTesting()
        // The start is chained off its own Task, so it can land after the
        // arrival the settle awaited.
        try await waitForChange { viewModel.instances.first?.status == .running }

        #expect(virtService.startCallCount == 1)
    }

    @Test("createVM does not start the new VM when the wizard didn't ask")
    func createVMSkipsAutoStart() async throws {
        let (viewModel, _, _, virtService, _) = makeViewModel()
        let wizard = makeCreationWizard(name: "Manual Start VM", startAfterCreate: false)

        try viewModel.createVM(from: wizard)
        await viewModel.awaitArrivalsForTesting()

        #expect(virtService.startCallCount == 0)
        #expect(viewModel.instances.first?.status != .running)
    }

    @Test("Cancelling a create keeps the row until the write settles, then removes it")
    func createVMCancelRemovesRowOnSettle() async throws {
        let diskService = MockDiskImageService()
        diskService.holdCreateDiskImage()
        let (viewModel, storage, _, _, _) = makeViewModel(diskImageService: diskService)
        let wizard = makeCreationWizard(name: "Cancelled VM", startAfterCreate: false)

        try viewModel.createVM(from: wizard)
        let arrival = try #require(viewModel.arrivals.first)
        try await diskService.parked.wait { diskService.isParked }
        viewModel.cancelArrival(arrival)
        try await waitForChange { arrival.stage == .cancelling }

        // The write is uninterruptible, so the row stays — reading
        // "Cancelling…" — until it settles.
        #expect(viewModel.entries.map(\.id) == [arrival.id])
        #expect(arrival.displayLabel == "Cancelling\u{2026}")

        diskService.resumeCreateDiskImage()
        await viewModel.awaitArrivalsForTesting()

        #expect(viewModel.entries.isEmpty)
        // Cancelled before publication, so the staged tree is the whole of it.
        let staged = try #require(storage.stagedBundleURLs.last)
        #expect(storage.discardedStagedURLs == [staged])
        #expect(storage.publishBundleCallCount == 0)
    }

    @Test("A create in flight puts nothing at the VM's own bundle URL")
    func createVMKeepsBundleStagedUntilItSettles() async throws {
        let diskService = MockDiskImageService()
        diskService.holdCreateDiskImage()
        let (viewModel, storage, _, _, _) = makeViewModel(diskImageService: diskService)
        let wizard = makeCreationWizard(name: "Mid-flight VM", startAfterCreate: false)

        try viewModel.createVM(from: wizard)
        let destination = try #require(viewModel.arrivals.first).destinationURL
        try await diskService.parked.wait { diskService.isParked }
        let staged = try #require(storage.stagedBundleURLs.last)

        // The configuration is written and the disk image is not — exactly the
        // state an abnormal exit used to leave adoptable. It is all under the
        // staged path, which no listing admits.
        #expect(storage.bundles[staged] != nil)
        #expect(storage.bundles[destination] == nil)
        #expect(!(try storage.listVMBundles().contains(destination)))
        #expect(
            diskService.lastCreatedDiskImageURL
                == VMBundleLayout(bundleURL: staged).diskImageURL)

        diskService.resumeCreateDiskImage()
        await viewModel.awaitArrivalsForTesting()

        #expect(storage.bundles[destination] != nil)
        #expect(try storage.listVMBundles().contains(destination))
    }

    @Test("A quit mid-write discards the staged tree, not the arrival's empty destination")
    func abandonArrivalsDiscardsTheStagedTree() async throws {
        let diskService = MockDiskImageService()
        diskService.holdCreateDiskImage()
        let (viewModel, storage, _, _, _) = makeViewModel(diskImageService: diskService)
        let wizard = makeCreationWizard(name: "Quit Mid-write VM", startAfterCreate: false)

        try viewModel.createVM(from: wizard)
        let arrival = try #require(viewModel.arrivals.first)
        try await diskService.parked.wait { diskService.isParked }
        let staged = try #require(storage.stagedBundleURLs.last)

        viewModel.abandonArrivalsForTermination()

        // Synchronous, because the process ends right after — and aimed at the
        // staged tree, since the destination holds nothing until publication.
        #expect(viewModel.entries.isEmpty)
        #expect(storage.discardedStagedURLs == [staged])
        #expect(fileSystem.trashedURLs.isEmpty)
        #expect(arrival.stage == .cancelling)

        diskService.resumeCreateDiskImage()
        #expect(await arrival.settle() == nil)
    }

    @Test("createVM leaves nothing at the bundle URL when publication fails")
    func createVMPublishFailureLeavesNothingBehind() async throws {
        let storage = MockVMStorageService()
        storage.publishBundleError = VMStorageError.bundleAlreadyExists(
            URL(filePath: "/tmp/occupied.kernova"))
        let (viewModel, _, _, _, _) = makeViewModel(storageService: storage)
        let wizard = makeCreationWizard(name: "Unpublishable VM", startAfterCreate: false)

        try viewModel.createVM(from: wizard)
        let destination = try #require(viewModel.arrivals.first).destinationURL
        await viewModel.awaitArrivalsForTesting()

        #expect(viewModel.entries.isEmpty)
        #expect(storage.bundles[destination] == nil)
        #expect(!FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)))
        #expect(presenter.showError == true)
        let staged = try #require(storage.stagedBundleURLs.last)
        #expect(storage.discardedStagedURLs == [staged])
    }

    @Test("The cancel confirmation for a create reads as a creation")
    func cancelPreparingPromptNamesCreation() {
        let prompt = VMCommandCore.cancelPreparingPrompt(.creating)

        #expect(prompt.title == "Cancel Creation?")
        #expect(prompt.confirmTitle == "Cancel Creation")
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
        wizard.startAfterCreate = false
        wizard.ipswDownloadPath = destination.path(percentEncoded: false)
        wizard.confirmOverwrite()

        try viewModel.createVM(from: wizard)
        await viewModel.awaitArrivalsForTesting()

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
        wizard.startAfterCreate = false
        wizard.ipswDownloadPath = destination.path(percentEncoded: false)

        try viewModel.createVM(from: wizard)
        await viewModel.awaitArrivalsForTesting()

        let instance = try #require(viewModel.instances.first)
        let context = try #require(instance.configuration.installContext)
        #expect(!context.requestedFreshDownload)
    }

    // MARK: - Cancel Installation

    @Test("cancelGuestSetup preserves bundle and instance (non-destructive)")
    func cancelGuestSetupPreservesBundle() async throws {
        let (viewModel, storage, _, _, _) = makeViewModel()
        let instance = VMInstanceFixture.make(name: "Installing VM") {
            $0.installContext = MacOSInstallContext(
                source: .localFile, localIPSWPath: "/tmp/foo.ipsw"
            )
        }
        instance.activity.placeForTesting(.initialBoot)
        viewModel.library.admitForTesting(instance)
        storage.bundles[instance.bundleURL] = instance.configuration

        // A long-running install we can observe being cancelled.
        let cancelStream = AsyncStream<Void>.makeStream()
        try instance.launchParkedSetup {
            cancelStream.continuation.yield(())
            cancelStream.continuation.finish()
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
            removableMediaDeviceService: MockRemovableMediaDeviceService(),
            fileSystem: MockFileSystem(),
            downloadsDirectory: nil,
            preferences: preferences,
            vmnetNetworks: MockVmnetNetworkProvider(), arpTable: ScriptedARPTable(), entitlements: .entitled
        )
        viewModel.presenter = presenter
        let instance = VMInstanceFixture.make(name: "Race VM") {
            $0.installContext = MacOSInstallContext(
                source: .localFile, localIPSWPath: "/tmp/foo.ipsw"
            )
        }
        instance.activity.placeForTesting(.initialBoot)
        viewModel.library.register(instance, storage: storage)

        // Spawn the install + auto-boot pipeline; returns immediately after
        // launching the setup operation.
        await viewModel.start(instance)

        // Wait until the mock install has parked, so the cancel below
        // actually races a running install rather than a not-yet-started one.
        for await _ in raceInstaller.installStartedStream { break }

        viewModel.cancelGuestSetup(instance)

        // Drain the install task to completion so post-conditions are
        // observable (the catch block runs synchronously after await).
        await instance.setupOperationTask?.value

        // The fix routes this case through the cancel outcome: VM is back
        // to .initialBoot, no error dialog, error message cleared.
        #expect(instance.status == .initialBoot)
        #expect(instance.errorMessage == nil)
        #expect(presenter.showError == false)
    }

    @Test("cancelGuestSetup does not change selection")
    func cancelGuestSetupKeepsSelection() async throws {
        let (viewModel, storage, _, _, _) = makeViewModel()
        let first = VMInstanceFixture.make(name: "First")
        let installing = VMInstanceFixture.make(name: "Installing") {
            $0.installContext = MacOSInstallContext(
                source: .localFile, localIPSWPath: "/tmp/foo.ipsw"
            )
        }
        installing.activity.placeForTesting(.initialBoot)
        viewModel.library.admitForTesting([first, installing])
        viewModel.selectedID = installing.id
        storage.bundles[installing.bundleURL] = installing.configuration

        let cancelStream = AsyncStream<Void>.makeStream()
        try installing.launchParkedSetup {
            cancelStream.continuation.yield(())
            cancelStream.continuation.finish()
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
        let instance = VMInstanceFixture.make(name: "Debian") {
            $0.linuxInstallContext = LinuxInstallContext(
                source: .catalogEntry(makeLinuxCatalogEntry()),
                downloadDestinationPath: destinationPath)
        }
        instance.activity.placeForTesting(.initialBoot)
        viewModel.library.register(instance, storage: storage)
        return instance
    }

    @Test("A pending Linux image download loads as .initialBoot")
    func initialStatusHonorsLinuxContext() {
        var config = VMConfiguration(name: "Debian", guestOS: .linux, bootMode: .efi)
        config.linuxInstallContext = LinuxInstallContext(source: .catalogEntry(makeLinuxCatalogEntry()))
        let layout = VMBundleLayout(bundleURL: VMInstanceFixture.bundleURL(for: config.id))

        #expect(VMLibrary.initialPhase(for: config, layout: layout) == .initialBoot)
    }

    @Test("createVM persists a catalog pick's download context for Linux")
    func createVMPersistsLinuxDownloadContext() async throws {
        let (viewModel, _, _, _, _) = makeViewModel()
        let wizard = VMCreationViewModel()
        wizard.selectedOS = .linux
        wizard.selectedBootMode = .efi
        wizard.vmName = "Catalog Linux VM"
        wizard.startAfterCreate = false
        let entry = makeLinuxCatalogEntry()
        wizard.selectLinuxCatalogEntry(entry)

        try viewModel.createVM(from: wizard)
        await viewModel.awaitArrivalsForTesting()

        let created = viewModel.instances.first
        #expect(catalogEntry(of: created?.configuration.linuxInstallContext) == entry)
        // The download is what the VM is waiting on, so it has never booted.
        #expect(created?.status == .initialBoot)
        #expect(created?.configuration.installContext == nil)
    }

    @Test("createVM leaves a local-ISO Linux VM with no download context")
    func createVMLocalISOHasNoLinuxContext() async throws {
        let (viewModel, _, _, _, _) = makeViewModel()
        let wizard = VMCreationViewModel()
        wizard.selectedOS = .linux
        wizard.selectedBootMode = .efi
        wizard.vmName = "Local ISO VM"
        wizard.startAfterCreate = false
        wizard.selectLocalISO(path: "/tmp/ubuntu.iso", bookmark: nil)

        try viewModel.createVM(from: wizard)
        await viewModel.awaitArrivalsForTesting()

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
        await instance.setupOperationTask?.value

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
        // The boot is a fresh admission the setup's outcome chains, so it is
        // waited for by its effect rather than by the setup's own task.
        try await waitForChange { instance.status == .running }

        #expect(instance.configuration.linuxInstallContext == nil)
        #expect(virtService.startCallCount == 1)
        // The status the pipeline handed the boot, not just that a boot ran.
        #expect(virtService.statusAtStart == .stopped)
        #expect(instance.status == .running)
        #expect(presenter.showError == false)
    }

    @Test("A second Start during a running Linux download is refused as busy")
    func startDoesNotRestartAnInFlightLinuxDownload() async throws {
        let resolveService = MockLinuxImageResolveService()
        let (viewModel, storage, _, _, _) = makeViewModel(
            linuxImageResolveService: resolveService)
        let instance = makePendingLinuxVM(in: viewModel, storage: storage)
        try instance.launchParkedSetup()

        await viewModel.start(instance)

        // Draining the setup that holds the VM settles the question: a second
        // pipeline would have run to completion here and asked the mirror.
        #expect(presenter.errorMessage?.contains("downloading its installer image") == true)
        instance.setupOperationTask?.cancel()
        await instance.setupOperationTask?.value
        #expect(resolveService.resolveCallCount == 0)
    }

    @Test("cancelGuestSetup cancels a Linux download and keeps its context")
    func cancelGuestSetupCancelsLinuxDownload() async throws {
        let (viewModel, storage, _, _, _) = makeViewModel()
        let instance = makePendingLinuxVM(in: viewModel, storage: storage)

        let cancelStream = AsyncStream<Void>.makeStream()
        try instance.launchParkedSetup {
            cancelStream.continuation.yield(())
            cancelStream.continuation.finish()
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
        let instance = VMInstanceFixture.make(guestOS: .macOS, files: storage.files)
        viewModel.library.admitForTesting(instance)

        viewModel.setAgentInstallNudgeDismissed(true, for: instance)
        #expect(instance.hostState.agentInstallNudgeDismissed == true)
        #expect(storage.hostStates[instance.bundleURL]?.agentInstallNudgeDismissed == true)
        #expect(storage.saveHostStateCallCount == 1)

        viewModel.setAgentInstallNudgeDismissed(false, for: instance)
        #expect(instance.hostState.agentInstallNudgeDismissed == false)
        #expect(storage.hostStates[instance.bundleURL]?.agentInstallNudgeDismissed == false)
        #expect(storage.saveHostStateCallCount == 2)
        // The flag is host state, so no write reaches `config.json`.
        #expect(storage.saveConfigurationCallCount == 0)
    }

    @Test("setAgentInstallNudgeDismissed no-ops when unchanged")
    func setAgentInstallNudgeDismissedNoOpsWhenUnchanged() {
        let (viewModel, storage, _, _, _) = makeViewModel()
        let instance = VMInstanceFixture.make(guestOS: .macOS, files: storage.files)
        viewModel.library.admitForTesting(instance)

        // Default is already false; setting false again writes nothing.
        viewModel.setAgentInstallNudgeDismissed(false, for: instance)
        #expect(storage.saveHostStateCallCount == 0)
    }

    @Test("dismissAgentInstallNudge still sets the flag to true")
    func dismissAgentInstallNudgeSetsTrue() {
        let (viewModel, storage, _, _, _) = makeViewModel()
        let instance = VMInstanceFixture.make(guestOS: .macOS, files: storage.files)
        viewModel.library.admitForTesting(instance)

        viewModel.dismissAgentInstallNudge(for: instance)

        #expect(instance.hostState.agentInstallNudgeDismissed == true)
        #expect(storage.saveHostStateCallCount == 1)
    }

    @Test("resetAllAgentInstallNudges re-arms every VM and the app-wide preference")
    func resetAllAgentInstallNudgesReArmsEveryVM() {
        let (viewModel, _, _, _, _) = makeViewModel()
        let first = VMInstanceFixture.make(
            name: "First", guestOS: .macOS,
            hostState: VMHostState(agentInstallNudgeDismissed: true))
        let second = VMInstanceFixture.make(
            name: "Second", guestOS: .macOS,
            hostState: VMHostState(agentInstallNudgeDismissed: true))
        let third = VMInstanceFixture.make(name: "Third", guestOS: .macOS)
        // `third` stays armed to confirm the reset no-ops on already-armed VMs.
        viewModel.library.admitForTesting([first, second, third])
        viewModel.agentInstallPromptDisabled = true

        viewModel.resetAllAgentInstallNudges()

        #expect(first.hostState.agentInstallNudgeDismissed == false)
        #expect(second.hostState.agentInstallNudgeDismissed == false)
        #expect(third.hostState.agentInstallNudgeDismissed == false)
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
        let instance = VMInstanceFixture.make()
        viewModel.library.admitForTesting([instance])

        for phase in Self.transitionalPhases {
            instance.activity.placeForTesting(phase)
            #expect(viewModel.hasUninterruptibleWork, "\(phase)")
        }
        // Termination save-suspends these, so they must not hold a quit back.
        for phase in [
            VMLifecyclePhase.running(sessionID: UUID()), .livePaused(sessionID: UUID()),
            .suspended, .stopped,
        ] {
            instance.activity.placeForTesting(phase)
            #expect(!viewModel.hasUninterruptibleWork, "\(phase)")
        }
    }

    @Test("hasUninterruptibleWork is false for an empty library")
    func hasUninterruptibleWorkIsFalseWhenEmpty() {
        let (viewModel, _, _, _, _) = makeViewModel()
        #expect(!viewModel.hasUninterruptibleWork)
    }

    @Test("hasUninterruptibleWork covers an arrival still writing its bundle")
    func hasUninterruptibleWorkCoversAnArrival() async {
        let (viewModel, _, _, _, _) = makeViewModel()
        let gate = GatedStep()
        let arrival = viewModel.library.beginGatedArrival(
            .cloning(sourceID: UUID()), named: "Copying", gate: gate)

        #expect(viewModel.hasUninterruptibleWork)

        gate.release()
        await arrival.settle()
        #expect(!viewModel.hasUninterruptibleWork)
    }

    @Test("hasSaveInFlight covers a saving VM alone")
    func hasSaveInFlightCoversSavingOnly() {
        let (viewModel, _, _, _, _) = makeViewModel()
        let instance = VMInstanceFixture.make()
        viewModel.library.admitForTesting([instance])

        let live = VMLifecyclePhase.running(sessionID: UUID())
        instance.activity.placeForTesting(.operating(.saving, from: live))
        #expect(viewModel.hasSaveInFlight)
        // A capture writes files too, so it waits out alongside a suspend.
        instance.activity.placeForTesting(.operating(.capturingSnapshot(.live), from: live))
        #expect(viewModel.hasSaveInFlight)
        instance.activity.placeForTesting(.operating(.capturingSnapshot(.stopped), from: .stopped))
        #expect(viewModel.hasSaveInFlight)
        // Every other transition is one an explicit quit may terminate through.
        for phase in [
            VMLifecyclePhase.operating(
                .bringUp(.starting(recovery: false)), from: .stopped, boundSession: UUID()),
            .operating(.bringUp(.restoringSavedState), from: .suspended, boundSession: UUID()),
            .operating(
                .bringUp(.reverting(snapshotID: UUID(), resumesAfter: false)), from: .stopped),
            .operating(.bringUp(.settingUp(.macOSInstall)), from: .initialBoot),
            .running(sessionID: UUID()), .livePaused(sessionID: UUID()), .suspended, .stopped,
        ] {
            instance.activity.placeForTesting(phase)
            #expect(!viewModel.hasSaveInFlight, "\(phase)")
        }
    }

    @Test("hasSaveInFlight finds a saving VM among settled ones")
    func hasSaveInFlightFindsAnyInstance() {
        let (viewModel, _, _, _, _) = makeViewModel()
        let running = VMInstanceFixture.make()
        running.activity.placeForTesting(.running(sessionID: UUID()))
        let saving = VMInstanceFixture.make()
        saving.activity.placeForTesting(.operating(.saving, from: .running(sessionID: UUID())))
        viewModel.library.admitForTesting([running, saving])

        #expect(viewModel.hasSaveInFlight)
    }

    @Test("hasSaveInFlight is false for an empty library")
    func hasSaveInFlightIsFalseWhenEmpty() {
        let (viewModel, _, _, _, _) = makeViewModel()
        #expect(!viewModel.hasSaveInFlight)
    }

    /// A pause presents `.running` until the VZ call returns, so no
    /// status-driven surface can render it — the operation holding the VM is
    /// what the sidebar's busy term reads.
    @Test("A settling pause holds the VM while its status still says running")
    func isBusyCoversSettlingPause() async throws {
        let (viewModel, suspending) = makeSuspendingViewModel()
        let instance = VMInstanceFixture.make()
        instance.activity.placeForTesting(.running(sessionID: UUID()))
        viewModel.library.admitForTesting([instance])

        let pause = Task { @MainActor in try await viewModel.lifecycle.pause(instance) }
        await suspending.waitUntilSuspended()

        #expect(instance.status == .running)
        #expect(instance.phase.operation?.kind == .pausing)

        suspending.resumeSuspended()
        try await pause.value
        #expect(instance.phase.operation == nil)
    }

    @Test("A wait on the operation resolves by observation when a settling pause ends")
    func isBusyWakesAnObservedWait() async throws {
        let (viewModel, suspending) = makeSuspendingViewModel()
        let instance = VMInstanceFixture.make()
        instance.activity.placeForTesting(.running(sessionID: UUID()))
        viewModel.library.admitForTesting([instance])

        let pause = Task { @MainActor in try await viewModel.lifecycle.pause(instance) }
        await suspending.waitUntilSuspended()
        #expect(instance.phase.operation != nil)

        // Released from a separate task so the wait below arms first, making the
        // resolution an observation wake rather than an already-true predicate.
        Task { @MainActor in suspending.resumeSuspended() }
        try await waitForChange { instance.phase.operation == nil }

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
        let dismissed = VMInstanceFixture.make(
            name: "Dismissed", hostState: VMHostState(agentInstallNudgeDismissed: true))
        let armed = VMInstanceFixture.make(name: "Armed")
        viewModel.library.admitForTesting([dismissed, armed])

        viewModel.agentInstallPromptDisabled = true
        viewModel.agentInstallPromptDisabled = false

        #expect(dismissed.hostState.agentInstallNudgeDismissed == true)
        #expect(armed.hostState.agentInstallNudgeDismissed == false)
        #expect(storage.saveHostStateCallCount == 0)
    }

    // MARK: - Rename

    @Test("renameVMInDetail sets activeRename to detail target")
    func renameVMInDetailSetsDetailTarget() {
        let (viewModel, _, _, _, _) = makeViewModel()
        let instance = VMInstanceFixture.make()
        viewModel.library.admitForTesting(instance)

        viewModel.renameVMInDetail(instance)

        #expect(viewModel.activeRename == .detail(instance.id))
    }

    @Test("renameVMInSidebar sets activeRename to sidebar target")
    func renameVMInSidebarSetsSidebarTarget() {
        let (viewModel, _, _, _, _) = makeViewModel()
        let instance = VMInstanceFixture.make()
        viewModel.library.admitForTesting(instance)

        viewModel.renameVMInSidebar(instance)

        #expect(viewModel.activeRename == .sidebar(instance.id))
    }

    @Test("commitRename updates name and persists")
    func commitRenameUpdatesName() {
        let (viewModel, storage, _, _, _) = makeViewModel()
        let instance = VMInstanceFixture.make(name: "Old Name", files: storage.files)
        viewModel.library.admitForTesting(instance)
        viewModel.activeRename = .detail(instance.id)

        viewModel.commitRename(for: instance, newName: "New Name", from: .detail)

        #expect(instance.name == "New Name")
        #expect(viewModel.activeRename == nil)
        #expect(storage.saveConfigurationCallCount == 1)
    }

    @Test("commitRename trims whitespace")
    func commitRenameTrimWhitespace() {
        let (viewModel, _, _, _, _) = makeViewModel()
        let instance = VMInstanceFixture.make(name: "Original")
        viewModel.library.admitForTesting(instance)
        viewModel.activeRename = .detail(instance.id)

        viewModel.commitRename(for: instance, newName: "  Trimmed  ", from: .detail)

        #expect(instance.name == "Trimmed")
        #expect(viewModel.activeRename == nil)
    }

    @Test("commitRename rejects empty name and preserves original")
    func commitRenameRejectsEmpty() {
        let (viewModel, storage, _, _, _) = makeViewModel()
        let instance = VMInstanceFixture.make(name: "Keep Me", files: storage.files)
        viewModel.library.admitForTesting(instance)
        viewModel.activeRename = .detail(instance.id)

        viewModel.commitRename(for: instance, newName: "", from: .detail)

        #expect(instance.name == "Keep Me")
        #expect(viewModel.activeRename == nil)
        #expect(storage.saveConfigurationCallCount == 0)
    }

    @Test("commitRename rejects whitespace-only name and preserves original")
    func commitRenameRejectsWhitespace() {
        let (viewModel, storage, _, _, _) = makeViewModel()
        let instance = VMInstanceFixture.make(name: "Keep Me", files: storage.files)
        viewModel.library.admitForTesting(instance)
        viewModel.activeRename = .detail(instance.id)

        viewModel.commitRename(for: instance, newName: "   ", from: .detail)

        #expect(instance.name == "Keep Me")
        #expect(viewModel.activeRename == nil)
        #expect(storage.saveConfigurationCallCount == 0)
    }

    @Test("commitRename from a superseded surface commits but keeps the newer rename active")
    func commitRenameFromSupersededSurfaceKeepsNewerRename() {
        let (viewModel, storage, _, _, _) = makeViewModel()
        let instance = VMInstanceFixture.make(name: "Old Name", files: storage.files)
        viewModel.library.admitForTesting(instance)
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
        let instance = VMInstanceFixture.make()
        viewModel.library.admitForTesting(instance)
        viewModel.activeRename = .sidebar(instance.id)

        viewModel.cancelRename(for: instance, from: .sidebar)

        #expect(viewModel.activeRename == nil)
        #expect(storage.saveConfigurationCallCount == 0)
    }

    @Test("cancelRename from a superseded surface keeps the newer rename active")
    func cancelRenameFromSupersededSurfaceKeepsNewerRename() {
        let (viewModel, _, _, _, _) = makeViewModel()
        let instance = VMInstanceFixture.make()
        viewModel.library.admitForTesting(instance)
        viewModel.activeRename = .detail(instance.id)

        viewModel.cancelRename(for: instance, from: .sidebar)

        #expect(viewModel.activeRename == .detail(instance.id))
    }

    @Test("commitRename for one VM cannot clear another VM's rename marker")
    func commitRenameForOtherVMKeepsMarker() {
        let (viewModel, _, _, _, _) = makeViewModel()
        let renamed = VMInstanceFixture.make(name: "Renamed VM")
        let other = VMInstanceFixture.make(name: "Other VM")
        viewModel.library.admitForTesting([renamed, other])
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
    /// An operation of every kind that shows a status of its own.
    private static var transitionalPhases: [VMLifecyclePhase] {
        let live = VMLifecyclePhase.running(sessionID: UUID())
        return [
            .operating(.bringUp(.starting(recovery: false)), from: .stopped, boundSession: UUID()),
            .operating(.saving, from: live),
            .operating(.capturingSnapshot(.live), from: live),
            .operating(.capturingSnapshot(.stopped), from: .stopped),
            .operating(.bringUp(.restoringSavedState), from: .suspended, boundSession: UUID()),
            .operating(
                .bringUp(.reverting(snapshotID: UUID(), resumesAfter: false)), from: .stopped),
            .operating(.bringUp(.settingUp(.macOSInstall)), from: .initialBoot),
        ]
    }

    /// A fixture VM marked to start automatically.
    private func makeAutoStartInstance(
        name: String, guestOS: VMGuestOS = .linux, hostState: VMHostState = VMHostState(),
        mutate: (inout VMConfiguration) -> Void = { _ in }
    ) -> VMInstance {
        var hostState = hostState
        hostState.startsAutomaticallyOnLaunch = true
        return VMInstanceFixture.make(name: name, guestOS: guestOS, hostState: hostState, mutate: mutate)
    }

    @Test("macOSVMNamesMarkedForAutoStart lists marked macOS VMs in library order")
    func markedMacOSVMNamesFollowLibraryOrder() {
        let (viewModel, _, _, _, _) = makeViewModel()
        let firstMac = makeAutoStartInstance(name: "Mac One", guestOS: .macOS)
        let unmarkedMac = VMInstanceFixture.make(name: "Mac Unmarked", guestOS: .macOS)
        let markedLinux = makeAutoStartInstance(name: "Linux Marked")
        let secondMac = makeAutoStartInstance(name: "Mac Two", guestOS: .macOS)
        viewModel.library.admitForTesting([firstMac, unmarkedMac, markedLinux, secondMac])

        // Linux guests don't count against the macOS cap, and an unmarked macOS
        // VM isn't coming up at launch.
        #expect(viewModel.macOSVMNamesMarkedForAutoStart == ["Mac One", "Mac Two"])
    }

    @Test("startAutomaticVMsForLaunch starts only marked VMs")
    func autoStartStartsOnlyMarked() async {
        let (viewModel, _, _, virtService, _) = makeViewModel()
        let marked1 = makeAutoStartInstance(name: "Marked 1")
        let marked2 = makeAutoStartInstance(name: "Marked 2")
        let unmarked = VMInstanceFixture.make(name: "Unmarked")
        viewModel.library.admitForTesting([marked1, marked2, unmarked])

        await viewModel.startAutomaticVMsForLaunch()

        #expect(virtService.startCallCount == 2)
        #expect(marked1.status == .running)
        #expect(marked2.status == .running)
        #expect(unmarked.status == .stopped)
    }

    @Test("startAutomaticVMsForLaunch resumes a marked VM with saved state")
    func autoStartResumesColdPaused() async throws {
        let (viewModel, _, _, virtService, _) = makeViewModel()
        let saved = makeAutoStartInstance(name: "Suspended")
        saved.activity.placeForTesting(.suspended)
        defer { VMInstanceFixture.removeBundle(of: saved) }
        try VMInstanceFixture.writeSaveFile(for: saved)
        viewModel.library.admitForTesting([saved])

        await viewModel.startAutomaticVMsForLaunch()

        // A cold resume is the restore bring-up, run through `start`.
        #expect(virtService.startCallCount == 1)
        #expect(virtService.lastStartRoute == .restoredSavedState)
        #expect(virtService.resumeCallCount == 0)
        #expect(saved.status == .running)
    }

    /// A VM awaiting its initial boot carries the setup context that put it
    /// there — `VMLibrary.initialPhase` assigns the phase from nothing else —
    /// and that context is what a start would run.
    @Test("startAutomaticVMsForLaunch leaves a marked VM awaiting initial boot alone")
    func autoStartSkipsInitialBoot() async {
        let (viewModel, _, _, virtService, _) = makeViewModel()
        let fresh = makeAutoStartInstance(name: "Never Booted") {
            $0.installContext = MacOSInstallContext(source: .downloadLatest)
        }
        fresh.activity.placeForTesting(.initialBoot)
        viewModel.library.admitForTesting([fresh])

        await viewModel.startAutomaticVMsForLaunch()

        #expect(virtService.startCallCount == 0)
        #expect(fresh.status == .initialBoot)
    }

    /// The status reads `.error` — an ordinary boot retry — but the surviving
    /// install context means `start(_:)` would route back into the installer.
    @Test("startAutomaticVMsForLaunch leaves a marked VM whose setup failed alone")
    func autoStartSkipsFailedSetup() async {
        let (viewModel, _, _, virtService, _) = makeViewModel()
        let stalled = makeAutoStartInstance(name: "Setup Failed") {
            $0.linuxInstallContext = LinuxInstallContext(
                source: .catalogEntry(makeLinuxCatalogEntry()))
        }
        stalled.activity.placeForTesting(.failed(message: "Test failure"))
        viewModel.library.admitForTesting([stalled])

        await viewModel.startAutomaticVMsForLaunch()

        #expect(virtService.startCallCount == 0)
        #expect(stalled.status == .error)
    }

    /// A start that would raise the account sheet is not a bring-up nobody is
    /// present for, and a login launch has no window to raise it in.
    @available(macOS 27.0, *)
    @Test("startAutomaticVMsForLaunch leaves a marked VM owing a guest account alone")
    func autoStartSkipsAnOutstandingGuestAccount() async {
        let (viewModel, _, _, virtService, _) = makeViewModel()
        let owing = makeAutoStartInstance(name: "Unattended", guestOS: .macOS) {
            $0.pendingGuestAccount = GuestAccountIntent(
                fullName: "Ada Lovelace", username: "ada", logsInAutomatically: false,
                enablesRemoteLogin: false)
        }
        owing.activity.placeForTesting(.stopped)
        viewModel.library.admitForTesting([owing])

        await viewModel.startAutomaticVMsForLaunch()

        #expect(virtService.startCallCount == 0)
        // Passed over, not refused: nothing is alerted about at a login.
        #expect(presenter.errors.isEmpty)
        #expect(owing.configuration.pendingGuestAccount != nil)
    }

    @Test("startAutomaticVMsForLaunch carries on past a VM that fails to start")
    func autoStartContinuesAfterFailure() async {
        let virtService = MockVirtualizationService()
        virtService.startError = VirtualizationError.noVirtualMachine
        let (viewModel, _, _, _, _) = makeViewModel(virtualizationService: virtService)
        let failing = makeAutoStartInstance(name: "Failing")
        let following = makeAutoStartInstance(name: "Following")
        viewModel.library.admitForTesting([failing, following])

        await viewModel.startAutomaticVMsForLaunch()

        #expect(virtService.startCallCount == 2)
        #expect(presenter.showError == true)
    }

    @Test("startAutomaticVMsForLaunch leaves a failed restore cold-paused and carries on")
    func autoStartRestoreFailureRestsColdPausedAndContinues() async throws {
        let virtService = MockVirtualizationService()
        virtService.restoreError = VirtualizationError.restoreFailed(
            underlying: NSError(domain: "test", code: 1))
        let (viewModel, _, _, _, _) = makeViewModel(virtualizationService: virtService)
        let suspended = makeAutoStartInstance(name: "Suspended")
        suspended.activity.placeForTesting(.suspended)
        try FileManager.default.createDirectory(
            at: suspended.bundleURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: suspended.bundleURL) }
        FileManager.default.createFile(
            atPath: suspended.bundle.saveFileURL.path(percentEncoded: false),
            contents: Data("fake save".utf8))
        let following = makeAutoStartInstance(name: "Following")
        viewModel.library.admitForTesting([suspended, following])

        // A stream reader is the one surface a login launch has, and a VM left
        // resting back on its saved state moves no field the event diff turns
        // into a failure — so the pass reports it explicitly.
        let events = viewModel.commands.events()
        var iterator = events.makeAsyncIterator()

        await viewModel.startAutomaticVMsForLaunch()

        // The failed restore and the following VM's boot, both through `start`.
        #expect(virtService.startCallCount == 2)
        #expect(virtService.resumeCallCount == 0)
        #expect(suspended.status == .paused)
        #expect(suspended.errorMessage == nil)
        #expect(presenter.showError == true)
        // Exactly one surfacing, not two: the report routes through the same
        // presenter path the pass would otherwise have used on its own.
        #expect(presenter.errors.count == 1)
        let batch = await iterator.next()
        let failures = (batch ?? []).compactMap { event -> UUID? in
            guard case .failure(let id, _, _) = event else { return nil }
            return id
        }
        #expect(failures == [suspended.id])
    }

    @Test("startAutomaticVMsForLaunch stops between VMs once cancelled")
    func autoStartHonorsCancellation() async {
        let (viewModel, suspending) = makeSuspendingViewModel()
        let first = makeAutoStartInstance(name: "First")
        let second = makeAutoStartInstance(name: "Second")
        viewModel.library.admitForTesting([first, second])

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
        let first = makeAutoStartInstance(name: "First")
        let second = makeAutoStartInstance(name: "Second")
        viewModel.library.admitForTesting([first, second])

        let pass = Task { await viewModel.startAutomaticVMsForLaunch() }
        // Deleted while the first VM is still booting, so the pass's snapshot
        // holds an instance the library no longer has.
        await suspending.waitUntilSuspended()
        viewModel.library.evict(second)
        suspending.shouldSuspendOnStart = false
        suspending.resumeSuspended()
        await pass.value

        #expect(first.status == .running)
        #expect(second.status == .stopped)
    }

    @Test("startAutomaticVMsForLaunch does nothing when no VM is marked")
    func autoStartNoOpWhenNothingMarked() async {
        let (viewModel, _, _, virtService, _) = makeViewModel()
        viewModel.library.admitForTesting([VMInstanceFixture.make(name: "Unmarked")])

        await viewModel.startAutomaticVMsForLaunch()

        #expect(virtService.startCallCount == 0)
        #expect(virtService.resumeCallCount == 0)
    }

    /// Nobody is at the machine for this pass, so it takes no surface: each
    /// bring-up is only reported as one, and what that costs on screen is the
    /// app delegate's decision from the app's own posture.
    @Test("startAutomaticVMsForLaunch reports every bring-up and surfaces nothing itself")
    func autoStartReadiesWithoutSurfacing() async throws {
        let (viewModel, _, _, virtService, _) = makeViewModel()
        // No window exists on a headless launch, which is what leaves the
        // presenter nil.
        viewModel.presenter = nil
        let popOut = makeAutoStartInstance(name: "Pop Out", hostState: VMHostState(displayPreference: .popOut))
        let inline = makeAutoStartInstance(name: "Inline")
        let saved = makeAutoStartInstance(name: "Suspended")
        saved.activity.placeForTesting(.suspended)
        defer { VMInstanceFixture.removeBundle(of: saved) }
        try VMInstanceFixture.writeSaveFile(for: saved)
        viewModel.library.admitForTesting([popOut, inline, saved])
        viewModel.selectedID = inline.id
        var readied: [UUID] = []
        var displayWindows = 0
        var libraryRequests = 0
        viewModel.onReadyDisplay = { readied.append($0.id) }
        viewModel.onOpenDisplayWindow = { _ in displayWindows += 1 }
        viewModel.onSurfaceLibrary = { libraryRequests += 1 }

        await viewModel.startAutomaticVMsForLaunch()

        // Two boots and one restore, all through `start`.
        #expect(virtService.startCallCount == 3)
        #expect(virtService.resumeCallCount == 0)
        #expect(popOut.status == .running)
        #expect(inline.status == .running)
        #expect(saved.status == .running)
        #expect(readied == [popOut.id, inline.id, saved.id])
        #expect(displayWindows == 0)
        #expect(libraryRequests == 0)
        // The pass leaves the library showing whatever the user left it on.
        #expect(viewModel.selectedID == inline.id)
    }

    // MARK: - Import

    /// Builds a `.kernova`-shaped source bundle URL under a per-call-unique temp parent.
    ///
    /// The parent keeps parallel tests from colliding. When `createOnDisk` is true (the
    /// default), writes the bundle and its `config.json` on disk — `importVM` copies real files via
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
            try VMBundleFiles(url: url, access: CoordinatedBundleFileAccess()).writeInitial(config)
        } else {
            // Nothing is copied, so the source only has to read.
            storage.bundles[url] = config
        }
        return (url, config)
    }

    @Test("importVM imports a single bundle and adds its VM")
    func importVMSingleBundle() async throws {
        let (viewModel, storage, _, _, _) = makeViewModel()
        let source = try makeImportSource(name: "Imported VM", storage: storage)
        defer { try? FileManager.default.removeItem(at: source.url.deletingLastPathComponent()) }

        _ = viewModel.importVMs(fromDroppedURLs: [source.url])
        await viewModel.awaitArrivalsForTesting()

        #expect(viewModel.instances.count == 1)
        let imported = viewModel.instances.first
        #expect(imported?.configuration.id == source.config.id)
        #expect(viewModel.arrivals.isEmpty)
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
        // A real file, since the import copies the source directory itself.
        try VMBundleFiles(url: source.url, access: CoordinatedBundleFileAccess()).update(.hostState) {
            $0 = VMHostState(startsAutomaticallyOnLaunch: true, displayPreference: .popOut)
        }

        _ = viewModel.importVMs(fromDroppedURLs: [source.url])
        await viewModel.awaitArrivalsForTesting()

        let imported = try #require(viewModel.instances.first)
        #expect(imported.hostState.startsAutomaticallyOnLaunch == false)
        // …and the cleared flag reached the imported bundle, not just the row.
        let importedFiles = VMBundleFiles(url: imported.bundleURL, access: CoordinatedBundleFileAccess())
        #expect(try importedFiles.read().hostState.startsAutomaticallyOnLaunch == false)
        // The rest of the host state arrives with the bundle: the row reads the
        // published bundle rather than keeping the defaults it was built with.
        #expect(imported.hostState.displayPreference == .popOut)
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
        await viewModel.awaitArrivalsForTesting()

        // Pre-fix, a synchronous loop over `importVM` only imported the first bundle and
        // rejected the rest with a "preparing operation in progress" error.
        #expect(viewModel.instances.count == 3)
        let importedIDs = Set(viewModel.instances.map(\.configuration.id))
        #expect(importedIDs == Set(sources.map(\.config.id)))
        #expect(viewModel.arrivals.isEmpty)
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
        await viewModel.awaitArrivalsForTesting()

        // The second bundle's destination must not collide with the first's — reservation consults
        // in-flight arrivals in `entries`, not just on-disk state, so the not-yet-copied first
        // arrival is visible to the second's collision check (pre-fix, `fileExists` alone missed it).
        #expect(viewModel.instances.count == 2)
        let names = Set(viewModel.instances.map { $0.bundleURL.lastPathComponent })
        #expect(names == ["Same Name.kernova", "Same Name 2.kernova"])
        #expect(presenter.showError == false)
    }

    @Test("importVM selects the existing instance when a VM with the same UUID is already in the library")
    func importVMDuplicateUUIDSelectsExisting() async throws {
        let (viewModel, storage, _, _, _) = makeViewModel()
        let existing = VMInstanceFixture.make(name: "Existing VM")
        viewModel.library.admitForTesting(existing)

        // Source lives elsewhere on disk (never copied — the duplicate-UUID short-circuit
        // returns before the copy) but shares the same config UUID.
        let source = try makeImportSource(
            name: existing.configuration.name, storage: storage, createOnDisk: false)
        storage.bundles[source.url] = existing.configuration

        _ = viewModel.importVMs(fromDroppedURLs: [source.url])
        await viewModel.awaitArrivalsForTesting()

        #expect(viewModel.instances.count == 1)
    }

    @Test("importVM selects the existing instance when the source is already inside the VMs directory")
    func importVMSourceAlreadyInVMsDirectory() async throws {
        let (viewModel, storage, _, _, _) = makeViewModel()
        let vmsDir = try storage.vmsDirectory
        let config = VMConfiguration(name: "Already There", guestOS: .linux, bootMode: .efi)
        let bundleURL = vmsDir.appendingPathComponent("\(config.id.uuidString).kernova", isDirectory: true)
        storage.bundles[bundleURL] = config
        let existing = VMInstance(
            bundle: viewModel.library.bundleFactory.make(
                VMInstanceFixture.read(bundleURL, from: storage.files)),
            phase: .stopped,
            preferences: makeTestPreferences())
        viewModel.library.admitForTesting(existing)

        _ = viewModel.importVMs(fromDroppedURLs: [bundleURL])
        await viewModel.awaitArrivalsForTesting()

        #expect(viewModel.instances.count == 1)
        #expect(viewModel.selectedID == existing.id)
    }

    @Test("importVMs batch with a duplicate in the middle still imports the surrounding bundles")
    func importVMsBatchWithDuplicateInMiddle() async throws {
        let (viewModel, storage, _, _, _) = makeViewModel()
        let existing = VMInstanceFixture.make(name: "Already Imported")
        viewModel.library.admitForTesting(existing)

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
        await viewModel.awaitArrivalsForTesting()

        // The duplicate is a synchronous no-op (select-existing) that must not stall the batch.
        #expect(viewModel.instances.count == 3)
        let importedIDs = Set(viewModel.instances.map(\.configuration.id))
        #expect(importedIDs == [existing.configuration.id, first.config.id, third.config.id])
        #expect(presenter.showError == false)
        #expect(viewModel.selectedID == third.config.id)
    }

    @Test("importVM removes the arrival and surfaces an error when the copy fails")
    func importVMCopyFailureRemovesTheArrival() async throws {
        let (viewModel, storage, _, _, _) = makeViewModel()
        // Registered with the mock but never created on disk, so the real `FileManager.copyItem`
        // fails with "no such file."
        let source = try makeImportSource(name: "Missing Source", storage: storage, createOnDisk: false)

        _ = viewModel.importVMs(fromDroppedURLs: [source.url])
        await viewModel.awaitArrivalsForTesting()

        #expect(viewModel.entries.isEmpty)
        #expect(presenter.showError == true)
        #expect(presenter.errorMessage != nil)
    }

    @Test("importVM leaves nothing at the destination when publication fails")
    func importVMPublishFailureLeavesNothingBehind() async throws {
        let storage = MockVMStorageService()
        storage.publishBundleError = VMStorageError.bundleAlreadyExists(
            URL(filePath: "/tmp/occupied.kernova"))
        let (viewModel, _, _, _, _) = makeViewModel(storageService: storage)
        let source = try makeImportSource(name: "Unpublishable Import", storage: storage)
        defer { try? FileManager.default.removeItem(at: source.url.deletingLastPathComponent()) }

        _ = viewModel.importVMs(fromDroppedURLs: [source.url])
        let destination = try #require(viewModel.arrivals.first).destinationURL
        await viewModel.awaitArrivalsForTesting()

        // The copy landed in staging, so the reserved destination never existed.
        #expect(viewModel.entries.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)))
        #expect(presenter.showError == true)
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
        await viewModel.awaitArrivalsForTesting()

        #expect(viewModel.instances.count == 2)
        let importedIDs = Set(viewModel.instances.map(\.configuration.id))
        #expect(importedIDs == [first.config.id, third.config.id])
        #expect(presenter.showError == true)
    }

    @Test("importVM proceeds while a clone is preparing (#487 — import/clone can't collide)")
    func importVMProceedsWhileCloning() async throws {
        let (viewModel, storage, _, _, _) = makeViewModel()
        let gate = GatedStep()
        let clone = viewModel.library.beginGatedArrival(
            .cloning(sourceID: UUID()), named: "Cloning VM", gate: gate)

        let source = try makeImportSource(name: "Concurrent Import", storage: storage)
        defer { try? FileManager.default.removeItem(at: source.url.deletingLastPathComponent()) }

        _ = viewModel.importVMs(fromDroppedURLs: [source.url])
        let imported = try #require(viewModel.arrivals.first { $0.kind == .importing })
        await imported.settle()

        #expect(viewModel.instances.map(\.id) == [source.config.id])
        #expect(viewModel.arrivals.map(\.id) == [clone.id])
        #expect(presenter.showError == false)

        gate.release()
        await clone.settle()
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

        await viewModel.awaitArrivalsForTesting()

        // The second trigger reserves synchronously against the first trigger's already-registered
        // arrivals in `entries`, so every bundle imports with a distinct destination — no
        // collision and no waiting behind the other batch's copies.
        #expect(viewModel.instances.count == allSources.count)
        let importedIDs = Set(viewModel.instances.map(\.configuration.id))
        #expect(importedIDs == Set(allSources.map(\.config.id)))
        #expect(viewModel.arrivals.isEmpty)
        #expect(presenter.showError == false)
    }

    @Test("A second arrival keeps the selection on the one the user is already watching (#487)")
    func registerPreservesSelectionOfAnArrival() async throws {
        let (viewModel, storage, _, _, _) = makeViewModel()
        let gate = GatedStep()
        let preparing = viewModel.library.beginGatedArrival(
            .cloning(sourceID: UUID()), named: "Already Preparing", gate: gate)
        viewModel.selectedID = preparing.id

        let source = try makeImportSource(name: "Concurrent Import", storage: storage)
        defer { try? FileManager.default.removeItem(at: source.url.deletingLastPathComponent()) }

        _ = viewModel.importVMs(fromDroppedURLs: [source.url])

        // A second, unrelated import shouldn't steal the sidebar's focus from the
        // arrival the user is already watching.
        #expect(viewModel.selectedID == preparing.id)
        #expect(viewModel.entries.count == 2)

        await viewModel.arrivals.first { $0.kind == .importing }?.settle()
        #expect(viewModel.selectedID == preparing.id)
        gate.release()
        await preparing.settle()
    }

    // MARK: - Clone

    @Test("cloneVM registers the clone's arrival and selects it")
    func cloneVMRegistersAnArrival() async {
        let (viewModel, storage, _, _, _) = makeViewModel()
        let instance = VMInstanceFixture.make(name: "Original")
        instance.activity.placeForTesting(.stopped)
        viewModel.library.admitForTesting(instance)
        storage.bundles[instance.bundleURL] = instance.configuration

        viewModel.cloneVM(instance)

        #expect(viewModel.entries.count == 2)
        let arrival = viewModel.arrivals.first
        #expect(arrival?.kind == .cloning(sourceID: instance.id))
        #expect(arrival?.name == "Original Copy")
        #expect(viewModel.selectedID == arrival?.id)

        await viewModel.awaitArrivalsForTesting()
    }

    @Test("cloneVM turns its arrival into a VM on success")
    func cloneVMSettlesTheArrival() async {
        let (viewModel, storage, _, _, _) = makeViewModel()
        let instance = VMInstanceFixture.make(name: "Original")
        instance.activity.placeForTesting(.stopped)
        viewModel.library.admitForTesting(instance)
        storage.bundles[instance.bundleURL] = instance.configuration

        viewModel.cloneVM(instance)
        await viewModel.awaitArrivalsForTesting()

        #expect(viewModel.arrivals.isEmpty)
        #expect(viewModel.instances.count == 2)
        #expect(storage.cloneVMBundleCallCount == 1)
    }

    /// Duplicating a VM asks for a copy of the machine: not a second guest
    /// booting at every launch, not a baseline the clone's bundle holds no
    /// snapshot for, and not the source's window placement or dismissals.
    @Test("A clone starts with the default host state, whatever its source's")
    func cloneStartsWithDefaultHostState() async throws {
        let (viewModel, storage, _, _, _) = makeViewModel()
        var sourceHostState = VMHostState(
            startsAutomaticallyOnLaunch: true, displayPreference: .fullscreen,
            lastFullscreenDisplayID: 4_280_803_137, agentInstallNudgeDismissed: true)
        sourceHostState.applyEphemeralMode(enabled: true, baseline: UUID())
        let instance = VMInstanceFixture.make(name: "Original", hostState: sourceHostState)
        instance.activity.placeForTesting(.stopped)
        viewModel.library.register(instance, storage: storage)

        viewModel.cloneVM(instance)
        await viewModel.awaitArrivalsForTesting()
        let clone = try #require(viewModel.instances.first { $0.id != instance.id })

        #expect(clone.hostState == VMHostState())
        #expect(
            storage.files.data(
                atRelativePath: VMBundleLayout.hostStateRelativePath, in: clone.bundleURL) == nil)
        #expect(storage.lastCloneFilesToCopy?.contains("host-state.json") == false)
        #expect(instance.hostState == sourceHostState)
    }

    @Test("cloneVM removes its arrival on storage error and selects remaining instance")
    func cloneVMRemovesTheArrivalOnError() async {
        let storage = MockVMStorageService()
        storage.cloneVMBundleError = VMStorageError.bundleAlreadyExists(URL(filePath: "/tmp/occupied.kernova"))
        let (viewModel, _, _, _, _) = makeViewModel(storageService: storage)
        let instance = VMInstanceFixture.make(name: "Fail Clone")
        instance.activity.placeForTesting(.stopped)
        viewModel.library.admitForTesting(instance)

        viewModel.cloneVM(instance)

        // The arrival was registered
        #expect(viewModel.arrivals.count == 1)

        // Wait for its copy to fail
        await viewModel.awaitArrivalsForTesting()

        #expect(viewModel.entries.map(\.id) == [instance.id])
        #expect(viewModel.selectedID == instance.id)
        #expect(presenter.showError == true)
        #expect(presenter.errorMessage != nil)
    }

    @Test("cloneVM leaves nothing at the clone's bundle URL when publication fails")
    func cloneVMPublishFailureLeavesNothingBehind() async throws {
        let storage = MockVMStorageService()
        storage.publishBundleError = VMStorageError.bundleAlreadyExists(
            URL(filePath: "/tmp/occupied.kernova"))
        let (viewModel, _, _, _, _) = makeViewModel(storageService: storage)
        let instance = VMInstanceFixture.make(name: "Clone Source")
        instance.activity.placeForTesting(.stopped)
        viewModel.library.admitForTesting(instance)
        storage.bundles[instance.bundleURL] = instance.configuration

        viewModel.cloneVM(instance)
        let destination = try #require(viewModel.arrivals.first).destinationURL
        await viewModel.awaitArrivalsForTesting()

        // Every byte the clone wrote went to staging, so a publication that never
        // happened leaves the clone's own bundle URL untouched.
        #expect(viewModel.entries.map(\.id) == [instance.id])
        #expect(storage.bundles[destination] == nil)
        #expect(
            !FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)))
        #expect(presenter.showError == true)
        let staged = try #require(storage.stagedBundleURLs.last)
        #expect(storage.discardedStagedURLs == [staged])
    }

    @Test("cloneVM is skipped when VM is running")
    func cloneVMSkippedWhenRunning() async {
        let (viewModel, storage, _, _, _) = makeViewModel()
        let instance = VMInstanceFixture.make(name: "Running VM")
        instance.activity.placeForTesting(.running(sessionID: UUID()))
        viewModel.library.admitForTesting(instance)

        viewModel.cloneVM(instance)

        #expect(viewModel.entries.count == 1)
        #expect(storage.cloneVMBundleCallCount == 0)
    }

    @Test("cloneVM proceeds while an import is preparing (#487 — clone/import can't collide)")
    func cloneVMProceedsWhileImportPreparing() async throws {
        try await cloneProceeds(beside: .importing)
    }

    @Test("cloneVM proceeds while another clone is preparing (#487 — UUID-named bundles can't collide)")
    func cloneVMProceedsWhileAnotherCloneIsPreparing() async throws {
        try await cloneProceeds(beside: .cloning(sourceID: UUID()))
    }

    /// Clones a VM while an arrival of `kind` for another VM is still writing.
    private func cloneProceeds(beside kind: VMArrival.Kind) async throws {
        let (viewModel, storage, _, _, _) = makeViewModel()
        let gate = GatedStep()
        let existing = viewModel.library.beginGatedArrival(kind, named: "In Flight", gate: gate)
        let instance = VMInstanceFixture.make(name: "Source")
        instance.activity.placeForTesting(.stopped)
        viewModel.library.admitForTesting(instance)
        storage.bundles[instance.bundleURL] = instance.configuration

        viewModel.cloneVM(instance)

        let clone = try #require(viewModel.arrivals.first { $0.id != existing.id })
        await clone.settle()

        #expect(viewModel.entries.count == 3)
        #expect(viewModel.instances.map(\.id).contains(clone.id))
        #expect(presenter.showError == false)

        gate.release()
        await existing.settle()
    }

    @Test("cloneVM increments name when Copy already exists")
    func cloneVMIncrementsName() async {
        let (viewModel, storage, _, _, _) = makeViewModel()
        let instance = VMInstanceFixture.make(name: "VM")
        instance.activity.placeForTesting(.stopped)
        let copyInstance = VMInstanceFixture.make(name: "VM Copy")
        viewModel.library.admitForTesting([instance, copyInstance])
        storage.bundles[instance.bundleURL] = instance.configuration

        viewModel.cloneVM(instance)

        #expect(viewModel.arrivals.first?.name == "VM Copy 2")
        await viewModel.awaitArrivalsForTesting()
    }

    @Test("cloneVM remaps internal additional disk path to its regenerated id and copies the file")
    func cloneVMRemapsAdditionalDiskPath() async throws {
        let (viewModel, storage, _, _, _) = makeViewModel()

        // Build a source bundle on disk with a real additional-disk file
        // living at `AdditionalDisks/<source-disk-id>.asif`.
        let sourceDiskID = UUID()
        let instance = VMInstanceFixture.make(name: "Original") {
            $0.storageDisks = [
                StorageDisk(path: "Disk.asif", isInternal: true),
                StorageDisk(
                    id: sourceDiskID,
                    path: "AdditionalDisks/\(sourceDiskID.uuidString).asif",
                    label: "Extra",
                    isInternal: true
                ),
            ]
        }
        instance.activity.placeForTesting(.stopped)
        let sourceLayout = VMBundleLayout(bundleURL: instance.bundleURL)
        let fm = FileManager.default
        try fm.createDirectory(at: sourceLayout.additionalDisksDirectoryURL, withIntermediateDirectories: true)
        let sourceDiskFile = sourceLayout.additionalDiskURL(id: sourceDiskID)
        try Data("disk-bytes".utf8).write(to: sourceDiskFile)
        defer { try? fm.removeItem(at: instance.bundleURL) }

        viewModel.library.admitForTesting(instance)
        storage.bundles[instance.bundleURL] = instance.configuration

        viewModel.cloneVM(instance)
        await viewModel.awaitArrivalsForTesting()

        let clone = viewModel.instances.first { $0.id != instance.id }
        #expect(clone != nil)
        defer { clone.map { try? fm.removeItem(at: $0.bundleURL) } }

        let clonedDisks = clone?.configuration.storageDisks ?? []
        guard let extra = clonedDisks.first(where: { $0.path.hasPrefix("AdditionalDisks/") }) else {
            Issue.record("Cloned configuration is missing the additional disk")
            return
        }

        // The path must point at the regenerated id, not the source's id,
        // and the copied file must exist at exactly that resolved location.
        #expect(extra.id != sourceDiskID)
        #expect(extra.path == "AdditionalDisks/\(extra.id.uuidString).asif")
        if let clone {
            let resolved = clone.bundleURL.appendingPathComponent(extra.path)
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
        let instance = VMInstanceFixture.make(name: "Original", guestOS: guestOS) {
            if guestOS == .macOS {
                $0.machineIdentifierData = machineID
            } else {
                $0.genericMachineIdentifierData = machineID
            }
        }
        instance.activity.placeForTesting(.stopped)
        viewModel.library.admitForTesting(instance)
        storage.bundles[instance.bundleURL] = instance.configuration
        return instance
    }

    /// The identity field `guestOS` uses, read off the clone `viewModel`
    /// produced from `source` once its copy task has settled.
    private func clonedMachineID(
        of source: VMInstance, in viewModel: VMLibraryViewModel, guestOS: VMGuestOS
    ) async -> Data? {
        await viewModel.awaitArrivalsForTesting()
        let clone = viewModel.instances.first { $0.id != source.id }
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

    @Test("cancelArrival marks the row Cancelling… and keeps it until the copy settles (#496)")
    func cancelArrivalMarksCancelling() async throws {
        let (viewModel, storage, _, _, _) = makeViewModel()
        let gate = GatedStep()
        let arrival = viewModel.library.beginGatedArrival(
            .cloning(sourceID: UUID()), named: "Cloning VM", gate: gate)
        viewModel.selectedID = arrival.id

        viewModel.cancelArrival(arrival)
        try await waitForChange { arrival.stage == .cancelling }

        // The uninterruptible copy is still in flight, so the row stays as "Cancelling…";
        // the arrival removes it, and discards what it wrote, once the copy settles.
        #expect(viewModel.entries.map(\.id) == [arrival.id])
        #expect(arrival.displayLabel == "Cancelling\u{2026}")

        gate.release()
        #expect(await arrival.settle() == nil)
        #expect(viewModel.entries.isEmpty)
        #expect(storage.discardedStagedURLs == storage.stagedBundleURLs)
        #expect(presenter.showError == false)
    }

    @Test("cancelArrival selects the remaining instance after the copy settles (#496)")
    func cancelArrivalSelectsRemaining() async throws {
        let (viewModel, _, _, _, _) = makeViewModel()
        let other = VMInstanceFixture.make(name: "Other VM")
        viewModel.library.admitForTesting(other)
        let gate = GatedStep()
        let arrival = viewModel.library.beginGatedArrival(named: "Cancel Me", gate: gate)
        #expect(viewModel.selectedID == arrival.id)

        viewModel.cancelArrival(arrival)
        try await waitForChange { arrival.stage == .cancelling }
        gate.release()
        await arrival.settle()

        #expect(viewModel.entries.map(\.id) == [other.id])
        #expect(viewModel.selectedID == other.id)
    }

    @Test("A cancel confirmed after the copy settled leaves the VM it became")
    func cancelAfterSettleLeavesTheVM() async throws {
        let (viewModel, storage, _, _, _) = makeViewModel()
        let gate = GatedStep()
        let arrival = viewModel.library.beginGatedArrival(named: "Settled Import", gate: gate)
        gate.release()
        let instance = try #require(await arrival.settle())

        // The confirmation outlived the arrival: nothing is being prepared any
        // more, so the stale confirm is refused and logged rather than trashing
        // the VM the user now has.
        viewModel.cancelArrival(arrival)

        #expect(viewModel.instances.map(\.id) == [instance.id])
        #expect(storage.deleteVMBundleCallCount == 0)
        #expect(fileSystem.trashedURLs.isEmpty)
        #expect(presenter.showError == false)
    }

    @Test("requestCancelPreparing sets state for alert")
    func requestCancelPreparingSetsState() async {
        let (viewModel, _, _, _, _) = makeViewModel()
        let gate = GatedStep()
        let arrival = viewModel.library.beginGatedArrival(
            .cloning(sourceID: UUID()), named: "Cloning VM", gate: gate)

        viewModel.requestCancelPreparing(arrival)

        #expect(presenter.showCancelPreparingConfirmation == true)
        #expect(presenter.arrivalToCancel === arrival)

        gate.release()
        await arrival.settle()
    }

    // MARK: - Force Stop Confirmation

    @Test("requestForceStop sets instance and shows confirmation")
    func requestForceStop() {
        let (viewModel, _, _, _, _) = makeViewModel()
        let instance = VMInstanceFixture.make()
        instance.activity.placeForTesting(.running(sessionID: UUID()))
        viewModel.library.admitForTesting(instance)

        viewModel.requestForceStop(instance)

        #expect(presenter.instanceToForceStop?.id == instance.id)
        #expect(presenter.showForceStopConfirmation == true)
    }

    @Test("forceStopVerb delegates to lifecycle")
    func forceStopVerb() async {
        let (viewModel, _, _, virtService, _) = makeViewModel()
        let instance = VMInstanceFixture.make()
        instance.activity.placeForTesting(.running(sessionID: UUID()))
        viewModel.library.admitForTesting(instance)

        await viewModel.forceStop(instance)

        #expect(virtService.forceStopCallCount == 1)
        #expect(instance.status == .stopped)
    }

    // MARK: - Reorder

    @Test("moveEntries reorders instances and persists order to UserDefaults")
    func moveEntriesReordersAndPersists() {
        let (viewModel, _, _, _, _) = makeViewModel()
        let a = VMInstanceFixture.make(name: "A")
        let b = VMInstanceFixture.make(name: "B")
        let c = VMInstanceFixture.make(name: "C")
        viewModel.library.admitForTesting([a, b, c])

        viewModel.moveEntries(fromOffsets: IndexSet(integer: 2), toOffset: 0)

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
            fileSystem: MockFileSystem(),
            downloadsDirectory: nil,
            preferences: preferences,
            vmnetNetworks: MockVmnetNetworkProvider(), arpTable: ScriptedARPTable(), entitlements: .entitled
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
        let a = VMInstanceFixture.make(name: "A")
        let b = VMInstanceFixture.make(name: "B")
        viewModel.library.admitForTesting([a, b])
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
            fileSystem: MockFileSystem(),
            downloadsDirectory: nil,
            preferences: preferences,
            vmnetNetworks: MockVmnetNetworkProvider(), arpTable: ScriptedARPTable(), entitlements: .entitled
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
        let mock = MockRemovableMediaDeviceService()
        let (viewModel, _, _, _, _) = makeViewModel(removableMediaDeviceService: mock)
        let instance = VMInstanceFixture.make(guestOS: .macOS)
        instance.activity.placeForTesting(.running(sessionID: UUID()))
        instance.beginSessionContext()
        viewModel.library.admitForTesting(instance)

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
        let mock = MockRemovableMediaDeviceService()
        let (viewModel, _, _, _, _) = makeViewModel(removableMediaDeviceService: mock)
        let instance = VMInstanceFixture.make(guestOS: .macOS) {
            $0.removableMedia = [
                RemovableMediaItem(path: installerURL.path(percentEncoded: false), readOnly: true)
            ]
        }
        instance.activity.placeForTesting(.running(sessionID: UUID()))
        viewModel.library.admitForTesting(instance)

        viewModel.mountGuestAgentInstaller(on: instance)

        #expect(mock.attachCallCount == 0)
        #expect(presenter.showInstallerMountedAlert == true)
        #expect(presenter.installerMountedVMName == instance.name)
        // List unchanged
        #expect(instance.configuration.removableMedia?.count == 1)
    }

    @Test("mountGuestAgentInstaller forwards the .manage purpose to the alert")
    func mountGuestAgentInstallerManagePurpose() throws {
        _ = try #require(KernovaMacOSAgentInfo.installerDiskImageURL)
        let (viewModel, _, _, _, _) = makeViewModel()
        let instance = VMInstanceFixture.make(guestOS: .macOS)
        instance.activity.placeForTesting(.running(sessionID: UUID()))
        viewModel.library.admitForTesting(instance)

        viewModel.mountGuestAgentInstaller(on: instance, purpose: .manage)

        #expect(presenter.installerMountedPurpose == .manage)
        #expect(presenter.installerMountedDelivery == .usb)
    }

    @Test("mountGuestAgentInstaller attaches nothing for a guest that takes the disk on virtio")
    func mountGuestAgentInstallerVirtioAttachesNothing() async throws {
        _ = try #require(KernovaMacOSAgentInfo.installerDiskImageURL)
        let mock = MockRemovableMediaDeviceService()
        let (viewModel, _, _, _, _) = makeViewModel(removableMediaDeviceService: mock)
        let instance = VMInstanceFixture.make(guestOS: .macOS) {
            $0.installedImage = .macOSRestoreImage(version: "12.0.1", build: "21A559")
        }
        instance.activity.placeForTesting(.running(sessionID: UUID()))
        viewModel.library.admitForTesting(instance)

        viewModel.mountGuestAgentInstaller(on: instance)
        await Task.yield()

        #expect(presenter.showInstallerMountedAlert == true)
        #expect(presenter.installerMountedDelivery == .virtio)
        // The disk rides in on `storageDevices` at boot, so neither the
        // removable-media list nor the persisted disk list may grow.
        #expect(instance.configuration.removableMedia == nil)
        #expect(instance.configuration.storageDisks == nil)
        #expect(mock.attachCallCount == 0)
        #expect(!instance.hasGuestAgentInstallerMounted)
    }

    @Test("onAgentBecameCurrent (wired by loadVMs) auto-ejects the installer disk")
    func onAgentBecameCurrentAutoEjectsInstaller() async throws {
        let installerURL = try #require(KernovaMacOSAgentInfo.installerDiskImageURL)
        let storage = MockVMStorageService()
        var config = VMConfiguration(name: "Wired VM", guestOS: .macOS, bootMode: .macOS)
        config.removableMedia = [
            RemovableMediaItem(path: installerURL.path(percentEncoded: false), readOnly: true)
        ]
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(config.id.uuidString).kernova", isDirectory: true)
        storage.bundles[url] = config
        let (viewModel, _, _, _, _) = makeViewModel(storageService: storage)
        await viewModel.loadVMs()
        let instance = try #require(viewModel.instances.first)

        #expect(instance.hasGuestAgentInstallerMounted)

        // Fire the hook the view model wired in `wireHooks(for:)` — it
        // must detach the installer regardless of which window is open.
        instance.onAgentBecameCurrent?()

        #expect(!instance.hasGuestAgentInstallerMounted)
        #expect(instance.configuration.removableMedia == nil)
    }

    // MARK: - Storage Disk Helpers

    @Test("An edit naming an attachment that is already gone raises no alert")
    func staleAttachmentEditIsSilent() {
        let (viewModel, _, _, _, _) = makeViewModel()
        let instance = VMInstanceFixture.make()
        viewModel.library.admitForTesting(instance)

        // The verb refuses — a rename field can commit after its row went — and
        // the adapter logs rather than putting a second alert in front of a
        // user who can already see the row is gone.
        viewModel.renameStorageDisk(UUID(), newLabel: "New", on: instance)
        viewModel.setRemovableMediaNotes(UUID(), notes: "New", on: instance)

        #expect(!presenter.showError)
    }

    @Test("sharingVMNames lists other VMs referencing a path and excludes the instance")
    func sharingVMNamesDetectsAndExcludes() async throws {
        let (viewModel, _, _, _, _) = makeViewModel()
        let sharedPath = "/Volumes/External/shared.img"
        let target = VMInstanceFixture.make(name: "Target") {
            $0.storageDisks = [
                StorageDisk(
                    path: sharedPath, readOnly: false, label: "S", isInternal: false, kind: .virtio)
            ]
        }
        let diskSharer = VMInstanceFixture.make(name: "DiskSharer") {
            $0.storageDisks = [
                StorageDisk(
                    path: sharedPath, readOnly: false, label: "S", isInternal: false, kind: .virtio)
            ]
        }
        let mediaSharer = VMInstanceFixture.make(name: "MediaSharer") {
            $0.removableMedia = [RemovableMediaItem(path: sharedPath, readOnly: true)]
        }
        let unrelated = VMInstanceFixture.make(name: "Unrelated")
        viewModel.library.admitForTesting([target, diskSharer, mediaSharer, unrelated])

        let names = await viewModel.sharingVMNames(forPath: sharedPath, bookmark: nil, excluding: target)
        #expect(Set(names) == ["DiskSharer", "MediaSharer"])

        // A unique path is shared with no one.
        let unique = await viewModel.sharingVMNames(
            forPath: "/Volumes/External/unique.img", bookmark: nil, excluding: target)
        #expect(unique.isEmpty)
    }

    @Test("sharingVMNames ignores internal (bundle-relative) disks")
    func sharingVMNamesIgnoresInternalDisks() async {
        let (viewModel, _, _, _, _) = makeViewModel()
        let a = VMInstanceFixture.make(name: "A") {
            $0.storageDisks = [
                StorageDisk(
                    path: "Disk.asif", readOnly: false, label: "Main", isInternal: true,
                    kind: .virtio)
            ]
        }
        let b = VMInstanceFixture.make(name: "B") {
            $0.storageDisks = [
                StorageDisk(
                    path: "Disk.asif", readOnly: false, label: "Main", isInternal: true,
                    kind: .virtio)
            ]
        }
        viewModel.library.admitForTesting([a, b])
        // Same relative path, but both are bundle-internal → not shared.
        let shared = await viewModel.sharingVMNames(forPath: "Disk.asif", bookmark: nil, excluding: a)
        #expect(shared.isEmpty)
    }

    @Test("A read for a VM the library no longer holds answers empty and raises nothing")
    func readsForADepartedVMAnswerEmpty() async {
        let (viewModel, _, _, _, _) = makeViewModel()
        let sharedPath = "/Volumes/External/shared.img"
        let departed = VMInstanceFixture.make(name: "Departed") {
            $0.storageDisks = [
                StorageDisk(
                    path: sharedPath, readOnly: false, label: "S", isInternal: false, kind: .virtio)
            ]
        }
        departed.seedSnapshotManifest(VMSnapshotManifest(snapshots: [VMSnapshot(name: "Base", macAddress: nil)]))
        let sharer = VMInstanceFixture.make(name: "Sharer") {
            $0.storageDisks = [
                StorageDisk(
                    path: sharedPath, readOnly: false, label: "S", isInternal: false, kind: .virtio)
            ]
        }
        viewModel.library.admitForTesting([sharer])

        // Where a sheet is left when its VM leaves the library while it is still
        // up: every read addresses the VM by id, and every one is refused.
        #expect(await viewModel.snapshotOnDiskBytes(for: departed).isEmpty)
        #expect(await viewModel.externalAttachments(for: departed).isEmpty)
        #expect(
            await viewModel.sharingVMNames(
                forPath: sharedPath, bookmark: nil, excluding: departed
            ).isEmpty)
        // There is nothing left for the user to act on, so nothing is put in
        // front of them.
        #expect(!presenter.showError)

        // Listed, the same three answer — so the emptiness above is the refusal
        // rather than an empty subject.
        viewModel.library.admitForTesting(departed)
        #expect(await viewModel.snapshotOnDiskBytes(for: departed).count == 1)
        #expect(await viewModel.externalAttachments(for: departed).count == 1)
        #expect(
            await viewModel.sharingVMNames(
                forPath: sharedPath, bookmark: nil, excluding: departed) == ["Sharer"])
    }

    // MARK: - Reconcile Rollback

    @Test("Reorder-only removableMedia change triggers no detach/attach")
    func liveRemovableReorderIsNoOp() async throws {
        let mock = MockRemovableMediaDeviceService()
        let (viewModel, _, _, _, _) = makeViewModel(removableMediaDeviceService: mock)
        let idA = UUID()
        let idB = UUID()
        let instance = VMInstanceFixture.make {
            $0.removableMedia = [
                RemovableMediaItem(id: idA, path: "/tmp/a.iso", readOnly: true),
                RemovableMediaItem(id: idB, path: "/tmp/b.iso", readOnly: true),
            ]
        }
        let sessionID = UUID()
        instance.activity.placeForTesting(.running(sessionID: sessionID))
        instance.beginSessionContext()
        instance.recordAttachedMedia(
            RemovableMediaDeviceInfo(id: idA, path: "/tmp/a.iso", readOnly: true), for: sessionID)
        instance.recordAttachedMedia(
            RemovableMediaDeviceInfo(id: idB, path: "/tmp/b.iso", readOnly: true), for: sessionID)
        viewModel.library.admitForTesting(instance)

        viewModel.library.editConfiguration(of: instance) {
            $0.removableMedia = [
                // Swapped order; identical items.
                RemovableMediaItem(id: idB, path: "/tmp/b.iso", readOnly: true),
                RemovableMediaItem(id: idA, path: "/tmp/a.iso", readOnly: true),
            ]
        }
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
        let mock = MockRemovableMediaDeviceService()
        mock.detachError = TransientError()
        let (viewModel, _, _, _, _) = makeViewModel(removableMediaDeviceService: mock)
        let id = UUID()
        let instance = VMInstanceFixture.make {
            $0.removableMedia = [RemovableMediaItem(id: id, path: "/tmp/old.iso", readOnly: true)]
        }
        let sessionID = UUID()
        instance.activity.placeForTesting(.running(sessionID: sessionID))
        instance.beginSessionContext()
        instance.recordAttachedMedia(
            RemovableMediaDeviceInfo(id: id, path: "/tmp/old.iso", readOnly: true), for: sessionID)
        viewModel.library.admitForTesting(instance)

        // The user's removal intent persists — config says "no media", live
        // still has it.
        viewModel.library.editConfiguration(of: instance) { $0.removableMedia = nil }
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
        let mock = MockRemovableMediaDeviceService()
        mock.attachError = TransientError()
        let (viewModel, _, _, _, _) = makeViewModel(removableMediaDeviceService: mock)
        let instance = VMInstanceFixture.make()
        instance.activity.placeForTesting(.running(sessionID: UUID()))
        instance.beginSessionContext()
        let id = UUID()
        viewModel.library.admitForTesting(instance)

        // The user added a removable item; it persists before the live
        // attach runs.
        viewModel.library.editConfiguration(of: instance) {
            $0.removableMedia = [
                RemovableMediaItem(id: id, path: "/tmp/missing.iso", readOnly: true)
            ]
        }
        while !presenter.showError { await Task.yield() }
        for _ in 0..<5 { await Task.yield() }

        // Attach failed → device never mounted → config rolled back to nil.
        #expect(instance.configuration.removableMedia == nil)
    }

    @Test("Failed swap rollback preserves the entry's label and note")
    func liveRemovableRollbackOnSwapFailurePreservesLabelAndNotes() async throws {
        struct TransientError: Error {}
        let mock = MockRemovableMediaDeviceService()
        mock.detachError = TransientError()
        let (viewModel, _, _, _, _) = makeViewModel(removableMediaDeviceService: mock)
        let id = UUID()
        var oldItem = RemovableMediaItem(id: id, path: "/tmp/old.iso", readOnly: true, label: "Installer")
        oldItem.notes = "from the Ubuntu mirror"
        let instance = VMInstanceFixture.make { $0.removableMedia = [oldItem] }
        let sessionID = UUID()
        instance.activity.placeForTesting(.running(sessionID: sessionID))
        instance.beginSessionContext()
        instance.recordAttachedMedia(
            RemovableMediaDeviceInfo(id: id, path: "/tmp/old.iso", readOnly: true), for: sessionID)
        viewModel.library.admitForTesting(instance)

        // Same id, different path (path swap) — the target persists, carrying
        // the label and note forward since only the path/readOnly changed.
        var newItem = oldItem
        newItem.path = "/tmp/new.iso"
        viewModel.library.editConfiguration(of: instance) { $0.removableMedia = [newItem] }
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
        let mock = MockRemovableMediaDeviceService()
        mock.detachError = TransientError()
        let (viewModel, _, _, _, _) = makeViewModel(removableMediaDeviceService: mock)
        let id = UUID()
        let instance = VMInstanceFixture.make {
            $0.removableMedia = [RemovableMediaItem(id: id, path: "/tmp/old.iso", readOnly: true)]
        }
        let sessionID = UUID()
        instance.activity.placeForTesting(.running(sessionID: sessionID))
        instance.beginSessionContext()
        instance.recordAttachedMedia(
            RemovableMediaDeviceInfo(id: id, path: "/tmp/old.iso", readOnly: true), for: sessionID)
        viewModel.library.admitForTesting(instance)

        // Same id, different path (path swap) — the target persists.
        viewModel.library.editConfiguration(of: instance) {
            $0.removableMedia = [RemovableMediaItem(id: id, path: "/tmp/new.iso", readOnly: true)]
        }
        while !presenter.showError { await Task.yield() }
        for _ in 0..<5 { await Task.yield() }

        let rolled = try #require(instance.configuration.removableMedia)
        #expect(rolled.count == 1)
        #expect(rolled.first?.id == id)
        // Critical: path is the ORIGINAL one, not the failed-swap target.
        #expect(rolled.first?.path == "/tmp/old.iso")
    }

    // MARK: - Remembered USB accessories

    /// A view model that can pass accessories through, and one VM in its
    /// library remembering `key`.
    ///
    /// The VM's bundle directory is never created, so the pairing write cannot
    /// reach disk — which is the failure under test.
    private func makeViewModelRememberingAnAccessory(key: String) -> (
        VMLibraryViewModel, VMInstance
    ) {
        let viewModel = VMLibraryViewModel(
            storageService: MockVMStorageService(),
            diskImageService: MockDiskImageService(),
            virtualizationService: MockVirtualizationService(),
            installService: MockMacOSInstallService(),
            ipswService: MockIPSWService(),
            removableMediaDeviceService: MockRemovableMediaDeviceService(),
            usbAccessoryService: MockUSBAccessoryService(),
            fileSystem: fileSystem,
            downloadsDirectory: nil,
            preferences: preferences,
            vmnetNetworks: MockVmnetNetworkProvider(), arpTable: ScriptedARPTable(), entitlements: .entitled
        )
        viewModel.presenter = presenter
        let instance = VMInstanceFixture.make(name: "Work")
        viewModel.library.wireHooks(for: instance)
        viewModel.library.admitForTesting(instance)
        instance.seedUSBPairings(
            USBAccessoryPairingSet(pairings: [
                USBAccessoryPairing(
                    key: key, form: .serialNumber, displayName: "Samsung Type-C",
                    receptacleLabel: nil)
            ]))
        return (viewModel, instance)
    }

    @Test("A remembered accessory that cannot be forgotten on disk says so")
    func forgetUSBAccessoryReportsAFailedWrite() {
        let (viewModel, instance) = makeViewModelRememberingAnAccessory(key: "k")
        instance.fixtureBundleFiles.setReplaceError(
            CocoaError(.fileWriteUnknown), for: VMBundleLayout.usbPairingsRelativePath)

        viewModel.forgetUSBAccessory(key: "k", on: instance)

        // Silence would take the row off the list while the rule stayed in the
        // bundle, and the accessory would go back to this VM at the next launch.
        #expect(presenter.showError)
    }

    @Test("Forgetting an accessory the virtual machine does not remember says so")
    func forgetUSBAccessoryReportsAMiss() {
        let (viewModel, instance) = makeViewModelRememberingAnAccessory(key: "k")

        viewModel.forgetUSBAccessory(key: "nope", on: instance)

        #expect(presenter.showError)
        #expect(instance.usbPairings.pairings.map(\.key) == ["k"])
    }
}

/// Counts the quits the command core asked the adapter to perform.
@MainActor
private final class QuitHookRecorder {
    private(set) var count = 0
    let gate = AsyncGate()

    func record() {
        count += 1
        gate.notify()
    }
}
