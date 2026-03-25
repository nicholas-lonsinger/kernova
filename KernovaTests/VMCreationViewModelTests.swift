import Testing
import Foundation
@testable import Kernova

@Suite("VMCreationViewModel Tests")
@MainActor
struct VMCreationViewModelTests {

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

        // macOS with downloadLatest but no download path is invalid
        vm.selectedOS = .macOS
        vm.ipswSource = .downloadLatest
        vm.ipswDownloadPath = nil
        #expect(vm.canAdvance == false)

        // macOS with downloadLatest and download path is valid
        vm.ipswDownloadPath = "/Users/user/Downloads/RestoreImage.ipsw"
        #expect(vm.canAdvance == true)

        // macOS with localFile but no path is invalid
        vm.ipswSource = .localFile
        vm.ipswPath = nil
        #expect(vm.canAdvance == false)

        // macOS with localFile and path is valid
        vm.ipswPath = "/path/to/restore.ipsw"
        #expect(vm.canAdvance == true)
    }

    @Test("canAdvance at bootConfig for macOS downloadLatest requires ipswDownloadPath")
    func canAdvanceBootConfigMacOSDownloadLatest() {
        let vm = VMCreationViewModel()
        vm.currentStep = .bootConfig
        vm.selectedOS = .macOS
        vm.ipswSource = .downloadLatest

        // Without download path — invalid
        vm.ipswDownloadPath = nil
        #expect(vm.canAdvance == false)

        // With download path — valid
        vm.ipswDownloadPath = "/Users/user/Downloads/RestoreImage.ipsw"
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
        #expect(vm.diskSizeInGB == VMGuestOS.macOS.defaultDiskSizeInGB)
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
        #expect(vm.diskSizeInGB == VMGuestOS.linux.defaultDiskSizeInGB)
    }

    // MARK: - buildConfiguration

    @Test("buildConfiguration produces configuration with correct fields for Linux EFI")
    func buildConfigurationLinuxEFI() {
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
        #expect(config.discImagePath == "/path/to/ubuntu.iso")
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
        #expect(config.discImagePath == nil)  // not EFI
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

    @Test("buildConfiguration sets discImagePath only for EFI boot mode")
    func buildConfigurationDiscImagePathOnlyForEFI() {
        let vm = VMCreationViewModel()
        vm.selectedOS = .linux
        vm.selectedBootMode = .linuxKernel
        vm.vmName = "Test"
        vm.isoPath = "/should/be/ignored.iso"
        vm.kernelPath = "/path/to/vmlinuz"

        let config = vm.buildConfiguration()
        #expect(config.discImagePath == nil)
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

    @Test("ipswDownloadPathFileExists is false when path is nil")
    func fileExistsFalseWhenPathNil() {
        let vm = VMCreationViewModel()
        vm.ipswDownloadPath = nil

        #expect(vm.ipswDownloadPathFileExists == false)
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

    @Test("validationMessage returns download location hint for macOS downloadLatest with nil path")
    func validationMessageMacOSDownloadLatestNoPath() {
        let vm = VMCreationViewModel()
        vm.currentStep = .bootConfig
        vm.selectedOS = .macOS
        vm.ipswSource = .downloadLatest
        vm.ipswDownloadPath = nil

        #expect(vm.validationMessage == "Choose a download location.")
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
}
