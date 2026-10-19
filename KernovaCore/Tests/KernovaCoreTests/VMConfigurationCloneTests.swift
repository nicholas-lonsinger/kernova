import Foundation
import KernovaKit
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

    // MARK: - Identity

    @Test("Clone generates a new UUID")
    func cloneNewUUID() {
        let original = makeConfig()
        let clone = original.clonedForNewInstance(existingNames: [])
        #expect(clone.id != original.id)
    }

    @Test("Clone generates a new creation date")
    func cloneNewCreationDate() {
        let original = VMConfiguration(
            name: "Old VM",
            guestOS: .linux,
            bootMode: .efi,
            cpuCount: VMGuestOS.linux.hostCPUCount,
            memorySizeInGB: VMGuestOS.linux.hostMemorySize,
            createdAt: Date.distantPast
        )
        let clone = original.clonedForNewInstance(existingNames: [])
        #expect(clone.createdAt > original.createdAt)
    }

    // MARK: - Name Generation

    @Test("Clone appends ' Copy' to the name")
    func cloneNameCopy() {
        let clone = makeConfig(name: "Ubuntu").clonedForNewInstance(existingNames: ["Ubuntu"])
        #expect(clone.name == "Ubuntu Copy")
    }

    @Test("Clone appends ' Copy 2' when ' Copy' already exists")
    func cloneNameCopy2() {
        let clone = makeConfig(name: "Ubuntu").clonedForNewInstance(
            existingNames: ["Ubuntu", "Ubuntu Copy"]
        )
        #expect(clone.name == "Ubuntu Copy 2")
    }

    // MARK: - Preserved Settings

    @Test("Clone preserves resource settings")
    func clonePreservesResources() {
        let original = VMConfiguration(
            name: "Test",
            guestOS: .linux,
            bootMode: .efi,
            cpuCount: 8,
            memorySizeInGB: .gibibytes(16)
        )
        let clone = original.clonedForNewInstance(existingNames: [])

        #expect(clone.cpuCount == 8)
        #expect(clone.memorySizeInGB == .gibibytes(16))
    }

    @Test("Clone preserves display settings")
    func clonePreservesDisplay() {
        let original = VMConfiguration(
            name: "Test",
            guestOS: .linux,
            bootMode: .efi,
            cpuCount: VMGuestOS.linux.hostCPUCount,
            memorySizeInGB: VMGuestOS.linux.hostMemorySize,
            displayWidth: 2560,
            displayHeight: 1440,
            displayPPI: 218
        )
        let clone = original.clonedForNewInstance(existingNames: [])

        #expect(clone.displayWidth == 2560)
        #expect(clone.displayHeight == 1440)
        #expect(clone.displayPPI == 218)
    }

    @Test("Clone preserves network settings")
    func clonePreservesNetwork() {
        let original = VMConfiguration(
            name: "Test",
            guestOS: .linux,
            bootMode: .efi,
            cpuCount: VMGuestOS.linux.hostCPUCount,
            memorySizeInGB: VMGuestOS.linux.hostMemorySize,
            networkEnabled: true,
            macAddress: "aa:bb:cc:dd:ee:ff"
        )
        let clone = original.clonedForNewInstance(existingNames: [])

        #expect(clone.networkEnabled == true)
        #expect(clone.networkMode == .nat)
        // Copied as-is: the clone's caller decides it with the machine identity.
        #expect(clone.macAddress == "aa:bb:cc:dd:ee:ff")
    }

    @Test("Clone preserves the bridged mode and its interface")
    func clonePreservesBridgedInterface() {
        let original = VMConfiguration(
            name: "Test",
            guestOS: .linux,
            bootMode: .efi,
            cpuCount: VMGuestOS.linux.hostCPUCount,
            memorySizeInGB: VMGuestOS.linux.hostMemorySize,
            networkMode: .bridged,
            bridgedInterfaceIdentifier: "en0"
        )
        let clone = original.clonedForNewInstance(existingNames: [])

        #expect(clone.networkMode == .bridged)
        #expect(clone.bridgedInterfaceIdentifier == "en0")
    }

    @Test("Clone preserves guest OS and boot mode")
    func clonePreservesOSAndBoot() {
        let original = makeConfig(guestOS: .linux, bootMode: .linuxKernel)
        let clone = original.clonedForNewInstance(existingNames: [])

        #expect(clone.guestOS == .linux)
        #expect(clone.bootMode == .linuxKernel)
    }

    @Test("Clone preserves macOS hardware model data")
    func clonePreservesHardwareModelData() {
        let hwData = Data([0x01, 0x02, 0x03])
        let clone = makeConfig(hardwareModelData: hwData).clonedForNewInstance(existingNames: [])
        #expect(clone.hardwareModelData == hwData)
    }

    // MARK: - Shared Directories

    @Test("Clone preserves shared directory paths and readOnly flags")
    func clonePreservesSharedDirectoryPaths() {
        let dirs = [
            SharedDirectory(path: "/Users/test/Documents", readOnly: false, mountName: "1234abcd-Documents"),
            SharedDirectory(path: "/Users/test/ReadOnly", readOnly: true),
        ]
        let original = makeConfig(sharedDirectories: dirs)
        let clone = original.clonedForNewInstance(existingNames: [])

        #expect(clone.sharedDirectories?[0].path == "/Users/test/Documents")
        #expect(clone.sharedDirectories?[0].readOnly == false)
        #expect(clone.sharedDirectories?[1].path == "/Users/test/ReadOnly")
        #expect(clone.sharedDirectories?[1].readOnly == true)
        #expect(clone.sharedDirectories?.map(\.id) == original.sharedDirectories?.map(\.id))
        #expect(clone.sharedDirectories?[0].mountName == "1234abcd-Documents")
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
        config.storageDisks = disks
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

    // MARK: - lastSeenAgentVersion

    @Test("Clone preserves lastSeenAgentVersion")
    func clonePreservesLastSeenAgentVersion() {
        // The disk image is copied as part of the clone, which means the
        // installed agent comes along with it — so the persisted version is
        // still accurate for the new VM. (Without this, the clone would show
        // a spurious "install agent" badge until next boot.)
        var config = makeConfig(guestOS: .macOS, bootMode: .macOS)
        config.lastSeenAgentVersion = "0.9.2"
        let clone = config.clonedForNewInstance(existingNames: [])
        #expect(clone.lastSeenAgentVersion == "0.9.2")
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

    // MARK: - Setup Intent

    @Test("Clone clears both pending setup contexts")
    func cloneClearsSetupContexts() {
        // The clone copies the source bundle's finished artifacts, so carrying
        // either context would falsely mark it as awaiting an initial boot.
        var macOS = makeConfig(guestOS: .macOS, bootMode: .macOS)
        macOS.installContext = MacOSInstallContext(
            source: .localFile, localIPSWPath: "/tmp/restore.ipsw")
        var linux = makeConfig()
        linux.linuxInstallContext = LinuxInstallContext(source: .catalogEntry(makeLinuxCatalogEntry()))

        #expect(macOS.clonedForNewInstance(existingNames: []).installContext == nil)
        #expect(linux.clonedForNewInstance(existingNames: []).linuxInstallContext == nil)
    }

    // MARK: - Security Bookmarks

    @Test("Clone carries security bookmarks through disks, media, and shared directories")
    func cloneCarriesBookmarksThrough() {
        // The clone references the same external files, so the same access
        // grants remain valid — bookmarks must survive the ID regeneration.
        let diskBookmark = Data([0x01])
        let mediaBookmark = Data([0x02])
        let dirBookmark = Data([0x03])
        var config = makeConfig(sharedDirectories: [
            SharedDirectory(path: "/Users/test/Shared", bookmark: dirBookmark)
        ])
        config.storageDisks = [
            StorageDisk(path: "/ext/backup.img", isInternal: false, bookmark: diskBookmark)
        ]
        config.removableMedia = [
            RemovableMediaItem(path: "/tmp/install.iso", bookmark: mediaBookmark)
        ]

        let clone = config.clonedForNewInstance(existingNames: [])

        #expect(clone.storageDisks?[0].bookmark == diskBookmark)
        #expect(clone.removableMedia?[0].bookmark == mediaBookmark)
        #expect(clone.sharedDirectories?[0].bookmark == dirBookmark)
    }
}
