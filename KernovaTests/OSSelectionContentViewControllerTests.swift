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

        #expect(findButton(titled: "macOS", in: vc.view)?.state == .on)
        #expect(findButton(titled: "Linux", in: vc.view)?.state == .off)
    }

    @Test("Selecting an OS updates the model and enforces radio exclusivity")
    func selectingUpdatesModelAndChrome() {
        let vm = VMCreationViewModel()
        let vc = OSSelectionContentViewController(creationVM: vm)
        vc.loadViewIfNeeded()

        findButton(titled: "Linux", in: vc.view)?.performClick(nil)

        #expect(vm.selectedOS == .linux)
        #expect(findButton(titled: "Linux", in: vc.view)?.state == .on)
        #expect(findButton(titled: "macOS", in: vc.view)?.state == .off)
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

        findButton(titled: "Linux", in: vc.view)?.performClick(nil)

        #expect(vm.cpuCount == originalCPU)
        #expect(vm.memoryInGB == originalMemory)
    }
}
