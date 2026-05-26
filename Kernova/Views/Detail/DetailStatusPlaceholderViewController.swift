import AppKit

/// Centered spinner + status label shown in the detail pane during transient
/// states (starting, suspending, restoring, …) and while a clone/import is
/// preparing.
///
/// The AppKit replacement for the former SwiftUI `transitionView` /
/// `preparingState` progress placeholders in `VMDetailView`.
@MainActor
final class DetailStatusPlaceholderViewController: NSViewController {
    private let spinner = NSProgressIndicator()
    private let label = NSTextField(labelWithString: "")

    override func loadView() {
        spinner.style = .spinning
        spinner.controlSize = .large
        spinner.isIndeterminate = true
        spinner.translatesAutoresizingMaskIntoConstraints = false

        label.font = .preferredFont(forTextStyle: .headline)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.isSelectable = false

        let stack = NSStackView(views: [spinner, label])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        view = container
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        spinner.startAnimation(nil)
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        spinner.stopAnimation(nil)
    }

    /// Sets the status text shown beneath the spinner.
    func configure(label text: String) {
        label.stringValue = text
    }
}
