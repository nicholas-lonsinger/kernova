import AppKit
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport
@testable import KernovaUI

@Suite("IPSWSelectionContentViewController Tests", .caseScoped)
@MainActor
struct IPSWSelectionContentViewControllerTests {
    private let scratch = TestScratchDirectory(prefix: "IPSWSelectionContentViewControllerTests")

    init() throws {
        try FileManager.default.createDirectory(at: scratch.url, withIntermediateDirectories: true)
    }

    /// The descriptions say what each source does, so the title carries no
    /// popover repeating them.
    @Test("The step shows its subtitle and each source's description, and no title popover")
    func showsSubtitleAndDescriptions() {
        let vc = IPSWSelectionContentViewController(
            creationVM: VMCreationViewModel.overEngine())
        vc.loadViewIfNeeded()

        for text in [
            "Choose how to obtain the macOS restore image (IPSW) for installation.",
            "Download the latest compatible macOS restore image from Apple.",
            "Browse every macOS release Apple still hosts, including older versions.",
            "Install from a restore image at a URL you supply.",
            "Select an IPSW file already on your Mac.",
        ] {
            #expect(findLabel(withText: text, in: vc.view) != nil, "\(text)")
        }
        #expect(
            firstSubview(InfoButtonView.self, in: vc.view) {
                $0.button.toolTip == "About macOS Restore Image"
            } == nil)
    }

    @Test("Until the lookup answers, Download Latest shows progress and the Downloads folder, and no file")
    func defaultDownloadSelected() {
        let vm = VMCreationViewModel.overEngine(downloadsDirectory: scratch.url)
        let vc = IPSWSelectionContentViewController(creationVM: vm)
        vc.loadViewIfNeeded()

        #expect(findButton(titled: "Download Latest", in: vc.view)?.state == .on)
        #expect(findButton(titled: "Choose a Version…", in: vc.view)?.state == .off)
        #expect(findButton(titled: "Choose Local File…", in: vc.view)?.state == .off)
        #expect(firstSubview(NSProgressIndicator.self, in: vc.view) != nil)
        #expect(findLabel(withText: "Looking up the latest macOS\u{2026}", in: vc.view) != nil)
        #expect(
            findLabel(
                withText: wizardAbbreviateWithTilde(scratch.url.path(percentEncoded: false)),
                in: vc.view) != nil)
        #expect(findLabel(containing: ".ipsw", in: vc.view) == nil)
    }

    @Test("Download Latest names the image it will fetch, the way a pinned pick does")
    func downloadLatestShowsLookedUpImage() async throws {
        let probeService = MockRestoreImageProbeService()
        probeService.sizeResult = 19_772_077_142
        let vm = VMCreationViewModel.overEngine(probeService: probeService, ipswService: MockIPSWService())

        let vc = IPSWSelectionContentViewController(creationVM: vm)
        vc.loadViewIfNeeded()
        // Mounting the step joins the lookup; the badge upgrades when it answers.
        vc.viewDidAppear()
        await vc.latestImageTaskForTesting?.value

        #expect(
            findLabel(
                containing: "macOS 26.5.2  ·  Build 25F84  ·  \(DataFormatters.formatBytes(19_772_077_142))",
                in: vc.view) != nil)
        // The destination stays on the badge's second line.
        let destination = try #require(vm.ipswDownloadPath)
        #expect(destination.hasSuffix("/UniversalMac_26.5.2_25F84_Restore.ipsw"))
        #expect(findLabel(withText: wizardAbbreviateWithTilde(destination), in: vc.view) != nil)
        #expect(firstSubview(NSProgressIndicator.self, in: vc.view) == nil)
        // Nothing about "latest" is the user's to change.
        #expect(findButton(titled: "Change…", in: vc.view) == nil)
    }

    @Test("A size the server won't report leaves the version and build on the badge")
    func downloadLatestShowsImageWithoutItsSize() async {
        let probeService = MockRestoreImageProbeService()
        probeService.sizeError = RestoreImageProbeError.unknownSize
        let vm = VMCreationViewModel.overEngine(probeService: probeService, ipswService: MockIPSWService())

        let vc = IPSWSelectionContentViewController(creationVM: vm)
        vc.loadViewIfNeeded()
        vc.viewDidAppear()
        await vc.latestImageTaskForTesting?.value

        #expect(findLabel(containing: "macOS 26.5.2  ·  Build 25F84", in: vc.view) != nil)
    }

    @Test("A failed lookup says so, names the Downloads folder and no file, and Try Again looks it up again")
    func failedLookupOffersTryAgain() async throws {
        let ipswService = MockIPSWService()
        ipswService.fetchError = URLError(.notConnectedToInternet)
        let vm = VMCreationViewModel.overEngine(
            probeService: MockRestoreImageProbeService(), ipswService: ipswService,
            downloadsDirectory: scratch.url)
        // Whatever already sits in Downloads is no file this download names.
        makeIPSW(at: scratch.url.appendingPathComponent("RestoreImage.ipsw").path(percentEncoded: false))

        let vc = IPSWSelectionContentViewController(creationVM: vm)
        vc.loadViewIfNeeded()
        vc.viewDidAppear()
        await vc.latestImageTaskForTesting?.value

        #expect(findLabel(withText: "Couldn\u{2019}t look up the latest macOS", in: vc.view) != nil)
        #expect(
            findLabel(
                withText: wizardAbbreviateWithTilde(scratch.url.path(percentEncoded: false)),
                in: vc.view) != nil)
        #expect(findLabel(containing: ".ipsw", in: vc.view) == nil)
        #expect(findLabel(containing: "Build", in: vc.view) == nil)
        #expect(findButton(titled: "Use Existing File", in: vc.view) == nil)
        #expect(firstSubview(NSProgressIndicator.self, in: vc.view) == nil)

        // Back online: Try Again starts a new lookup and shows progress until
        // it answers.
        ipswService.fetchError = nil
        try #require(findButton(titled: "Try Again", in: vc.view)).performClick(nil)
        #expect(vm.latestImageLookup == .unanswered)
        #expect(firstSubview(NSProgressIndicator.self, in: vc.view) != nil)
        await vc.latestImageTaskForTesting?.value

        #expect(ipswService.fetchCallCount == 2)
        #expect(findLabel(containing: "macOS 26.5.2  ·  Build 25F84", in: vc.view) != nil)
        #expect(findButton(titled: "Try Again", in: vc.view) == nil)
    }

    @Test("The image badge spans the step's width however the step was built")
    func imageBadgeSpansTheStepWidth() async throws {
        // A short destination, so the badge's own content is far narrower than
        // the step and only the layout can make it span.
        let vm = VMCreationViewModel.overEngine(
            probeService: MockRestoreImageProbeService(), ipswService: MockIPSWService(),
            downloadsDirectory: URL(fileURLWithPath: "/D", isDirectory: true))

        // Mounted before the lookup answers, so the badge is rebuilt in place.
        let rebuilt = IPSWSelectionContentViewController(creationVM: vm)
        rebuilt.loadViewIfNeeded()
        rebuilt.viewDidAppear()
        await rebuilt.latestImageTaskForTesting?.value
        // Mounted after it answered, so the badge is built with the view.
        let built = IPSWSelectionContentViewController(creationVM: vm)
        built.loadViewIfNeeded()

        for vc in [rebuilt, built] {
            vc.view.frame = NSRect(x: 0, y: 0, width: WizardStyle.width, height: 460)
            vc.view.layoutSubtreeIfNeeded()
            let subtitle = try #require(
                findLabel(
                    withText: "Choose how to obtain the macOS restore image (IPSW) for installation.",
                    in: vc.view))
            let step = try #require(subtitle.superview as? NSStackView)
            let conditional = try #require(step.arrangedSubviews.last as? NSStackView)
            let badge = try #require(conditional.arrangedSubviews.first)
            // Held to the step's width by a constraint, rather than left to
            // whichever width a `.leading` stack settles on for it — which a
            // headless layout does not reproduce, so the frame alone can't
            // tell the two apart.
            #expect(
                conditional.constraints.contains {
                    $0.isActive && $0.firstItem === badge && $0.firstAttribute == .width
                        && $0.relation == .equal && $0.secondItem === conditional
                        && $0.secondAttribute == .width && $0.multiplier == 1 && $0.constant == 0
                })
            #expect(badge.frame.width == conditional.frame.width)
        }
    }

    @Test("Overwrite warning shows when a file exists; Use Existing switches to local file")
    func overwriteUseExisting() async {
        let path = makeIPSW()

        let inspector = MockLocalRestoreImageInspector()
        inspector.inspectResult = InspectedRestoreImage(
            version: "26.5.2", build: "25F84", isSupportedOnThisHost: true, sizeBytes: 15_500_000_000)
        let vm = await makeLookedUpWizard(localImageInspector: inspector)
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
                containing: "macOS 26.5.2  ·  Build 25F84  ·  \(DataFormatters.formatBytes(15_500_000_000))",
                in: vc.view) != nil)
    }

    @Test("A file of a different build is named, and not adopted until confirmed")
    func mismatchedExistingFileIsNotAdopted() async {
        let inspector = MockLocalRestoreImageInspector()
        inspector.inspectResult = InspectedRestoreImage(
            version: "14.2", build: "23C64", isSupportedOnThisHost: true, sizeBytes: 8_500_000_000)
        let vm = VMCreationViewModel.overEngine(
            localImageInspector: inspector, downloadsDirectory: scratch.url)
        let entry = makeCatalogEntry(version: "15.6.1", build: "24G90")
        vm.selectCatalogEntry(entry)
        let path = makeIPSW(at: vm.ipswDownloadPath)

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
        makeIPSW()

        let inspector = MockLocalRestoreImageInspector()
        inspector.inspectError = LocalRestoreImageError.unreadable
        let vm = await makeLookedUpWizard(localImageInspector: inspector)

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
        makeIPSW()

        let inspector = SuspendingMockLocalRestoreImageInspector()
        let vm = await makeLookedUpWizard(localImageInspector: inspector)

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
        let vm = VMCreationViewModel.overEngine(localImageInspector: inspector)
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
        let vm = VMCreationViewModel.overEngine(localImageInspector: inspector)
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

    /// The nav bar owns why Next is disabled, so the step adds no banner saying
    /// the same.
    @Test("A pending pick leaves the checking message to the nav bar")
    func pendingPickLeavesCheckingToNavBar() async throws {
        let inspector = SuspendingMockLocalRestoreImageInspector()
        let vm = VMCreationViewModel.overEngine(localImageInspector: inspector)
        vm.selectLocalFile(path: "/tmp/picked.ipsw", bookmark: nil)
        try await inspector.waitUntilInspecting()

        let vc = IPSWSelectionContentViewController(creationVM: vm)
        vc.loadViewIfNeeded()
        vc.viewDidAppear()

        #expect(findLabel(containing: "Checking", in: vc.view) == nil)
        vm.currentStep = .bootConfig
        #expect(vm.validationMessage == "Checking the selected restore image\u{2026}")

        inspector.release()
        await vc.localFileInspectionTaskForTesting?.value
    }

    @Test("Download & Replace confirms the overwrite and dismisses the banner")
    func overwriteConfirm() async {
        makeIPSW()

        let vm = await makeLookedUpWizard()
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
        let inspector = MockLocalRestoreImageInspector()
        inspector.inspectResult = InspectedRestoreImage(
            version: "14.2", build: "23C64", isSupportedOnThisHost: true)
        let vm = VMCreationViewModel.overEngine(
            localImageInspector: inspector, downloadsDirectory: scratch.url)
        let entry = makeCatalogEntry(version: "15.6.1", build: "24G90")
        vm.selectCatalogEntry(entry)
        makeIPSW(at: vm.ipswDownloadPath)

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
        makeIPSW()

        let inspector = SuspendingMockLocalRestoreImageInspector()
        let vm = await makeLookedUpWizard(localImageInspector: inspector)

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

    // MARK: - The account offer

    private static let accountToggleTitle = "Set up macOS automatically"

    @available(macOS 27.0, *)
    @Test("An image that can be provisioned offers the account toggle")
    func provisionableImageOffersTheAccountToggle() {
        let vm = VMCreationViewModel.overEngine()
        vm.selectCatalogEntry(makeCatalogEntry(version: "27.0", build: "27A100"))
        let vc = IPSWSelectionContentViewController(creationVM: vm)
        vc.loadViewIfNeeded()

        #expect(findLabel(withText: Self.accountToggleTitle, in: vc.view) != nil)
    }

    @Test("An image that can't be provisioned shows no account toggle at all")
    func unprovisionableImageShowsNoAccountToggle() {
        let vm = VMCreationViewModel.overEngine()
        vm.selectCatalogEntry(makeCatalogEntry(version: "26.4", build: "25E200"))
        let vc = IPSWSelectionContentViewController(creationVM: vm)
        vc.loadViewIfNeeded()

        // Absent, never disabled — a toggle explaining why it can't be used is
        // a control the user is asked to reason about for nothing.
        #expect(findLabel(withText: Self.accountToggleTitle, in: vc.view) == nil)
        #expect(firstSubview(NSSwitch.self, in: vc.view) == nil)
    }

    @available(macOS 27.0, *)
    @Test("The account toggle writes back, and a pick that can't deliver takes the offer away")
    func accountToggleWritesBackAndRetracts() throws {
        let vm = VMCreationViewModel.overEngine()
        vm.selectCatalogEntry(makeCatalogEntry(version: "27.0", build: "27A100"))
        let vc = IPSWSelectionContentViewController(creationVM: vm)
        vc.loadViewIfNeeded()

        let toggle = try #require(firstSubview(NSSwitch.self, in: vc.view))
        #expect(toggle.state == .off)
        toggle.state = .on
        toggle.sendAction(toggle.action, to: toggle.target)
        #expect(vm.unattendedSetupEnabled)
        #expect(vm.unattendedSetupActive)

        // Picking an older image rebuilds this card away, and the wizard stops
        // creating an account without the toggle's answer being rewritten.
        vm.selectCatalogEntry(makeCatalogEntry(version: "26.4", build: "25E200"))
        let rebuilt = IPSWSelectionContentViewController(creationVM: vm)
        rebuilt.loadViewIfNeeded()
        #expect(findLabel(withText: Self.accountToggleTitle, in: rebuilt.view) == nil)
        #expect(!vm.unattendedSetupActive)
    }

    @Test("Double-clicking Download Latest selects it and advances once the lookup has answered")
    func doubleClickDownloadLatestAdvances() async throws {
        let vm = VMCreationViewModel.overEngine(
            probeService: MockRestoreImageProbeService(), ipswService: MockIPSWService())
        vm.selectCatalogEntry(makeCatalogEntry())
        vm.currentStep = .bootConfig
        let vc = IPSWSelectionContentViewController(creationVM: vm)
        vc.loadViewIfNeeded()
        // A plain NSButton would start a tracking loop waiting for a real mouse-up.
        let radio = try #require(
            findButton(titled: "Download Latest", in: vc.view) as? DoubleClickRadioButton)
        let doubleClick = try #require(
            NSEvent.mouseEvent(
                with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, eventNumber: 0, clickCount: 2, pressure: 1))

        // Before the answer the source is chosen, but the step holds.
        radio.mouseDown(with: doubleClick)
        #expect(vm.ipswSource == .downloadLatest)
        #expect(vm.currentStep == .bootConfig)

        await vc.latestImageTaskForTesting?.value
        radio.mouseDown(with: doubleClick)
        #expect(vm.currentStep == .resources)
    }

    // MARK: - Helpers

    /// A wizard on Download Latest whose lookup found `makeLatestImage()`, so its
    /// destination is that image's file in this test's Downloads folder — the
    /// one ``makeIPSW(at:)`` writes by default.
    private func makeLookedUpWizard(
        localImageInspector: any LocalRestoreImageInspecting = MockLocalRestoreImageInspector()
    ) async -> VMCreationViewModel {
        let vm = VMCreationViewModel.overEngine(
            probeService: MockRestoreImageProbeService(), localImageInspector: localImageInspector,
            ipswService: MockIPSWService(), downloadsDirectory: scratch.url)
        await vm.loadLatestImageDetails()?.value
        return vm
    }

    /// Puts an empty IPSW at `path`, the looked-up image's destination in this
    /// test's Downloads folder unless named.
    @discardableResult
    private func makeIPSW(at path: String? = nil) -> String {
        let path =
            path
            ?? scratch.url.appendingPathComponent(makeLatestImage().suggestedFilename)
            .path(percentEncoded: false)
        FileManager.default.createFile(atPath: path, contents: Data())
        return path
    }
}
