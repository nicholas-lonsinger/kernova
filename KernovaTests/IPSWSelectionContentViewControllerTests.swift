import AppKit
import Testing

@testable import Kernova

@Suite("IPSWSelectionContentViewController Tests", .admissionGated)
@MainActor
struct IPSWSelectionContentViewControllerTests {
    @Test("Defaults to Download Latest with the default destination shown")
    func defaultDownloadSelected() {
        let vm = VMCreationViewModel()  // macOS + downloadLatest, default download path
        let vc = IPSWSelectionContentViewController(creationVM: vm)
        vc.loadViewIfNeeded()

        #expect(findButton(titled: "Download Latest", in: vc.view)?.state == .on)
        #expect(findButton(titled: "Choose a Version…", in: vc.view)?.state == .off)
        #expect(findButton(titled: "Choose Local File…", in: vc.view)?.state == .off)
        #expect(
            findLabel(withText: wizardAbbreviateWithTilde(vm.ipswDownloadPath), in: vc.view) != nil)
    }

    @Test("Download Latest names the image it will fetch, the way a pinned pick does")
    func downloadLatestShowsLookedUpImage() async {
        let probeService = MockRestoreImageProbeService()
        probeService.sizeResult = 19_772_077_142
        let vm = VMCreationViewModel(probeService: probeService, ipswService: MockIPSWService())

        let vc = IPSWSelectionContentViewController(creationVM: vm)
        vc.loadViewIfNeeded()
        // Mounting the step is what asks; the badge upgrades when it answers.
        vc.viewDidAppear()
        await vc.latestImageTaskForTesting?.value

        #expect(
            findLabel(
                containing: "macOS 26.5.2  ·  Build 25F84  ·  \(DataFormatters.formatBytes(19_772_077_142))",
                in: vc.view) != nil)
        // The destination stays on the badge's second line.
        #expect(
            findLabel(withText: wizardAbbreviateWithTilde(vm.ipswDownloadPath), in: vc.view) != nil)
        // Nothing about "latest" is the user's to change.
        #expect(findButton(titled: "Change…", in: vc.view) == nil)
    }

    @Test("A size the server won't report leaves the version and build on the badge")
    func downloadLatestShowsImageWithoutItsSize() async {
        let probeService = MockRestoreImageProbeService()
        probeService.sizeError = RestoreImageProbeError.unknownSize
        let vm = VMCreationViewModel(probeService: probeService, ipswService: MockIPSWService())

        let vc = IPSWSelectionContentViewController(creationVM: vm)
        vc.loadViewIfNeeded()
        vc.viewDidAppear()
        await vc.latestImageTaskForTesting?.value

        #expect(findLabel(containing: "macOS 26.5.2  ·  Build 25F84", in: vc.view) != nil)
    }

    @Test("A failed lookup leaves the destination-only badge the step always had")
    func downloadLatestFallsBackToThePathBadge() async {
        let ipswService = MockIPSWService()
        ipswService.fetchError = URLError(.notConnectedToInternet)
        let vm = VMCreationViewModel(
            probeService: MockRestoreImageProbeService(), ipswService: ipswService)

        let vc = IPSWSelectionContentViewController(creationVM: vm)
        vc.loadViewIfNeeded()
        vc.viewDidAppear()
        await vc.latestImageTaskForTesting?.value

        #expect(
            findLabel(withText: wizardAbbreviateWithTilde(vm.ipswDownloadPath), in: vc.view) != nil)
        #expect(findLabel(containing: "Build", in: vc.view) == nil)
    }

    @Test("Overwrite warning shows when a file exists; Use Existing switches to local file")
    func overwriteUseExisting() async {
        let path = makeTempIPSW()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let inspector = MockLocalRestoreImageInspector()
        let vm = VMCreationViewModel(localImageInspector: inspector)
        vm.ipswDownloadPath = path
        #expect(vm.shouldShowOverwriteWarning == true)

        let vc = IPSWSelectionContentViewController(creationVM: vm)
        vc.loadViewIfNeeded()
        #expect(findButton(titled: "Use Existing File", in: vc.view) != nil)

        findButton(titled: "Use Existing File", in: vc.view)?.performClick(nil)
        await vc.adoptTaskForTesting?.value

        #expect(
            vm.ipswSelection
                == .localFile(
                    LocalRestoreImage(
                        path: path, bookmark: nil, inspection: .usable(inspector.inspectResult))))
        // The badge upgrades to the file's own metadata, not just its path.
        #expect(
            findLabel(
                containing: "macOS 15.6.1  ·  Build 24G90  ·  \(DataFormatters.formatBytes(15_500_000_000))",
                in: vc.view) != nil)
    }

    @Test("A file of a different build is named, and not adopted until confirmed")
    func mismatchedExistingFileIsNotAdopted() async {
        let path = makeTempIPSW()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let inspector = MockLocalRestoreImageInspector()
        inspector.inspectResult = InspectedRestoreImage(
            version: "14.2", build: "23C64", isSupportedOnThisHost: true, sizeBytes: 8_500_000_000)
        let vm = VMCreationViewModel(localImageInspector: inspector)
        let entry = makeCatalogEntry(version: "15.6.1", build: "24G90")
        vm.selectCatalogEntry(entry)
        vm.ipswDownloadPath = path

        let vc = IPSWSelectionContentViewController(creationVM: vm)
        vc.loadViewIfNeeded()
        findButton(titled: "Use Existing File", in: vc.view)?.performClick(nil)
        await vc.adoptTaskForTesting?.value

        #expect(vm.ipswSelection == .catalogVersion(entry))
        #expect(findLabel(containing: "macOS 14.2 (23C64)", in: vc.view) != nil)

        // The user can still override, which is what "Use It Anyway" is for.
        findButton(titled: "Use It Anyway", in: vc.view)?.performClick(nil)
        #expect(
            vm.ipswSelection
                == .localFile(
                    LocalRestoreImage(
                        path: path, bookmark: nil, inspection: .usable(inspector.inspectResult))))
        // The found image's own metadata replaces the mismatch banner.
        #expect(
            findLabel(
                containing: "macOS 14.2  ·  Build 23C64  ·  \(DataFormatters.formatBytes(8_500_000_000))",
                in: vc.view) != nil)
    }

    @Test("An unreadable file offers only a re-download")
    func unreadableExistingFileOffersReplace() async {
        let path = makeTempIPSW()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let inspector = MockLocalRestoreImageInspector()
        inspector.inspectError = LocalRestoreImageError.unreadable
        let vm = VMCreationViewModel(localImageInspector: inspector)
        vm.ipswDownloadPath = path

        let vc = IPSWSelectionContentViewController(creationVM: vm)
        vc.loadViewIfNeeded()
        findButton(titled: "Use Existing File", in: vc.view)?.performClick(nil)
        await vc.adoptTaskForTesting?.value

        #expect(vm.ipswSource == .downloadLatest)
        #expect(findLabel(containing: "isn't a usable restore image", in: vc.view) != nil)
        #expect(findButton(titled: "Use It Anyway", in: vc.view) == nil)
        #expect(findButton(titled: "Download & Replace", in: vc.view) != nil)
    }

    @Test("Leaving the step mid-check adopts nothing")
    func cancelledInspectionCommitsNothing() async throws {
        let path = makeTempIPSW()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let inspector = SuspendingMockLocalRestoreImageInspector()
        let vm = VMCreationViewModel(localImageInspector: inspector)
        vm.ipswDownloadPath = path

        let vc = IPSWSelectionContentViewController(creationVM: vm)
        vc.loadViewIfNeeded()
        findButton(titled: "Use Existing File", in: vc.view)?.performClick(nil)
        let inFlight = try #require(vc.adoptTaskForTesting)
        try await inspector.waitUntilInspecting()

        // Navigating back off the step cancels the inspection under way.
        vc.viewWillDisappear()
        inspector.release()
        await inFlight.value

        // Adopting here would leave the radios and the model disagreeing.
        #expect(vm.ipswSelection == .downloadLatest)
    }

    @Test("Leaving the step and returning while a pick's inspection is still running redraws when it lands")
    func reenteringMidInspectionPicksTheWatchBackUp() async throws {
        let inspector = SuspendingMockLocalRestoreImageInspector()
        let vm = VMCreationViewModel(localImageInspector: inspector)
        vm.selectLocalFile(path: "/tmp/picked.ipsw", bookmark: nil)
        try await inspector.waitUntilInspecting()

        // The shell mounts a fresh VC on every entry to this step — Next, then
        // Back, replaces this one with a new instance mid-inspection.
        let firstVC = IPSWSelectionContentViewController(creationVM: vm)
        firstVC.loadViewIfNeeded()
        firstVC.viewDidAppear()
        firstVC.viewWillDisappear()

        let secondVC = IPSWSelectionContentViewController(creationVM: vm)
        secondVC.loadViewIfNeeded()
        secondVC.viewDidAppear()
        #expect(findLabel(containing: "macOS 15.6.1", in: secondVC.view) == nil)

        inspector.release()
        await secondVC.localFileInspectionTaskForTesting?.value

        #expect(findLabel(containing: "macOS 15.6.1  ·  Build 24G90", in: secondVC.view) != nil)
    }

    @Test("A hand-picked unsupported IPSW shows the same message the adopt route uses, with no metadata")
    func unsupportedPickShowsUnusableBanner() async {
        let inspector = MockLocalRestoreImageInspector()
        inspector.inspectResult = InspectedRestoreImage(
            version: "13.0", build: "22A5286j", isSupportedOnThisHost: false)
        let vm = VMCreationViewModel(localImageInspector: inspector)
        vm.selectLocalFile(path: "/tmp/picked.ipsw", bookmark: nil)

        let vc = IPSWSelectionContentViewController(creationVM: vm)
        vc.loadViewIfNeeded()
        vc.viewDidAppear()
        await vc.localFileInspectionTaskForTesting?.value

        #expect(
            findLabel(
                containing: "That restore image can't install into a virtual machine on this Mac",
                in: vc.view) != nil)
        #expect(findLabel(containing: "Build ", in: vc.view) == nil)
        #expect(findButton(titled: "Change…", in: vc.view) != nil)
    }

    @Test("A pending pick shows a checking banner")
    func pendingPickShowsCheckingBanner() async throws {
        let inspector = SuspendingMockLocalRestoreImageInspector()
        let vm = VMCreationViewModel(localImageInspector: inspector)
        vm.selectLocalFile(path: "/tmp/picked.ipsw", bookmark: nil)
        try await inspector.waitUntilInspecting()

        let vc = IPSWSelectionContentViewController(creationVM: vm)
        vc.loadViewIfNeeded()
        vc.viewDidAppear()

        #expect(findLabel(containing: "Checking this restore image", in: vc.view) != nil)

        inspector.release()
        await vc.localFileInspectionTaskForTesting?.value
    }

    @Test("Download & Replace confirms the overwrite and dismisses the banner")
    func overwriteConfirm() {
        let path = makeTempIPSW()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let vm = VMCreationViewModel()
        vm.ipswDownloadPath = path
        #expect(vm.shouldShowOverwriteWarning == true)

        let vc = IPSWSelectionContentViewController(creationVM: vm)
        vc.loadViewIfNeeded()

        findButton(titled: "Download & Replace", in: vc.view)?.performClick(nil)
        #expect(vm.shouldShowOverwriteWarning == false)
        // Banner is rebuilt away once the conflict is resolved.
        #expect(findButton(titled: "Download & Replace", in: vc.view) == nil)
    }

    @Test("Switching install source clears a stale mismatch banner")
    func sourceSwitchClearsMismatchBanner() async {
        let path = makeTempIPSW()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let inspector = MockLocalRestoreImageInspector()
        inspector.inspectResult = InspectedRestoreImage(
            version: "14.2", build: "23C64", isSupportedOnThisHost: true)
        let vm = VMCreationViewModel(localImageInspector: inspector)
        let entry = makeCatalogEntry(version: "15.6.1", build: "24G90")
        vm.selectCatalogEntry(entry)
        vm.ipswDownloadPath = path

        let vc = IPSWSelectionContentViewController(creationVM: vm)
        vc.loadViewIfNeeded()
        findButton(titled: "Use Existing File", in: vc.view)?.performClick(nil)
        await vc.adoptTaskForTesting?.value
        #expect(findButton(titled: "Use It Anyway", in: vc.view) != nil)

        // Clicking another source drops the verdict, so the button that would
        // adopt the file that verdict described has to go with it.
        findButton(titled: "Choose Local File…", in: vc.view)?.performClick(nil)

        #expect(findButton(titled: "Use It Anyway", in: vc.view) == nil)
        #expect(vm.ipswSelection == .catalogVersion(entry))
        #expect(findButton(titled: "Choose a Version…", in: vc.view)?.state == .on)
        #expect(findButton(titled: "Choose Local File…", in: vc.view)?.state == .off)
    }

    @Test("Switching install source clears a stale checking banner")
    func sourceSwitchClearsCheckingBanner() async throws {
        let path = makeTempIPSW()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let inspector = SuspendingMockLocalRestoreImageInspector()
        let vm = VMCreationViewModel(localImageInspector: inspector)
        vm.ipswDownloadPath = path

        let vc = IPSWSelectionContentViewController(creationVM: vm)
        vc.loadViewIfNeeded()
        findButton(titled: "Use Existing File", in: vc.view)?.performClick(nil)
        let inFlight = try #require(vc.adoptTaskForTesting)
        try await inspector.waitUntilInspecting()
        #expect(findLabel(containing: "Checking the file already", in: vc.view) != nil)

        // The switch cancels the check, so its banner would never resolve on its
        // own — and while it shows it hides the only controls that clear the
        // overwrite warning blocking Next.
        findButton(titled: "Choose a Version…", in: vc.view)?.performClick(nil)

        #expect(findLabel(containing: "Checking the file already", in: vc.view) == nil)
        #expect(findButton(titled: "Use Existing File", in: vc.view) != nil)
        #expect(findButton(titled: "Download & Replace", in: vc.view) != nil)

        inspector.release()
        await inFlight.value
        #expect(vm.ipswSelection == .downloadLatest)
    }

    // MARK: - Helpers

    @MainActor
    private func makeTempIPSW() -> String {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("RestoreImage-\(UUID().uuidString).ipsw")
            .path(percentEncoded: false)
        FileManager.default.createFile(atPath: path, contents: Data())
        return path
    }
}
