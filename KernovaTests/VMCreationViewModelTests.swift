import Testing
import Foundation
import KernovaTestSupport
@testable import Kernova

@Suite("VMCreationViewModel Tests")
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
    func canAdvanceBootConfig() {
        let vm = VMCreationViewModel()
        vm.currentStep = .bootConfig

        // macOS with downloadLatest is valid (the destination is always the
        // Downloads default; only an unresolved overwrite conflict blocks)
        vm.selectedOS = .macOS
        vm.ipswSource = .downloadLatest
        vm.ipswDownloadPath = "/nonexistent/RestoreImage.ipsw"
        #expect(vm.canAdvance == true)

        // macOS with localFile but no path is invalid
        vm.ipswSource = .localFile
        vm.ipswPath = nil
        #expect(vm.canAdvance == false)

        // macOS with localFile and path is valid
        vm.ipswPath = "/path/to/restore.ipsw"
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
        vm.ipswSource = .downloadLatest
        // Use a non-existent path so the overwrite warning doesn't trigger
        vm.ipswDownloadPath = "/nonexistent/path/RestoreImage.ipsw"
        #expect(vm.canAdvance == true)
    }

    @Test("canAdvance at bootConfig for Linux EFI requires ISO path")
    func canAdvanceBootConfigLinuxEFI() {
        let vm = VMCreationViewModel()
        vm.currentStep = .bootConfig
        vm.selectedOS = .linux
        vm.selectedBootMode = .efi

        vm.isoPath = nil
        #expect(vm.canAdvance == false)

        vm.isoPath = "/path/to/ubuntu.iso"
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

    // MARK: - applyOSDefaults

    @Test("applyOSDefaults sets correct values for macOS")
    func applyOSDefaultsMacOS() {
        let vm = VMCreationViewModel()
        vm.selectedOS = .macOS
        // Set non-default values first
        vm.cpuCount = 1
        vm.memoryInGB = 1
        vm.diskSizeInGB = 1

        vm.applyOSDefaults()

        #expect(vm.cpuCount == VMGuestOS.macOS.defaultCPUCount)
        #expect(vm.memoryInGB == VMGuestOS.macOS.defaultMemoryInGB)
        #expect(vm.diskSizeInGB == VMGuestOS.defaultDiskSizeInGB)
    }

    @Test("applyOSDefaults sets correct values for Linux")
    func applyOSDefaultsLinux() {
        let vm = VMCreationViewModel()
        vm.selectedOS = .linux
        // Set non-default values first
        vm.cpuCount = 1
        vm.memoryInGB = 1
        vm.diskSizeInGB = 1

        vm.applyOSDefaults()

        #expect(vm.cpuCount == VMGuestOS.linux.defaultCPUCount)
        #expect(vm.memoryInGB == VMGuestOS.linux.defaultMemoryInGB)
        #expect(vm.diskSizeInGB == VMGuestOS.defaultDiskSizeInGB)
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
        vm.isoPath = "/path/to/ubuntu.iso"

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
        vm.isoPath = "/path/to/image.iso"

        let config = vm.buildConfiguration()
        #expect(config.name == "Spaces Around")
    }

    @Test("buildConfiguration only installs an installer ISO for EFI boot mode")
    func buildConfigurationInstallerISOOnlyForEFI() {
        let vm = VMCreationViewModel()
        vm.selectedOS = .linux
        vm.selectedBootMode = .linuxKernel
        vm.vmName = "Test"
        vm.isoPath = "/should/be/ignored.iso"
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
        vm.isoPath = "/path/to/ubuntu.iso"
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
        vm.isoPath = "/path/to/image.iso"

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
        vm.isoPath = "/path/to/image.iso"

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
        vm.isoPath = "/path/to/image.iso"
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

    // MARK: - Overwrite Warning

    @Test("shouldShowOverwriteWarning is false when source is localFile")
    func overwriteWarningFalseForLocalFile() {
        let vm = VMCreationViewModel()
        vm.ipswSource = .localFile
        vm.ipswDownloadPath = "/usr/bin/true"  // exists on disk

        #expect(vm.shouldShowOverwriteWarning == false)
    }

    @Test("shouldShowOverwriteWarning is false when file does not exist at path")
    func overwriteWarningFalseWhenFileDoesNotExist() {
        let vm = VMCreationViewModel()
        vm.ipswSource = .downloadLatest
        vm.ipswDownloadPath = "/nonexistent/path/RestoreImage.ipsw"

        #expect(vm.shouldShowOverwriteWarning == false)
    }

    @Test("shouldShowOverwriteWarning is true when download source and file exists")
    func overwriteWarningTrueWhenDownloadAndFileExists() {
        let vm = VMCreationViewModel()
        vm.ipswSource = .downloadLatest
        vm.ipswDownloadPath = "/usr/bin/true"  // exists on disk

        #expect(vm.shouldShowOverwriteWarning == true)
    }

    @Test("confirmOverwrite suppresses warning for current path")
    func confirmOverwriteSuppressesWarning() {
        let vm = VMCreationViewModel()
        vm.ipswSource = .downloadLatest
        vm.ipswDownloadPath = "/usr/bin/true"
        #expect(vm.shouldShowOverwriteWarning == true)

        vm.confirmOverwrite()
        #expect(vm.shouldShowOverwriteWarning == false)
    }

    @Test("changing path after confirmOverwrite resets warning")
    func changingPathResetsConfirmation() {
        let vm = VMCreationViewModel()
        vm.ipswSource = .downloadLatest
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
        vm.ipswSource = .downloadLatest
        vm.ipswDownloadPath = "/usr/bin/true"

        vm.useExistingDownloadFile()

        #expect(vm.ipswSource == .localFile)
        #expect(vm.ipswPath == "/usr/bin/true")
    }

    @Test("canAdvance is false when overwrite warning is unresolved")
    func canAdvanceFalseWithUnresolvedOverwriteWarning() {
        let vm = VMCreationViewModel()
        vm.currentStep = .bootConfig
        vm.selectedOS = .macOS
        vm.ipswSource = .downloadLatest
        vm.ipswDownloadPath = "/usr/bin/true"  // exists on disk → triggers warning

        #expect(vm.shouldShowOverwriteWarning == true)
        #expect(vm.canAdvance == false)
    }

    @Test("canAdvance is true after confirming overwrite")
    func canAdvanceTrueAfterConfirmingOverwrite() {
        let vm = VMCreationViewModel()
        vm.currentStep = .bootConfig
        vm.selectedOS = .macOS
        vm.ipswSource = .downloadLatest
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
        vm.isoPath = "/path/to/image.iso"
        #expect(vm.validationMessage == nil)

        // resources with valid name
        vm.currentStep = .resources
        vm.vmName = "My VM"
        #expect(vm.validationMessage == nil)
    }

    @Test("validationMessage returns ISO hint for Linux EFI with no isoPath")
    func validationMessageLinuxEFINoISO() {
        let vm = VMCreationViewModel()
        vm.currentStep = .bootConfig
        vm.selectedOS = .linux
        vm.selectedBootMode = .efi
        vm.isoPath = nil

        #expect(vm.validationMessage == "Select an ISO image to continue.")
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

    @Test("validationMessage returns IPSW hint for macOS localFile with no ipswPath")
    func validationMessageMacOSLocalFileNoIPSW() {
        let vm = VMCreationViewModel()
        vm.currentStep = .bootConfig
        vm.selectedOS = .macOS
        vm.ipswSource = .localFile
        vm.ipswPath = nil

        #expect(vm.validationMessage == "Select a restore image file.")
    }

    @Test("validationMessage returns conflict hint when overwrite warning is showing")
    func validationMessageOverwriteConflict() {
        let vm = VMCreationViewModel()
        vm.currentStep = .bootConfig
        vm.selectedOS = .macOS
        vm.ipswSource = .downloadLatest
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

    // MARK: - buildInstallContext

    @Test("buildInstallContext snapshots downloadLatest with chosen path")
    func buildInstallContextDownloadLatest() {
        let vm = VMCreationViewModel()
        vm.ipswSource = .downloadLatest
        vm.ipswDownloadPath = "/Users/me/Downloads/RestoreImage.ipsw"

        let context = vm.buildInstallContext()

        #expect(context.source == .downloadLatest)
        #expect(context.downloadDestinationPath == "/Users/me/Downloads/RestoreImage.ipsw")
        #expect(context.localIPSWPath == nil)
    }

    @Test("buildInstallContext snapshots localFile with chosen path")
    func buildInstallContextLocalFile() {
        let vm = VMCreationViewModel()
        vm.ipswSource = .localFile
        vm.ipswPath = "/tmp/macOS-26.ipsw"

        let context = vm.buildInstallContext()

        #expect(context.source == .localFile)
        #expect(context.localIPSWPath == "/tmp/macOS-26.ipsw")
        #expect(context.downloadDestinationPath == nil)
        #expect(!context.requestedFreshDownload)
    }

    @Test("buildInstallContext defaults requestedFreshDownload to false")
    func buildInstallContextDefaultsFreshFalse() {
        let vm = VMCreationViewModel()
        vm.ipswSource = .downloadLatest
        vm.ipswDownloadPath = "/Users/me/Downloads/RestoreImage.ipsw"

        let context = vm.buildInstallContext()

        #expect(!context.requestedFreshDownload)
    }

    @Test("buildInstallContext sets requestedFreshDownload when overwrite confirmed")
    func buildInstallContextSetsFreshOnConfirmedOverwrite() {
        let vm = VMCreationViewModel()
        vm.ipswSource = .downloadLatest
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
        vm.ipswSource = .downloadLatest
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

        #expect(vm.ipswSource == .catalogVersion)
        #expect(vm.selectedCatalogEntry == entry)
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

    @Test("Returning to Download Latest restores the fixed destination")
    func downloadLatestRestoresDefaultDestination() {
        let vm = VMCreationViewModel()
        vm.selectCatalogEntry(makeCatalogEntry())
        vm.selectDownloadLatest()

        #expect(vm.ipswSource == .downloadLatest)
        #expect(vm.selectedCatalogEntry == nil)
        #expect(vm.ipswDownloadPath == VMCreationViewModel.defaultIPSWDownloadPath)
    }

    @Test("The catalog source cannot advance until a version is chosen")
    func catalogSourceRequiresAPick() {
        let vm = VMCreationViewModel()
        vm.currentStep = .bootConfig
        vm.ipswSource = .catalogVersion

        #expect(!vm.canAdvance)
        #expect(vm.validationMessage == "Choose a macOS version to continue.")

        vm.selectCatalogEntry(makeCatalogEntry())
        #expect(vm.canAdvance)
        #expect(vm.validationMessage == nil)
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
        vm.useExistingDownloadFile()

        #expect(vm.ipswSource == .localFile)
        #expect(vm.ipswPath == destination)
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

        #expect(vm.ipswSource == .customURL)
        #expect(vm.pastedImage == image)
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

    @Test("The URL source cannot advance until a URL is checked")
    func customURLSourceRequiresACheckedImage() {
        let vm = VMCreationViewModel()
        vm.currentStep = .bootConfig
        vm.ipswSource = .customURL

        #expect(!vm.canAdvance)
        #expect(vm.validationMessage == "Add a restore image URL to continue.")

        vm.selectPastedImage(makeProbedImage())
        #expect(vm.canAdvance)
        #expect(vm.validationMessage == nil)
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

    // MARK: - Adopting an Existing File

    @Test("An existing file matching the pinned build is adopted")
    func adoptsMatchingExistingFile() async {
        let inspector = MockLocalRestoreImageInspector()
        inspector.inspectResult = InspectedRestoreImage(
            version: "15.6.1", build: "24G90", isSupportedOnThisHost: true)
        let vm = VMCreationViewModel(localImageInspector: inspector)
        vm.selectCatalogEntry(makeCatalogEntry(version: "15.6.1", build: "24G90"))
        let destination = vm.ipswDownloadPath

        let verdict = await vm.adoptExistingDownloadFile()

        #expect(verdict == .adopted(inspector.inspectResult))
        #expect(vm.ipswSource == .localFile)
        #expect(vm.ipswPath == destination)
        #expect(inspector.lastInspectedURL?.path(percentEncoded: false) == destination)
    }

    @Test("An existing file of a different build is reported, not adopted")
    func refusesMismatchedExistingFile() async {
        let inspector = MockLocalRestoreImageInspector()
        inspector.inspectResult = InspectedRestoreImage(
            version: "14.2", build: "23C64", isSupportedOnThisHost: true)
        let vm = VMCreationViewModel(localImageInspector: inspector)
        vm.selectCatalogEntry(makeCatalogEntry(version: "15.6.1", build: "24G90"))

        let verdict = await vm.adoptExistingDownloadFile()

        #expect(verdict == .mismatch(expected: "24G90", found: inspector.inspectResult))
        // The wrong-image install this exists to prevent.
        #expect(vm.ipswSource == .catalogVersion)
        #expect(vm.ipswPath == nil)
    }

    @Test("An unreadable file is refused with a reason")
    func refusesUnreadableExistingFile() async {
        let inspector = MockLocalRestoreImageInspector()
        inspector.inspectError = LocalRestoreImageError.unreadable
        let vm = VMCreationViewModel(localImageInspector: inspector)
        vm.selectCatalogEntry(makeCatalogEntry())

        let verdict = await vm.adoptExistingDownloadFile()

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

        let verdict = await vm.adoptExistingDownloadFile()

        #expect(
            verdict
                == .unusable(
                    message: LocalRestoreImageError.unsupported.errorDescription ?? ""))
        #expect(vm.ipswSource == .catalogVersion)
    }

    @Test("Download Latest pins no build, so any usable image is adopted")
    func downloadLatestAdoptsAnyUsableImage() async {
        let inspector = MockLocalRestoreImageInspector()
        inspector.inspectResult = InspectedRestoreImage(
            version: "14.2", build: "23C64", isSupportedOnThisHost: true)
        let vm = VMCreationViewModel(localImageInspector: inspector)
        vm.selectDownloadLatest()

        #expect(vm.pinnedBuild == nil)
        let verdict = await vm.adoptExistingDownloadFile()

        #expect(verdict == .adopted(inspector.inspectResult))
        #expect(vm.ipswSource == .localFile)
    }

    @Test("A URL pick with no parsed build pins nothing to compare against")
    func customURLWithoutBuildPinsNothing() async {
        let inspector = MockLocalRestoreImageInspector()
        let vm = VMCreationViewModel(localImageInspector: inspector)
        vm.selectPastedImage(
            makeProbedImage(
                urlString: "https://example.com/image.ipsw", version: nil, build: nil))

        #expect(vm.pinnedBuild == nil)
        #expect(await vm.adoptExistingDownloadFile() == .adopted(inspector.inspectResult))
    }

    @Test("An inspection cancelled mid-flight adopts nothing")
    func cancelledInspectionAdoptsNothing() async throws {
        let inspector = SuspendingMockLocalRestoreImageInspector()
        let vm = VMCreationViewModel(localImageInspector: inspector)
        // The build matches, so only the cancellation keeps this from adopting.
        vm.selectCatalogEntry(makeCatalogEntry(version: "15.6.1", build: "24G90"))

        let adopt = Task { await vm.adoptExistingDownloadFile() }
        try await inspector.waitUntilInspecting()
        adopt.cancel()
        inspector.release()

        #expect(await adopt.value == .cancelled)
        #expect(vm.ipswSource == .catalogVersion)
        #expect(vm.ipswPath == nil)
    }

    @Test("pinnedBuild names the build each source is promising")
    func pinnedBuildTracksTheSource() {
        let vm = VMCreationViewModel()
        #expect(vm.pinnedBuild == nil)

        vm.selectCatalogEntry(makeCatalogEntry(build: "24G90"))
        #expect(vm.pinnedBuild == "24G90")

        vm.selectPastedImage(makeProbedImage(build: "25G72"))
        #expect(vm.pinnedBuild == "25G72")

        vm.selectDownloadLatest()
        #expect(vm.pinnedBuild == nil)
    }

    @Test("Switching between pinned sources keeps both picks; Download Latest clears them")
    func downloadLatestClearsBothPinnedPicks() {
        let vm = VMCreationViewModel()
        vm.selectCatalogEntry(makeCatalogEntry())
        vm.selectPastedImage(makeProbedImage())
        #expect(vm.selectedCatalogEntry != nil)
        #expect(vm.pastedImage != nil)

        // Download Latest is the one source that owns neither pick.
        vm.selectDownloadLatest()
        #expect(vm.selectedCatalogEntry == nil)
        #expect(vm.pastedImage == nil)
    }
}

/// Inspector stand-in that stays inside `inspect` until the test releases it,
/// the way a multi-gigabyte image keeps the real one busy for seconds.
final class SuspendingMockLocalRestoreImageInspector: LocalRestoreImageInspecting, @unchecked Sendable {
    private let inspectResult = InspectedRestoreImage(
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
