import Foundation
import KernovaCommandModel
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport

@Suite("VMConfiguration Clone Tests", .caseScoped)
struct VMConfigurationCloneTests {
    private func makeConfig(
        name: String = "My VM",
        guestOS: VMGuestOS = .linux,
        bootMode: VMBootMode = .efi,
        sharedDirectories: [SharedDirectory]? = nil,
        hardwareModelData: Data? = nil
    ) -> VMConfiguration {
        VMConfiguration(
            name: name,
            guestOS: guestOS,
            bootMode: bootMode,
            cpuCount: guestOS.hostCPUCount,
            memorySizeInGB: guestOS.hostMemorySize,
            hardwareModelData: hardwareModelData,
            sharedDirectories: sharedDirectories
        )
    }

    // MARK: - Shared Directories

    @Test("Clone preserves shared directory paths and readOnly flags")
    func clonePreservesSharedDirectoryPaths() {
        let dirs = [
            SharedDirectory(path: "/Users/test/Documents", readOnly: false, name: "1234abcd-Documents"),
            SharedDirectory(path: "/Users/test/ReadOnly", readOnly: true),
        ]
        let original = makeConfig(sharedDirectories: dirs)
        let clone = original.clonedForNewInstance(existingNames: [])

        #expect(clone.sharedDirectories?[0].path == "/Users/test/Documents")
        #expect(clone.sharedDirectories?[0].readOnly == false)
        #expect(clone.sharedDirectories?[1].path == "/Users/test/ReadOnly")
        #expect(clone.sharedDirectories?[1].readOnly == true)
        #expect(clone.sharedDirectories?.map(\.id) == original.sharedDirectories?.map(\.id))
        #expect(clone.sharedDirectories?[0].name == "1234abcd-Documents")
    }

    // MARK: - Storage Disks

    @Test("Clone preserves storage disk paths, labels, readOnly, isInternal, and kind")
    func clonePreservesStorageDiskFields() {
        let disks = [
            StorageDisk(path: "Disk.asif", readOnly: false, label: "Main Disk", isInternal: true, kind: .virtio),
            StorageDisk(
                path: "/ext/installer.iso", readOnly: true, label: "Installer", isInternal: false,
                kind: .usbMassStorage, notes: "weekly snapshot source"
            ),
        ]
        var config = makeConfig()
        config.storageDisks = NamedList(repairing: disks)
        let clone = config.clonedForNewInstance(existingNames: [])

        #expect(clone.storageDisks?[0].path == "Disk.asif")
        #expect(clone.storageDisks?[0].readOnly == false)
        #expect(clone.storageDisks?[0].label == "Main Disk")
        #expect(clone.storageDisks?[0].isInternal == true)
        #expect(clone.storageDisks?[0].kind == .virtio)
        #expect(clone.storageDisks?[1].path == "/ext/installer.iso")
        #expect(clone.storageDisks?[1].readOnly == true)
        #expect(clone.storageDisks?[1].label == "Installer")
        #expect(clone.storageDisks?[1].isInternal == false)
        #expect(clone.storageDisks?[1].kind == .usbMassStorage)
        #expect(clone.storageDisks?.map(\.id) == disks.map(\.id))
        #expect(clone.storageDisks?[1].notes == "weekly snapshot source")
    }

    // MARK: - Removable Media

    @Test("Clone keeps removable media item IDs")
    func clonePreservesRemovableMediaIDs() {
        let originalUUID = UUID()
        let items = [
            RemovableMediaItem(
                id: originalUUID, path: "/tmp/install.iso", readOnly: true, label: "Installer",
                notes: "from the Ubuntu mirror")
        ]
        var config = makeConfig()
        config.removableMedia = items

        let clone = config.clonedForNewInstance(existingNames: [])

        #expect(clone.removableMedia?.count == 1)
        #expect(clone.removableMedia?[0].path == "/tmp/install.iso")
        #expect(clone.removableMedia?[0].id == originalUUID)
        #expect(clone.removableMedia?[0].notes == "from the Ubuntu mirror")
    }
}
