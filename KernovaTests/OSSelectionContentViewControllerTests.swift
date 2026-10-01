import AppKit
import KernovaKit
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

    @Test("Selecting another OS resets the resources to its defaults")
    func selectingResetsResources() {
        let vm = VMCreationViewModel()
        let vc = OSSelectionContentViewController(creationVM: vm)
        vc.loadViewIfNeeded()
        vm.memorySize = VMMemorySize(mebibytes: 1536)

        findButton(titled: "Linux", in: vc.view)?.performClick(nil)

        #expect(vm.cpuCount == VMGuestOS.linux.defaultCPUCount)
        #expect(vm.memorySize == VMGuestOS.linux.defaultMemorySize)
    }
}
