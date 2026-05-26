import AppKit

/// Delegate for ``VMCreationWizardViewController``.
///
/// The wizard is intentionally decoupled from `VMLibraryViewModel`. The host
/// (`DetailContainerViewController`) implements these methods to dismiss the
/// sheet and perform the actual VM creation, mirroring the
/// `DeleteVMSheetContentViewController` decoupling.
@MainActor
protocol VMCreationWizardViewControllerDelegate: AnyObject {
    /// Invoked when the user clicks Cancel (or presses Escape).
    func wizardDidCancel(_ vc: VMCreationWizardViewController)

    /// Invoked when the user clicks Create on the final step.
    ///
    /// - Parameters:
    ///   - vc: The wizard reporting the event.
    ///   - creationVM: The fully-populated wizard model the host should hand to
    ///     `VMLibraryViewModel.createVM(from:)`.
    func wizardDidRequestCreate(
        _ vc: VMCreationWizardViewController,
        creationVM: VMCreationViewModel
    )
}

/// The multi-step VM creation wizard, presented as a fixed-size sheet.
///
/// Owns three regions — a step-progress indicator, a swappable content area
/// hosting one step view controller at a time, and a navigation bar. The shell
/// observes the shared ``VMCreationViewModel`` (the single source of truth all
/// steps read/write) and reacts to changes in `currentStep`, `canAdvance`,
/// `canCreate`, and `validationMessage` — it never receives per-step delegate
/// callbacks. Button actions mutate the model (`goNext()`/`goBack()`) and let
/// observation drive the transition, so menu-driven and button-driven state
/// take the identical path.
@MainActor
final class VMCreationWizardViewController: NSViewController {
    weak var delegate: VMCreationWizardViewControllerDelegate?

    private let creationVM: VMCreationViewModel

    // MARK: - Subviews held for state updates

    private let stepIndicator = WizardStepIndicatorView()
    private let contentContainer = NSView()
    private let validationLabel = NSTextField(labelWithString: "")
    private let cancelButton = NSButton()
    private let backButton = NSButton()
    private let nextButton = NSButton()
    private let createButton = NSButton()

    // MARK: - Transition state

    private var currentChild: NSViewController?
    private var displayedStep: VMCreationStep?
    private var observation: ObservationLoop?

    init(creationVM: VMCreationViewModel) {
        self.creationVM = creationVM
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("VMCreationWizardViewController does not support NSCoder")
    }

    // MARK: - Lifecycle

    override func loadView() {
        let container = NSView()

        let indicatorRow = makeIndicatorRow()
        let divider1 = makeHorizontalSeparator()
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        let divider2 = makeHorizontalSeparator()
        let navBar = makeNavBar()

        [indicatorRow, divider1, contentContainer, divider2, navBar].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview($0)
        }

        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: WizardStyle.width),
            container.heightAnchor.constraint(equalToConstant: WizardStyle.height),

            indicatorRow.topAnchor.constraint(equalTo: container.topAnchor),
            indicatorRow.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            indicatorRow.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            divider1.topAnchor.constraint(equalTo: indicatorRow.bottomAnchor),
            divider1.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            divider1.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            contentContainer.topAnchor.constraint(equalTo: divider1.bottomAnchor),
            contentContainer.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            divider2.topAnchor.constraint(equalTo: contentContainer.bottomAnchor),
            divider2.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            divider2.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            navBar.topAnchor.constraint(equalTo: divider2.bottomAnchor),
            navBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            navBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            navBar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // Mount the initial step and set the initial chrome. `apply()` mounts
        // because `displayedStep` is still nil.
        apply()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        if observation == nil {
            observation = observeRecurring(
                track: { [weak self] in
                    guard let self else { return }
                    _ = self.creationVM.currentStep
                    _ = self.creationVM.canAdvance
                    _ = self.creationVM.canCreate
                    _ = self.creationVM.validationMessage
                    _ = self.creationVM.selectedOS
                },
                apply: { [weak self] in
                    self?.apply()
                }
            )
        }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        observation?.cancel()
        observation = nil
    }

    // MARK: - Chrome construction

    private func makeIndicatorRow() -> NSView {
        let container = NSView()
        stepIndicator.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stepIndicator)
        let padding = WizardStyle.chromePadding
        NSLayoutConstraint.activate([
            stepIndicator.topAnchor.constraint(equalTo: container.topAnchor, constant: padding),
            stepIndicator.bottomAnchor.constraint(
                equalTo: container.bottomAnchor, constant: -padding),
            stepIndicator.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stepIndicator.leadingAnchor.constraint(
                greaterThanOrEqualTo: container.leadingAnchor, constant: padding),
        ])
        return container
    }

    private func makeNavBar() -> NSView {
        let container = NSView()

        cancelButton.title = "Cancel"
        cancelButton.bezelStyle = .rounded
        cancelButton.target = self
        cancelButton.action = #selector(cancelTapped)
        cancelButton.keyEquivalent = "\u{1B}"  // Escape

        backButton.title = "Back"
        backButton.bezelStyle = .rounded
        backButton.target = self
        backButton.action = #selector(backTapped)

        nextButton.title = "Next"
        nextButton.bezelStyle = .rounded
        nextButton.target = self
        nextButton.action = #selector(nextTapped)

        createButton.title = "Create"
        createButton.bezelStyle = .rounded
        createButton.target = self
        createButton.action = #selector(createTapped)

        validationLabel.font = .preferredFont(forTextStyle: .caption1)
        validationLabel.textColor = .secondaryLabelColor
        validationLabel.isSelectable = false
        validationLabel.lineBreakMode = .byTruncatingTail
        validationLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        validationLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [
            cancelButton, spacer, validationLabel, backButton, nextButton, createButton,
        ])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(row)
        let padding = WizardStyle.chromePadding
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: container.topAnchor, constant: padding),
            row.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: padding),
            row.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -padding),
            row.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -padding),
        ])
        return container
    }

    private func makeHorizontalSeparator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    // MARK: - State application

    /// Idempotent refresh of all chrome from the model, performing a step
    /// transition when `currentStep` has changed since the last mount.
    private func apply() {
        let step = creationVM.currentStep

        validationLabel.stringValue = creationVM.validationMessage ?? ""

        backButton.isHidden = step == .osSelection

        let isReview = step == .review
        nextButton.isHidden = isReview
        createButton.isHidden = !isReview
        nextButton.isEnabled = creationVM.canAdvance
        createButton.isEnabled = creationVM.canCreate

        // Only the visible primary button owns the Return key.
        nextButton.keyEquivalent = isReview ? "" : "\r"
        createButton.keyEquivalent = isReview ? "\r" : ""

        stepIndicator.currentStep = step

        if displayedStep != step {
            showStep(step)
            displayedStep = step
        }
    }

    /// Swaps the content area to the view controller for `step`.
    ///
    /// No animation — determinism over flourish, matching the SwiftUI
    /// predecessor (which had no step transition).
    private func showStep(_ step: VMCreationStep) {
        let newChild = makeStepViewController(for: step)
        addChild(newChild)
        newChild.view.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(newChild.view)
        // Small horizontal inset so a scrolling step's scroller sits close to
        // the window edge; the step insets its own content the rest of the way.
        // Vertical padding stays at the full content padding.
        let vPad = WizardStyle.contentPadding
        let hPad = WizardStyle.edgeInset
        NSLayoutConstraint.activate([
            newChild.view.topAnchor.constraint(
                equalTo: contentContainer.topAnchor, constant: vPad),
            newChild.view.leadingAnchor.constraint(
                equalTo: contentContainer.leadingAnchor, constant: hPad),
            newChild.view.trailingAnchor.constraint(
                equalTo: contentContainer.trailingAnchor, constant: -hPad),
            newChild.view.bottomAnchor.constraint(
                equalTo: contentContainer.bottomAnchor, constant: -vPad),
        ])

        if let old = currentChild {
            old.view.removeFromSuperview()
            old.removeFromParent()
        }
        currentChild = newChild
    }

    /// Builds the step view controller for `step`, reading `selectedOS` fresh
    /// so the OS-conditional boot slot picks the right VC each time it's mounted.
    private func makeStepViewController(for step: VMCreationStep) -> NSViewController {
        switch step {
        case .osSelection:
            return OSSelectionContentViewController(creationVM: creationVM)
        case .bootConfig:
            // OS-conditional: read `selectedOS` fresh each time the step is
            // entered so going Back and changing the OS rebuilds the right VC.
            if creationVM.selectedOS == .macOS {
                return IPSWSelectionContentViewController(creationVM: creationVM)
            }
            return BootConfigContentViewController(creationVM: creationVM)
        case .resources:
            return ResourceConfigContentViewController(creationVM: creationVM)
        case .review:
            return ReviewContentViewController(creationVM: creationVM)
        }
    }

    // MARK: - Actions

    @objc private func cancelTapped() {
        delegate?.wizardDidCancel(self)
    }

    @objc private func backTapped() {
        creationVM.goBack()
        // Apply synchronously for an immediate, flicker-free transition. The
        // observation loop is the backstop for model changes originating inside
        // a step (e.g. typing a name toggles `canAdvance`); `apply()` is
        // idempotent, so the later observation fire is a harmless no-op.
        apply()
    }

    @objc private func nextTapped() {
        creationVM.goNext()
        apply()
    }

    @objc private func createTapped() {
        // VM creation is async and takes seconds (bundle write + sparse disk
        // allocation). Disable navigation immediately so a second click can't
        // spawn a duplicate create and Cancel can't tear the sheet down mid-
        // creation; the host dismisses the sheet when createVM completes.
        createButton.isEnabled = false
        backButton.isEnabled = false
        cancelButton.isEnabled = false
        delegate?.wizardDidRequestCreate(self, creationVM: creationVM)
    }

    // MARK: - Failure recovery

    /// Re-enables navigation after a failed create and presents the error as a
    /// sheet on the wizard's own window so the user can read it and retry.
    ///
    /// The error is shown here rather than via the host's main-window alert
    /// because the wizard sheet is still attached to that window; a sheet-on-
    /// sheet (the alert atop the wizard) is well-defined, whereas two sheets on
    /// the same window would contend.
    func presentCreationFailure(message: String?) {
        cancelButton.isEnabled = true
        backButton.isEnabled = true
        // Restore Create/Next enabled state from the model.
        apply()

        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Couldn’t Create Virtual Machine"
        alert.informativeText = message ?? "An unknown error occurred while creating the virtual machine."
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window, completionHandler: nil)
    }
}
