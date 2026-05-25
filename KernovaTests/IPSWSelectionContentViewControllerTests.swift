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

        #expect(card(containingLabel: "Download Latest", in: vc.view)?.isSelected == true)
        #expect(card(containingLabel: "Choose Local File", in: vc.view)?.isSelected == false)
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
    private func allCards(in view: NSView) -> [WizardSelectableCardView] {
        var result: [WizardSelectableCardView] = []
        if let card = view as? WizardSelectableCardView { result.append(card) }
        for subview in view.subviews { result.append(contentsOf: allCards(in: subview)) }
        return result
    }

    @MainActor
    private func card(containingLabel text: String, in view: NSView) -> WizardSelectableCardView? {
        allCards(in: view).first { findLabel(withText: text, in: $0) != nil }
    }
}
