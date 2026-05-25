import AppKit
import Testing

@testable import Kernova

@Suite("VMCreationWizardViewController Tests")
@MainActor
struct VMCreationWizardViewControllerTests {
    @Test("Initial OS-selection step: Back hidden, Next enabled, Create hidden")
    func initialStepChrome() {
        let vm = VMCreationViewModel()
        let wizard = VMCreationWizardViewController(creationVM: vm)
        wizard.loadViewIfNeeded()

        #expect(wizard.children.count == 1)
        #expect(wizard.children.first is OSSelectionContentViewController)

        #expect(findButton(titled: "Back", in: wizard.view)?.isHidden == true)
        let next = findButton(titled: "Next", in: wizard.view)
        #expect(next?.isHidden == false)
        #expect(next?.isEnabled == true)
        #expect(findButton(titled: "Create", in: wizard.view)?.isHidden == true)
    }

    @Test("Shell fits the fixed wizard dimensions")
    func fittingSizeMatchesTokens() {
        let wizard = VMCreationWizardViewController(creationVM: VMCreationViewModel())
        wizard.loadViewIfNeeded()
        wizard.view.layoutSubtreeIfNeeded()
        #expect(wizard.view.fittingSize.width == WizardStyle.width)
        #expect(wizard.view.fittingSize.height == WizardStyle.height)
    }

    @Test("Next advances the model and swaps the mounted step")
    func nextAdvancesAndSwapsChild() {
        let vm = VMCreationViewModel()
        let wizard = VMCreationWizardViewController(creationVM: vm)
        wizard.loadViewIfNeeded()

        findButton(titled: "Next", in: wizard.view)?.performClick(nil)

        #expect(vm.currentStep == .bootConfig)
        #expect(wizard.children.count == 1)
        #expect(wizard.children.first is WizardStepPlaceholderViewController)
    }

    @Test("Back returns to the previous step")
    func backReturnsToPreviousStep() {
        let vm = VMCreationViewModel()
        vm.currentStep = .resources
        let wizard = VMCreationWizardViewController(creationVM: vm)
        wizard.loadViewIfNeeded()

        let back = findButton(titled: "Back", in: wizard.view)
        #expect(back?.isHidden == false)
        back?.performClick(nil)

        #expect(vm.currentStep == .bootConfig)
    }

    @Test("Review step shows Create and reports the model on click")
    func reviewStepCreate() {
        let vm = VMCreationViewModel()
        vm.currentStep = .review
        let wizard = VMCreationWizardViewController(creationVM: vm)
        let delegate = MockDelegate()
        wizard.delegate = delegate
        wizard.loadViewIfNeeded()

        #expect(findButton(titled: "Next", in: wizard.view)?.isHidden == true)
        let create = findButton(titled: "Create", in: wizard.view)
        #expect(create?.isHidden == false)
        #expect(create?.isEnabled == true)

        create?.performClick(nil)
        #expect(delegate.createRequests.count == 1)
        #expect(delegate.createRequests.first === vm)
    }

    @Test("Create is disabled on review when the name is blank")
    func reviewCreateDisabledWhenNameBlank() {
        let vm = VMCreationViewModel()
        vm.currentStep = .review
        vm.vmName = "   "
        let wizard = VMCreationWizardViewController(creationVM: vm)
        wizard.loadViewIfNeeded()

        #expect(findButton(titled: "Create", in: wizard.view)?.isEnabled == false)
    }

    @Test("Cancel reports to the delegate")
    func cancelFiresDelegate() {
        let wizard = VMCreationWizardViewController(creationVM: VMCreationViewModel())
        let delegate = MockDelegate()
        wizard.delegate = delegate
        wizard.loadViewIfNeeded()

        findButton(titled: "Cancel", in: wizard.view)?.performClick(nil)
        #expect(delegate.cancelCount == 1)
    }

    @Test("Validation message displays and gates Next when the model is invalid")
    func validationGatesNext() {
        let vm = VMCreationViewModel()
        vm.currentStep = .resources
        vm.vmName = ""
        let wizard = VMCreationWizardViewController(creationVM: vm)
        wizard.loadViewIfNeeded()

        #expect(findButton(titled: "Next", in: wizard.view)?.isEnabled == false)
        #expect(
            findLabel(withText: "Enter a name for your virtual machine.", in: wizard.view) != nil)
    }

    // MARK: - Helpers

    @MainActor
    private final class MockDelegate: VMCreationWizardViewControllerDelegate {
        var cancelCount = 0
        var createRequests: [VMCreationViewModel] = []

        func wizardDidCancel(_ vc: VMCreationWizardViewController) {
            cancelCount += 1
        }

        func wizardDidRequestCreate(
            _ vc: VMCreationWizardViewController,
            creationVM: VMCreationViewModel
        ) {
            createRequests.append(creationVM)
        }
    }
}

// MARK: - Shared view-tree helpers

@MainActor
func findButton(titled title: String, in view: NSView) -> NSButton? {
    if let button = view as? NSButton, !(view is NSPopUpButton), button.title == title {
        return button
    }
    for subview in view.subviews {
        if let button = findButton(titled: title, in: subview) { return button }
    }
    return nil
}

@MainActor
func findLabel(withText text: String, in view: NSView) -> NSTextField? {
    if let field = view as? NSTextField, !(view is NSButton), field.stringValue == text {
        return field
    }
    for subview in view.subviews {
        if let field = findLabel(withText: text, in: subview) { return field }
    }
    return nil
}
