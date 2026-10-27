import AppKit
import KernovaKit
import Testing

@testable import KernovaCore
@testable import KernovaUI

@Suite("OSSelectionContentViewController Tests", .caseScoped)
@MainActor
struct OSSelectionContentViewControllerTests {
    @Test("The step shows its subtitle and each OS's description")
    func showsSubtitleAndDescriptions() {
        let vc = OSSelectionContentViewController(
            creationVM: VMCreationViewModel.overEngine())
        vc.loadViewIfNeeded()

        for text in [
            "Select the operating system you want to run in your virtual machine.",
            "Run macOS in a virtual machine on Apple Silicon.",
            "Run Linux distributions using EFI or direct kernel boot.",
        ] {
            #expect(findLabel(withText: text, in: vc.view) != nil, "\(text)")
        }
    }

    @Test("Initial selection reflects the model's selectedOS")
    func initialSelectionReflectsModel() {
        let vm = VMCreationViewModel.overEngine()  // defaults to .macOS
        let vc = OSSelectionContentViewController(creationVM: vm)
        vc.loadViewIfNeeded()

        #expect(findButton(titled: "macOS", in: vc.view)?.state == .on)
        #expect(findButton(titled: "Linux", in: vc.view)?.state == .off)
    }

    @Test("Selecting an OS updates the model and enforces radio exclusivity, staying on the step")
    func selectingUpdatesModelAndChrome() {
        let vm = VMCreationViewModel.overEngine()
        let vc = OSSelectionContentViewController(creationVM: vm)
        vc.loadViewIfNeeded()

        findButton(titled: "Linux", in: vc.view)?.performClick(nil)

        #expect(vm.selectedOS == .linux)
        #expect(findButton(titled: "Linux", in: vc.view)?.state == .on)
        #expect(findButton(titled: "macOS", in: vc.view)?.state == .off)
        #expect(vm.currentStep == .osSelection)
    }

    @Test("Double-clicking an OS selects it and advances to the next step")
    func doubleClickSelectsAndAdvances() throws {
        let vm = VMCreationViewModel.overEngine()
        let vc = OSSelectionContentViewController(creationVM: vm)
        vc.loadViewIfNeeded()
        // A plain NSButton would start a tracking loop waiting for a real mouse-up.
        let radio = try #require(findButton(titled: "Linux", in: vc.view) as? DoubleClickRadioButton)

        radio.mouseDown(with: try doubleClick())

        #expect(vm.selectedOS == .linux)
        #expect(findButton(titled: "Linux", in: vc.view)?.state == .on)
        #expect(findButton(titled: "macOS", in: vc.view)?.state == .off)
        #expect(vm.currentStep == .bootConfig)
    }

    private func doubleClick() throws -> NSEvent {
        try #require(
            NSEvent.mouseEvent(
                with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, eventNumber: 0, clickCount: 2, pressure: 1))
    }
}
