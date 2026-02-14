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

        // macOS with downloadLatest is valid
        vm.selectedOS = .macOS
        vm.ipswSource = .downloadLatest
        #expect(vm.canAdvance == true)

        // macOS with localFile but no path is invalid
        vm.ipswSource = .localFile
        vm.ipswPath = nil
        #expect(vm.canAdvance == false)

        // macOS with localFile and path is valid
        vm.ipswPath = "/path/to/restore.ipsw"
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
        #expect(config.isoPath == "/path/to/ubuntu.iso")
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
        #expect(config.isoPath == nil)  // not EFI
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

    @Test("buildConfiguration sets isoPath only for EFI boot mode")
    func buildConfigurationIsoPathOnlyForEFI() {
        let vm = VMCreationViewModel()
        vm.selectedOS = .linux
        vm.selectedBootMode = .linuxKernel
        vm.vmName = "Test"
        vm.isoPath = "/should/be/ignored.iso"
        vm.kernelPath = "/path/to/vmlinuz"

        let config = vm.buildConfiguration()
        #expect(config.isoPath == nil)
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
}
