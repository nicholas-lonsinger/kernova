import AppKit
import Testing

@testable import Kernova

@Suite("ResourceConfigContentViewController Tests")
@MainActor
struct ResourceConfigContentViewControllerTests {
    @Test("Name field writes back to the model on edit")
    func nameLiveWriteBack() {
        let vm = VMCreationViewModel()
        let vc = ResourceConfigContentViewController(creationVM: vm)
        vc.loadViewIfNeeded()

        guard let field = nameField(in: vc.view) else {
            Issue.record("Expected a name NSTextField")
            return
        }
        field.stringValue = "Test Box"
        // Simulate the live-edit notification the field posts while typing.
        vc.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))

        #expect(vm.vmName == "Test Box")
    }

    @Test("CPU/memory stepper bounds come from the selected OS")
    func stepperBoundsPerOS() {
        let vm = VMCreationViewModel()
        vm.selectedOS = .linux
        let vc = ResourceConfigContentViewController(creationVM: vm)
        vc.loadViewIfNeeded()

        let steppers = allSteppers(in: vc.view)
        #expect(steppers.count == 2)
        // Linux minimums: CPU 2, memory 2.
        #expect(steppers.contains { $0.minValue == Double(VMGuestOS.linux.minCPUCount) })
        #expect(steppers.allSatisfy { $0.maxValue >= $0.minValue })
    }

    @Test("Disk popup is populated from availableDiskSizes with size-as-tag")
    func diskPopupPopulated() {
        let vm = VMCreationViewModel()  // macOS
        let vc = ResourceConfigContentViewController(creationVM: vm)
        vc.loadViewIfNeeded()

        guard let popup = diskPopUp(in: vc.view) else {
            Issue.record("Expected a disk NSPopUpButton")
            return
        }
        let expected = VMGuestOS.macOS.availableDiskSizes
        #expect(popup.numberOfItems == expected.count)
        let tags = (0..<popup.numberOfItems).map { popup.item(at: $0)?.tag ?? -1 }
        #expect(tags == expected)
    }

    @Test("Selecting a disk size writes back to the model")
    func diskSelectionWriteBack() {
        let vm = VMCreationViewModel()
        let vc = ResourceConfigContentViewController(creationVM: vm)
        vc.loadViewIfNeeded()

        guard let popup = diskPopUp(in: vc.view) else {
            Issue.record("Expected a disk NSPopUpButton")
            return
        }
        let target = VMGuestOS.macOS.availableDiskSizes.last!
        popup.selectItem(withTag: target)
        // `performClick` on a pop-up opens the menu rather than firing the
        // action, so send the action directly (the user-selection path).
        popup.sendAction(popup.action, to: popup.target)

        #expect(vm.diskSizeInGB == target)
    }

    @Test("Standing CPU/memory values are clamped into the OS range on build")
    func valuesClampedOnBuild() {
        let vm = VMCreationViewModel()
        // Force an out-of-range value, then build for an OS whose max is lower.
        vm.cpuCount = 9_999
        let vc = ResourceConfigContentViewController(creationVM: vm)
        vc.loadViewIfNeeded()

        #expect(vm.cpuCount <= VMGuestOS.macOS.maxCPUCount)
        #expect(vm.cpuCount >= VMGuestOS.macOS.minCPUCount)
    }

    // MARK: - Helpers

    @MainActor
    private func allSteppers(in view: NSView) -> [NSStepper] {
        var result: [NSStepper] = []
        if let stepper = view as? NSStepper { result.append(stepper) }
        for subview in view.subviews { result.append(contentsOf: allSteppers(in: subview)) }
        return result
    }

    @MainActor
    private func diskPopUp(in view: NSView) -> NSPopUpButton? {
        if let popup = view as? NSPopUpButton { return popup }
        for subview in view.subviews {
            if let popup = diskPopUp(in: subview) { return popup }
        }
        return nil
    }

    @MainActor
    private func nameField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.isEditable { return field }
        for subview in view.subviews {
            if let field = nameField(in: subview) { return field }
        }
        return nil
    }
}
