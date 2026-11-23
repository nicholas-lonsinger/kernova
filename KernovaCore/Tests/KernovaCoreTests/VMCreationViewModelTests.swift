import Foundation
import KernovaCommandModel
import KernovaKit
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport

@Suite("VMCreationViewModel Tests", .caseScoped)
@MainActor
struct VMCreationViewModelTests {
    /// Puts a file at `path`, as an earlier download would have left one.
    private func placeFile(at path: String?) throws {
        let path = try #require(path)
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(),
            withIntermediateDirectories: true)
        #expect(FileManager.default.createFile(atPath: path, contents: Data()))
    }

    // MARK: - buildConfiguration

    @Test("buildConfiguration produces configuration with correct fields for Linux EFI")
    func buildConfigurationLinuxEFI() throws {
        let vm = VMCreationViewModel.overFakeEngine()
        vm.selectedOS = .linux
        vm.linuxBootMode = .efi
        vm.vmName = "  Test Linux  "
        vm.cpuCount = 4
        vm.memorySize = .gibibytes(8)
        vm.networkEnabled = true
        vm.selectLocalISO(path: "/path/to/ubuntu.iso", bookmark: nil)

        let config = vm.buildConfiguration()

        #expect(config.name == "Test Linux")  // trimmed
        #expect(config.guestOS == .linux)
        #expect(config.bootMode == .efi)
        #expect(config.cpuCount == 4)
        #expect(config.memorySizeInGB == .gibibytes(8))
        #expect(config.networkEnabled == true)
        #expect(config.macAddress != nil)  // generated for networking
        #expect(config.genericMachineIdentifierData != nil)  // generated for EFI
        // EFI install wizard inserts the ISO at storageDisks[0] so EFI
        // boots the installer; main disk goes to [1].
        let disks = config.storageDisks ?? []
        #expect(disks.count == 2)
        if disks.count >= 2 {
            #expect(disks[0].path == "/path/to/ubuntu.iso")
            #expect(disks[1].path == "Disk.asif")
            #expect(disks[1].isInternal)
        }
        #expect(config.kernelPath == nil)
        #expect(config.initrdPath == nil)
        #expect(config.kernelCommandLine == nil)
    }

    @Test(
        "A configuration carries the picks of its own boot mode and no other's",
        arguments: VMGuestOS.allCases, [LinuxBootMode.efi, .linuxKernel])
    func configurationCarriesOnlyItsBootModesPicks(guest: VMGuestOS, linuxBootMode: LinuxBootMode) {
        for installerOnDisk in [true, false] {
            // Every Linux pick is made before the guest is settled, as a user
            // who chose Linux, then went Back and chose the guest, leaves them.
            let vm = VMCreationViewModel.overFakeEngine()
            vm.selectedOS = .linux
            if installerOnDisk {
                vm.selectLocalISO(path: "/path/to/ubuntu.iso", bookmark: Data([0x01]))
            } else {
                vm.selectLinuxCatalogEntry(makeLinuxCatalogEntry())
            }
            vm.kernelPath = "/path/to/vmlinuz"
            vm.initrdPath = "/path/to/initrd"
            vm.kernelCommandLine = "console=hvc0"
            vm.kernelBookmark = Data([0x02])
            vm.initrdBookmark = Data([0x03])
            vm.linuxBootMode = linuxBootMode
            vm.selectedOS = guest
            vm.vmName = "Test"

            let config = vm.buildConfiguration()

            let expectedBootMode: VMBootMode =
                switch (guest, linuxBootMode) {
                case (.macOS, _): .macOS
                case (.linux, .efi): .efi
                case (.linux, .linuxKernel): .linuxKernel
                }
            let bootsMacOS = expectedBootMode == .macOS
            let bootsInstaller = expectedBootMode == .efi
            let bootsKernel = expectedBootMode == .linuxKernel
            #expect(config.bootMode == expectedBootMode)
            #expect((config.installContext != nil) == bootsMacOS)
            #expect((config.genericMachineIdentifierData != nil) == !bootsMacOS)
            #expect((config.storageDisks != nil) == (bootsInstaller && installerOnDisk))
            #expect((config.linuxInstallContext != nil) == (bootsInstaller && !installerOnDisk))
            #expect((config.kernelPath != nil) == bootsKernel)
            #expect((config.initrdPath != nil) == bootsKernel)
            #expect((config.kernelCommandLine != nil) == bootsKernel)
            #expect((config.kernelBookmark != nil) == bootsKernel)
            #expect((config.initrdBookmark != nil) == bootsKernel)
        }
    }

    // MARK: - Linux Image Selection

    @Test("A local ISO carries the grant minted for it into the installer disk")
    func localISOCarriesItsBookmark() throws {
        let vm = VMCreationViewModel.overFakeEngine()
        vm.selectedOS = .linux
        vm.linuxBootMode = .efi
        vm.vmName = "Test"
        let bookmark = Data([0x01, 0x02, 0x03])
        vm.selectLocalISO(path: "/path/to/ubuntu.iso", bookmark: bookmark)

        let disks = try #require(vm.buildConfiguration().storageDisks)
        #expect(disks.count == 2)
        #expect(disks[0].path == "/path/to/ubuntu.iso")
        #expect(disks[0].readOnly)
        #expect(disks[0].bookmark == bookmark)
        #expect(disks[1].isInternal)
    }

    // MARK: - Overwrite Warning

    @Test("A confirmation holds for the destination it was given for, and no other")
    func confirmationIsKeyedToItsDestination() throws {
        let vm = VMCreationViewModel.overFakeEngine()
        let confirmed = makeCatalogEntry(version: "15.6.1", build: "24G90")
        vm.selectCatalogEntry(confirmed)
        try placeFile(at: vm.ipswDownloadPath)
        vm.confirmOverwrite()
        #expect(vm.shouldShowOverwriteWarning == false)

        // Another destination that also holds a file still asks.
        vm.selectCatalogEntry(makeCatalogEntry(version: "26.6", build: "25G72"))
        try placeFile(at: vm.ipswDownloadPath)
        #expect(vm.shouldShowOverwriteWarning == true)
        #expect(!vm.buildInstallContext().requestedFreshDownload)

        // Coming back to the confirmed one finds the answer the user gave.
        vm.selectCatalogEntry(confirmed)
        #expect(vm.shouldShowOverwriteWarning == false)
    }

    // MARK: - buildInstallContext

    @Test("buildInstallContext snapshots localFile with chosen path")
    func buildInstallContextLocalFile() {
        let vm = VMCreationViewModel.overFakeEngine(localImageInspector: MockLocalRestoreImageInspector())
        let bookmark = Data([0x01, 0x02, 0x03])
        vm.selectLocalFile(path: "/tmp/macOS-26.ipsw", bookmark: bookmark)

        let context = vm.buildInstallContext()

        #expect(context.source == .localFile)
        #expect(context.localIPSWPath == "/tmp/macOS-26.ipsw")
        #expect(context.downloadDestinationPath == nil)
        #expect(context.localIPSWBookmark == bookmark)
    }
}
