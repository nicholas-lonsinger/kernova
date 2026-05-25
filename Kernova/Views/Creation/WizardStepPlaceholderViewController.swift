import AppKit

/// Temporary stand-in for a wizard step whose AppKit conversion has not landed yet.
///
/// Shows a centered "coming soon" label so the shell (step indicator,
/// navigation, transitions) stays fully navigable and visually inspectable
/// while steps are converted one at a time.
///
/// Each instance is deleted when its real step VC ships — it must not outlive
/// the conversion.
@MainActor
final class WizardStepPlaceholderViewController: NSViewController {
    private let stepTitle: String

    init(stepTitle: String) {
        self.stepTitle = stepTitle
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("WizardStepPlaceholderViewController does not support NSCoder")
    }

    override func loadView() {
        let container = NSView()

        let label = NSTextField(labelWithString: "\(stepTitle) — coming soon")
        label.font = .preferredFont(forTextStyle: .title3)
        label.textColor = .tertiaryLabelColor
        label.isSelectable = false
        label.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])

        view = container
    }
}
