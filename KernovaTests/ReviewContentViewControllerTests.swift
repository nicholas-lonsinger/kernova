import AppKit
import Testing

@testable import Kernova

@Suite("ReviewContentViewController Tests")
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

    @Test("Networking row reflects the disabled state")
    func networkingReflectsModel() {
        let vm = VMCreationViewModel()
        vm.networkEnabled = false
        let vc = ReviewContentViewController(creationVM: vm)
        vc.loadViewIfNeeded()

        #expect(findLabel(withText: "Disabled", in: vc.view) != nil)
        #expect(findLabel(withText: "Enabled", in: vc.view) == nil)
    }

    @Test("macOS + download shows the abbreviated save-to path")
    func macOSDownloadShowsSaveTo() {
        let vm = VMCreationViewModel()  // macOS + downloadLatest by default
        let vc = ReviewContentViewController(creationVM: vm)
        vc.loadViewIfNeeded()

        #expect(findLabel(withText: "Download Latest", in: vc.view) != nil)
        if let path = vm.ipswDownloadPath {
            #expect(findLabel(withText: wizardAbbreviateWithTilde(path), in: vc.view) != nil)
        }
    }

    @Test("macOS + local file shows the file basename")
    func macOSLocalFileShowsFile() {
        let vm = VMCreationViewModel()
        vm.ipswSource = .localFile
        vm.ipswPath = "/tmp/Restore.ipsw"
        let vc = ReviewContentViewController(creationVM: vm)
        vc.loadViewIfNeeded()

        #expect(findLabel(withText: "Local File", in: vc.view) != nil)
        #expect(findLabel(withText: "Restore.ipsw", in: vc.view) != nil)
    }

    @Test("Linux shows the ISO basename in the Boot section")
    func linuxShowsISO() {
        let vm = VMCreationViewModel()
        vm.selectedOS = .linux
        vm.isoPath = "/tmp/ubuntu.iso"
        let vc = ReviewContentViewController(creationVM: vm)
        vc.loadViewIfNeeded()

        #expect(findLabel(withText: "ubuntu.iso", in: vc.view) != nil)
    }

    @Test("Start-after-create switch writes back to the model")
    func startToggleWriteBack() {
        let vm = VMCreationViewModel()  // startAfterCreate defaults to true
        let vc = ReviewContentViewController(creationVM: vm)
        vc.loadViewIfNeeded()

        guard let toggle = findSwitch(in: vc.view) else {
            Issue.record("Expected an NSSwitch")
            return
        }
        #expect(toggle.state == .on)
        toggle.state = .off
        toggle.sendAction(toggle.action, to: toggle.target)
        #expect(vm.startAfterCreate == false)
    }

    // MARK: - Helpers

    @MainActor
    private func findSwitch(in view: NSView) -> NSSwitch? {
        if let toggle = view as? NSSwitch { return toggle }
        for subview in view.subviews {
            if let toggle = findSwitch(in: subview) { return toggle }
        }
        return nil
    }
}
