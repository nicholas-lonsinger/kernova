import AppKit
import KernovaKit
import Testing

@testable import Kernova

@Suite("OSSelectionContentViewController Tests", .caseScoped)
@MainActor
struct OSSelectionContentViewControllerTests {
    @Test("The step shows its subtitle and each OS's description")
    func showsSubtitleAndDescriptions() {
        let vc = OSSelectionContentViewController(creationVM: VMCreationViewModel())
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
