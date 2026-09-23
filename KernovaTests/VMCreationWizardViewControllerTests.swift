import AppKit
import KernovaTestSupport
import Testing

@testable import Kernova

@Suite("VMCreationWizardViewController Tests", .admissionGated, .scopedWindows)
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

    @Test("A second Create activation makes no second request")
    func createIsOneShot() {
        let vm = VMCreationViewModel()
        vm.currentStep = .review
        vm.vmName = "Double Clicked"
        let wizard = VMCreationWizardViewController(creationVM: vm)
        let delegate = MockDelegate()
        wizard.delegate = delegate
        wizard.loadViewIfNeeded()

        // The sheet dismisses asynchronously, so a double click reaches the
        // button twice with the wizard still on screen.
        let create = findButton(titled: "Create", in: wizard.view)
        create?.performClick(nil)
        create?.performClick(nil)

        #expect(delegate.createRequests.count == 1)
        #expect(create?.isEnabled == false)
        #expect(findButton(titled: "Back", in: wizard.view)?.isEnabled == false)
        #expect(findButton(titled: "Cancel", in: wizard.view)?.isEnabled == false)
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

        findButton(titled: "Create", in: wizard.view)?.performClick(nil)
        #expect(delegate.createRequests.count == 1)

        // The host calls this for the refusal raised before anything was
        // written. (No window in the test, so no alert is presented.)
        wizard.presentCreationFailure(message: "Disk full")
        #expect(findButton(titled: "Cancel", in: wizard.view)?.isEnabled == true)
        #expect(findButton(titled: "Back", in: wizard.view)?.isEnabled == true)
        #expect(findButton(titled: "Create", in: wizard.view)?.isEnabled == true)

        // And the retry goes through, rather than tripping the one-shot again.
        findButton(titled: "Create", in: wizard.view)?.performClick(nil)
        #expect(delegate.createRequests.count == 2)
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

    // MARK: - The account step

    /// A wizard model on an image that can be provisioned, with the account
    /// toggle on and the form filled.
    private func makeAccountModel() -> VMCreationViewModel {
        let vm = VMCreationViewModel()
        vm.selectCatalogEntry(makeCatalogEntry(version: "27.0", build: "27A100"))
        vm.unattendedSetupEnabled = true
        vm.guestAccountFullName = "Ada Lovelace"
        vm.guestAccountUsername = "ada"
        vm.guestAccountPassword = "analytical-engine"
        vm.guestAccountVerifyPassword = "analytical-engine"
        return vm
    }

    @available(macOS 27.0, *)
    @Test("The account step mounts its own view controller and joins the indicator")
    func accountStepMounts() {
        let vm = makeAccountModel()
        vm.currentStep = .guestAccount
        let wizard = VMCreationWizardViewController(creationVM: vm)
        wizard.loadViewIfNeeded()

        #expect(wizard.children.count == 1)
        #expect(wizard.children.first is GuestAccountContentViewController)
        #expect(findLabel(withText: "Account", in: wizard.view) != nil)
        #expect(findButton(titled: "Next", in: wizard.view)?.isEnabled == true)
    }

    @available(macOS 27.0, *)
    @Test("Next from Resources mounts the account step when an account is being created")
    func nextFromResourcesMountsTheAccountStep() {
        let vm = makeAccountModel()
        vm.currentStep = .resources
        let wizard = VMCreationWizardViewController(creationVM: vm)
        wizard.loadViewIfNeeded()

        findButton(titled: "Next", in: wizard.view)?.performClick(nil)

        #expect(vm.currentStep == .guestAccount)
        #expect(wizard.children.first is GuestAccountContentViewController)
    }

    @available(macOS 27.0, *)
    @Test("Tab walks the account fields in order when the step mounts after the sheet is up")
    func tabWalksTheAccountFields() throws {
        let vm = makeAccountModel()
        vm.currentStep = .resources
        let wizard = VMCreationWizardViewController(creationVM: vm)
        let parent = showTestWindow(
            styleMask: [.titled], contentSize: NSSize(width: 900, height: 800))
        let presenter = SheetPresenter()
        presenter.show(content: wizard, in: parent)
        let sheet = try #require(parent.attachedSheet)
        adoptAppWindow(sheet)
        // A key-view request builds the sheet's loop from the Resources step, as
        // the sheet does when it first shows.
        sheet.selectNextKeyView(nil)

        findButton(titled: "Next", in: wizard.view)?.performClick(nil)
        try #require(wizard.children.first is GuestAccountContentViewController)

        let labels = ["Full name", "Account name", "Password", "Verify"]
        let fields = try labels.map {
            try #require(editableField($0, in: wizard.view), "no \($0) field")
        }
        #expect(sheet.makeFirstResponder(fields[0]))
        // Asserts the loop Tab follows rather than where Tab lands: a window
        // that isn't key — no test window is — never moves focus on
        // `selectNextKeyView`, but the request still brings the loop up to date.
        sheet.selectNextKeyView(nil)
        for index in fields.indices.dropFirst() {
            #expect(
                fields[index - 1].nextValidKeyView === fields[index],
                "Tab from \(labels[index - 1]) lands on \(labels[index])")
        }
    }

    @Test("Next from Resources mounts Review when no account is being created")
    func nextFromResourcesSkipsTheAccountStep() {
        let vm = VMCreationViewModel()  // Download Latest, nothing looked up yet
        vm.currentStep = .resources
        let wizard = VMCreationWizardViewController(creationVM: vm)
        wizard.loadViewIfNeeded()

        // The step is absent, not disabled: nothing about it is on the indicator.
        #expect(findLabel(withText: "Account", in: wizard.view) == nil)

        findButton(titled: "Next", in: wizard.view)?.performClick(nil)

        #expect(vm.currentStep == .review)
        #expect(wizard.children.first is ReviewContentViewController)
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
