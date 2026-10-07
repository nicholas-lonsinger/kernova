import KernovaKit
import AppKit
import KernovaTestSupport
import Testing

@testable import Kernova

@Suite("ResourceConfigContentViewController Tests", .caseScoped)
@MainActor
struct ResourceConfigContentViewControllerTests {
    @Test("Name field writes back to the model on edit")
    func nameLiveWriteBack() {
        let vm = VMCreationViewModel()
        let vc = ResourceConfigContentViewController(creationVM: vm)
        vc.loadViewIfNeeded()

        guard let field = findEditableField(in: vc.view) else {
            Issue.record("Expected a name NSTextField")
            return
        }
        field.stringValue = "Test Box"
        // Simulate the live-edit notification the field posts while typing.
        vc.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))

        #expect(vm.vmName == "Test Box")
    }

    @Test("CPU/memory stepper bounds are the framework's, for every guest", arguments: VMGuestOS.allCases)
    func stepperBoundsAreTheFrameworks(os: VMGuestOS) throws {
        let vm = VMCreationViewModel()
        vm.selectedOS = os
        let vc = ResourceConfigContentViewController(creationVM: vm)
        vc.loadViewIfNeeded()

        let steppers = allSubviews(NSStepper.self, in: vc.view)
        try #require(steppers.count == 2)
        #expect(steppers[0].minValue == Double(VMResourceLimits.cpuCount.lower))
        #expect(steppers[0].maxValue == Double(VMResourceLimits.cpuCount.upper))
        #expect(steppers[1].minValue == VMResourceLimits.memorySize.lower.gibibytes)
        #expect(steppers[1].maxValue == VMResourceLimits.memorySize.upper.gibibytes)
    }

    @Test("Every guest is offered every disk size, tagged by size", arguments: VMGuestOS.allCases)
    func diskPopupPopulated(os: VMGuestOS) {
        let vm = VMCreationViewModel()
        vm.selectedOS = os
        let vc = ResourceConfigContentViewController(creationVM: vm)
        vc.loadViewIfNeeded()

        guard let popup = firstSubview(NSPopUpButton.self, in: vc.view) else {
            Issue.record("Expected a disk NSPopUpButton")
            return
        }
        let tags = (0..<popup.numberOfItems).map { popup.item(at: $0)?.tag ?? -1 }
        #expect(tags == VMGuestOS.allDiskSizes)
        #expect(popup.selectedTag() == VMGuestOS.defaultDiskSizeInGB)
    }

    @Test("Selecting a disk size writes back to the model")
    func diskSelectionWriteBack() {
        let vm = VMCreationViewModel()
        let vc = ResourceConfigContentViewController(creationVM: vm)
        vc.loadViewIfNeeded()

        guard let popup = firstSubview(NSPopUpButton.self, in: vc.view) else {
            Issue.record("Expected a disk NSPopUpButton")
            return
        }
        let target = VMGuestOS.allDiskSizes.last!
        popup.selectItem(withTag: target)
        // `performClick` on a pop-up opens the menu rather than firing the
        // action, so send the action directly (the user-selection path).
        popup.sendAction(popup.action, to: popup.target)

        #expect(vm.diskSizeInGB == target)
    }

    @Test("CPU field does not clamp mid-keystroke; it clamps on end-of-edit")
    func cpuClampsOnEndEditingOnly() throws {
        let vm = VMCreationViewModel()
        let vc = ResourceConfigContentViewController(creationVM: vm)
        vc.loadViewIfNeeded()

        let steppers = allSubviews(NSStepper.self, in: vc.view)
        let cpuField = try #require(numberFields(in: vc.view).first)
        let cpuStepper = try #require(steppers.first)
        let startingStepper = cpuStepper.integerValue

        // Typing the first digit of "16" reads as 1. The change notification
        // must not clamp — the stepper stays put and the field keeps the text.
        cpuField.stringValue = "1"
        vc.controlTextDidChange(
            Notification(name: NSControl.textDidChangeNotification, object: cpuField))
        #expect(cpuStepper.integerValue == startingStepper)
        #expect(cpuField.stringValue == "1")

        // Past the top, end-of-edit clamps and reconciles model, stepper, and
        // field together.
        cpuField.stringValue = String(VMResourceLimits.cpuCount.upper + 1)
        vc.controlTextDidEndEditing(
            Notification(name: NSControl.textDidEndEditingNotification, object: cpuField))
        #expect(vm.cpuCount == VMResourceLimits.cpuCount.upper)
        #expect(cpuStepper.integerValue == VMResourceLimits.cpuCount.upper)
        #expect(cpuField.integerValue == VMResourceLimits.cpuCount.upper)
    }

    @Test("The memory field takes a decimal to the nearest megabyte; the arrows move between whole gigabytes")
    func memoryFieldAndStepper() throws {
        let vm = VMCreationViewModel()
        let vc = ResourceConfigContentViewController(creationVM: vm)
        vc.loadViewIfNeeded()

        let memoryField = try #require(numberFields(in: vc.view).last)
        let memoryStepper = try #require(allSubviews(NSStepper.self, in: vc.view).last)
        #expect(memoryField.stringValue == vm.selectedOS.defaultMemorySize.gibibytesText)

        memoryField.stringValue = "1.5"
        vc.controlTextDidEndEditing(
            Notification(name: NSControl.textDidEndEditingNotification, object: memoryField))
        #expect(vm.memorySize.mebibytes == 1536)
        #expect(memoryField.stringValue == "1.5")

        memoryStepper.doubleValue = 2.5  // an up-arrow click from 1.5
        memoryStepper.sendAction(memoryStepper.action, to: memoryStepper.target)
        #expect(vm.memorySize == .gibibytes(2))
        #expect(memoryField.stringValue == "2")
        #expect(memoryStepper.doubleValue == 2)

        memoryField.stringValue = "1.5"
        vc.controlTextDidEndEditing(
            Notification(name: NSControl.textDidEndEditingNotification, object: memoryField))
        memoryStepper.doubleValue = 0.5  // a down-arrow click from 1.5
        memoryStepper.sendAction(memoryStepper.action, to: memoryStepper.target)
        #expect(vm.memorySize == .gibibytes(1))

        memoryField.stringValue = "plenty"
        vc.controlTextDidEndEditing(
            Notification(name: NSControl.textDidEndEditingNotification, object: memoryField))
        #expect(vm.memorySize == .gibibytes(1))
        #expect(memoryField.stringValue == "1")
    }

    // MARK: - Helpers

    /// The CPU and Memory fields, in that order: the right-aligned editable
    /// fields, in a pre-order walk.
    @MainActor
    private func numberFields(in view: NSView) -> [NSTextField] {
        allSubviews(NSTextField.self, in: view).filter { $0.isEditable && $0.alignment == .right }
    }
}
