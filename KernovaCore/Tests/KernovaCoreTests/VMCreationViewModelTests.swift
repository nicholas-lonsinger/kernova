import Foundation
import KernovaCommandModel
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

    // MARK: - canAdvance

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

    // MARK: - Resource defaults

    @Test("Resources start at the selected guest's defaults", arguments: VMGuestOS.allCases)
    func resourceDefaultsFollowTheGuest(os: VMGuestOS) {
        let vm = VMCreationViewModel.overFakeEngine()
        vm.selectedOS = os

        #expect(vm.cpuCount == os.defaultCPUCount(within: FakeVirtualizationHost.resourceLimits))
        #expect(vm.memorySize == os.defaultMemorySize(within: FakeVirtualizationHost.resourceLimits))
        #expect(vm.diskSizeInGB == VMGuestOS.defaultDiskSizeInGB)
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

    // MARK: - Overwrite Warning

    @Test("shouldShowOverwriteWarning is false when file does not exist at path")
    func overwriteWarningFalseWhenFileDoesNotExist() {
        let vm = VMCreationViewModel.overFakeEngine()
        vm.selectCatalogEntry(makeCatalogEntry())

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

    // MARK: - validationMessage

    @Test("validationMessage names both EFI image sources when neither is picked")
    func validationMessageLinuxEFINoImage() {
        let vm = VMCreationViewModel.overFakeEngine()
        vm.currentStep = .bootConfig
        vm.selectedOS = .linux
        vm.selectedBootMode = .efi

        #expect(vm.validationMessage == "Select an installer image to continue.")
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

    @Test("buildInstallContext sets requestedFreshDownload when overwrite confirmed")
    func buildInstallContextSetsFreshOnConfirmedOverwrite() async {
        let vm = VMCreationViewModel.overFakeEngine(
            probeService: MockRestoreImageProbeService(), ipswService: MockIPSWService())
        await vm.loadLatestImageDetails()?.value
        vm.confirmOverwrite()

        let context = vm.buildInstallContext()

        #expect(context.requestedFreshDownload)
    }

    // MARK: - Start After Create

    @Test("startAfterCreate defaults to true")
    func startAfterCreateDefaultsTrue() {
        let vm = VMCreationViewModel.overFakeEngine()
        #expect(vm.startAfterCreate == true)
    }

    // MARK: - Catalog Version Source

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

    @Test("A macOS guest with the toggle off walks no account step")
    func toggleOffWalksNoAccountStep() {
        let vm = makeAccountWizard()
        vm.unattendedSetupEnabled = false

        #expect(!vm.unattendedSetupActive)
        #expect(vm.steps == stepsWithoutAccount)
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
    @Test("The persisted account is trimmed, as the VM name is")
    func theAccountIsTrimmedBeforeItIsPersisted() throws {
        let vm = makeAccountWizard(fullName: "  Ada Lovelace  ", username: " ada ")
        vm.vmName = "Provisioned VM"

        let account = try #require(vm.buildConfiguration().pendingGuestAccount)
        #expect(account.fullName == "Ada Lovelace")
        #expect(account.username == "ada")
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
