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
        #expect(radio(titled: "Choose Local File", in: vc.view)?.state == .off)
        if let path = vm.ipswDownloadPath {
            #expect(findLabel(withText: wizardAbbreviateWithTilde(path), in: vc.view) != nil)
        }
    }

    @Test("Overwrite warning shows when a file exists; Use Existing switches to local file")
    func overwriteUseExisting() {
        let path = makeTempIPSW()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let vm = VMCreationViewModel()
        vm.ipswSource = .downloadLatest
        vm.ipswDownloadPath = path
        #expect(vm.shouldShowOverwriteWarning == true)

        let vc = IPSWSelectionContentViewController(creationVM: vm)
        vc.loadViewIfNeeded()
        #expect(findButton(titled: "Use Existing File", in: vc.view) != nil)

        findButton(titled: "Use Existing File", in: vc.view)?.performClick(nil)
        #expect(vm.ipswSource == .localFile)
        #expect(vm.ipswPath == path)
    }

    @Test("Download & Replace confirms the overwrite and dismisses the banner")
    func overwriteConfirm() {
        let path = makeTempIPSW()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let vm = VMCreationViewModel()
        vm.ipswSource = .downloadLatest
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
