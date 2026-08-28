import AppKit
import Testing

@testable import Kernova

@Suite("ReviewContentViewController Tests", .admissionGated)
@MainActor
struct ReviewContentViewControllerTests {
    @Test("General rows reflect the model")
    func generalRowsReflectModel() {
        let vm = VMCreationViewModel()
        vm.vmName = "My Test Box"
        let vc = ReviewContentViewController(creationVM: vm)
        vc.loadViewIfNeeded()

        #expect(findLabel(withText: "My Test Box", in: vc.view) != nil)
        #expect(findLabel(withText: vm.selectedOS.displayName, in: vc.view) != nil)
        #expect(findLabel(withText: "\(vm.cpuCount)", in: vc.view) != nil)
    }

    @Test("The network Mode row names the mode a new VM starts in")
    func networkingReflectsModel() {
        let vm = VMCreationViewModel()
        #expect(vm.networkEnabled)
        let sharedVC = ReviewContentViewController(creationVM: vm)
        sharedVC.loadViewIfNeeded()
        #expect(findLabel(withText: "Shared Network", in: sharedVC.view) != nil)
        #expect(findLabel(withText: "None", in: sharedVC.view) == nil)

        vm.networkEnabled = false
        let noneVC = ReviewContentViewController(creationVM: vm)
        noneVC.loadViewIfNeeded()
        #expect(findLabel(withText: "None", in: noneVC.view) != nil)
        #expect(findLabel(withText: "Shared Network", in: noneVC.view) == nil)
    }

    @Test("macOS + download shows the abbreviated save-to path")
    func macOSDownloadShowsSaveTo() {
        let vm = VMCreationViewModel()  // macOS + downloadLatest by default
        let vc = ReviewContentViewController(creationVM: vm)
        vc.loadViewIfNeeded()

        #expect(findLabel(withText: "Download Latest", in: vc.view) != nil)
        #expect(
            findLabel(withText: wizardAbbreviateWithTilde(vm.ipswDownloadPath), in: vc.view) != nil)
    }

    @Test("macOS + download names the looked-up version, build and size")
    func macOSDownloadShowsLookedUpImage() async {
        let probeService = MockRestoreImageProbeService()
        probeService.sizeResult = 19_772_077_142
        let vm = VMCreationViewModel(probeService: probeService, ipswService: MockIPSWService())
        await vm.loadLatestImageDetails()?.value

        let vc = ReviewContentViewController(creationVM: vm)
        vc.loadViewIfNeeded()

        #expect(findLabel(withText: "Download Latest", in: vc.view) != nil)
        #expect(findLabel(withText: "26.5.2 (25F84)", in: vc.view) != nil)
        #expect(
            findLabel(
                withText: DataFormatters.formatBytes(19_772_077_142), in: vc.view) != nil)
    }

    @Test("A lookup landing after this step appears fills the version and size in")
    func macOSDownloadFillsInLateLookup() async {
        let probeService = MockRestoreImageProbeService()
        probeService.sizeResult = 19_772_077_142
        let vm = VMCreationViewModel(probeService: probeService, ipswService: MockIPSWService())

        let vc = ReviewContentViewController(creationVM: vm)
        vc.loadViewIfNeeded()
        // Reaching the step ahead of the answer, as a slow or offline lookup does.
        #expect(findLabel(withText: "26.5.2 (25F84)", in: vc.view) == nil)

        vc.viewDidAppear()
        await vc.latestImageTaskForTesting?.value

        #expect(findLabel(withText: "26.5.2 (25F84)", in: vc.view) != nil)
        #expect(
            findLabel(
                withText: DataFormatters.formatBytes(19_772_077_142), in: vc.view) != nil)
        // The rows that were already there survive the redraw.
        #expect(findLabel(withText: "Download Latest", in: vc.view) != nil)
    }

    @Test("A lookup that fails leaves the step showing the destination alone")
    func macOSDownloadSurvivesFailedLookup() async {
        let ipswService = MockIPSWService()
        ipswService.fetchError = URLError(.notConnectedToInternet)
        let vm = VMCreationViewModel(
            probeService: MockRestoreImageProbeService(), ipswService: ipswService)

        let vc = ReviewContentViewController(creationVM: vm)
        vc.loadViewIfNeeded()
        vc.viewDidAppear()
        await vc.latestImageTaskForTesting?.value

        #expect(findLabel(withText: "Download Latest", in: vc.view) != nil)
        #expect(findLabel(withText: "macOS version", in: vc.view) == nil)
        #expect(
            findLabel(withText: wizardAbbreviateWithTilde(vm.ipswDownloadPath), in: vc.view) != nil)
    }

    @Test("A Linux review never reaches for a restore image")
    func linuxSkipsLatestImageLookup() {
        let ipswService = MockIPSWService()
        let vm = VMCreationViewModel(
            probeService: MockRestoreImageProbeService(), ipswService: ipswService)
        vm.selectedOS = .linux

        let vc = ReviewContentViewController(creationVM: vm)
        vc.loadViewIfNeeded()
        vc.viewDidAppear()

        #expect(vc.latestImageTaskForTesting == nil)
        #expect(ipswService.fetchCallCount == 0)
    }

    @Test("macOS + local file shows the file basename")
    func macOSLocalFileShowsFile() {
        let vm = VMCreationViewModel(localImageInspector: MockLocalRestoreImageInspector())
        vm.selectLocalFile(path: "/tmp/Restore.ipsw", bookmark: nil)
        let vc = ReviewContentViewController(creationVM: vm)
        vc.loadViewIfNeeded()

        #expect(findLabel(withText: "Local File", in: vc.view) != nil)
        #expect(findLabel(withText: "Restore.ipsw", in: vc.view) != nil)
        // Not yet inspected, so no version or size row shows.
        #expect(findLabel(withText: "macOS version", in: vc.view) == nil)
        #expect(findLabel(withText: "Size", in: vc.view) == nil)
    }

    @Test("macOS + local file names the version and size once the inspection lands")
    func macOSLocalFileShowsVersionAndSize() async {
        let inspector = MockLocalRestoreImageInspector()
        inspector.inspectResult = InspectedRestoreImage(
            version: "15.6.1", build: "24G90", isSupportedOnThisHost: true, sizeBytes: 15_500_000_000)
        let vm = VMCreationViewModel(localImageInspector: inspector)
        vm.selectLocalFile(path: "/tmp/Restore.ipsw", bookmark: nil)
        await vm.localFileInspectionTask?.value

        let vc = ReviewContentViewController(creationVM: vm)
        vc.loadViewIfNeeded()

        #expect(findLabel(withText: "15.6.1 (24G90)", in: vc.view) != nil)
        #expect(findLabel(withText: "Size", in: vc.view) != nil)
        #expect(
            findLabel(withText: DataFormatters.formatBytes(15_500_000_000), in: vc.view) != nil)
    }

    @Test("Linux shows the ISO basename in the Boot section")
    func linuxShowsISO() {
        let vm = VMCreationViewModel()
        vm.selectedOS = .linux
        vm.selectLocalISO(path: "/tmp/ubuntu.iso", bookmark: nil)
        let vc = ReviewContentViewController(creationVM: vm)
        vc.loadViewIfNeeded()

        #expect(findLabel(withText: "ubuntu.iso", in: vc.view) != nil)
    }

    @Test("A Linux catalog pick names the distribution, its size, and where it lands")
    func linuxShowsCatalogPick() {
        let vm = VMCreationViewModel()
        vm.selectedOS = .linux
        vm.selectLinuxCatalogEntry(
            makeLinuxCatalogEntry(
                distribution: "Ubuntu Desktop", version: "26.04 LTS",
                approxSizeBytes: 4_161_089_536))
        let vc = ReviewContentViewController(creationVM: vm)
        vc.loadViewIfNeeded()

        #expect(findLabel(withText: "Ubuntu Desktop", in: vc.view) != nil)
        #expect(findLabel(withText: "26.04 LTS", in: vc.view) != nil)
        #expect(
            findLabel(withText: wizardApproximateSize(4_161_089_536), in: vc.view) != nil)
        // The folder only: the mirror names the file, at download time.
        #expect(
            findLabel(
                withText: wizardAbbreviateWithTilde(
                    VMCreationViewModel.downloadsDirectory.path(percentEncoded: false)),
                in: vc.view) != nil)
    }

    @Test("A Linux URL pick names the file, its size, where it lands and how it is checked")
    func linuxShowsVerifiedURLPick() throws {
        let vm = VMCreationViewModel()
        vm.selectedOS = .linux
        let image = makeCustomLinuxImage()
        vm.selectLinuxCustomURL(image, sizeBytes: 1_073_741_824)
        let vc = ReviewContentViewController(creationVM: vm)
        vc.loadViewIfNeeded()

        #expect(findLabel(withText: "From URL", in: vc.view) != nil)
        // The name in the link the user pasted, not the name on disk.
        #expect(findLabel(withText: "alpine-3.22-aarch64.iso", in: vc.view) != nil)
        #expect(
            findLabel(withText: DataFormatters.formatBytes(1_073_741_824), in: vc.view) != nil)
        #expect(findLabel(withText: "Verified with your checksum", in: vc.view) != nil)
        // The URL names its own destination, so unlike a catalog pick the whole
        // path is known here — carrying a suffix unique to this link.
        let destination = LinuxImageFilename.destination(for: image.url)
        #expect(destination != "alpine-3.22-aarch64.iso")
        #expect(
            findLabel(
                withText: wizardAbbreviateWithTilde(
                    VMCreationViewModel.downloadPath(forFilename: destination)),
                in: vc.view) != nil)
    }

    @Test("A Linux URL pick with no checksum says the download is not verified")
    func linuxShowsUnverifiedURLPick() {
        let vm = VMCreationViewModel()
        vm.selectedOS = .linux
        vm.selectLinuxCustomURL(makeCustomLinuxImage(sha256: nil), sizeBytes: 1_073_741_824)
        let vc = ReviewContentViewController(creationVM: vm)
        vc.loadViewIfNeeded()

        #expect(findLabel(withText: "Not verified", in: vc.view) != nil)
    }

    @Test("Start-after-create switch writes back to the model")
    func startToggleWriteBack() {
        let vm = VMCreationViewModel()  // startAfterCreate defaults to true
        let vc = ReviewContentViewController(creationVM: vm)
        vc.loadViewIfNeeded()

        guard let toggle = firstSubview(NSSwitch.self, in: vc.view) else {
            Issue.record("Expected an NSSwitch")
            return
        }
        #expect(toggle.state == .on)
        toggle.state = .off
        toggle.sendAction(toggle.action, to: toggle.target)
        #expect(vm.startAfterCreate == false)
    }
}
