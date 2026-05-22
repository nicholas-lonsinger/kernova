import AppKit
import os

/// Window controller hosting the AppKit VM-creation wizard.
///
/// Presents as a sheet attached to the main window via
/// ``runSheet(on:)``. The wizard owns its own ``VMCreationViewModel`` and
/// drives the library view model only when the user clicks **Create** on
/// the final step.
@MainActor
final class VMCreationWizardWindowController: NSWindowController {
    private static let logger = Logger(subsystem: "com.kernova.app", category: "VMCreationWizardWindowController")

    private let library: VMLibraryViewModel
    private let creationVM = VMCreationViewModel()
    private var stepObservation: ObservationLoop?
    private var navigationObservation: ObservationLoop?

    // Step view controllers; lazily created when first navigated to so step
    // changes within the same session reuse the same instances.
    private var osStep: OSSelectionStepViewController?
    private var ipswStep: IPSWSelectionStepViewController?
    private var bootStep: BootConfigStepViewController?
    private var resourceStep: ResourceConfigStepViewController?
    private var reviewStep: ReviewStepViewController?

    // Chrome
    private let stepIndicator = NSStackView()
    private let contentContainer = NSView()
    private let validationLabel = NSTextField(labelWithString: "")
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let backButton = NSButton(title: "Back", target: nil, action: nil)
    private let primaryButton = NSButton(title: "Next", target: nil, action: nil)

    private var currentChild: NSViewController?
    private var continuation: CheckedContinuation<Void, Never>?

    init(library: VMLibraryViewModel) {
        self.library = library

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 550, height: 480),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = "New Virtual Machine"

        super.init(window: window)

        let rootVC = NSViewController()
        rootVC.view = buildRootView()
        window.contentViewController = rootVC

        wireButtons()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("VMCreationWizardWindowController does not support NSCoder")
    }

    /// Present the wizard as a sheet on `parent` and resume when the user
    /// either cancels or creates the VM.
    func runSheet(on parent: NSWindow) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            self.continuation = cont
            guard let window = self.window else {
                cont.resume()
                return
            }
            parent.beginSheet(window) { [weak self] _ in
                self?.continuation?.resume()
                self?.continuation = nil
            }
            self.stepDidChange()
            self.startObservation()
        }
    }

    // MARK: - View construction

    private func buildRootView() -> NSView {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false

        // Step indicator
        stepIndicator.orientation = .horizontal
        stepIndicator.spacing = 4
        stepIndicator.alignment = .centerY
        stepIndicator.translatesAutoresizingMaskIntoConstraints = false
        rebuildStepIndicator()

        let topPad = NSView()
        topPad.translatesAutoresizingMaskIntoConstraints = false

        let topRow = NSStackView(views: [stepIndicator])
        topRow.orientation = .horizontal
        topRow.alignment = .centerY
        topRow.distribution = .gravityAreas
        topRow.translatesAutoresizingMaskIntoConstraints = false
        topRow.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 12, right: 16)

        let topDivider = NSBox()
        topDivider.boxType = .separator
        topDivider.translatesAutoresizingMaskIntoConstraints = false

        contentContainer.translatesAutoresizingMaskIntoConstraints = false

        let bottomDivider = NSBox()
        bottomDivider.boxType = .separator
        bottomDivider.translatesAutoresizingMaskIntoConstraints = false

        validationLabel.font = .preferredFont(forTextStyle: .caption1)
        validationLabel.textColor = .secondaryLabelColor

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let buttonRow = NSStackView(views: [cancelButton, spacer, validationLabel, backButton, primaryButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.alignment = .centerY
        buttonRow.translatesAutoresizingMaskIntoConstraints = false
        buttonRow.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 16, right: 16)

        root.addSubview(topRow)
        root.addSubview(topDivider)
        root.addSubview(contentContainer)
        root.addSubview(bottomDivider)
        root.addSubview(buttonRow)

        NSLayoutConstraint.activate([
            topRow.topAnchor.constraint(equalTo: root.topAnchor),
            topRow.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            topRow.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            topDivider.topAnchor.constraint(equalTo: topRow.bottomAnchor),
            topDivider.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            topDivider.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            contentContainer.topAnchor.constraint(equalTo: topDivider.bottomAnchor, constant: 16),
            contentContainer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            contentContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            contentContainer.bottomAnchor.constraint(equalTo: bottomDivider.topAnchor, constant: -16),

            bottomDivider.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bottomDivider.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            buttonRow.topAnchor.constraint(equalTo: bottomDivider.bottomAnchor),
            buttonRow.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            buttonRow.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            buttonRow.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        return root
    }

    private func wireButtons() {
        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked(_:))
        cancelButton.keyEquivalent = "\u{1B}"

        backButton.target = self
        backButton.action = #selector(backClicked(_:))

        primaryButton.target = self
        primaryButton.action = #selector(primaryClicked(_:))
        primaryButton.keyEquivalent = "\r"
    }

    // MARK: - Step indicator

    private func rebuildStepIndicator() {
        for view in stepIndicator.arrangedSubviews {
            view.removeFromSuperview()
        }

        let steps = VMCreationStep.allCases
        for (index, step) in steps.enumerated() {
            let isCurrent = step == creationVM.currentStep

            let circle = NSView()
            circle.wantsLayer = true
            circle.layer?.cornerRadius = 4
            circle.layer?.backgroundColor =
                (isCurrent ? NSColor.controlAccentColor : NSColor.tertiaryLabelColor).cgColor
            circle.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                circle.widthAnchor.constraint(equalToConstant: 8),
                circle.heightAnchor.constraint(equalToConstant: 8),
            ])

            let label = NSTextField(labelWithString: step.title)
            label.font = .preferredFont(forTextStyle: .caption1)
            label.textColor = isCurrent ? .labelColor : .secondaryLabelColor

            let pair = NSStackView(views: [circle, label])
            pair.orientation = .horizontal
            pair.spacing = 4
            pair.alignment = .centerY

            stepIndicator.addArrangedSubview(pair)

            if index < steps.count - 1 {
                let separator = NSView()
                separator.wantsLayer = true
                separator.layer?.backgroundColor = NSColor.tertiaryLabelColor.cgColor
                separator.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([
                    separator.widthAnchor.constraint(equalToConstant: 24),
                    separator.heightAnchor.constraint(equalToConstant: 1),
                ])
                stepIndicator.addArrangedSubview(separator)
            }
        }
    }

    // MARK: - Observation

    private func startObservation() {
        stepObservation = observeRecurring(
            track: { [weak self] in
                guard let self else { return }
                _ = self.creationVM.currentStep
                _ = self.creationVM.selectedOS
            },
            apply: { [weak self] in self?.stepDidChange() }
        )

        navigationObservation = observeRecurring(
            track: { [weak self] in
                guard let self else { return }
                _ = self.creationVM.currentStep
                _ = self.creationVM.canAdvance
                _ = self.creationVM.canCreate
                _ = self.creationVM.validationMessage
            },
            apply: { [weak self] in self?.refreshNavigation() }
        )
        refreshNavigation()
    }

    // MARK: - Step swap

    private func stepDidChange() {
        rebuildStepIndicator()

        let child: CreationStepViewController = {
            switch creationVM.currentStep {
            case .osSelection:
                let step = osStep ?? OSSelectionStepViewController(creationVM: creationVM)
                osStep = step
                step.wizard = self
                return step
            case .bootConfig:
                switch creationVM.selectedOS {
                case .macOS:
                    let step = ipswStep ?? IPSWSelectionStepViewController(creationVM: creationVM)
                    ipswStep = step
                    step.wizard = self
                    return step
                case .linux:
                    let step = bootStep ?? BootConfigStepViewController(creationVM: creationVM)
                    bootStep = step
                    step.wizard = self
                    return step
                }
            case .resources:
                let step = resourceStep ?? ResourceConfigStepViewController(creationVM: creationVM)
                resourceStep = step
                step.wizard = self
                return step
            case .review:
                let step = reviewStep ?? ReviewStepViewController(creationVM: creationVM)
                reviewStep = step
                step.wizard = self
                return step
            }
        }()

        swapChild(to: child)
        child.stepDidAppear()
    }

    private func swapChild(to next: NSViewController) {
        if let current = currentChild {
            if current === next { return }
            current.view.removeFromSuperview()
            current.removeFromParent()
        }

        if window?.contentViewController?.children.contains(next) == false {
            window?.contentViewController?.addChild(next)
        }
        contentContainer.addFullSizeSubview(next.view)
        currentChild = next
    }

    // MARK: - Navigation refresh

    private func refreshNavigation() {
        backButton.isHidden = creationVM.currentStep == .osSelection
        validationLabel.stringValue = creationVM.validationMessage ?? ""
        if creationVM.currentStep == .review {
            primaryButton.title = "Create"
            primaryButton.isEnabled = creationVM.canCreate
        } else {
            primaryButton.title = "Next"
            primaryButton.isEnabled = creationVM.canAdvance
        }
    }

    // MARK: - Actions

    @objc private func cancelClicked(_ sender: Any?) {
        dismiss(returnCode: .cancel)
    }

    @objc private func backClicked(_ sender: Any?) {
        creationVM.goBack()
    }

    @objc private func primaryClicked(_ sender: Any?) {
        if creationVM.currentStep == .review {
            primaryButton.isEnabled = false
            cancelButton.isEnabled = false
            Task { [weak self] in
                guard let self else { return }
                await self.library.createVM(from: self.creationVM)
                self.dismiss(returnCode: .OK)
            }
        } else {
            creationVM.goNext()
        }
    }

    private func dismiss(returnCode: NSApplication.ModalResponse) {
        guard let window, let parent = window.sheetParent else { return }
        stepObservation?.cancel()
        navigationObservation?.cancel()
        // Reset the view model's bool so a re-trigger after dismiss works.
        library.showCreationWizard = false
        parent.endSheet(window, returnCode: returnCode)
    }
}
