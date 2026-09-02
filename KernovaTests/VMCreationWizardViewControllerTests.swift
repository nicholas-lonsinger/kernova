import AppKit
import Testing

@testable import Kernova

@Suite("VMCreationWizardViewController Tests", .admissionGated)
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
        // Default OS is macOS, so the boot step mounts the IPSW selection VC.
        #expect(wizard.children.first is IPSWSelectionContentViewController)
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

    @Test("A refused create leaves the wizard usable for a retry")
    func refusedCreateLeavesWizardUsable() {
        let vm = VMCreationViewModel()
        vm.currentStep = .review
        vm.vmName = "Retry VM"
        let wizard = VMCreationWizardViewController(creationVM: vm)
        let delegate = MockDelegate()
        wizard.delegate = delegate
        wizard.loadViewIfNeeded()

        // The create registers its row and returns on the same turn, so the
        // sheet is either closed or still showing the step to retry from —
        // never a disabled shell waiting on a copy.
        findButton(titled: "Create", in: wizard.view)?.performClick(nil)
        #expect(delegate.createRequests.count == 1)

        // The host calls this for the refusal raised before anything was
        // written. (No window in the test, so no alert is presented.)
        wizard.presentCreationFailure(message: "Disk full")
        #expect(findButton(titled: "Cancel", in: wizard.view)?.isEnabled == true)
        #expect(findButton(titled: "Create", in: wizard.view)?.isEnabled == true)
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
