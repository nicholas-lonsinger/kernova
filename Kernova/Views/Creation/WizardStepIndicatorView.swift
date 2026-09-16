import AppKit

/// The dotted step-progress bar at the top of the creation wizard.
///
/// Renders one dot + title per step in ``steps`` with thin connectors between
/// them, highlighting the current step in the accent color. Purely a display of
/// ``steps`` and ``currentStep`` — it holds no model reference and reports no
/// events.
@MainActor
final class WizardStepIndicatorView: NSView {
    private struct StepViews {
        let dot: NSImageView
        let label: NSTextField
    }

    private let mainStack = NSStackView()
    private var stepViews: [VMCreationStep: StepViews] = [:]

    /// The steps to render, in order; setting it redraws the bar.
    ///
    /// The wizard's own list rather than every case, because a configuration
    /// that cannot use a step does not walk it — and a bar listing a step the
    /// user never reaches misstates how far along they are.
    var steps: [VMCreationStep] = VMCreationStep.allCases {
        didSet {
            guard oldValue != steps else { return }
            rebuild()
        }
    }

    /// The step to highlight; setting it restyles the dots and labels.
    var currentStep: VMCreationStep = .osSelection {
        didSet {
            guard oldValue != currentStep else { return }
            updateHighlight()
        }
    }

    private static let dotPointSize: CGFloat = 8
    private static let connectorWidth: CGFloat = 24

    init() {
        super.init(frame: .zero)
        mainStack.orientation = .horizontal
        mainStack.alignment = .centerY
        mainStack.spacing = Spacing.tight
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        addFullSizeSubview(mainStack)
        rebuild()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("WizardStepIndicatorView does not support NSCoder")
    }

    private func rebuild() {
        for view in mainStack.arrangedSubviews {
            mainStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        stepViews.removeAll()

        for (index, step) in steps.enumerated() {
            mainStack.addArrangedSubview(makeStepGroup(for: step))
            if index < steps.count - 1 {
                mainStack.addArrangedSubview(makeConnector())
            }
        }
        updateHighlight()
    }

    private func makeStepGroup(for step: VMCreationStep) -> NSView {
        let dot = NSImageView(image: .systemSymbol("circle.fill", accessibilityDescription: ""))
        dot.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: Self.dotPointSize, weight: .regular)
        dot.setContentHuggingPriority(.required, for: .horizontal)

        let label = NSTextField(labelWithString: step.title)
        label.font = .preferredFont(forTextStyle: .caption1)
        label.isSelectable = false

        stepViews[step] = StepViews(dot: dot, label: label)

        let group = NSStackView(views: [dot, label])
        group.orientation = .horizontal
        group.alignment = .centerY
        group.spacing = Spacing.tight
        return group
    }

    private func makeConnector() -> NSView {
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        line.widthAnchor.constraint(equalToConstant: Self.connectorWidth).isActive = true
        return line
    }

    private func updateHighlight() {
        for (step, views) in stepViews {
            let isCurrent = step == currentStep
            views.dot.contentTintColor = isCurrent ? .controlAccentColor : .tertiaryLabelColor
            views.label.textColor = isCurrent ? .labelColor : .secondaryLabelColor
        }
    }
}
