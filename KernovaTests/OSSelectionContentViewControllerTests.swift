import AppKit
import Testing

@testable import Kernova

@Suite("OSSelectionContentViewController Tests")
@MainActor
struct OSSelectionContentViewControllerTests {
    @Test("Initial selection reflects the model's selectedOS")
    func initialSelectionReflectsModel() {
        let vm = VMCreationViewModel()  // defaults to .macOS
        let vc = OSSelectionContentViewController(creationVM: vm)
        vc.loadViewIfNeeded()

        #expect(card(containingLabel: "macOS", in: vc.view)?.isSelected == true)
        #expect(card(containingLabel: "Linux", in: vc.view)?.isSelected == false)
    }

    @Test("Selecting an OS updates the model and the selection chrome")
    func selectingUpdatesModelAndChrome() {
        let vm = VMCreationViewModel()
        let vc = OSSelectionContentViewController(creationVM: vm)
        vc.loadViewIfNeeded()

        card(containingLabel: "Linux", in: vc.view)?.onClick?()

        #expect(vm.selectedOS == .linux)
        #expect(card(containingLabel: "Linux", in: vc.view)?.isSelected == true)
        #expect(card(containingLabel: "macOS", in: vc.view)?.isSelected == false)
    }

    @Test("Selecting an OS does not apply OS resource defaults")
    func selectingDoesNotApplyOSDefaults() {
        // `applyOSDefaults()` is intentionally never called by the wizard;
        // changing the OS must leave CPU/memory at their standing values.
        let vm = VMCreationViewModel()
        let originalCPU = vm.cpuCount
        let originalMemory = vm.memoryInGB
        let vc = OSSelectionContentViewController(creationVM: vm)
        vc.loadViewIfNeeded()

        card(containingLabel: "Linux", in: vc.view)?.onClick?()

        #expect(vm.cpuCount == originalCPU)
        #expect(vm.memoryInGB == originalMemory)
    }

    // MARK: - Helpers

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
