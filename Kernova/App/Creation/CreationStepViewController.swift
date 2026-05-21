import AppKit

/// Base class for VM-creation wizard step view controllers.
///
/// All steps share the same parent view controller (``VMCreationWizardWindowController``)
/// and the same view model (``VMCreationViewModel``). Concrete subclasses
/// override ``loadView()`` to build their step's layout and may override
/// ``stepDidAppear()`` to refresh state when the step becomes visible
/// (e.g. recompute defaults from a previous step's choice).
@MainActor
class CreationStepViewController: NSViewController {
    let creationVM: VMCreationViewModel
    weak var wizard: VMCreationWizardWindowController?

    init(creationVM: VMCreationViewModel) {
        self.creationVM = creationVM
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("CreationStepViewController does not support NSCoder")
    }

    /// Called by the wizard when this step becomes the visible step.
    ///
    /// Subclasses can override to refresh derived state or take focus.
    func stepDidAppear() {}

    /// Convenience for building a centered title + subtitle header used by
    /// every step.
    func makeStepHeader(title: String, subtitle: String) -> NSStackView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .preferredFont(forTextStyle: .title2)
        titleLabel.alignment = .center

        let subtitleLabel = NSTextField(wrappingLabelWithString: subtitle)
        subtitleLabel.font = .preferredFont(forTextStyle: .body)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.alignment = .center
        subtitleLabel.maximumNumberOfLines = 0

        let stack = NSStackView(views: [titleLabel, subtitleLabel])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 6
        return stack
    }
}
