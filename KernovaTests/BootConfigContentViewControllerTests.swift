import AppKit
import Testing

@testable import Kernova

@Suite("BootConfigContentViewController Tests")
@MainActor
struct BootConfigContentViewControllerTests {
    @Test("EFI mode shows the ISO picker row")
    func efiShowsISORow() {
        let vm = VMCreationViewModel()
        vm.selectedOS = .linux
        vm.selectedBootMode = .efi
        let vc = BootConfigContentViewController(creationVM: vm)
        vc.loadViewIfNeeded()

        #expect(segmentedControl(in: vc.view)?.selectedSegment == 0)
        #expect(findLabel(withText: "ISO Image", in: vc.view) != nil)
        #expect(findLabel(withText: "Kernel", in: vc.view) == nil)
    }

    @Test("Switching to Linux Kernel updates the model and shows kernel rows")
    func switchToKernel() {
        let vm = VMCreationViewModel()
        vm.selectedOS = .linux
        vm.selectedBootMode = .efi
        let vc = BootConfigContentViewController(creationVM: vm)
        vc.loadViewIfNeeded()

        guard let segmented = segmentedControl(in: vc.view) else {
            Issue.record("Expected an NSSegmentedControl")
            return
        }
        segmented.selectedSegment = 1
        segmented.sendAction(segmented.action, to: segmented.target)

        #expect(vm.selectedBootMode == .linuxKernel)
        #expect(findLabel(withText: "Kernel", in: vc.view) != nil)
        #expect(findLabel(withText: "Initrd", in: vc.view) != nil)
    }

    @Test("Kernel command line writes back to the model on edit")
    func commandLineWriteBack() {
        let vm = VMCreationViewModel()
        vm.selectedOS = .linux
        vm.selectedBootMode = .linuxKernel
        let vc = BootConfigContentViewController(creationVM: vm)
        vc.loadViewIfNeeded()

        guard let field = editableField(in: vc.view) else {
            Issue.record("Expected an editable command-line NSTextField")
            return
        }
        // The default is both displayed and committed, so the value the user
        // sees is the one `buildConfiguration()` will use.
        #expect(field.stringValue == "console=hvc0")
        #expect(vm.kernelCommandLine == "console=hvc0")

        field.stringValue = "root=/dev/vda console=hvc0"
        vc.controlTextDidChange(
            Notification(name: NSControl.textDidChangeNotification, object: field))
        #expect(vm.kernelCommandLine == "root=/dev/vda console=hvc0")
    }

    @Test("Default kernel command line is committed to the model, not just displayed")
    func defaultCommandLineCommitted() {
        let vm = VMCreationViewModel()
        vm.selectedOS = .linux
        vm.selectedBootMode = .linuxKernel
        #expect(vm.kernelCommandLine == nil)

        let vc = BootConfigContentViewController(creationVM: vm)
        vc.loadViewIfNeeded()

        // Building the kernel section seeds the default so an untouched field
        // doesn't leave the guest booting without the shown command line.
        #expect(vm.kernelCommandLine == "console=hvc0")
    }

    @Test("An explicitly cleared command line is not re-seeded with the default")
    func clearedCommandLineNotReseeded() {
        let vm = VMCreationViewModel()
        vm.selectedOS = .linux
        vm.selectedBootMode = .linuxKernel
        vm.kernelCommandLine = ""  // user cleared it intentionally
        let vc = BootConfigContentViewController(creationVM: vm)
        vc.loadViewIfNeeded()

        #expect(vm.kernelCommandLine == "")
    }

    // MARK: - Helpers

    @MainActor
    private func segmentedControl(in view: NSView) -> NSSegmentedControl? {
        if let control = view as? NSSegmentedControl { return control }
        for subview in view.subviews {
            if let control = segmentedControl(in: subview) { return control }
        }
        return nil
    }

    @MainActor
    private func editableField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.isEditable { return field }
        for subview in view.subviews {
            if let field = editableField(in: subview) { return field }
        }
        return nil
    }
}
