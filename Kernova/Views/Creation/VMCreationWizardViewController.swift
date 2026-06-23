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
    /// Floating "more below" chevron, layered over the active step's scroll view
    /// and faded in whenever the scroll gate is unsatisfied.
    ///
    /// Hit-transparent, so it never blocks the scrolling it prompts. Shell-owned
    /// (one instance reused across steps) and kept above the mounted step view by
    /// ``showStep(_:)``.
    private let scrollIndicator = makeWizardScrollIndicator()
    /// Soft gradient at the bottom of the scroll area that fades content into the
    /// sheet background — a second "more below" cue, faded in/out with the chevron.
    private let scrollFade = WizardScrollFadeView()
    private let validationLabel = NSTextField(labelWithString: "")
    private let cancelButton = NSButton()
    private let backButton = NSButton()
    private let nextButton = NSButton()
    private let createButton = NSButton()

    // MARK: - Transition state

    private var currentChild: NSViewController?
    private var displayedStep: VMCreationStep?
    private var observation: ObservationLoop?
    /// Whether the scroller has already been flashed for the displayed step, so the
    /// "there's more below" flash fires once when an overflowing step appears.
    private var didFlashScrollersForStep = false

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
        let container = WizardRootView()

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

        // Overlay the "more below" affordances over the bottom of the content area.
        // Both start hidden; `apply()` fades them in when the active step overflows
        // and isn't yet at the bottom. The fade strip is added first so the chevron
        // layers above it. Both are pinned just inside the step's content padding
        // (the scroll viewport's bottom edge).
        scrollFade.translatesAutoresizingMaskIntoConstraints = false
        scrollFade.alphaValue = 0
        contentContainer.addSubview(scrollFade)

        scrollIndicator.translatesAutoresizingMaskIntoConstraints = false
        scrollIndicator.alphaValue = 0
        contentContainer.addSubview(scrollIndicator)

        NSLayoutConstraint.activate([
            scrollFade.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            scrollFade.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            scrollFade.bottomAnchor.constraint(
                equalTo: contentContainer.bottomAnchor, constant: -WizardStyle.contentPadding),
            scrollFade.heightAnchor.constraint(equalToConstant: wizardScrollFadeHeight),

            scrollIndicator.centerXAnchor.constraint(equalTo: contentContainer.centerXAnchor),
            scrollIndicator.bottomAnchor.constraint(
                equalTo: contentContainer.bottomAnchor,
                constant: -(WizardStyle.contentPadding + Spacing.small)),
        ])

        container.onScrollKey = { [weak self] key in
            self?.handleScrollKey(key)
        }

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
                    _ = self.creationVM.currentStepScrollGateSatisfied
                },
                apply: { [weak self] in
                    self?.apply()
                }
            )
        }
        // Focus the root view so keyboard scroll keys (Page Up/Down, Home/End,
        // arrows) reach the active step's scroll view via the forwarding overrides
        // below — the non-pointer way to satisfy the scroll gate. The initial step
        // mounted in `viewDidLoad` before the window existed, so claim focus now.
        view.window?.makeFirstResponder(view)
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
        row.spacing = Spacing.standard
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

        // Transition first: `showStep` forces a synchronous layout, so an
        // overflowing step has already engaged its scroll gate (writing the model
        // back through the gate observer) before we read it for the button state
        // below. That closes the window where a fast Return could advance a step
        // whose content hasn't been seen.
        if displayedStep != step {
            showStep(step)
            displayedStep = step
        }

        // The forward-navigation gate: per-step domain validation AND, on a step
        // that overflows, having scrolled to the bottom. A disabled primary button
        // ignores its Return key-equivalent, so the keyboard path is gated too.
        let scrollGate = creationVM.currentStepScrollGateSatisfied

        validationLabel.stringValue = creationVM.validationMessage ?? ""

        backButton.isHidden = step == .osSelection

        let isReview = step == .review
        nextButton.isHidden = isReview
        createButton.isHidden = !isReview
        nextButton.isEnabled = creationVM.canAdvance && scrollGate
        createButton.isEnabled = creationVM.canCreate && scrollGate

        // Only the visible primary button owns the Return key.
        nextButton.keyEquivalent = isReview ? "" : "\r"
        createButton.keyEquivalent = isReview ? "\r" : ""

        stepIndicator.currentStep = step

        let moreBelow = !scrollGate
        setMoreBelowAffordanceVisible(moreBelow)
        // Flash the scroller once when an overflowing step first appears — the
        // native "there's more below" hint, matching the delete sheet. Deferred to
        // the next runloop because `flashScrollers()` is a no-op before the step's
        // scroll view has drawn; capture the view now so a fast navigation flashes
        // the step that was actually overflowing.
        if moreBelow, !didFlashScrollersForStep {
            didFlashScrollersForStep = true
            let scrollView = activeStepScrollView
            DispatchQueue.main.async { scrollView?.flashScrollers() }
        }
    }

    /// Fades the "more below" affordances — the chevron and the bottom gradient — in
    /// or out together, mirroring the app's standard `NSAnimationContext` alpha fade.
    ///
    /// Animating to the current value is a no-op, so a satisfied step never flashes
    /// the affordances.
    private func setMoreBelowAffordanceVisible(_ visible: Bool) {
        let target: CGFloat = visible ? 1 : 0
        guard scrollIndicator.alphaValue != target else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            scrollIndicator.animator().alphaValue = target
            scrollFade.animator().alphaValue = target
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
        // The step view spans the full content width so a scrolling step's
        // scroller sits flush with the sheet edge (matching the settings pane);
        // the step insets its own content via `contentSideInset`. Vertical
        // padding stays at the full content padding.
        let vPad = WizardStyle.contentPadding
        NSLayoutConstraint.activate([
            newChild.view.topAnchor.constraint(
                equalTo: contentContainer.topAnchor, constant: vPad),
            newChild.view.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            newChild.view.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            newChild.view.bottomAnchor.constraint(
                equalTo: contentContainer.bottomAnchor, constant: -vPad),
        ])

        if let old = currentChild {
            old.view.removeFromSuperview()
            old.removeFromParent()
        }
        currentChild = newChild

        // A fresh step hasn't been flashed yet.
        didFlashScrollersForStep = false

        // Keep the "more below" affordances above the freshly added step view, with
        // the chevron above the fade strip.
        contentContainer.addSubview(scrollFade, positioned: .above, relativeTo: newChild.view)
        contentContainer.addSubview(scrollIndicator, positioned: .above, relativeTo: scrollFade)

        // Once on screen, force a synchronous layout pass so a scrolling step
        // measures its geometry and engages its scroll gate now, not a runloop
        // later — `apply()` reads the gate immediately after this returns. Guarded
        // on `window` so a not-yet-presented mount (and windowless tests) keeps the
        // optimistic default gate; the gate then settles on the first real layout.
        if view.window != nil {
            contentContainer.layoutSubtreeIfNeeded()
            // Reclaim focus onto the root view so the new step starts keyboard-
            // scrollable (the step's own controls take focus on click/Tab).
            // Reclaim focus onto the root view so the new step starts keyboard-
            // scrollable (the step's own controls take focus on click/Tab).
            view.window?.makeFirstResponder(view)
        }
    }

    // MARK: - Keyboard scrolling

    /// The active step's scroll view, when the step scrolls (its root view *is* the
    /// scroll view). `nil` for the non-scrolling OS step.
    private var activeStepScrollView: NSScrollView? {
        currentChild?.view as? NSScrollView
    }

    /// Scrolls the active step's scroll view in response to a keyboard scroll key
    /// forwarded by ``WizardRootView``.
    ///
    /// The root holds first responder so these keys land here — the non-pointer way
    /// to satisfy the scroll-to-bottom gate. Drives the clip-view origin directly
    /// (NSScrollView doesn't honor the `scrollPage…` responder actions when no
    /// document control is first responder), which also fires the bounds-changed
    /// notification the gate observes. No-op on the non-scrolling OS step.
    fileprivate func handleScrollKey(_ key: WizardScrollKey) {
        guard let scrollView = activeStepScrollView else { return }
        let clip = scrollView.contentView
        let viewport = clip.bounds.height
        let line: CGFloat = 24
        // Overlap a line of context between pages, matching standard page scrolling.
        let page = max(line, viewport - line)
        let maxOffset = max(0, (scrollView.documentView?.frame.height ?? 0) - viewport)

        var y = clip.bounds.origin.y
        switch key {
        case .pageDown: y += page
        case .pageUp: y -= page
        case .lineDown: y += line
        case .lineUp: y -= line
        case .top: y = 0
        case .bottom: y = maxOffset
        }
        y = min(max(0, y), maxOffset)

        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
        scrollView.reflectScrolledClipView(clip)
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
        commitPendingEdits()
        creationVM.goBack()
        // Apply synchronously for an immediate, flicker-free transition. The
        // observation loop is the backstop for model changes originating inside
        // a step (e.g. typing a name toggles `canAdvance`); `apply()` is
        // idempotent, so the later observation fire is a harmless no-op.
        apply()
    }

    @objc private func nextTapped() {
        commitPendingEdits()
        creationVM.goNext()
        apply()
    }

    @objc private func createTapped() {
        commitPendingEdits()
        // VM creation is async and takes seconds (bundle write + sparse disk
        // allocation). Disable navigation immediately so a second click can't
        // spawn a duplicate create and Cancel can't tear the sheet down mid-
        // creation; the host dismisses the sheet when createVM completes.
        createButton.isEnabled = false
        backButton.isEnabled = false
        cancelButton.isEnabled = false
        delegate?.wizardDidRequestCreate(self, creationVM: creationVM)
    }

    /// Forces the active text field (if any) to end editing so its value is
    /// committed to the model before we navigate.
    ///
    /// Step fields like CPU/Memory commit on `controlTextDidEndEditing`. Clicking
    /// a button resigns first responder and triggers that, but pressing Return
    /// (the Next/Create key equivalent) can fire the button action without first
    /// ending the field's edit; resigning first responder here closes that gap.
    private func commitPendingEdits() {
        view.window?.makeFirstResponder(nil)
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

/// A keyboard scroll key the wizard root forwards to the active step's scroll view.
enum WizardScrollKey {
    case pageDown, pageUp, top, bottom, lineDown, lineUp

    /// Classifies a `keyDown` event, or `nil` if it isn't a scroll key.
    init?(event: NSEvent) {
        guard let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first else { return nil }
        switch Int(scalar.value) {
        case NSPageDownFunctionKey, 0x20: self = .pageDown  // Page Down or Space
        case NSPageUpFunctionKey: self = .pageUp
        case NSHomeFunctionKey: self = .top
        case NSEndFunctionKey: self = .bottom
        case NSDownArrowFunctionKey: self = .lineDown
        case NSUpArrowFunctionKey: self = .lineUp
        default: return nil
        }
    }
}

/// Root container for the wizard shell that can hold first responder and turn
/// keyboard scroll keys into ``WizardScrollKey`` callbacks.
///
/// A plain `NSView` refuses first responder, so with no focused control the window
/// has nowhere to route keyboard scroll keys — and a plain view's `keyDown` doesn't
/// translate Page Down into the `scrollPage…` responder actions either. Accepting
/// first responder and classifying `keyDown` here lets the shell drive the active
/// step's scroll view, the keyboard path for satisfying the scroll-to-bottom gate.
private final class WizardRootView: NSView {
    var onScrollKey: ((WizardScrollKey) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if let key = WizardScrollKey(event: event) {
            onScrollKey?(key)
        } else {
            super.keyDown(with: event)
        }
    }
}
