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

        #expect(radio(titled: "Download Latest", in: vc.view)?.state == .on)
        #expect(radio(titled: "Choose a Version…", in: vc.view)?.state == .off)
        #expect(radio(titled: "Choose Local File…", in: vc.view)?.state == .off)
        #expect(
            findLabel(withText: wizardAbbreviateWithTilde(vm.ipswDownloadPath), in: vc.view) != nil)
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
        #expect(findLabelContaining("macOS 14.2 (23C64)", in: vc.view) != nil)

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
        #expect(findLabelContaining("isn't a usable restore image", in: vc.view) != nil)
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

    private func findLabelContaining(_ text: String, in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.stringValue.contains(text) { return field }
        for subview in view.subviews {
            if let found = findLabelContaining(text, in: subview) { return found }
        }
        return nil
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

    // MARK: - Helpers

    @MainActor
    private func makeTempIPSW() -> String {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("RestoreImage-\(UUID().uuidString).ipsw")
            .path(percentEncoded: false)
        FileManager.default.createFile(atPath: path, contents: Data())
        return path
    }

    @MainActor
    private func radio(titled title: String, in view: NSView) -> NSButton? {
        if let button = view as? NSButton, button.title == title { return button }
        for subview in view.subviews {
            if let found = radio(titled: title, in: subview) { return found }
        }
        return nil
    }
}
