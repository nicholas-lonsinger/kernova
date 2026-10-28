import Foundation
import KernovaCommandModel
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport

@Suite("VMCreationViewModel Tests", .caseScoped)
@MainActor
struct VMCreationViewModelTests {
    /// The standardized directory a path sits in.
    private func parentPath(of path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.deletingLastPathComponent()
            .path(percentEncoded: false)
    }

    /// The Downloads directory every download destination of `vm` must stay
    /// inside.
    private func downloadsPath(of vm: VMCreationViewModel) -> String {
        parentPath(of: vm.downloadPath(forFilename: "Probe.ipsw"))
    }

    /// Puts a file at `path`, as an earlier download would have left one.
    private func placeFile(at path: String?) throws {
        let path = try #require(path)
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(),
            withIntermediateDirectories: true)
        #expect(FileManager.default.createFile(atPath: path, contents: Data()))
    }

    /// A wizard on a catalog pick whose destination already holds a file.
    private func wizardWithFileAtTheDestination() throws -> VMCreationViewModel {
        let vm = VMCreationViewModel.overFakeEngine()
        vm.selectCatalogEntry(makeCatalogEntry())
        try placeFile(at: vm.ipswDownloadPath)
        return vm
    }

    // MARK: - Navigation

    @Test("goNext advances through all steps in order")
    func goNextAdvancesThroughSteps() async {
        let vm = VMCreationViewModel.overFakeEngine(probeService: MockRestoreImageProbeService())
        await vm.loadLatestImageDetails()?.value
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
        let vm = VMCreationViewModel.overFakeEngine()
        vm.currentStep = .review

        vm.goNext()
        #expect(vm.currentStep == .review)
    }

    @Test("goNext refuses a step that can't advance")
    func goNextRefusesAStepThatCannotAdvance() {
        let vm = VMCreationViewModel.overFakeEngine()
        vm.selectedOS = .linux
        vm.currentStep = .bootConfig
        #expect(!vm.canAdvance)

        vm.goNext()
        #expect(vm.currentStep == .bootConfig)
    }

    @Test("goBack retreats through steps in order")
    func goBackRetreatsThroughSteps() {
        let vm = VMCreationViewModel.overFakeEngine()
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
        let vm = VMCreationViewModel.overFakeEngine()
        #expect(vm.currentStep == .osSelection)

        vm.goBack()
        #expect(vm.currentStep == .osSelection)
    }

    // MARK: - canAdvance

    @Test("canAdvance is always true at osSelection step")
    func canAdvanceOSSelection() {
        let vm = VMCreationViewModel.overFakeEngine()
        vm.currentStep = .osSelection
        #expect(vm.canAdvance == true)
    }

    @Test("canAdvance at bootConfig depends on OS and mode selections")
    func canAdvanceBootConfig() async {
        let vm = VMCreationViewModel.overFakeEngine(localImageInspector: MockLocalRestoreImageInspector())
        vm.currentStep = .bootConfig
        vm.selectedOS = .macOS
        vm.selectCatalogEntry(makeCatalogEntry())
        #expect(vm.canAdvance == true)

        // A local file blocks until its inspection lands with a usable verdict.
        vm.selectLocalFile(path: "/path/to/restore.ipsw", bookmark: nil)
        #expect(vm.canAdvance == false)
        await vm.localFileInspectionTask?.value
        #expect(vm.canAdvance == true)
        #expect(vm.validationMessage == nil)
    }

    @Test("Download Latest can't leave its step until the lookup has answered")
    func downloadLatestWaitsForTheLookup() async {
        let vm = VMCreationViewModel.overFakeEngine(
            probeService: MockRestoreImageProbeService(), ipswService: MockIPSWService())
        vm.currentStep = .bootConfig

        #expect(vm.latestImageLookup == .unanswered)
        #expect(!vm.canAdvance)
        #expect(vm.validationMessage == "Looking up the latest macOS\u{2026}")
        vm.goNext()
        #expect(vm.currentStep == .bootConfig)

        await vm.loadLatestImageDetails()?.value
        #expect(vm.canAdvance)
        #expect(vm.validationMessage == nil)
    }

    @Test("A failed lookup lets the step advance with no file named")
    func failedLookupLetsTheStepAdvance() async {
        let ipswService = MockIPSWService()
        ipswService.fetchError = URLError(.notConnectedToInternet)
        let vm = VMCreationViewModel.overFakeEngine(
            probeService: MockRestoreImageProbeService(), ipswService: ipswService)
        vm.currentStep = .bootConfig

        await vm.loadLatestImageDetails()?.value

        #expect(vm.latestImageLookup == .failed)
        #expect(vm.canAdvance)
        vm.goNext()
        #expect(vm.currentStep == .resources)
    }

    @Test("Download Latest names no destination until the lookup answers")
    func downloadLatestHasNoDestinationBeforeTheLookup() {
        let vm = VMCreationViewModel.overFakeEngine()

        #expect(vm.ipswSource == .downloadLatest)
        #expect(vm.ipswDownloadPath == nil)
        #expect(vm.buildInstallContext().downloadDestinationPath == nil)
    }

    @Test("canAdvance at bootConfig for Linux EFI requires an image selection")
    func canAdvanceBootConfigLinuxEFI() {
        let vm = VMCreationViewModel.overFakeEngine()
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
        let vm = VMCreationViewModel.overFakeEngine()
        vm.currentStep = .bootConfig
        vm.selectedOS = .linux
        vm.selectedBootMode = .efi

        vm.selectLinuxCatalogEntry(makeLinuxCatalogEntry())
        #expect(vm.canAdvance == true)
    }

    @Test("canAdvance at bootConfig for Linux kernel requires kernel path")
    func canAdvanceBootConfigLinuxKernel() {
        let vm = VMCreationViewModel.overFakeEngine()
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
        let vm = VMCreationViewModel.overFakeEngine()
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
        let vm = VMCreationViewModel.overFakeEngine()
        vm.currentStep = .review
        #expect(vm.canAdvance == true)
    }

    // MARK: - canCreate

    @Test("canCreate requires non-empty trimmed name")
    func canCreate() {
        let vm = VMCreationViewModel.overFakeEngine()

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
        let vm = VMCreationViewModel.overFakeEngine()
        vm.selectedOS = .macOS
        vm.selectedBootMode = .efi  // should be overridden

        #expect(vm.effectiveBootMode == .macOS)
    }

    @Test("effectiveBootMode returns selectedBootMode for Linux guest")
    func effectiveBootModeLinux() {
        let vm = VMCreationViewModel.overFakeEngine()
        vm.selectedOS = .linux

        vm.selectedBootMode = .efi
        #expect(vm.effectiveBootMode == .efi)

        vm.selectedBootMode = .linuxKernel
        #expect(vm.effectiveBootMode == .linuxKernel)
    }

    // MARK: - Resource defaults

    @Test("Resources start at the selected guest's defaults", arguments: VMGuestOS.allCases)
    func resourceDefaultsFollowTheGuest(os: VMGuestOS) {
        let vm = VMCreationViewModel.overFakeEngine()
        vm.selectedOS = os

        #expect(vm.cpuCount == os.defaultCPUCount(within: FakeVirtualizationHost.resourceLimits))
        #expect(vm.memorySize == os.defaultMemorySize(within: FakeVirtualizationHost.resourceLimits))
        #expect(vm.diskSizeInGB == VMGuestOS.defaultDiskSizeInGB)
    }

    @Test("Switching guest resets the resources to the new guest's defaults; reselecting it keeps them")
    func switchingGuestResetsResources() {
        let vm = VMCreationViewModel.overFakeEngine()
        vm.cpuCount = 3
        vm.memorySize = VMMemorySize(mebibytes: 1536)

        vm.selectedOS = .macOS
        #expect(vm.cpuCount == 3)
        #expect(vm.memorySize.mebibytes == 1536)

        vm.selectedOS = .linux
        #expect(vm.cpuCount == VMGuestOS.linux.defaultCPUCount(within: FakeVirtualizationHost.resourceLimits))
        #expect(vm.memorySize == VMGuestOS.linux.defaultMemorySize(within: FakeVirtualizationHost.resourceLimits))
    }

    // MARK: - buildConfiguration

    @Test("buildConfiguration produces configuration with correct fields for Linux EFI")
    func buildConfigurationLinuxEFI() throws {
        let vm = VMCreationViewModel.overFakeEngine()
        vm.selectedOS = .linux
        vm.selectedBootMode = .efi
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

    @Test("buildConfiguration produces configuration with correct fields for Linux kernel")
    func buildConfigurationLinuxKernel() {
        let vm = VMCreationViewModel.overFakeEngine()
        vm.selectedOS = .linux
        vm.selectedBootMode = .linuxKernel
        vm.vmName = "Kernel VM"
        vm.cpuCount = 2
        vm.memorySize = .gibibytes(4)
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

    @Test("buildConfiguration only installs an installer ISO for EFI boot mode")
    func buildConfigurationInstallerISOOnlyForEFI() {
        let vm = VMCreationViewModel.overFakeEngine()
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
        let vm = VMCreationViewModel.overFakeEngine()
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

    @Test("buildConfiguration does not set genericMachineIdentifierData for macOS boot mode")
    func buildConfigurationNoGenericMachineIdentifierForMacOS() {
        let vm = VMCreationViewModel.overFakeEngine()
        vm.selectedOS = .macOS
        vm.vmName = "macOS Test"

        let config = vm.buildConfiguration()
        #expect(config.genericMachineIdentifierData == nil)
    }

    // MARK: - Linux Image Selection

    @Test("Each Linux source replaces the last, so only one pick is ever current")
    func linuxSourcesReplaceEachOther() {
        let vm = VMCreationViewModel.overFakeEngine()
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
        let vm = VMCreationViewModel.overFakeEngine()
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
        let vm = VMCreationViewModel.overFakeEngine()
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

    // MARK: - Overwrite Warning

    @Test("shouldShowOverwriteWarning is false when source is localFile")
    func overwriteWarningFalseForLocalFile() throws {
        let vm = try wizardWithFileAtTheDestination()
        vm.selectLocalFile(path: "/tmp/picked.ipsw", bookmark: nil)

        #expect(vm.ipswDownloadPath == nil)
        #expect(vm.shouldShowOverwriteWarning == false)
    }

    @Test("shouldShowOverwriteWarning is false when file does not exist at path")
    func overwriteWarningFalseWhenFileDoesNotExist() {
        let vm = VMCreationViewModel.overFakeEngine()
        vm.selectCatalogEntry(makeCatalogEntry())

        #expect(vm.shouldShowOverwriteWarning == false)
    }

    @Test("confirmOverwrite suppresses warning for current path")
    func confirmOverwriteSuppressesWarning() throws {
        let vm = try wizardWithFileAtTheDestination()
        #expect(vm.shouldShowOverwriteWarning == true)

        vm.confirmOverwrite()
        #expect(vm.shouldShowOverwriteWarning == false)
    }

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

    @Test("useExistingDownloadFile switches source to localFile and copies path")
    func useExistingDownloadFileSwitchesSource() {
        let vm = VMCreationViewModel.overFakeEngine()
        let inspected = InspectedRestoreImage(
            version: "15.6.1", build: "24G90", isSupportedOnThisHost: true, sizeBytes: 1_000)

        vm.useExistingDownloadFile(at: "/tmp/RestoreImage.ipsw", inspected: inspected)

        #expect(
            vm.ipswSelection
                == .localFile(
                    LocalRestoreImage(
                        path: "/tmp/RestoreImage.ipsw", bookmark: nil, inspection: .usable(inspected))))
    }

    @Test("canAdvance is true after confirming overwrite")
    func canAdvanceTrueAfterConfirmingOverwrite() throws {
        let vm = try wizardWithFileAtTheDestination()
        vm.currentStep = .bootConfig
        vm.selectedOS = .macOS
        #expect(vm.canAdvance == false)

        vm.confirmOverwrite()
        #expect(vm.shouldShowOverwriteWarning == false)
        #expect(vm.canAdvance == true)
    }

    // MARK: - validationMessage

    @Test("validationMessage is nil when canAdvance is true")
    func validationMessageNilWhenCanAdvance() {
        let vm = VMCreationViewModel.overFakeEngine()

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
        let vm = VMCreationViewModel.overFakeEngine()
        vm.currentStep = .bootConfig
        vm.selectedOS = .linux
        vm.selectedBootMode = .efi

        #expect(vm.validationMessage == "Select an installer image to continue.")
    }

    @Test("validationMessage returns kernel hint for Linux kernel with no kernelPath")
    func validationMessageLinuxKernelNoKernel() {
        let vm = VMCreationViewModel.overFakeEngine()
        vm.currentStep = .bootConfig
        vm.selectedOS = .linux
        vm.selectedBootMode = .linuxKernel
        vm.kernelPath = nil

        #expect(vm.validationMessage == "Select a kernel image to continue.")
    }

    @Test("validationMessage returns conflict hint when overwrite warning is showing")
    func validationMessageOverwriteConflict() throws {
        let vm = try wizardWithFileAtTheDestination()
        vm.currentStep = .bootConfig
        vm.selectedOS = .macOS

        #expect(vm.shouldShowOverwriteWarning == true)
        #expect(vm.validationMessage == "Resolve the file conflict above to continue.")
    }

    @Test("validationMessage returns name hint for resources step with empty name")
    func validationMessageResourcesEmptyName() {
        let vm = VMCreationViewModel.overFakeEngine()
        vm.currentStep = .resources

        vm.vmName = ""
        #expect(vm.validationMessage == "Enter a name for your virtual machine.")

        vm.vmName = "   "
        #expect(vm.validationMessage == "Enter a name for your virtual machine.")
    }

    // MARK: - buildLinuxInstallContext

    @Test("buildLinuxInstallContext snapshots a catalog pick with nothing downloaded yet")
    func buildLinuxInstallContextCatalogPick() throws {
        let vm = VMCreationViewModel.overFakeEngine()
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
        let vm = VMCreationViewModel.overFakeEngine()
        let digest = String(repeating: "a", count: 64)
        let image = makeCustomLinuxImage(sha256: digest)
        vm.selectLinuxCustomURL(image, sizeBytes: 1_073_741_824)

        let context = try #require(vm.buildLinuxInstallContext())

        #expect(
            customImage(of: context)?.url
                == URL(string: "https://mirror.example/alpine-3.22-aarch64.iso"))
        #expect(customImage(of: context)?.sha256 == digest)
        #expect(context.source.digestSource == .enteredByUser)
        // A fixed URL names its own destination, so unlike a catalog pick it is
        // known before the VM is created — and it is unique to the link, so it
        // can never land on a file the user already has.
        let destination = LinuxImageFilename.destination(for: image.url)
        #expect(destination != "alpine-3.22-aarch64.iso")
        #expect(context.downloadDestinationPath == vm.downloadPath(forFilename: destination))
    }

    @Test("A URL pick with no checksum carries none, and has nothing to verify")
    func buildLinuxInstallContextUnverifiedURLPick() throws {
        let vm = VMCreationViewModel.overFakeEngine()
        vm.selectLinuxCustomURL(makeCustomLinuxImage(sha256: nil), sizeBytes: 1_073_741_824)

        let context = try #require(vm.buildLinuxInstallContext())

        #expect(customImage(of: context)?.sha256 == nil)
        #expect(context.source.digestSource == nil)
    }

    @Test("An EFI image pick does not follow a switch to Linux-kernel boot")
    func buildLinuxInstallContextGatedOnEFI() {
        let vm = VMCreationViewModel.overFakeEngine()
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
        let vm = VMCreationViewModel.overFakeEngine()
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
        let vm = VMCreationViewModel.overFakeEngine()
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

    @Test("buildInstallContext snapshots downloadLatest with the looked-up destination")
    func buildInstallContextDownloadLatest() async {
        let vm = VMCreationViewModel.overFakeEngine(
            probeService: MockRestoreImageProbeService(), ipswService: MockIPSWService())
        await vm.loadLatestImageDetails()?.value

        let context = vm.buildInstallContext()

        #expect(context.source == .downloadLatest)
        #expect(
            context.downloadDestinationPath
                == vm.downloadPath(forFilename: "UniversalMac_26.5.2_25F84_Restore.ipsw"))
        #expect(context.localIPSWPath == nil)
        #expect(!context.requestedFreshDownload)
    }

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

    @Test("each selection maps to its persisted install-context source")
    func installContextSourceCoversEverySelection() {
        let vm = VMCreationViewModel.overFakeEngine(localImageInspector: MockLocalRestoreImageInspector())
        #expect(vm.buildInstallContext().source == .downloadLatest)

        vm.selectCatalogEntry(makeCatalogEntry())
        #expect(vm.buildInstallContext().source == .catalogVersion)

        vm.selectPastedImage(makeProbedImage())
        #expect(vm.buildInstallContext().source == .customURL)

        vm.selectLocalFile(path: "/tmp/macOS-26.ipsw", bookmark: nil)
        #expect(vm.buildInstallContext().source == .localFile)
    }

    @Test("buildInstallContext sets requestedFreshDownload when overwrite confirmed")
    func buildInstallContextSetsFreshOnConfirmedOverwrite() async {
        let vm = VMCreationViewModel.overFakeEngine(
            probeService: MockRestoreImageProbeService(), ipswService: MockIPSWService())
        await vm.loadLatestImageDetails()?.value
        vm.confirmOverwrite()

        let context = vm.buildInstallContext()

        #expect(context.requestedFreshDownload)
    }

    @Test("buildInstallContext clears requestedFreshDownload when path changes after confirm")
    func buildInstallContextClearsFreshWhenPathChangedAfterConfirm() {
        // `confirmOverwrite` records the path that was confirmed; if the user
        // then picks a different destination, the confirmation no longer
        // applies and the wizard should treat the new path as not-yet-confirmed.
        let vm = VMCreationViewModel.overFakeEngine()
        vm.selectCatalogEntry(makeCatalogEntry(version: "15.6.1", build: "24G90"))
        vm.confirmOverwrite()
        vm.selectCatalogEntry(makeCatalogEntry(version: "26.6", build: "25G72"))

        let context = vm.buildInstallContext()

        #expect(!context.requestedFreshDownload)
    }

    // MARK: - Start After Create

    @Test("startAfterCreate defaults to true")
    func startAfterCreateDefaultsTrue() {
        let vm = VMCreationViewModel.overFakeEngine()
        #expect(vm.startAfterCreate == true)
    }

    // MARK: - Catalog Version Source

    @Test("Choosing a catalog version moves the destination to Apple's filename")
    func catalogPickUsesPerBuildDestination() {
        let vm = VMCreationViewModel.overFakeEngine()
        let entry = makeCatalogEntry(version: "15.6.1", build: "24G90")
        vm.selectCatalogEntry(entry)

        #expect(vm.ipswSelection == .catalogVersion(entry))
        #expect(
            vm.ipswDownloadPath
                == vm.downloadPath(forFilename: "UniversalMac_15.6.1_24G90_Restore.ipsw"))
    }

    @Test("Two different picks never resolve to the same destination")
    func distinctPicksGetDistinctDestinations() {
        let vm = VMCreationViewModel.overFakeEngine()
        vm.selectCatalogEntry(makeCatalogEntry(version: "15.6.1", build: "24G90"))
        let first = vm.ipswDownloadPath
        vm.selectCatalogEntry(makeCatalogEntry(version: "26.6", build: "25G72"))

        #expect(first != vm.ipswDownloadPath)
    }

    @Test("Two spins of one version get distinct destinations")
    func sameVersionDifferentBuildsGetDistinctDestinations() {
        let vm = VMCreationViewModel.overFakeEngine()
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

    @Test("Returning to Download Latest names no destination until the lookup answers")
    func downloadLatestReturnsToNoDestination() {
        let vm = VMCreationViewModel.overFakeEngine()
        vm.selectCatalogEntry(makeCatalogEntry())
        vm.selectDownloadLatest()

        #expect(vm.ipswSelection == .downloadLatest)
        #expect(vm.ipswDownloadPath == nil)
    }

    @Test("The looked-up image names Download Latest's destination")
    func downloadLatestUsesTheLookedUpFilename() async {
        let vm = VMCreationViewModel.overFakeEngine(
            probeService: MockRestoreImageProbeService(), ipswService: MockIPSWService())

        await vm.loadLatestImageDetails()?.value

        let expected = vm.downloadPath(forFilename: "UniversalMac_26.5.2_25F84_Restore.ipsw")
        #expect(vm.ipswDownloadPath == expected)

        // And a later re-pick names the same file, the answer being in hand.
        vm.selectCatalogEntry(makeCatalogEntry())
        vm.selectDownloadLatest()
        #expect(vm.ipswDownloadPath == expected)
    }

    @Test("A lookup landing after another source was picked leaves that pick's destination")
    func lateLookupLeavesAnotherSourcesDestination() async {
        let vm = VMCreationViewModel.overFakeEngine(
            probeService: MockRestoreImageProbeService(), ipswService: MockIPSWService())

        // The pick happens while the lookup is in flight: nothing has awaited,
        // so the completion runs strictly after it.
        let lookup = vm.loadLatestImageDetails()
        vm.selectCatalogEntry(makeCatalogEntry(version: "15.6.1", build: "24G90"))
        await lookup?.value

        #expect(vm.latestImageLookup.foundImage?.build == "25F84")
        #expect(
            vm.ipswDownloadPath
                == vm.downloadPath(forFilename: "UniversalMac_15.6.1_24G90_Restore.ipsw"))
    }

    @Test("A failed lookup leaves Download Latest with no file destination, for the install to name")
    func failedLookupNamesNoFile() async throws {
        let ipswService = MockIPSWService()
        ipswService.fetchError = URLError(.notConnectedToInternet)
        let vm = VMCreationViewModel.overFakeEngine(
            probeService: MockRestoreImageProbeService(), ipswService: ipswService)
        // A file under any name in Downloads is no file this download names.
        try placeFile(at: vm.downloadPath(forFilename: "RestoreImage.ipsw"))

        await vm.loadLatestImageDetails()?.value

        #expect(vm.latestImageLookup == .failed)
        #expect(vm.ipswDownloadPath == nil)
        #expect(!vm.shouldShowOverwriteWarning)
        #expect(!vm.hasResumableDownload)
        #expect(vm.buildInstallContext().downloadDestinationPath == nil)
    }

    @Test("The overwrite warning and resume check cover the catalog source")
    func catalogSourceSharesDownloadWarnings() throws {
        let vm = try wizardWithFileAtTheDestination()
        vm.currentStep = .bootConfig
        #expect(vm.shouldShowOverwriteWarning)
        #expect(!vm.canAdvance)

        vm.confirmOverwrite()
        #expect(!vm.shouldShowOverwriteWarning)
        #expect(vm.canAdvance)
    }

    @Test("A catalog install context pins the URL, version, and build")
    func catalogInstallContextPinsTheImage() {
        let vm = VMCreationViewModel.overFakeEngine()
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
        let vm = VMCreationViewModel.overFakeEngine()
        vm.selectCatalogEntry(makeCatalogEntry())
        vm.confirmOverwrite()

        #expect(vm.buildInstallContext().requestedFreshDownload)
    }

    @Test("Use Existing File adopts the per-build download as a local file")
    func useExistingAdoptsPerBuildPath() throws {
        let vm = VMCreationViewModel.overFakeEngine()
        vm.selectCatalogEntry(makeCatalogEntry(version: "15.6.1", build: "24G90"))
        let destination = try #require(vm.ipswDownloadPath)
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
    func useExistingKeepsTheSeed() throws {
        let vm = VMCreationViewModel.overFakeEngine()
        let entry = makeCatalogEntry(version: "15.6.1", build: "24G90")
        vm.selectCatalogEntry(entry)
        vm.useExistingDownloadFile(
            at: try #require(vm.ipswDownloadPath),
            inspected: InspectedRestoreImage(
                version: "15.6.1", build: "24G90", isSupportedOnThisHost: true))

        #expect(vm.ipswSource == .localFile)
        #expect(vm.lastCatalogPick == entry)
    }

    // MARK: - Custom URL Source

    @Test("A checked URL moves the destination to that image's filename")
    func pastedImageUsesPerImageDestination() {
        let vm = VMCreationViewModel.overFakeEngine()
        let image = makeProbedImage()
        vm.selectPastedImage(image)

        #expect(vm.ipswSelection == .customURL(image))
        #expect(
            vm.ipswDownloadPath
                == vm.downloadPath(forFilename: "UniversalMac_15.6.1_24G90_Restore.ipsw"))
    }

    @Test("An off-convention URL lands on a filename generated for it")
    func pastedImageWithoutIPSWNameGetsItsOwnDestination() throws {
        let vm = VMCreationViewModel.overFakeEngine()
        let image = makeProbedImage(urlString: "https://example.com/d/", version: nil, build: nil)
        vm.selectPastedImage(image)

        let destination = try #require(vm.ipswDownloadPath)
        #expect(destination == vm.downloadPath(forFilename: RestoreImageFilename.unique(for: image.url)))
        #expect(parentPath(of: destination) == downloadsPath(of: vm))
    }

    @Test("Two off-convention URLs sharing a basename get different destinations")
    func pastedImagesWithOneBasenameGetDistinctDestinations() {
        let vm = VMCreationViewModel.overFakeEngine()
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
    func pastedImageWithTraversalStaysInDownloads() throws {
        let vm = VMCreationViewModel.overFakeEngine()
        // Decodes to `a/../../evil.ipsw`, which appended verbatim would
        // standardize to a path two directories above Downloads.
        vm.selectPastedImage(
            makeProbedImage(
                urlString: "https://host/a%2F..%2F..%2Fevil.ipsw", version: nil, build: nil))

        #expect(parentPath(of: try #require(vm.ipswDownloadPath)) == downloadsPath(of: vm))
    }

    @Test("The URL source shares the overwrite warning")
    func customURLSourceSharesDownloadWarnings() throws {
        let vm = VMCreationViewModel.overFakeEngine()
        vm.currentStep = .bootConfig
        vm.selectPastedImage(makeProbedImage())
        try placeFile(at: vm.ipswDownloadPath)
        #expect(vm.shouldShowOverwriteWarning)
        #expect(!vm.canAdvance)

        vm.confirmOverwrite()
        #expect(!vm.shouldShowOverwriteWarning)
        #expect(vm.canAdvance)
    }

    @Test("A URL install context pins the checked URL, version, and build")
    func customURLInstallContextPinsTheImage() {
        let vm = VMCreationViewModel.overFakeEngine()
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
        let vm = VMCreationViewModel.overFakeEngine(localImageInspector: inspector)

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
        let vm = VMCreationViewModel.overFakeEngine(localImageInspector: inspector)
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
        let vm = VMCreationViewModel.overFakeEngine(localImageInspector: inspector)
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

    @Test("While the inspection is pending, advance is blocked")
    func selectLocalFilePendingBlocksAdvance() async throws {
        let inspector = SuspendingMockLocalRestoreImageInspector()
        let vm = VMCreationViewModel.overFakeEngine(localImageInspector: inspector)
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
        let vm = VMCreationViewModel.overFakeEngine(localImageInspector: inspector)

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
        let vm = VMCreationViewModel.overFakeEngine(localImageInspector: inspector)

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
    func adoptsMatchingExistingFile() async throws {
        let inspector = MockLocalRestoreImageInspector()
        inspector.inspectResult = InspectedRestoreImage(
            version: "15.6.1", build: "24G90", isSupportedOnThisHost: true)
        let vm = VMCreationViewModel.overFakeEngine(localImageInspector: inspector)
        vm.selectCatalogEntry(makeCatalogEntry(version: "15.6.1", build: "24G90"))
        let destination = try #require(vm.ipswDownloadPath)

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
    func refusesMismatchedExistingFile() async throws {
        let inspector = MockLocalRestoreImageInspector()
        inspector.inspectResult = InspectedRestoreImage(
            version: "14.2", build: "23C64", isSupportedOnThisHost: true)
        let vm = VMCreationViewModel.overFakeEngine(localImageInspector: inspector)
        let entry = makeCatalogEntry(version: "15.6.1", build: "24G90")
        vm.selectCatalogEntry(entry)

        let verdict = await vm.adoptExistingDownloadFile(at: try #require(vm.ipswDownloadPath))

        #expect(verdict == .mismatch(expected: "24G90", found: inspector.inspectResult))
        // The wrong-image install this exists to prevent.
        #expect(vm.ipswSelection == .catalogVersion(entry))
    }

    @Test("An unreadable file is refused with a reason")
    func refusesUnreadableExistingFile() async throws {
        let inspector = MockLocalRestoreImageInspector()
        inspector.inspectError = LocalRestoreImageError.unreadable
        let vm = VMCreationViewModel.overFakeEngine(localImageInspector: inspector)
        vm.selectCatalogEntry(makeCatalogEntry())

        let verdict = await vm.adoptExistingDownloadFile(at: try #require(vm.ipswDownloadPath))

        #expect(
            verdict
                == .unusable(
                    message: LocalRestoreImageError.unreadable.errorDescription ?? ""))
        #expect(vm.ipswSource == .catalogVersion)
    }

    @Test("An image the host can't run is refused even when the build matches")
    func refusesUnsupportedExistingFile() async throws {
        let inspector = MockLocalRestoreImageInspector()
        inspector.inspectResult = InspectedRestoreImage(
            version: "15.6.1", build: "24G90", isSupportedOnThisHost: false)
        let vm = VMCreationViewModel.overFakeEngine(localImageInspector: inspector)
        vm.selectCatalogEntry(makeCatalogEntry(version: "15.6.1", build: "24G90"))

        let verdict = await vm.adoptExistingDownloadFile(at: try #require(vm.ipswDownloadPath))

        #expect(
            verdict
                == .unusable(
                    message: LocalRestoreImageError.unsupported.errorDescription ?? ""))
        #expect(vm.ipswSource == .catalogVersion)
    }

    @Test("A pasted URL that names no build adopts any usable image at its destination")
    func buildlessPickAdoptsAnyUsableImage() async throws {
        let inspector = MockLocalRestoreImageInspector()
        inspector.inspectResult = InspectedRestoreImage(
            version: "14.2", build: "23C64", isSupportedOnThisHost: true)
        let vm = VMCreationViewModel.overFakeEngine(localImageInspector: inspector)
        vm.selectPastedImage(
            makeProbedImage(urlString: "https://example.com/restore.ipsw", version: nil, build: nil))

        #expect(vm.expectedBuild == nil)
        let verdict = await vm.adoptExistingDownloadFile(at: try #require(vm.ipswDownloadPath))

        #expect(verdict == .adopted(inspector.inspectResult))
        #expect(vm.ipswSource == .localFile)
    }

    @Test("Once the lookup lands, a file of another build is reported, not adopted")
    func downloadLatestRefusesAnotherBuildOnceTheLookupLands() async throws {
        let inspector = MockLocalRestoreImageInspector()
        inspector.inspectResult = InspectedRestoreImage(
            version: "14.2", build: "23C64", isSupportedOnThisHost: true)
        let vm = VMCreationViewModel.overFakeEngine(
            probeService: MockRestoreImageProbeService(), localImageInspector: inspector, ipswService: MockIPSWService()
        )
        await vm.loadLatestImageDetails()?.value

        let verdict = await vm.adoptExistingDownloadFile(at: try #require(vm.ipswDownloadPath))

        // The wrong-image install a per-build destination prevents for the
        // download, which a hand-placed file at that destination reintroduces.
        #expect(verdict == .mismatch(expected: "25F84", found: inspector.inspectResult))
        #expect(vm.ipswSelection == .downloadLatest)
    }

    @Test("A file of the looked-up build is adopted")
    func downloadLatestAdoptsTheLookedUpBuild() async throws {
        let inspector = MockLocalRestoreImageInspector()
        inspector.inspectResult = InspectedRestoreImage(
            version: "26.5.2", build: "25F84", isSupportedOnThisHost: true)
        let vm = VMCreationViewModel.overFakeEngine(
            probeService: MockRestoreImageProbeService(), localImageInspector: inspector, ipswService: MockIPSWService()
        )
        await vm.loadLatestImageDetails()?.value
        let destination = try #require(vm.ipswDownloadPath)

        let verdict = await vm.adoptExistingDownloadFile(at: destination)

        #expect(verdict == .adopted(inspector.inspectResult))
        #expect(
            vm.ipswSelection
                == .localFile(
                    LocalRestoreImage(
                        path: destination, bookmark: nil,
                        inspection: .usable(inspector.inspectResult))))
    }

    @Test("An inspection cancelled mid-flight adopts nothing")
    func cancelledInspectionAdoptsNothing() async throws {
        let inspector = SuspendingMockLocalRestoreImageInspector()
        let vm = VMCreationViewModel.overFakeEngine(localImageInspector: inspector)
        // The build matches, so only the cancellation keeps this from adopting.
        let entry = makeCatalogEntry(version: "15.6.1", build: "24G90")
        vm.selectCatalogEntry(entry)

        let destination = try #require(vm.ipswDownloadPath)
        let adopt = Task { await vm.adoptExistingDownloadFile(at: destination) }
        try await inspector.waitUntilInspecting()
        adopt.cancel()
        inspector.release()

        #expect(await adopt.value == .cancelled)
        #expect(vm.ipswSelection == .catalogVersion(entry))
    }

    @Test("expectedBuild names the build each source is promising")
    func expectedBuildTracksTheSource() async {
        let vm = VMCreationViewModel.overFakeEngine(
            probeService: MockRestoreImageProbeService(), ipswService: MockIPSWService())
        #expect(vm.expectedBuild == nil)

        vm.selectCatalogEntry(makeCatalogEntry(build: "24G90"))
        #expect(vm.expectedBuild == "24G90")

        vm.selectPastedImage(makeProbedImage(build: "25G72"))
        #expect(vm.expectedBuild == "25G72")

        // "Whatever is newest" names nothing until the lookup says what that is.
        vm.selectDownloadLatest()
        #expect(vm.expectedBuild == nil)
        #expect(vm.latestImageLookup == .unanswered)

        await vm.loadLatestImageDetails()?.value
        #expect(vm.expectedBuild == "25F84")
    }

    @Test("Switching between pinned sources keeps both picks; Download Latest clears them")
    func downloadLatestClearsBothPinnedPicks() {
        let vm = VMCreationViewModel.overFakeEngine()
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
        let vm = VMCreationViewModel.overFakeEngine()
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
        let vm = VMCreationViewModel.overFakeEngine(probeService: probeService, ipswService: ipswService)

        await vm.loadLatestImageDetails()?.value

        #expect(vm.latestImageLookup == .found(ipswService.fetchResult, sizeBytes: 19_772_077_142))
        // The size is read for the image the lookup named, not for the wizard's
        // own destination.
        #expect(probeService.lastSizedURL == ipswService.fetchResult.url)
    }

    @Test("A second lookup joins the first instead of re-fetching")
    func latestImageLookupRunsOnce() async {
        let ipswService = MockIPSWService()
        let vm = VMCreationViewModel.overFakeEngine(
            probeService: MockRestoreImageProbeService(), ipswService: ipswService)

        let first = vm.loadLatestImageDetails()
        #expect(vm.loadLatestImageDetails() == first)
        await first?.value

        // Nothing left to look up, so a later call starts nothing at all.
        #expect(vm.loadLatestImageDetails() == nil)
        #expect(ipswService.fetchCallCount == 1)
    }

    @Test("A failed lookup says so, and the next call retries through unanswered")
    func latestImageLookupFailureRetries() async {
        let ipswService = MockIPSWService()
        ipswService.fetchError = URLError(.notConnectedToInternet)
        let vm = VMCreationViewModel.overFakeEngine(
            probeService: MockRestoreImageProbeService(), ipswService: ipswService)

        await vm.loadLatestImageDetails()?.value
        #expect(vm.latestImageLookup == .failed)

        // Back online, the wizard asks again — a failure must not latch.
        ipswService.fetchError = nil
        let retry = vm.loadLatestImageDetails()
        #expect(vm.latestImageLookup == .unanswered)
        #expect(vm.ipswDownloadPath == nil)
        await retry?.value
        #expect(vm.latestImageLookup.foundImage?.build == "25F84")
        #expect(ipswService.fetchCallCount == 2)
    }

    @Test("A size that can't be read still leaves the version and build to show")
    func latestImageLookupSurvivesAnUnknownSize() async {
        let probeService = MockRestoreImageProbeService()
        probeService.sizeError = RestoreImageProbeError.unknownSize
        let vm = VMCreationViewModel.overFakeEngine(probeService: probeService, ipswService: MockIPSWService())

        await vm.loadLatestImageDetails()?.value

        #expect(vm.latestImageLookup == .found(makeLatestImage(), sizeBytes: nil))
    }

    // MARK: - Guest Account

    /// A wizard on an image that can be provisioned, with the toggle on and the
    /// form filled — the state the account assertions vary from.
    private func makeAccountWizard(
        fullName: String = "Ada Lovelace",
        username: String = "ada",
        password: String = "analytical-engine",
        verify: String? = nil,
        host: FakeVirtualizationHost = FakeVirtualizationHost()
    ) -> VMCreationViewModel {
        let vm = VMCreationViewModel.overFakeEngine(host: host)
        vm.selectCatalogEntry(makeCatalogEntry(version: "27.0", build: "27A100"))
        vm.unattendedSetupEnabled = true
        vm.guestAccountFullName = fullName
        vm.guestAccountUsername = username
        vm.guestAccountPassword = password
        vm.guestAccountVerifyPassword = verify ?? password
        return vm
    }

    private var stepsWithoutAccount: [VMCreationStep] {
        [.osSelection, .bootConfig, .resources, .review]
    }

    @Test("A Linux guest walks no account step")
    func linuxWalksNoAccountStep() {
        let vm = makeAccountWizard()
        vm.selectedOS = .linux

        #expect(!vm.offersUnattendedSetup)
        #expect(vm.steps == stepsWithoutAccount)
    }

    @Test("A macOS guest with the toggle off walks no account step")
    func toggleOffWalksNoAccountStep() {
        let vm = makeAccountWizard()
        vm.unattendedSetupEnabled = false

        #expect(!vm.unattendedSetupActive)
        #expect(vm.steps == stepsWithoutAccount)
    }

    @Test("An image below the provisioning floor walks no account step")
    func belowFloorWalksNoAccountStep() {
        let vm = makeAccountWizard()
        vm.selectCatalogEntry(makeCatalogEntry(version: "26.4", build: "25E200"))

        #expect(!vm.offersUnattendedSetup)
        #expect(vm.steps == stepsWithoutAccount)
    }

    @available(macOS 27.0, *)
    @Test("An image at the provisioning floor puts the account step before Review")
    func atFloorWalksTheAccountStep() {
        let vm = makeAccountWizard()

        #expect(vm.offersUnattendedSetup)
        #expect(vm.unattendedSetupActive)
        #expect(vm.steps == [.osSelection, .bootConfig, .resources, .guestAccount, .review])
    }

    @available(macOS 27.0, *)
    @Test("goNext from Resources lands on the account step when one is being created")
    func goNextFromResourcesReachesTheAccountStep() {
        let vm = makeAccountWizard()
        vm.currentStep = .resources

        vm.goNext()
        #expect(vm.currentStep == .guestAccount)

        vm.goNext()
        #expect(vm.currentStep == .review)

        vm.goBack()
        #expect(vm.currentStep == .guestAccount)
    }

    @available(macOS 27.0, *)
    @Test("Picking an image that can't be provisioned retracts the offer, leaving the toggle alone")
    func pre27PickRetractsTheOffer() {
        let vm = makeAccountWizard()
        #expect(vm.unattendedSetupActive)

        vm.selectCatalogEntry(makeCatalogEntry(version: "26.4", build: "25E200"))

        #expect(!vm.unattendedSetupActive)
        #expect(vm.steps == stepsWithoutAccount)
        #expect(vm.unattendedSetupIntent == nil)
        // The answer the user gave is still theirs; only the offer retracted. A
        // pick that can deliver again restores it without re-asking.
        #expect(vm.unattendedSetupEnabled)
        vm.selectCatalogEntry(makeCatalogEntry(version: "27.1", build: "27B100"))
        #expect(vm.unattendedSetupActive)
    }

    // MARK: - Selected Image Version

    @Test("Download Latest names no version until the lookup answers")
    func downloadLatestVersionFollowsTheLookup() async {
        let ipswService = MockIPSWService()
        ipswService.fetchResult = makeLatestImage(version: "27.0", build: "27A100")
        let vm = VMCreationViewModel.overFakeEngine(
            probeService: MockRestoreImageProbeService(), ipswService: ipswService)

        #expect(vm.selectedImageVersion == nil)

        await vm.loadLatestImageDetails()?.value
        #expect(vm.selectedImageVersion == MacOSVersion(major: 27, minor: 0))
    }

    @Test("A catalog pick names the version the catalog recorded")
    func catalogPickNamesItsVersion() {
        let vm = VMCreationViewModel.overFakeEngine()
        vm.selectCatalogEntry(makeCatalogEntry(version: "27.1", build: "27B100"))

        #expect(vm.selectedImageVersion == MacOSVersion(major: 27, minor: 1))
    }

    @Test("A pasted URL names a version only when its filename carried one")
    func pastedURLNamesItsVersionWhenTheFilenameHasOne() {
        let vm = VMCreationViewModel.overFakeEngine()
        vm.selectPastedImage(makeProbedImage(version: "27.0", build: "27A100"))
        #expect(vm.selectedImageVersion == MacOSVersion(major: 27, minor: 0))

        vm.selectPastedImage(
            makeProbedImage(
                urlString: "https://example.com/image.ipsw", version: nil, build: nil))
        #expect(vm.selectedImageVersion == nil)
    }

    @Test("A local file names no version until its inspection lands")
    func localFileVersionFollowsTheInspection() async {
        let inspector = MockLocalRestoreImageInspector()
        inspector.inspectResult = InspectedRestoreImage(
            version: "27.0", build: "27A100", isSupportedOnThisHost: true, sizeBytes: nil)
        let vm = VMCreationViewModel.overFakeEngine(localImageInspector: inspector)

        vm.selectLocalFile(path: "/tmp/Restore.ipsw", bookmark: nil)
        #expect(vm.selectedImageVersion == nil)

        await vm.localFileInspectionTask?.value
        #expect(vm.selectedImageVersion == MacOSVersion(major: 27, minor: 0))
    }

    // MARK: - Guest Account Validation

    @available(macOS 27.0, *)
    @Test("A form with a field still blank asks for the details rather than judging them")
    func blankAccountAsksForTheDetails() {
        let vm = makeAccountWizard(fullName: "", username: "", password: "", verify: "")
        vm.currentStep = .guestAccount

        #expect(!vm.canAdvance)
        #expect(vm.validationMessage == "Enter the account details to continue.")

        // One field short reads the same — the form is incomplete either way.
        vm.guestAccountFullName = "Ada Lovelace"
        vm.guestAccountUsername = "ada"
        vm.guestAccountPassword = "analytical-engine"
        #expect(vm.validationMessage == "Enter the account details to continue.")
    }

    @available(macOS 27.0, *)
    @Test("Whitespace alone is not a name — what is validated is what would be created")
    func whitespaceOnlyFieldsAreIncomplete() {
        let vm = makeAccountWizard(fullName: "   ", username: "  ")

        #expect(vm.guestAccountValidationMessage == "Enter the account details to continue.")
        #expect(!vm.canCreate)
    }

    @available(macOS 27.0, *)
    @Test("The persisted account is trimmed, as the VM name is")
    func theAccountIsTrimmedBeforeItIsPersisted() throws {
        let vm = makeAccountWizard(fullName: "  Ada Lovelace  ", username: " ada ")
        vm.vmName = "Provisioned VM"

        let account = try #require(vm.buildConfiguration().pendingGuestAccount)
        #expect(account.fullName == "Ada Lovelace")
        #expect(account.username == "ada")
    }

    @available(macOS 27.0, *)
    @Test("Create is refused while the account the wizard is creating is incomplete")
    func createIsRefusedForAnIncompleteAccount() {
        let vm = makeAccountWizard(fullName: "", username: "", password: "", verify: "")
        vm.vmName = "Provisioned VM"
        // Review is reachable with the toggle on and the form untouched, and
        // creating there would persist an empty account and arm an empty
        // password — a prompt nothing could ever satisfy.
        vm.currentStep = .review

        #expect(!vm.canCreate)

        vm.unattendedSetupEnabled = false
        #expect(vm.canCreate)
    }

    @available(macOS 27.0, *)
    @Test("Create is refused while the two spellings of the password differ")
    func createIsRefusedForAMismatchedPassword() {
        let vm = makeAccountWizard(password: "analytical-engine", verify: "difference-engine")
        vm.vmName = "Provisioned VM"

        #expect(!vm.canCreate)
    }

    @available(macOS 27.0, *)
    @Test("A verification that doesn't match the password says so")
    func mismatchedPasswordsSaySo() {
        let vm = makeAccountWizard(password: "analytical-engine", verify: "difference-engine")
        vm.currentStep = .guestAccount

        #expect(!vm.canAdvance)
        #expect(vm.validationMessage == "The passwords don\u{2019}t match.")
    }

    @available(macOS 27.0, *)
    @Test("A complete account Virtualization accepts advances with nothing to say")
    func completeAccountAdvances() {
        let vm = makeAccountWizard()
        vm.currentStep = .guestAccount

        #expect(vm.canAdvance)
        #expect(vm.validationMessage == nil)
    }

    @available(macOS 27.0, *)
    @Test("An account the host refuses surfaces the host's own message")
    func refusedAccountSurfacesTheHostsMessage() throws {
        let vm = makeAccountWizard(
            password: "a",
            host: FakeVirtualizationHost(
                refusal: GuestProvisioningRefusal(field: .password, message: "Choose a longer password.")))
        vm.currentStep = .guestAccount

        #expect(!vm.canAdvance)
        #expect(vm.validationMessage == "Choose a longer password.")
    }

    @Test("A wizard creating no account has nothing to validate")
    func inactiveAccountValidatesNothing() {
        let vm = makeAccountWizard(fullName: "", username: "", password: "", verify: "")
        vm.unattendedSetupEnabled = false

        #expect(vm.guestAccountValidationMessage == nil)
    }

    // MARK: - The Persisted Account

    @available(macOS 27.0, *)
    @Test("An active account is persisted beside the install, and its password rides with it")
    func activeAccountIsPersistedBesideTheInstall() throws {
        let vm = makeAccountWizard()
        vm.guestAccountLogsInAutomatically = true
        vm.guestAccountEnablesRemoteLogin = true

        let intent = try #require(vm.unattendedSetupIntent)
        #expect(intent.fullName == "Ada Lovelace")
        #expect(intent.username == "ada")
        #expect(intent.logsInAutomatically)
        #expect(intent.enablesRemoteLogin)
        #expect(vm.guestAccountPasswordForCreate == "analytical-engine")
    }

    @available(macOS 27.0, *)
    @Test("The install context still describes only its source")
    func accountLeavesTheSourceIntact() {
        let vm = makeAccountWizard()

        let context = vm.buildInstallContext()
        #expect(context.source == .catalogVersion)
        #expect(context.version == "27.0")
        #expect(context.build == "27A100")
    }

    @Test("A wizard creating no account persists none, and hands the create verb no password")
    func inactiveAccountPersistsNothing() {
        let vm = makeAccountWizard()
        vm.vmName = "Plain VM"
        vm.unattendedSetupEnabled = false

        #expect(vm.buildConfiguration().pendingGuestAccount == nil)
        #expect(vm.unattendedSetupIntent == nil)
        #expect(vm.guestAccountPasswordForCreate == nil)
    }

    @available(macOS 27.0, *)
    @Test("The account outlives the install context it was gathered with")
    func buildConfigurationCarriesTheAccount() throws {
        let vm = makeAccountWizard()
        vm.vmName = "Provisioned VM"

        let configuration = vm.buildConfiguration()
        // Beside the install rather than inside it: the install ends when the
        // image lands, and the account is owed for one boot longer.
        let intent = try #require(configuration.pendingGuestAccount)
        #expect(intent.username == "ada")
        #expect(configuration.installContext != nil)
    }

    // MARK: - A Step That Disappears Under the User

    @available(macOS 27.0, *)
    @Test("A pick that retracts the account step moves the user off it, not nowhere")
    func retractingTheAccountStepClampsTheCurrentStep() {
        let vm = makeAccountWizard()
        vm.currentStep = .guestAccount

        // What a local file's inspection landing does: the offer goes while the
        // user is standing on the step it belongs to.
        vm.selectCatalogEntry(makeCatalogEntry(version: "26.4", build: "25E200"))

        #expect(vm.currentStep == .resources)
        #expect(vm.steps.contains(vm.currentStep))
        // Next and Back both work again, which is what the clamp is for.
        vm.goNext()
        #expect(vm.currentStep == .review)
        vm.goBack()
        #expect(vm.currentStep == .resources)
    }

    @available(macOS 27.0, *)
    @Test("A step that comes back does not mount itself under the user")
    func aRestoredStepDoesNotMoveTheUser() {
        let vm = makeAccountWizard()
        vm.currentStep = .guestAccount

        vm.selectCatalogEntry(makeCatalogEntry(version: "26.4", build: "25E200"))
        #expect(vm.currentStep == .resources)

        // The step is walkable again, and the user is still where the clamp
        // left them: a pick landing — a file's inspection, the latest-image
        // lookup — is nobody's request to be moved forward, and moving them
        // swaps the fields under whatever they are typing into.
        vm.selectCatalogEntry(makeCatalogEntry(version: "27.1", build: "27B100"))
        #expect(vm.currentStep == .resources)
        #expect(vm.steps.contains(.guestAccount))
        // Forward is theirs to ask for — the account step sits after Resources.
        vm.goNext()
        #expect(vm.currentStep == .guestAccount)
    }

    // MARK: - What Blocks Create

    @available(macOS 27.0, *)
    @Test("Review names the step that blocks Create rather than greying it in silence")
    func reviewNamesTheStepBlockingCreate() throws {
        let vm = makeAccountWizard(password: "analytical-engine", verify: "difference-engine")
        vm.vmName = "Provisioned VM"
        vm.currentStep = .review

        #expect(!vm.canCreate)
        // Review has no account controls, so the hint has to say where the
        // problem is as well as what it is.
        let message = try #require(vm.validationMessage)
        #expect(message == "Account: The passwords don\u{2019}t match.")
    }

    @available(macOS 27.0, *)
    @Test("Review says nothing once nothing blocks Create")
    func reviewSaysNothingWhenCreateIsReady() {
        let vm = makeAccountWizard()
        vm.vmName = "Provisioned VM"
        vm.currentStep = .review

        #expect(vm.canCreate)
        #expect(vm.validationMessage == nil)
    }
}

/// Inspector whose calls suspend independently and resolve in whatever order
/// the test releases them by index — models `VZMacOSRestoreImage` ignoring
/// cancellation, so a superseded pick's read can finish after a newer one's.
@MainActor
final class OrderedSuspendingMockLocalRestoreImageInspector: LocalRestoreImageInspecting {
    private final class CallState {
        let gate = AsyncGate()
        var released = false
    }
    private var calls: [CallState] = []
    /// Notified whenever a new call registers, for ``waitUntilCallCount(_:)``.
    private let callRegisteredGate = AsyncGate()

    nonisolated init() {}

    func inspect(_ url: URL) async throws -> InspectedRestoreImage {
        let call = CallState()
        calls.append(call)
        callRegisteredGate.notify()
        try? await call.gate.wait(until: { call.released })
        return InspectedRestoreImage(
            version: "15.6.1", build: "24G90", isSupportedOnThisHost: true)
    }

    /// Suspends until `inspect` has been called at least `count` times.
    func waitUntilCallCount(_ count: Int) async throws {
        try await callRegisteredGate.wait(until: { self.calls.count >= count })
    }

    /// Lets the `callIndex`th call (0-based, in call order) finish.
    func release(callIndex: Int) {
        calls[callIndex].released = true
        calls[callIndex].gate.notify()
    }
}
