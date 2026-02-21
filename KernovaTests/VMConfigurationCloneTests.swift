import Testing
import Foundation
@testable import Kernova

@Suite("VMConfiguration Clone Tests")
struct VMConfigurationCloneTests {

    private func makeConfig(
        name: String = "My VM",
        guestOS: VMGuestOS = .linux,
        bootMode: VMBootMode = .efi,
        prefersFullscreen: Bool = true,
        notes: String = "Some notes",
        sharedDirectories: [SharedDirectory]? = nil,
        hardwareModelData: Data? = nil
    ) -> VMConfiguration {
        VMConfiguration(
            name: name,
            guestOS: guestOS,
            bootMode: bootMode,
            prefersFullscreen: prefersFullscreen,
            hardwareModelData: hardwareModelData,
            sharedDirectories: sharedDirectories,
            notes: notes
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

    @Test("Clone appends ' Copy 3' when ' Copy' and ' Copy 2' already exist")
    func cloneNameCopy3() {
        let clone = makeConfig(name: "Ubuntu").clonedForNewInstance(
            existingNames: ["Ubuntu", "Ubuntu Copy", "Ubuntu Copy 2"]
        )
        #expect(clone.name == "Ubuntu Copy 3")
    }

    @Test("generateCloneName returns ' Copy' when no conflicts")
    func generateCloneNameNoConflict() {
        let name = VMConfiguration.generateCloneName(baseName: "VM", existingNames: ["VM"])
        #expect(name == "VM Copy")
    }

    @Test("generateCloneName skips to next available number")
    func generateCloneNameSkips() {
        let name = VMConfiguration.generateCloneName(
            baseName: "VM",
            existingNames: ["VM", "VM Copy", "VM Copy 2", "VM Copy 3"]
        )
        #expect(name == "VM Copy 4")
    }

    // MARK: - Preserved Settings

    @Test("Clone preserves resource settings")
    func clonePreservesResources() {
        let original = VMConfiguration(
            name: "Test",
            guestOS: .linux,
            bootMode: .efi,
            cpuCount: 8,
            memorySizeInGB: 16,
            diskSizeInGB: 128
        )
        let clone = original.clonedForNewInstance(existingNames: [])

        #expect(clone.cpuCount == 8)
        #expect(clone.memorySizeInGB == 16)
        #expect(clone.diskSizeInGB == 128)
    }

    @Test("Clone preserves display settings")
    func clonePreservesDisplay() {
        let original = VMConfiguration(
            name: "Test",
            guestOS: .linux,
            bootMode: .efi,
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
            networkEnabled: true,
            macAddress: "aa:bb:cc:dd:ee:ff"
        )
        let clone = original.clonedForNewInstance(existingNames: [])

        #expect(clone.networkEnabled == true)
        // macAddress is copied as-is; caller regenerates it
        #expect(clone.macAddress == "aa:bb:cc:dd:ee:ff")
    }

    @Test("Clone preserves guest OS and boot mode")
    func clonePreservesOSAndBoot() {
        let original = makeConfig(guestOS: .linux, bootMode: .linuxKernel)
        let clone = original.clonedForNewInstance(existingNames: [])

        #expect(clone.guestOS == .linux)
        #expect(clone.bootMode == .linuxKernel)
    }

    @Test("Clone preserves notes")
    func clonePreservesNotes() {
        let clone = makeConfig(notes: "Important notes").clonedForNewInstance(existingNames: [])
        #expect(clone.notes == "Important notes")
    }

    @Test("Clone preserves macOS hardware model data")
    func clonePreservesHardwareModelData() {
        let hwData = Data([0x01, 0x02, 0x03])
        let clone = makeConfig(hardwareModelData: hwData).clonedForNewInstance(existingNames: [])
        #expect(clone.hardwareModelData == hwData)
    }

    // MARK: - Reset Fields

    @Test("Clone resets prefersFullscreen to false")
    func cloneResetsPrefersFullscreen() {
        let clone = makeConfig(prefersFullscreen: true).clonedForNewInstance(existingNames: [])
        #expect(clone.prefersFullscreen == false)
    }

    // MARK: - Shared Directories

    @Test("Clone regenerates shared directory IDs")
    func cloneRegeneratesSharedDirectoryIDs() {
        let dirs = [
            SharedDirectory(path: "/Users/test/Documents", readOnly: false),
            SharedDirectory(path: "/Users/test/Downloads", readOnly: true),
        ]
        let original = makeConfig(sharedDirectories: dirs)
        let clone = original.clonedForNewInstance(existingNames: [])

        #expect(clone.sharedDirectories?.count == 2)
        #expect(clone.sharedDirectories?[0].id != original.sharedDirectories?[0].id)
        #expect(clone.sharedDirectories?[1].id != original.sharedDirectories?[1].id)
    }

    @Test("Clone preserves shared directory paths and readOnly flags")
    func clonePreservesSharedDirectoryPaths() {
        let dirs = [
            SharedDirectory(path: "/Users/test/Documents", readOnly: false),
            SharedDirectory(path: "/Users/test/ReadOnly", readOnly: true),
        ]
        let original = makeConfig(sharedDirectories: dirs)
        let clone = original.clonedForNewInstance(existingNames: [])

        #expect(clone.sharedDirectories?[0].path == "/Users/test/Documents")
        #expect(clone.sharedDirectories?[0].readOnly == false)
        #expect(clone.sharedDirectories?[1].path == "/Users/test/ReadOnly")
        #expect(clone.sharedDirectories?[1].readOnly == true)
    }

    @Test("Clone with nil shared directories remains nil")
    func cloneNilSharedDirectories() {
        let clone = makeConfig(sharedDirectories: nil).clonedForNewInstance(existingNames: [])
        #expect(clone.sharedDirectories == nil)
    }
}
