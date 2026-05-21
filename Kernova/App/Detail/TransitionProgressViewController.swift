import AppKit

/// Centered spinner + label shown during VM lifecycle transitions where no
/// other surface fits (starting/stopping/pausing/resuming/installing without
/// progress yet).
///
/// Replaces `VMDetailView.transitionView`.
@MainActor
final class TransitionProgressViewController: NSViewController {
    private let instance: VMInstance
    private let spinner = NSProgressIndicator()
    private let label = NSTextField(labelWithString: "")
    private var observation: ObservationLoop?

    init(instance: VMInstance) {
        self.instance = instance
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("TransitionProgressViewController does not support NSCoder")
    }

    override func loadView() {
        let container = NSView()

        spinner.style = .spinning
        spinner.controlSize = .large
        spinner.isIndeterminate = true
        spinner.startAnimation(nil)

        label.font = .preferredFont(forTextStyle: .headline)
        label.textColor = .secondaryLabelColor
        label.alignment = .center

        let stack = NSStackView(views: [spinner, label])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])

        view = container

        observation = observeRecurring(
            track: { [weak self] in _ = self?.instance.status },
            apply: { [weak self] in self?.refresh() }
        )
        refresh()
    }

    private func refresh() {
        label.stringValue = instance.status.displayName
    }
}
