import AppKit
import Testing

@testable import Kernova

@Suite("IPSWSelectionContentViewController Tests")
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

        #expect(vm.ipswSelection == .localFile(path: path, bookmark: nil))
    }

    @Test("A file of a different build is named, and not adopted until confirmed")
    func mismatchedExistingFileIsNotAdopted() async {
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

        #expect(vm.ipswSelection == .catalogVersion(entry))
        #expect(findLabel(containing: "macOS 14.2 (23C64)", in: vc.view) != nil)

        // The user can still override, which is what "Use It Anyway" is for.
        findButton(titled: "Use It Anyway", in: vc.view)?.performClick(nil)
        #expect(vm.ipswSelection == .localFile(path: path, bookmark: nil))
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
