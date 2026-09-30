import AppKit
import KernovaTestSupport
import Testing

@testable import Kernova

@Suite("OSSelectionContentViewController Tests", .caseScoped)
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

    @Test("Selecting an OS moves the resource defaults and leaves the values the user chose")
    func selectingMovesDefaultsAndLeavesChoices() {
        let vm = VMCreationViewModel()
        let vc = OSSelectionContentViewController(creationVM: vm)
        vc.loadViewIfNeeded()
        vm.memorySize = VMMemorySize(mebibytes: 1536)

        findButton(titled: "Linux", in: vc.view)?.performClick(nil)

        #expect(vm.cpuCount == VMGuestOS.linux.defaultCPUCount)
        #expect(vm.memorySize.mebibytes == 1536)
    }
}
