import Testing
import Foundation
import KernovaTestSupport
@testable import Kernova

@Suite("VMCreationViewModel Tests", .admissionGated)
@MainActor
struct VMCreationViewModelTests {
    /// The standardized directory a path sits in.
    private func parentPath(of path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.deletingLastPathComponent()
            .path(percentEncoded: false)
    }

    /// The Downloads directory every download destination must stay inside.
    private var downloadsPath: String {
        parentPath(of: VMCreationViewModel.defaultIPSWDownloadPath)
    }

    // MARK: - Navigation

    @Test("goNext advances through all steps in order")
    func goNextAdvancesThroughSteps() {
        let vm = VMCreationViewModel()
        #expect(vm.currentStep == .osSelection)

        vm.goNext()
        #expect(vm.currentStep == .bootConfig)

        vm.goNext()
        #expect(vm.currentStep == .resources)

        vm.goNext()
        #expect(vm.currentStep == .review)
    }

    @Test("goNext at review step is a no-op")
    func goNextAtReviewIsNoOp() {
        let vm = VMCreationViewModel()
        vm.currentStep = .review

        vm.goNext()
        #expect(vm.currentStep == .review)
    }

    @Test("goBack retreats through steps in order")
    func goBackRetreatsThroughSteps() {
        let vm = VMCreationViewModel()
        vm.currentStep = .review

        vm.goBack()
        #expect(vm.currentStep == .resources)

        vm.goBack()
        #expect(vm.currentStep == .bootConfig)

        vm.goBack()
        #expect(vm.currentStep == .osSelection)
    }

    @Test("goBack at osSelection step is a no-op")
    func goBackAtOSSelectionIsNoOp() {
        let vm = VMCreationViewModel()
        #expect(vm.currentStep == .osSelection)

        vm.goBack()
        #expect(vm.currentStep == .osSelection)
    }

    // MARK: - canAdvance

    @Test("canAdvance is always true at osSelection step")
    func canAdvanceOSSelection() {
        let vm = VMCreationViewModel()
        vm.currentStep = .osSelection
        #expect(vm.canAdvance == true)
    }

    @Test("canAdvance at bootConfig depends on OS and mode selections")
    func canAdvanceBootConfig() async {
        let vm = VMCreationViewModel(localImageInspector: MockLocalRestoreImageInspector())
        vm.currentStep = .bootConfig

        // macOS with downloadLatest is valid (the destination is always the
        // Downloads default; only an unresolved overwrite conflict blocks)
        vm.selectedOS = .macOS
        vm.ipswDownloadPath = "/nonexistent/RestoreImage.ipsw"
        #expect(vm.canAdvance == true)

        // A local file blocks until its inspection lands with a usable verdict.
        vm.selectLocalFile(path: "/path/to/restore.ipsw", bookmark: nil)
        #expect(vm.canAdvance == false)
        await vm.localFileInspectionTask?.value
        #expect(vm.canAdvance == true)
    }

    @Test("ipswDownloadPath defaults to ~/Downloads/RestoreImage.ipsw")
    func ipswDownloadPathHasDefault() {
        let vm = VMCreationViewModel()
        #expect(vm.ipswDownloadPath == VMCreationViewModel.defaultIPSWDownloadPath)
    }

    @Test("canAdvance is true for macOS downloadLatest when file does not exist at path")
    func canAdvanceDefaultMacOSDownloadLatest() {
        let vm = VMCreationViewModel()
        vm.currentStep = .bootConfig
        vm.selectedOS = .macOS
        // Use a non-existent path so the overwrite warning doesn't trigger
        vm.ipswDownloadPath = "/nonexistent/path/RestoreImage.ipsw"
        #expect(vm.canAdvance == true)
    }

    @Test("canAdvance at bootConfig for Linux EFI requires an image selection")
    func canAdvanceBootConfigLinuxEFI() {
        let vm = VMCreationViewModel()
        vm.currentStep = .bootConfig
        vm.selectedOS = .linux
        vm.selectedBootMode = .efi

        #expect(vm.linuxSelection == nil)
        #expect(vm.canAdvance == false)

        vm.selectLocalISO(path: "/path/to/ubuntu.iso", bookmark: nil)
        #expect(vm.canAdvance == true)
    }

    @Test("canAdvance at bootConfig for Linux EFI accepts a catalog pick, nothing on disk")
    func canAdvanceBootConfigLinuxCatalogPick() {
        let vm = VMCreationViewModel()
        vm.currentStep = .bootConfig
        vm.selectedOS = .linux
        vm.selectedBootMode = .efi

        vm.selectLinuxCatalogEntry(makeLinuxCatalogEntry())
        #expect(vm.canAdvance == true)
    }

    @Test("canAdvance at bootConfig for Linux kernel requires kernel path")
    func canAdvanceBootConfigLinuxKernel() {
        let vm = VMCreationViewModel()
        vm.currentStep = .bootConfig
        vm.selectedOS = .linux
        vm.selectedBootMode = .linuxKernel

        vm.kernelPath = nil
        #expect(vm.canAdvance == false)

        vm.kernelPath = "/path/to/vmlinuz"
        #expect(vm.canAdvance == true)
    }

    @Test("canAdvance at resources requires non-empty trimmed name")
    func canAdvanceResources() {
        let vm = VMCreationViewModel()
        vm.currentStep = .resources

        vm.vmName = "My VM"
        #expect(vm.canAdvance == true)

        vm.vmName = "   "
        #expect(vm.canAdvance == false)

        vm.vmName = ""
        #expect(vm.canAdvance == false)
    }

    @Test("canAdvance is always true at review step")
    func canAdvanceReview() {
        let vm = VMCreationViewModel()
        vm.currentStep = .review
        #expect(vm.canAdvance == true)
    }

    // MARK: - canCreate

    @Test("canCreate requires non-empty trimmed name")
    func canCreate() {
        let vm = VMCreationViewModel()

        vm.vmName = "Test VM"
        #expect(vm.canCreate == true)

        vm.vmName = "  Valid  "
        #expect(vm.canCreate == true)

        vm.vmName = "   "
        #expect(vm.canCreate == false)

        vm.vmName = ""
        #expect(vm.canCreate == false)
    }

    // MARK: - effectiveBootMode

    @Test("effectiveBootMode returns macOS for macOS guest regardless of selectedBootMode")
    func effectiveBootModeMacOS() {
        let vm = VMCreationViewModel()
        vm.selectedOS = .macOS
        vm.selectedBootMode = .efi  // should be overridden

        #expect(vm.effectiveBootMode == .macOS)
    }

    @Test("effectiveBootMode returns selectedBootMode for Linux guest")
    func effectiveBootModeLinux() {
        let vm = VMCreationViewModel()
        vm.selectedOS = .linux

        vm.selectedBootMode = .efi
        #expect(vm.effectiveBootMode == .efi)

        vm.selectedBootMode = .linuxKernel
        #expect(vm.effectiveBootMode == .linuxKernel)
    }

    // MARK: - buildConfiguration

    @Test("buildConfiguration produces configuration with correct fields for Linux EFI")
    func buildConfigurationLinuxEFI() throws {
        let vm = VMCreationViewModel()
        vm.selectedOS = .linux
        vm.selectedBootMode = .efi
        vm.vmName = "  Test Linux  "
        vm.cpuCount = 4
        vm.memoryInGB = 8
        vm.diskSizeInGB = 64
        vm.networkEnabled = true
        vm.selectLocalISO(path: "/path/to/ubuntu.iso", bookmark: nil)

        let config = vm.buildConfiguration()

        #expect(config.name == "Test Linux")  // trimmed
        #expect(config.guestOS == .linux)
        #expect(config.bootMode == .efi)
        #expect(config.cpuCount == 4)
        #expect(config.memorySizeInGB == 8)
        #expect(config.diskSizeInGB == 64)
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

    @Test("buildConfiguration produces configuration with correct fields for Linux kernel")
    func buildConfigurationLinuxKernel() {
        let vm = VMCreationViewModel()
        vm.selectedOS = .linux
        vm.selectedBootMode = .linuxKernel
        vm.vmName = "Kernel VM"
        vm.cpuCount = 2
        vm.memoryInGB = 4
        vm.diskSizeInGB = 32
        vm.networkEnabled = false
        vm.kernelPath = "/path/to/vmlinuz"
        vm.initrdPath = "/path/to/initrd"
        vm.kernelCommandLine = "console=hvc0"

        let config = vm.buildConfiguration()

        #expect(config.name == "Kernel VM")
        #expect(config.guestOS == .linux)
        #expect(config.bootMode == .linuxKernel)
        #expect(config.networkEnabled == false)
        #expect(config.macAddress == nil)  // no networking
        #expect(config.genericMachineIdentifierData != nil)  // generated for linuxKernel
        #expect(config.storageDisks == nil)  // Linux Kernel boot: no installer in storageDisks
        #expect(config.kernelPath == "/path/to/vmlinuz")
        #expect(config.initrdPath == "/path/to/initrd")
        #expect(config.kernelCommandLine == "console=hvc0")
    }

    @Test("buildConfiguration trims whitespace from VM name")
    func buildConfigurationTrimsName() {
        let vm = VMCreationViewModel()
        vm.selectedOS = .linux
        vm.selectedBootMode = .efi
        vm.vmName = "   Spaces Around   "
        vm.selectLocalISO(path: "/path/to/image.iso", bookmark: nil)

        let config = vm.buildConfiguration()
        #expect(config.name == "Spaces Around")
    }

    @Test("buildConfiguration only installs an installer ISO for EFI boot mode")
    func buildConfigurationInstallerISOOnlyForEFI() {
        let vm = VMCreationViewModel()
        vm.selectedOS = .linux
        vm.selectedBootMode = .linuxKernel
        vm.vmName = "Test"
        vm.selectLocalISO(path: "/should/be/ignored.iso", bookmark: nil)
        vm.kernelPath = "/path/to/vmlinuz"

        let config = vm.buildConfiguration()
        // Linux Kernel boot loads the kernel directly — no installer
        // enters storageDisks, so the field stays nil (default main disk).
        #expect(config.storageDisks == nil)
    }

    @Test("buildConfiguration sets kernel fields only for linuxKernel boot mode")
    func buildConfigurationKernelFieldsOnlyForLinuxKernel() {
        let vm = VMCreationViewModel()
        vm.selectedOS = .linux
        vm.selectedBootMode = .efi
        vm.vmName = "Test"
        vm.selectLocalISO(path: "/path/to/ubuntu.iso", bookmark: nil)
        vm.kernelPath = "/should/be/ignored"
        vm.initrdPath = "/should/be/ignored"
        vm.kernelCommandLine = "should be ignored"

        let config = vm.buildConfiguration()
        #expect(config.kernelPath == nil)
        #expect(config.initrdPath == nil)
        #expect(config.kernelCommandLine == nil)
    }

    @Test("buildConfiguration omits macAddress when networking is disabled")
    func buildConfigurationNoMacAddressWithoutNetwork() {
        let vm = VMCreationViewModel()
        vm.selectedOS = .linux
        vm.selectedBootMode = .efi
        vm.vmName = "No Network"
        vm.networkEnabled = false
        vm.selectLocalISO(path: "/path/to/image.iso", bookmark: nil)

        let config = vm.buildConfiguration()
        #expect(config.macAddress == nil)
    }

    @Test("buildConfiguration generates macAddress when networking is enabled")
    func buildConfigurationGeneratesMacAddress() {
        let vm = VMCreationViewModel()
        vm.selectedOS = .linux
        vm.selectedBootMode = .efi
        vm.vmName = "With Network"
        vm.networkEnabled = true
        vm.selectLocalISO(path: "/path/to/image.iso", bookmark: nil)

        let config = vm.buildConfiguration()
        #expect(config.macAddress != nil)
        #expect(!config.macAddress!.isEmpty)
    }

    @Test("buildConfiguration generates genericMachineIdentifierData for EFI and linuxKernel")
    func buildConfigurationGeneratesGenericMachineIdentifier() {
        let vm = VMCreationViewModel()
        vm.selectedOS = .linux
        vm.vmName = "Test"

        vm.selectedBootMode = .efi
        vm.selectLocalISO(path: "/path/to/image.iso", bookmark: nil)
        let efiConfig = vm.buildConfiguration()
        #expect(efiConfig.genericMachineIdentifierData != nil)

        vm.selectedBootMode = .linuxKernel
        vm.kernelPath = "/path/to/vmlinuz"
        let kernelConfig = vm.buildConfiguration()
        #expect(kernelConfig.genericMachineIdentifierData != nil)
    }

    @Test("buildConfiguration does not set genericMachineIdentifierData for macOS boot mode")
    func buildConfigurationNoGenericMachineIdentifierForMacOS() {
        let vm = VMCreationViewModel()
        vm.selectedOS = .macOS
        vm.vmName = "macOS Test"

        let config = vm.buildConfiguration()
        #expect(config.genericMachineIdentifierData == nil)
    }

    // MARK: - Linux Image Selection

    @Test("The distribution picker reads the injected catalog, not the bundled resource")
    func linuxCatalogServiceIsInjectable() {
        let vm = VMCreationViewModel(
            linuxCatalogService: MockLinuxImageCatalogService(
                entries: [makeLinuxCatalogEntry(id: "fedora-workstation-44")],
                generatedAt: "2026-01-01"))

        #expect(vm.linuxCatalogService.entries.map(\.id) == ["fedora-workstation-44"])
        #expect(vm.linuxCatalogService.generatedAt == "2026-01-01")
    }

    @Test("Each Linux source replaces the last, so only one pick is ever current")
    func linuxSourcesReplaceEachOther() {
        let vm = VMCreationViewModel()
        let entry = makeLinuxCatalogEntry(id: "debian-13")

        vm.selectLinuxCatalogEntry(entry)
        #expect(vm.linuxSelection == .catalogEntry(entry))

        vm.selectLocalISO(path: "/path/to/ubuntu.iso", bookmark: nil)
        #expect(vm.linuxSelection == .localISO(path: "/path/to/ubuntu.iso", bookmark: nil))

        vm.selectLinuxCatalogEntry(entry)
        #expect(vm.linuxSelection == .catalogEntry(entry))
    }

    @Test("A local ISO carries the grant minted for it into the installer disk")
    func localISOCarriesItsBookmark() throws {
        let vm = VMCreationViewModel()
        vm.selectedOS = .linux
        vm.selectedBootMode = .efi
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

    @Test("A catalog pick attaches nothing: its ISO does not exist yet")
    func catalogPickLeavesStorageDisksNil() {
        let vm = VMCreationViewModel()
        vm.selectedOS = .linux
        vm.selectedBootMode = .efi
        vm.vmName = "Test"
        vm.selectLinuxCatalogEntry(makeLinuxCatalogEntry())

        let config = vm.buildConfiguration()

        // The download happens after creation, so the builder synthesizes the
        // default main disk and the ISO joins later.
        #expect(config.storageDisks == nil)
        #expect(config.bootMode == .efi)
    }

    @Test("Kernel boot ignores an image picked in the EFI segment")
    func kernelBootIgnoresTheImagePick() {
        let vm = VMCreationViewModel()
        vm.selectedOS = .linux
        vm.selectedBootMode = .linuxKernel
        vm.vmName = "Test"
        vm.selectLinuxCatalogEntry(makeLinuxCatalogEntry())
        vm.kernelPath = "/path/to/vmlinuz"

        let config = vm.buildConfiguration()

        #expect(config.storageDisks == nil)
        #expect(config.kernelPath == "/path/to/vmlinuz")
    }

    // MARK: - Overwrite Warning

    @Test("shouldShowOverwriteWarning is false when source is localFile")
    func overwriteWarningFalseForLocalFile() {
        let vm = VMCreationViewModel(localImageInspector: MockLocalRestoreImageInspector())
        vm.selectLocalFile(path: "/tmp/picked.ipsw", bookmark: nil)
        vm.ipswDownloadPath = "/usr/bin/true"  // exists on disk

        #expect(vm.shouldShowOverwriteWarning == false)
    }

    @Test("shouldShowOverwriteWarning is false when file does not exist at path")
    func overwriteWarningFalseWhenFileDoesNotExist() {
        let vm = VMCreationViewModel()
        vm.ipswDownloadPath = "/nonexistent/path/RestoreImage.ipsw"

        #expect(vm.shouldShowOverwriteWarning == false)
    }

    @Test("shouldShowOverwriteWarning is true when download source and file exists")
    func overwriteWarningTrueWhenDownloadAndFileExists() {
        let vm = VMCreationViewModel()
        vm.ipswDownloadPath = "/usr/bin/true"  // exists on disk

        #expect(vm.shouldShowOverwriteWarning == true)
    }

    @Test("confirmOverwrite suppresses warning for current path")
    func confirmOverwriteSuppressesWarning() {
        let vm = VMCreationViewModel()
        vm.ipswDownloadPath = "/usr/bin/true"
        #expect(vm.shouldShowOverwriteWarning == true)

        vm.confirmOverwrite()
        #expect(vm.shouldShowOverwriteWarning == false)
    }

    @Test("changing path after confirmOverwrite resets warning")
    func changingPathResetsConfirmation() {
        let vm = VMCreationViewModel()
        vm.ipswDownloadPath = "/usr/bin/true"
        vm.confirmOverwrite()
        #expect(vm.shouldShowOverwriteWarning == false)

        // Change to another existing path — warning should reappear
        vm.ipswDownloadPath = "/usr/bin/false"
        #expect(vm.shouldShowOverwriteWarning == true)
    }

    @Test("useExistingDownloadFile switches source to localFile and copies path")
    func useExistingDownloadFileSwitchesSource() {
        let vm = VMCreationViewModel()
        vm.ipswDownloadPath = "/usr/bin/true"
        let inspected = InspectedRestoreImage(
            version: "15.6.1", build: "24G90", isSupportedOnThisHost: true, sizeBytes: 1_000)

        vm.useExistingDownloadFile(at: vm.ipswDownloadPath, inspected: inspected)

        #expect(
            vm.ipswSelection
                == .localFile(
                    LocalRestoreImage(
                        path: "/usr/bin/true", bookmark: nil, inspection: .usable(inspected))))
    }

    @Test("canAdvance is false when overwrite warning is unresolved")
    func canAdvanceFalseWithUnresolvedOverwriteWarning() {
        let vm = VMCreationViewModel()
        vm.currentStep = .bootConfig
        vm.selectedOS = .macOS
        vm.ipswDownloadPath = "/usr/bin/true"  // exists on disk → triggers warning

        #expect(vm.shouldShowOverwriteWarning == true)
        #expect(vm.canAdvance == false)
    }

    @Test("canAdvance is true after confirming overwrite")
    func canAdvanceTrueAfterConfirmingOverwrite() {
        let vm = VMCreationViewModel()
        vm.currentStep = .bootConfig
        vm.selectedOS = .macOS
        vm.ipswDownloadPath = "/usr/bin/true"  // exists on disk → triggers warning
        #expect(vm.canAdvance == false)

        vm.confirmOverwrite()
        #expect(vm.shouldShowOverwriteWarning == false)
        #expect(vm.canAdvance == true)
    }

    // MARK: - validationMessage

    @Test("validationMessage is nil when canAdvance is true")
    func validationMessageNilWhenCanAdvance() {
        let vm = VMCreationViewModel()

        // osSelection — always advanceable
        vm.currentStep = .osSelection
        #expect(vm.validationMessage == nil)

        // review — always advanceable
        vm.currentStep = .review
        #expect(vm.validationMessage == nil)

        // bootConfig with valid config
        vm.currentStep = .bootConfig
        vm.selectedOS = .linux
        vm.selectedBootMode = .efi
        vm.selectLocalISO(path: "/path/to/image.iso", bookmark: nil)
        #expect(vm.validationMessage == nil)

        // resources with valid name
        vm.currentStep = .resources
        vm.vmName = "My VM"
        #expect(vm.validationMessage == nil)
    }

    @Test("validationMessage names both EFI image sources when neither is picked")
    func validationMessageLinuxEFINoImage() {
        let vm = VMCreationViewModel()
        vm.currentStep = .bootConfig
        vm.selectedOS = .linux
        vm.selectedBootMode = .efi

        #expect(vm.validationMessage == "Select an installer image to continue.")
    }

    @Test("validationMessage returns kernel hint for Linux kernel with no kernelPath")
    func validationMessageLinuxKernelNoKernel() {
        let vm = VMCreationViewModel()
        vm.currentStep = .bootConfig
        vm.selectedOS = .linux
        vm.selectedBootMode = .linuxKernel
        vm.kernelPath = nil

        #expect(vm.validationMessage == "Select a kernel image to continue.")
    }

    @Test("validationMessage returns conflict hint when overwrite warning is showing")
    func validationMessageOverwriteConflict() {
        let vm = VMCreationViewModel()
        vm.currentStep = .bootConfig
        vm.selectedOS = .macOS
        vm.ipswDownloadPath = "/usr/bin/true"  // exists on disk → triggers warning

        #expect(vm.shouldShowOverwriteWarning == true)
        #expect(vm.validationMessage == "Resolve the file conflict above to continue.")
    }

    @Test("validationMessage returns name hint for resources step with empty name")
    func validationMessageResourcesEmptyName() {
        let vm = VMCreationViewModel()
        vm.currentStep = .resources

        vm.vmName = ""
        #expect(vm.validationMessage == "Enter a name for your virtual machine.")

        vm.vmName = "   "
        #expect(vm.validationMessage == "Enter a name for your virtual machine.")
    }

    // MARK: - buildLinuxInstallContext

    @Test("buildLinuxInstallContext snapshots a catalog pick with nothing downloaded yet")
    func buildLinuxInstallContextCatalogPick() throws {
        let vm = VMCreationViewModel()
        let entry = makeLinuxCatalogEntry(
            id: "ubuntu-desktop-26.04", distribution: "Ubuntu Desktop", version: "26.04 LTS")
        vm.selectLinuxCatalogEntry(entry)

        let context = try #require(vm.buildLinuxInstallContext())

        #expect(catalogEntry(of: context) == entry)
        // The mirror names the file, and only a resolution just before the
        // download can say what that name is.
        #expect(context.downloadDestinationPath == nil)
    }

    @Test("buildLinuxInstallContext snapshots a URL pick with its checksum and destination")
    func buildLinuxInstallContextURLPick() throws {
        let vm = VMCreationViewModel()
        let digest = String(repeating: "a", count: 64)
        let image = makeCustomLinuxImage(sha256: digest)
        vm.selectLinuxCustomURL(image, sizeBytes: 1_073_741_824)

        let context = try #require(vm.buildLinuxInstallContext())

        #expect(
            customImage(of: context)?.url
                == URL(string: "https://mirror.example/alpine-3.22-aarch64.iso"))
        #expect(customImage(of: context)?.sha256 == digest)
        #expect(context.hasVerifyStep)
        // A fixed URL names its own destination, so unlike a catalog pick it is
        // known before the VM is created — and it is unique to the link, so it
        // can never land on a file the user already has.
        let destination = LinuxImageFilename.destination(for: image.url)
        #expect(destination != "alpine-3.22-aarch64.iso")
        #expect(
            context.downloadDestinationPath
                == VMCreationViewModel.downloadPath(forFilename: destination))
    }

    @Test("A URL pick with no checksum carries none, and has nothing to verify")
    func buildLinuxInstallContextUnverifiedURLPick() throws {
        let vm = VMCreationViewModel()
        vm.selectLinuxCustomURL(makeCustomLinuxImage(sha256: nil), sizeBytes: 1_073_741_824)

        let context = try #require(vm.buildLinuxInstallContext())

        #expect(customImage(of: context)?.sha256 == nil)
        #expect(context.hasVerifyStep == false)
    }

    @Test("An EFI image pick does not follow a switch to Linux-kernel boot")
    func buildLinuxInstallContextGatedOnEFI() {
        let vm = VMCreationViewModel()
        vm.selectedOS = .linux
        vm.selectedBootMode = .efi
        vm.selectLinuxCatalogEntry(makeLinuxCatalogEntry())
        #expect(vm.buildLinuxInstallContext() != nil)

        // A kernel-boot VM never boots an installer image, so a pick made
        // before the switch must not reach the created VM — the same rule
        // `buildConfiguration()` applies to the installer `storageDisks`.
        vm.selectedBootMode = .linuxKernel
        #expect(vm.buildLinuxInstallContext() == nil)

        vm.selectLinuxCustomURL(makeCustomLinuxImage(), sizeBytes: 1_073_741_824)
        #expect(vm.buildLinuxInstallContext() == nil)

        // Switching back restores the pick, which was never dropped.
        vm.selectedBootMode = .efi
        #expect(vm.buildLinuxInstallContext() != nil)
    }

    @Test("buildLinuxInstallContext is nil for a local ISO and for no selection at all")
    func buildLinuxInstallContextWithoutCatalogPick() {
        let vm = VMCreationViewModel()
        // Nothing chosen yet.
        #expect(vm.buildLinuxInstallContext() == nil)

        // An ISO already on disk goes straight into `storageDisks`; there is
        // nothing left for the post-create pipeline to fetch.
        vm.selectLocalISO(path: "/path/to/ubuntu.iso", bookmark: Data([0x01]))
        #expect(vm.buildLinuxInstallContext() == nil)

        vm.selectLinuxCatalogEntry(makeLinuxCatalogEntry())
        #expect(vm.buildLinuxInstallContext() != nil)

        // Moving back to a local ISO retracts the download.
        vm.selectLocalISO(path: "/path/to/ubuntu.iso", bookmark: nil)
        #expect(vm.buildLinuxInstallContext() == nil)
    }

    @Test("A catalog pick leaves storageDisks to the pipeline, a local ISO fills them in")
    func buildLinuxInstallContextMatchesBuildConfiguration() {
        let vm = VMCreationViewModel()
        vm.selectedOS = .linux
        vm.selectedBootMode = .efi
        vm.selectLinuxCatalogEntry(makeLinuxCatalogEntry())

        #expect(vm.buildConfiguration().storageDisks == nil)
        #expect(vm.buildLinuxInstallContext() != nil)

        vm.selectLocalISO(path: "/path/to/ubuntu.iso", bookmark: nil)

        #expect(vm.buildConfiguration().storageDisks?.count == 2)
        #expect(vm.buildLinuxInstallContext() == nil)
    }

    // MARK: - buildInstallContext

    @Test("buildInstallContext snapshots downloadLatest with chosen path")
    func buildInstallContextDownloadLatest() {
        let vm = VMCreationViewModel()
        vm.ipswDownloadPath = "/Users/me/Downloads/RestoreImage.ipsw"

        let context = vm.buildInstallContext()

        #expect(context.source == .downloadLatest)
        #expect(context.downloadDestinationPath == "/Users/me/Downloads/RestoreImage.ipsw")
        #expect(context.localIPSWPath == nil)
    }

    @Test("buildInstallContext snapshots localFile with chosen path")
    func buildInstallContextLocalFile() {
        let vm = VMCreationViewModel(localImageInspector: MockLocalRestoreImageInspector())
        vm.selectLocalFile(path: "/tmp/macOS-26.ipsw", bookmark: nil)

        let context = vm.buildInstallContext()

        #expect(context.source == .localFile)
        #expect(context.localIPSWPath == "/tmp/macOS-26.ipsw")
        #expect(context.downloadDestinationPath == nil)
    }

    @Test("buildInstallContext carries a local pick's bookmark")
    func buildInstallContextCarriesLocalBookmark() {
        let vm = VMCreationViewModel(localImageInspector: MockLocalRestoreImageInspector())
        let bookmark = Data([0x01, 0x02, 0x03])
        vm.selectLocalFile(path: "/tmp/macOS-26.ipsw", bookmark: bookmark)

        let context = vm.buildInstallContext()

        #expect(context.localIPSWPath == "/tmp/macOS-26.ipsw")
        #expect(context.localIPSWBookmark == bookmark)
    }

    @Test("each selection maps to its persisted install-context source")
    func installContextSourceCoversEverySelection() {
        let vm = VMCreationViewModel(localImageInspector: MockLocalRestoreImageInspector())
        #expect(vm.buildInstallContext().source == .downloadLatest)

        vm.selectCatalogEntry(makeCatalogEntry())
        #expect(vm.buildInstallContext().source == .catalogVersion)

        vm.selectPastedImage(makeProbedImage())
        #expect(vm.buildInstallContext().source == .customURL)

        vm.selectLocalFile(path: "/tmp/macOS-26.ipsw", bookmark: nil)
        #expect(vm.buildInstallContext().source == .localFile)
    }

    @Test("buildInstallContext defaults requestedFreshDownload to false")
    func buildInstallContextDefaultsFreshFalse() {
        let vm = VMCreationViewModel()
        vm.ipswDownloadPath = "/Users/me/Downloads/RestoreImage.ipsw"

        let context = vm.buildInstallContext()

        #expect(!context.requestedFreshDownload)
    }

    @Test("buildInstallContext sets requestedFreshDownload when overwrite confirmed")
    func buildInstallContextSetsFreshOnConfirmedOverwrite() {
        let vm = VMCreationViewModel()
        vm.ipswDownloadPath = "/Users/me/Downloads/RestoreImage.ipsw"
        vm.confirmOverwrite()

        let context = vm.buildInstallContext()

        #expect(context.requestedFreshDownload)
    }

    @Test("buildInstallContext clears requestedFreshDownload when path changes after confirm")
    func buildInstallContextClearsFreshWhenPathChangedAfterConfirm() {
        // `confirmOverwrite` records the path that was confirmed; if the user
        // then picks a different destination, the confirmation no longer
        // applies and the wizard should treat the new path as not-yet-confirmed.
        let vm = VMCreationViewModel()
        vm.ipswDownloadPath = "/Users/me/Downloads/A.ipsw"
        vm.confirmOverwrite()
        vm.ipswDownloadPath = "/Users/me/Downloads/B.ipsw"

        let context = vm.buildInstallContext()

        #expect(!context.requestedFreshDownload)
    }

    // MARK: - Start After Create

    @Test("startAfterCreate defaults to true")
    func startAfterCreateDefaultsTrue() {
        let vm = VMCreationViewModel()
        #expect(vm.startAfterCreate == true)
    }

    // MARK: - Catalog Version Source

    @Test("Choosing a catalog version moves the destination to Apple's filename")
    func catalogPickUsesPerBuildDestination() {
        let vm = VMCreationViewModel()
        let entry = makeCatalogEntry(version: "15.6.1", build: "24G90")
        vm.selectCatalogEntry(entry)

        #expect(vm.ipswSelection == .catalogVersion(entry))
        #expect(
            vm.ipswDownloadPath
                == VMCreationViewModel.downloadPath(
                    forFilename: "UniversalMac_15.6.1_24G90_Restore.ipsw"))
        #expect(vm.ipswDownloadPath != VMCreationViewModel.defaultIPSWDownloadPath)
    }

    @Test("Two different picks never resolve to the same destination")
    func distinctPicksGetDistinctDestinations() {
        let vm = VMCreationViewModel()
        vm.selectCatalogEntry(makeCatalogEntry(version: "15.6.1", build: "24G90"))
        let first = vm.ipswDownloadPath
        vm.selectCatalogEntry(makeCatalogEntry(version: "26.6", build: "25G72"))

        #expect(first != vm.ipswDownloadPath)
    }

    @Test("Two spins of one version get distinct destinations")
    func sameVersionDifferentBuildsGetDistinctDestinations() {
        let vm = VMCreationViewModel()
        vm.selectCatalogEntry(
            makeCatalogEntry(
                version: "15.4", build: "24E246",
                urlString:
                    "https://updates.cdn-apple.com/a/UniversalMac_15.4_24E246_Restore.ipsw"))
        let first = vm.ipswDownloadPath
        vm.selectCatalogEntry(
            makeCatalogEntry(
                version: "15.4", build: "24E248",
                urlString:
                    "https://updates.cdn-apple.com/b/UniversalMac_15.4_24E248_Restore.ipsw"))

        #expect(first != vm.ipswDownloadPath)
    }

    @Test("Returning to Download Latest takes the fixed destination until the lookup answers")
    func downloadLatestRestoresDefaultDestination() {
        let vm = VMCreationViewModel()
        vm.selectCatalogEntry(makeCatalogEntry())
        vm.selectDownloadLatest()

        #expect(vm.ipswSelection == .downloadLatest)
        #expect(vm.ipswDownloadPath == VMCreationViewModel.defaultIPSWDownloadPath)
    }

    @Test("The looked-up image names Download Latest's destination")
    func downloadLatestUsesTheLookedUpFilename() async {
        let vm = VMCreationViewModel(
            probeService: MockRestoreImageProbeService(), ipswService: MockIPSWService())

        await vm.loadLatestImageDetails()?.value

        // The lookup landing on the live source moves the destination itself,
        // so the wizard names the file it is about to write.
        let expected = VMCreationViewModel.downloadPath(
            forFilename: "UniversalMac_26.5.2_25F84_Restore.ipsw")
        #expect(vm.ipswDownloadPath == expected)
        #expect(vm.ipswDownloadPath != VMCreationViewModel.defaultIPSWDownloadPath)

        // And a later re-pick names the same file, the answer being in hand.
        vm.selectCatalogEntry(makeCatalogEntry())
        vm.selectDownloadLatest()
        #expect(vm.ipswDownloadPath == expected)
    }

    @Test("A lookup landing after another source was picked leaves that pick's destination")
    func lateLookupLeavesAnotherSourcesDestination() async {
        let vm = VMCreationViewModel(
            probeService: MockRestoreImageProbeService(), ipswService: MockIPSWService())

        // The pick happens while the lookup is in flight: nothing has awaited,
        // so the completion runs strictly after it.
        let lookup = vm.loadLatestImageDetails()
        vm.selectCatalogEntry(makeCatalogEntry(version: "15.6.1", build: "24G90"))
        await lookup?.value

        #expect(vm.latestImage?.build == "25F84")
        #expect(
            vm.ipswDownloadPath
                == VMCreationViewModel.downloadPath(
                    forFilename: "UniversalMac_15.6.1_24G90_Restore.ipsw"))
    }

    @Test("A failed lookup leaves the destination on the fixed fallback")
    func failedLookupKeepsTheFallbackDestination() async {
        let ipswService = MockIPSWService()
        ipswService.fetchError = URLError(.notConnectedToInternet)
        let vm = VMCreationViewModel(
            probeService: MockRestoreImageProbeService(), ipswService: ipswService)

        await vm.loadLatestImageDetails()?.value

        #expect(vm.ipswDownloadPath == VMCreationViewModel.defaultIPSWDownloadPath)
    }

    @Test("The overwrite warning and resume check cover the catalog source")
    func catalogSourceSharesDownloadWarnings() {
        let vm = VMCreationViewModel()
        vm.currentStep = .bootConfig
        vm.selectCatalogEntry(makeCatalogEntry())
        vm.ipswDownloadPath = "/usr/bin/true"  // exists on disk
        #expect(vm.shouldShowOverwriteWarning)
        #expect(!vm.canAdvance)

        vm.confirmOverwrite()
        #expect(!vm.shouldShowOverwriteWarning)
        #expect(vm.canAdvance)
    }

    @Test("A catalog install context pins the URL, version, and build")
    func catalogInstallContextPinsTheImage() {
        let vm = VMCreationViewModel()
        let entry = makeCatalogEntry(version: "15.6.1", build: "24G90")
        vm.selectCatalogEntry(entry)

        let context = vm.buildInstallContext()

        #expect(context.source == .catalogVersion)
        #expect(context.remoteURL == entry.url)
        #expect(context.version == "15.6.1")
        #expect(context.build == "24G90")
        #expect(context.downloadDestinationPath == vm.ipswDownloadPath)
        #expect(!context.requestedFreshDownload)
    }

    @Test("Download & Replace carries into the catalog install context")
    func catalogInstallContextCarriesFreshDownload() {
        let vm = VMCreationViewModel()
        vm.selectCatalogEntry(makeCatalogEntry())
        vm.confirmOverwrite()

        #expect(vm.buildInstallContext().requestedFreshDownload)
    }

    @Test("Use Existing File adopts the per-build download as a local file")
    func useExistingAdoptsPerBuildPath() {
        let vm = VMCreationViewModel()
        vm.selectCatalogEntry(makeCatalogEntry(version: "15.6.1", build: "24G90"))
        let destination = vm.ipswDownloadPath
        let inspected = InspectedRestoreImage(
            version: "15.6.1", build: "24G90", isSupportedOnThisHost: true, sizeBytes: 1_000)
        vm.useExistingDownloadFile(at: destination, inspected: inspected)

        #expect(
            vm.ipswSelection
                == .localFile(
                    LocalRestoreImage(path: destination, bookmark: nil, inspection: .usable(inspected)))
        )
    }

    @Test("Use Existing File keeps the pick that named the file, for the sheet")
    func useExistingKeepsTheSeed() {
        let vm = VMCreationViewModel()
        let entry = makeCatalogEntry(version: "15.6.1", build: "24G90")
        vm.selectCatalogEntry(entry)
        vm.useExistingDownloadFile(
            at: vm.ipswDownloadPath,
            inspected: InspectedRestoreImage(
                version: "15.6.1", build: "24G90", isSupportedOnThisHost: true))

        #expect(vm.ipswSource == .localFile)
        #expect(vm.lastCatalogPick == entry)
    }

    @Test("Only download sources own the destination")
    func downloadsImageCoversBothDownloadSources() {
        #expect(IPSWSource.downloadLatest.downloadsImage)
        #expect(IPSWSource.catalogVersion.downloadsImage)
        #expect(IPSWSource.customURL.downloadsImage)
        #expect(!IPSWSource.localFile.downloadsImage)
    }

    // MARK: - Custom URL Source

    @Test("A checked URL moves the destination to that image's filename")
    func pastedImageUsesPerImageDestination() {
        let vm = VMCreationViewModel()
        let image = makeProbedImage()
        vm.selectPastedImage(image)

        #expect(vm.ipswSelection == .customURL(image))
        #expect(
            vm.ipswDownloadPath
                == VMCreationViewModel.downloadPath(
                    forFilename: "UniversalMac_15.6.1_24G90_Restore.ipsw"))
        #expect(vm.ipswDownloadPath != VMCreationViewModel.defaultIPSWDownloadPath)
    }

    @Test("An off-convention URL lands on its own filename, not the shared default")
    func pastedImageWithoutIPSWNameGetsItsOwnDestination() {
        let vm = VMCreationViewModel()
        vm.selectPastedImage(
            makeProbedImage(urlString: "https://example.com/d/", version: nil, build: nil))

        #expect(vm.ipswDownloadPath.hasSuffix(".ipsw"))
        // Sharing "Download Latest"'s destination would let its image satisfy
        // this URL's download — a different macOS than the one pinned.
        #expect(vm.ipswDownloadPath != VMCreationViewModel.defaultIPSWDownloadPath)
        #expect(parentPath(of: vm.ipswDownloadPath) == downloadsPath)
    }

    @Test("Two off-convention URLs sharing a basename get different destinations")
    func pastedImagesWithOneBasenameGetDistinctDestinations() {
        let vm = VMCreationViewModel()
        vm.selectPastedImage(
            makeProbedImage(
                urlString: "https://a.example.com/restore.ipsw", version: nil, build: nil))
        let first = vm.ipswDownloadPath
        vm.selectPastedImage(
            makeProbedImage(
                urlString: "https://b.example.com/restore.ipsw", version: nil, build: nil))

        #expect(first != vm.ipswDownloadPath)
    }

    @Test("A URL whose filename walks out of Downloads cannot move the destination")
    func pastedImageWithTraversalStaysInDownloads() {
        let vm = VMCreationViewModel()
        // Decodes to `a/../../evil.ipsw`, which appended verbatim would
        // standardize to a path two directories above Downloads.
        vm.selectPastedImage(
            makeProbedImage(
                urlString: "https://host/a%2F..%2F..%2Fevil.ipsw", version: nil, build: nil))

        #expect(parentPath(of: vm.ipswDownloadPath) == downloadsPath)
    }

    @Test("The URL source shares the overwrite warning")
    func customURLSourceSharesDownloadWarnings() {
        let vm = VMCreationViewModel()
        vm.currentStep = .bootConfig
        vm.selectPastedImage(makeProbedImage())
        vm.ipswDownloadPath = "/usr/bin/true"  // exists on disk
        #expect(vm.shouldShowOverwriteWarning)
        #expect(!vm.canAdvance)

        vm.confirmOverwrite()
        #expect(!vm.shouldShowOverwriteWarning)
        #expect(vm.canAdvance)
    }

    @Test("A URL install context pins the checked URL, version, and build")
    func customURLInstallContextPinsTheImage() {
        let vm = VMCreationViewModel()
        let image = makeProbedImage()
        vm.selectPastedImage(image)

        let context = vm.buildInstallContext()

        #expect(context.source == .customURL)
        #expect(context.remoteURL == image.url)
        #expect(context.version == "15.6.1")
        #expect(context.build == "24G90")
        #expect(context.downloadDestinationPath == vm.ipswDownloadPath)
    }

    // MARK: - Local File Selection

    @Test("selectLocalFile commits the path immediately, then the inspection upgrades it")
    func selectLocalFileCommitsImmediatelyThenUpgrades() async {
        let inspector = MockLocalRestoreImageInspector()
        inspector.inspectResult = InspectedRestoreImage(
            version: "15.6.1", build: "24G90", isSupportedOnThisHost: true,
            sizeBytes: 5_000_000_000)
        let vm = VMCreationViewModel(localImageInspector: inspector)

        vm.selectLocalFile(path: "/tmp/picked.ipsw", bookmark: nil)
        #expect(
            vm.ipswSelection == .localFile(LocalRestoreImage(path: "/tmp/picked.ipsw", bookmark: nil)))

        await vm.localFileInspectionTask?.value

        #expect(
            vm.ipswSelection
                == .localFile(
                    LocalRestoreImage(
                        path: "/tmp/picked.ipsw", bookmark: nil,
                        inspection: .usable(inspector.inspectResult))))
    }

    @Test("An unsupported pick leaves an unusable verdict and blocks advance")
    func selectLocalFileUnsupportedLeavesUnusable() async {
        let inspector = MockLocalRestoreImageInspector()
        inspector.inspectResult = InspectedRestoreImage(
            version: "13.0", build: "22A5286j", isSupportedOnThisHost: false)
        let vm = VMCreationViewModel(localImageInspector: inspector)
        vm.currentStep = .bootConfig
        vm.selectedOS = .macOS

        vm.selectLocalFile(path: "/tmp/picked.ipsw", bookmark: nil)
        await vm.localFileInspectionTask?.value

        #expect(
            vm.ipswSelection
                == .localFile(
                    LocalRestoreImage(
                        path: "/tmp/picked.ipsw", bookmark: nil, inspection: .unusable(.unsupported))))
        #expect(vm.canAdvance == false)
        #expect(vm.validationMessage == "Choose a restore image this Mac can install.")
    }

    @Test("An inspection error leaves the path unusable and blocks advance")
    func selectLocalFileInspectionErrorLeavesUnusable() async {
        let inspector = MockLocalRestoreImageInspector()
        inspector.inspectError = LocalRestoreImageError.unreadable
        let vm = VMCreationViewModel(localImageInspector: inspector)
        vm.currentStep = .bootConfig
        vm.selectedOS = .macOS

        vm.selectLocalFile(path: "/tmp/picked.ipsw", bookmark: nil)
        await vm.localFileInspectionTask?.value

        #expect(
            vm.ipswSelection
                == .localFile(
                    LocalRestoreImage(
                        path: "/tmp/picked.ipsw", bookmark: nil, inspection: .unusable(.unreadable))))
        #expect(vm.canAdvance == false)
        #expect(vm.validationMessage == "Choose a file this Mac can read as a restore image.")
    }

    @Test("A supported pick reaches usable and unblocks advance")
    func selectLocalFileSupportedUnblocksAdvance() async {
        let inspector = MockLocalRestoreImageInspector()
        let vm = VMCreationViewModel(localImageInspector: inspector)
        vm.currentStep = .bootConfig
        vm.selectedOS = .macOS

        vm.selectLocalFile(path: "/tmp/picked.ipsw", bookmark: nil)
        await vm.localFileInspectionTask?.value

        #expect(vm.canAdvance == true)
        #expect(vm.validationMessage == nil)
    }

    @Test("While the inspection is pending, advance is blocked")
    func selectLocalFilePendingBlocksAdvance() async throws {
        let inspector = SuspendingMockLocalRestoreImageInspector()
        let vm = VMCreationViewModel(localImageInspector: inspector)
        vm.currentStep = .bootConfig
        vm.selectedOS = .macOS

        vm.selectLocalFile(path: "/tmp/picked.ipsw", bookmark: nil)
        try await inspector.waitUntilInspecting()

        guard case .localFile(let image) = vm.ipswSelection else {
            Issue.record("Expected a local file selection")
            return
        }
        #expect(image.inspection == .pending)
        #expect(vm.canAdvance == false)
        #expect(vm.validationMessage == "Checking the selected restore image…")

        inspector.release()
        await vm.localFileInspectionTask?.value
    }

    @Test("An inspection landing after the source switched away leaves that source current")
    func selectLocalFileInspectionLandingAfterSourceSwitchIsDropped() async throws {
        let inspector = SuspendingMockLocalRestoreImageInspector()
        let vm = VMCreationViewModel(localImageInspector: inspector)

        vm.selectLocalFile(path: "/tmp/picked.ipsw", bookmark: nil)
        let inspection = try #require(vm.localFileInspectionTask)
        try await inspector.waitUntilInspecting()

        let entry = makeCatalogEntry(version: "15.6.1", build: "24G90")
        vm.selectCatalogEntry(entry)
        inspector.release()
        await inspection.value

        #expect(vm.ipswSelection == .catalogVersion(entry))
    }

    @Test("A superseded inspection finishing after a newer one leaves the newer task current")
    func outOfOrderInspectionsLeaveTheNewerTaskCurrent() async throws {
        let inspector = OrderedSuspendingMockLocalRestoreImageInspector()
        let vm = VMCreationViewModel(localImageInspector: inspector)

        vm.selectLocalFile(path: "/tmp/first.ipsw", bookmark: nil)
        let firstTask = try #require(vm.localFileInspectionTask)
        try await inspector.waitUntilCallCount(1)

        vm.selectLocalFile(path: "/tmp/second.ipsw", bookmark: nil)
        let secondTask = try #require(vm.localFileInspectionTask)
        try await inspector.waitUntilCallCount(2)

        // The superseded first pick's read finishes first — `VZMacOSRestoreImage`
        // ignores cancellation, so an older read racing to completion after a
        // re-pick is the ordinary ordering, not adversarial timing.
        inspector.release(callIndex: 0)
        await firstTask.value

        // The newer pick's task must still be what the model hands out — a
        // premature clear here is what leaves a re-entered step awaiting
        // nothing while the second inspection is still running.
        #expect(vm.localFileInspectionTask != nil)

        inspector.release(callIndex: 1)
        await secondTask.value

        #expect(vm.localFileInspectionTask == nil)
    }

    // MARK: - Adopting an Existing File

    @Test("An existing file matching the pinned build is adopted")
    func adoptsMatchingExistingFile() async {
        let inspector = MockLocalRestoreImageInspector()
        inspector.inspectResult = InspectedRestoreImage(
            version: "15.6.1", build: "24G90", isSupportedOnThisHost: true)
        let vm = VMCreationViewModel(localImageInspector: inspector)
        vm.selectCatalogEntry(makeCatalogEntry(version: "15.6.1", build: "24G90"))
        let destination = vm.ipswDownloadPath

        let verdict = await vm.adoptExistingDownloadFile(at: destination)

        #expect(verdict == .adopted(inspector.inspectResult))
        #expect(
            vm.ipswSelection
                == .localFile(
                    LocalRestoreImage(
                        path: destination, bookmark: nil,
                        inspection: .usable(inspector.inspectResult))))
        #expect(inspector.lastInspectedURL?.path(percentEncoded: false) == destination)
    }

    @Test("An existing file of a different build is reported, not adopted")
    func refusesMismatchedExistingFile() async {
        let inspector = MockLocalRestoreImageInspector()
        inspector.inspectResult = InspectedRestoreImage(
            version: "14.2", build: "23C64", isSupportedOnThisHost: true)
        let vm = VMCreationViewModel(localImageInspector: inspector)
        let entry = makeCatalogEntry(version: "15.6.1", build: "24G90")
        vm.selectCatalogEntry(entry)

        let verdict = await vm.adoptExistingDownloadFile(at: vm.ipswDownloadPath)

        #expect(verdict == .mismatch(expected: "24G90", found: inspector.inspectResult))
        // The wrong-image install this exists to prevent.
        #expect(vm.ipswSelection == .catalogVersion(entry))
    }

    @Test("An unreadable file is refused with a reason")
    func refusesUnreadableExistingFile() async {
        let inspector = MockLocalRestoreImageInspector()
        inspector.inspectError = LocalRestoreImageError.unreadable
        let vm = VMCreationViewModel(localImageInspector: inspector)
        vm.selectCatalogEntry(makeCatalogEntry())

        let verdict = await vm.adoptExistingDownloadFile(at: vm.ipswDownloadPath)

        #expect(
            verdict
                == .unusable(
                    message: LocalRestoreImageError.unreadable.errorDescription ?? ""))
        #expect(vm.ipswSource == .catalogVersion)
    }

    @Test("An image the host can't run is refused even when the build matches")
    func refusesUnsupportedExistingFile() async {
        let inspector = MockLocalRestoreImageInspector()
        inspector.inspectResult = InspectedRestoreImage(
            version: "15.6.1", build: "24G90", isSupportedOnThisHost: false)
        let vm = VMCreationViewModel(localImageInspector: inspector)
        vm.selectCatalogEntry(makeCatalogEntry(version: "15.6.1", build: "24G90"))

        let verdict = await vm.adoptExistingDownloadFile(at: vm.ipswDownloadPath)

        #expect(
            verdict
                == .unusable(
                    message: LocalRestoreImageError.unsupported.errorDescription ?? ""))
        #expect(vm.ipswSource == .catalogVersion)
    }

    @Test("Download Latest names no build before the lookup answers, so any usable image is adopted")
    func downloadLatestAdoptsAnyUsableImage() async {
        let inspector = MockLocalRestoreImageInspector()
        inspector.inspectResult = InspectedRestoreImage(
            version: "14.2", build: "23C64", isSupportedOnThisHost: true)
        let vm = VMCreationViewModel(localImageInspector: inspector)
        vm.selectDownloadLatest()

        #expect(vm.expectedBuild == nil)
        let verdict = await vm.adoptExistingDownloadFile(at: vm.ipswDownloadPath)

        #expect(verdict == .adopted(inspector.inspectResult))
        #expect(vm.ipswSource == .localFile)
    }

    @Test("Once the lookup lands, a file of another build is reported, not adopted")
    func downloadLatestRefusesAnotherBuildOnceTheLookupLands() async {
        let inspector = MockLocalRestoreImageInspector()
        inspector.inspectResult = InspectedRestoreImage(
            version: "14.2", build: "23C64", isSupportedOnThisHost: true)
        let vm = VMCreationViewModel(
            probeService: MockRestoreImageProbeService(),
            localImageInspector: inspector,
            ipswService: MockIPSWService())
        await vm.loadLatestImageDetails()?.value

        let verdict = await vm.adoptExistingDownloadFile(at: vm.ipswDownloadPath)

        // The wrong-image install a per-build destination prevents for the
        // download, which a hand-placed file at that destination reintroduces.
        #expect(verdict == .mismatch(expected: "25F84", found: inspector.inspectResult))
        #expect(vm.ipswSelection == .downloadLatest)
    }

    @Test("A file of the looked-up build is adopted")
    func downloadLatestAdoptsTheLookedUpBuild() async {
        let inspector = MockLocalRestoreImageInspector()
        inspector.inspectResult = InspectedRestoreImage(
            version: "26.5.2", build: "25F84", isSupportedOnThisHost: true)
        let vm = VMCreationViewModel(
            probeService: MockRestoreImageProbeService(),
            localImageInspector: inspector,
            ipswService: MockIPSWService())
        await vm.loadLatestImageDetails()?.value
        let destination = vm.ipswDownloadPath

        let verdict = await vm.adoptExistingDownloadFile(at: destination)

        #expect(verdict == .adopted(inspector.inspectResult))
        #expect(
            vm.ipswSelection
                == .localFile(
                    LocalRestoreImage(
                        path: destination, bookmark: nil,
                        inspection: .usable(inspector.inspectResult))))
    }

    @Test("A URL pick with no parsed build pins nothing to compare against")
    func customURLWithoutBuildPinsNothing() async {
        let inspector = MockLocalRestoreImageInspector()
        let vm = VMCreationViewModel(localImageInspector: inspector)
        vm.selectPastedImage(
            makeProbedImage(
                urlString: "https://example.com/image.ipsw", version: nil, build: nil))

        #expect(vm.expectedBuild == nil)
        #expect(
            await vm.adoptExistingDownloadFile(at: vm.ipswDownloadPath)
                == .adopted(inspector.inspectResult))
    }

    @Test("An inspection cancelled mid-flight adopts nothing")
    func cancelledInspectionAdoptsNothing() async throws {
        let inspector = SuspendingMockLocalRestoreImageInspector()
        let vm = VMCreationViewModel(localImageInspector: inspector)
        // The build matches, so only the cancellation keeps this from adopting.
        let entry = makeCatalogEntry(version: "15.6.1", build: "24G90")
        vm.selectCatalogEntry(entry)

        let destination = vm.ipswDownloadPath
        let adopt = Task { await vm.adoptExistingDownloadFile(at: destination) }
        try await inspector.waitUntilInspecting()
        adopt.cancel()
        inspector.release()

        #expect(await adopt.value == .cancelled)
        #expect(vm.ipswSelection == .catalogVersion(entry))
    }

    @Test("Adoption inspects and commits the path it was handed, not the live destination")
    func adoptUsesTheCallersPath() async {
        let inspector = MockLocalRestoreImageInspector()
        let vm = VMCreationViewModel(localImageInspector: inspector)
        // The destination as the caller showed it to the user.
        let snapshot = "/tmp/kernova-snapshot-\(UUID().uuidString).ipsw"
        #expect(snapshot != vm.ipswDownloadPath)

        let verdict = await vm.adoptExistingDownloadFile(at: snapshot)

        #expect(verdict == .adopted(inspector.inspectResult))
        #expect(inspector.lastInspectedURL?.path(percentEncoded: false) == snapshot)
        #expect(
            vm.ipswSelection
                == .localFile(
                    LocalRestoreImage(
                        path: snapshot, bookmark: nil, inspection: .usable(inspector.inspectResult)))
        )
    }

    @Test("A destination that moves mid-inspection changes neither the file adopted nor the build")
    func adoptIgnoresADestinationThatMovesMidInspection() async throws {
        let inspector = SuspendingMockLocalRestoreImageInspector()
        let vm = VMCreationViewModel(
            probeService: MockRestoreImageProbeService(),
            localImageInspector: inspector,
            ipswService: MockIPSWService())
        let destination = vm.ipswDownloadPath

        let adopt = Task { await vm.adoptExistingDownloadFile(at: destination) }
        try await inspector.waitUntilInspecting()
        // The lookup lands during the seconds the read takes, moving both the
        // destination and the build "Download Latest" promises.
        await vm.loadLatestImageDetails()?.value
        #expect(vm.ipswDownloadPath != destination)
        #expect(vm.expectedBuild == "25F84")
        inspector.release()

        // The verdict answers the question that was asked: the file read is the
        // file adopted, and a build that arrived afterwards is not held against
        // it — a mismatch here would name a build the user never saw, about a
        // file at a path nothing inspected.
        #expect(await adopt.value == .adopted(inspector.inspectResult))
        #expect(
            vm.ipswSelection
                == .localFile(
                    LocalRestoreImage(
                        path: destination, bookmark: nil,
                        inspection: .usable(inspector.inspectResult))))
    }

    @Test("expectedBuild names the build each source is promising")
    func expectedBuildTracksTheSource() async {
        let vm = VMCreationViewModel(
            probeService: MockRestoreImageProbeService(), ipswService: MockIPSWService())
        #expect(vm.expectedBuild == nil)

        vm.selectCatalogEntry(makeCatalogEntry(build: "24G90"))
        #expect(vm.expectedBuild == "24G90")

        vm.selectPastedImage(makeProbedImage(build: "25G72"))
        #expect(vm.expectedBuild == "25G72")

        // "Whatever is newest" names nothing until the lookup says what that is.
        vm.selectDownloadLatest()
        #expect(vm.expectedBuild == nil)

        await vm.loadLatestImageDetails()?.value
        #expect(vm.expectedBuild == "25F84")
    }

    @Test("Switching between pinned sources keeps both picks; Download Latest clears them")
    func downloadLatestClearsBothPinnedPicks() {
        let vm = VMCreationViewModel()
        vm.selectCatalogEntry(makeCatalogEntry())
        vm.selectPastedImage(makeProbedImage())
        #expect(vm.lastCatalogPick != nil)
        #expect(vm.lastPastedImage != nil)

        // Download Latest is the one source that owns neither pick.
        vm.selectDownloadLatest()
        #expect(vm.lastCatalogPick == nil)
        #expect(vm.lastPastedImage == nil)
    }

    @Test("A pinned payload leaves with its source, while the sheet seed stays")
    func switchingSourcesDropsThePayloadButKeepsTheSeed() {
        let vm = VMCreationViewModel()
        let entry = makeCatalogEntry(version: "15.6.1", build: "24G90")
        let image = makeProbedImage(build: "25G72")
        vm.selectCatalogEntry(entry)
        vm.selectPastedImage(image)

        // Only the live source carries a payload, so no reader can reach the
        // catalog entry while the URL source is current.
        #expect(vm.ipswSelection == .customURL(image))
        #expect(vm.expectedBuild == "25G72")
        // The seed survives so the version picker re-opens on the old pick.
        #expect(vm.lastCatalogPick == entry)
    }

    // MARK: - Latest Image Lookup

    @Test("The lookup names the version, build and size Download Latest will fetch")
    func latestImageLookupPopulatesDetails() async {
        let ipswService = MockIPSWService()
        let probeService = MockRestoreImageProbeService()
        probeService.sizeResult = 19_772_077_142
        let vm = VMCreationViewModel(probeService: probeService, ipswService: ipswService)

        await vm.loadLatestImageDetails()?.value

        #expect(vm.latestImage?.version == "26.5.2")
        #expect(vm.latestImage?.build == "25F84")
        #expect(vm.latestImageSizeBytes == 19_772_077_142)
        // The size is read for the image the lookup named, not for the wizard's
        // own destination.
        #expect(probeService.lastSizedURL == ipswService.fetchResult.url)
    }

    @Test("A second lookup joins the first instead of re-fetching")
    func latestImageLookupRunsOnce() async {
        let ipswService = MockIPSWService()
        let vm = VMCreationViewModel(
            probeService: MockRestoreImageProbeService(), ipswService: ipswService)

        let first = vm.loadLatestImageDetails()
        #expect(vm.loadLatestImageDetails() == first)
        await first?.value

        // Nothing left to look up, so a later call starts nothing at all.
        #expect(vm.loadLatestImageDetails() == nil)
        #expect(ipswService.fetchCallCount == 1)
    }

    @Test("A failed lookup leaves the details unset, and the next call retries")
    func latestImageLookupFailureRetries() async {
        let ipswService = MockIPSWService()
        ipswService.fetchError = URLError(.notConnectedToInternet)
        let vm = VMCreationViewModel(
            probeService: MockRestoreImageProbeService(), ipswService: ipswService)

        await vm.loadLatestImageDetails()?.value
        #expect(vm.latestImage == nil)
        #expect(vm.latestImageSizeBytes == nil)

        // Back online, the wizard asks again — a failure must not latch.
        ipswService.fetchError = nil
        await vm.loadLatestImageDetails()?.value
        #expect(vm.latestImage?.build == "25F84")
        #expect(ipswService.fetchCallCount == 2)
    }

    @Test("A size that can't be read still leaves the version and build to show")
    func latestImageLookupSurvivesAnUnknownSize() async {
        let probeService = MockRestoreImageProbeService()
        probeService.sizeError = RestoreImageProbeError.unknownSize
        let vm = VMCreationViewModel(probeService: probeService, ipswService: MockIPSWService())

        await vm.loadLatestImageDetails()?.value

        #expect(vm.latestImage?.version == "26.5.2")
        #expect(vm.latestImageSizeBytes == nil)
    }
}

/// Inspector stand-in that stays inside `inspect` until the test releases it,
/// the way a multi-gigabyte image keeps the real one busy for seconds.
final class SuspendingMockLocalRestoreImageInspector: LocalRestoreImageInspecting, @unchecked Sendable {
    let inspectResult = InspectedRestoreImage(
        version: "15.6.1", build: "24G90", isSupportedOnThisHost: true)
    private let gate = AsyncGate()
    private let lock = NSLock()
    private var isInspecting = false
    private var isReleased = false

    func inspect(_ url: URL) async throws -> InspectedRestoreImage {
        lock.withLock { self.isInspecting = true }
        gate.notify()
        try? await gate.wait(until: { self.lock.withLock { self.isReleased } })
        return inspectResult
    }

    /// Suspends until `inspect` is in flight.
    func waitUntilInspecting() async throws {
        try await gate.wait(until: { self.lock.withLock { self.isInspecting } })
    }

    /// Lets the in-flight inspection finish.
    func release() {
        lock.withLock { self.isReleased = true }
        gate.notify()
    }
}

/// Inspector whose calls suspend independently and resolve in whatever order
/// the test releases them by index — models `VZMacOSRestoreImage` ignoring
/// cancellation, so a superseded pick's read can finish after a newer one's.
final class OrderedSuspendingMockLocalRestoreImageInspector: LocalRestoreImageInspecting,
    @unchecked Sendable
{
    private final class CallState {
        let gate = AsyncGate()
        var released = false
    }
    private let lock = NSLock()
    private var calls: [CallState] = []
    /// Notified whenever a new call registers, for ``waitUntilCallCount(_:)``.
    private let callRegisteredGate = AsyncGate()

    func inspect(_ url: URL) async throws -> InspectedRestoreImage {
        let (index, gate) = lock.withLock { () -> (Int, AsyncGate) in
            calls.append(CallState())
            return (calls.count - 1, calls[calls.count - 1].gate)
        }
        callRegisteredGate.notify()
        try? await gate.wait(until: { self.lock.withLock { self.calls[index].released } })
        return InspectedRestoreImage(
            version: "15.6.1", build: "24G90", isSupportedOnThisHost: true)
    }

    /// Suspends until `inspect` has been called at least `count` times.
    func waitUntilCallCount(_ count: Int) async throws {
        try await callRegisteredGate.wait(until: { self.lock.withLock { self.calls.count >= count } })
    }

    /// Lets the `callIndex`th call (0-based, in call order) finish.
    func release(callIndex: Int) {
        let gate = lock.withLock { () -> AsyncGate in
            calls[callIndex].released = true
            return calls[callIndex].gate
        }
        gate.notify()
    }
}
