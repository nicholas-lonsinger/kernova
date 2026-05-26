import AppKit

/// The dotted step-progress bar at the top of the creation wizard.
///
/// Renders one dot + title per ``VMCreationStep`` with thin connectors between
/// them, highlighting the current step in the accent color. Purely a display of
/// ``currentStep`` — it holds no model reference and reports no events.
///
/// The dots are `NSImageView`s (filled-circle SF Symbols tinted via
/// `contentTintColor`) and the connectors are `NSBox` separators, so all colors
/// adapt to light/dark automatically — no `viewDidChangeEffectiveAppearance`
/// override or manual `CGColor` resolution.
@MainActor
final class WizardStepIndicatorView: NSView {
    private struct StepViews {
        let dot: NSImageView
        let label: NSTextField
    }

    private var stepViews: [VMCreationStep: StepViews] = [:]

    /// The step to highlight.
    ///
    /// Setting it restyles the dots and labels.
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
        build()
        updateHighlight()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("WizardStepIndicatorView does not support NSCoder")
    }

    private func build() {
        let mainStack = NSStackView()
        mainStack.orientation = .horizontal
        mainStack.alignment = .centerY
        mainStack.spacing = 4
        mainStack.translatesAutoresizingMaskIntoConstraints = false

        let steps = VMCreationStep.allCases
        for (index, step) in steps.enumerated() {
            mainStack.addArrangedSubview(makeStepGroup(for: step))
            if index < steps.count - 1 {
                mainStack.addArrangedSubview(makeConnector())
            }
        }

        addFullSizeSubview(mainStack)
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
        group.spacing = 4
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
