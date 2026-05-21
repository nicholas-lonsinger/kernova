import AppKit

/// "No virtual machine selected" placeholder shown when the sidebar has no
/// active selection.
///
/// Replaces SwiftUI `ContentUnavailableView` previously used in
/// `MainDetailView`.
@MainActor
final class EmptyStateViewController: NSViewController {
    private let viewModel: VMLibraryViewModel

    init(viewModel: VMLibraryViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("EmptyStateViewController does not support NSCoder")
    }

    override func loadView() {
        let container = NSView()

        let icon = NSImageView(image: .systemSymbol("desktopcomputer", accessibilityDescription: ""))
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 56, weight: .regular)
        icon.contentTintColor = .tertiaryLabelColor

        let title = NSTextField(labelWithString: "No Virtual Machine Selected")
        title.font = .preferredFont(forTextStyle: .title2)
        title.alignment = .center

        let subtitle = NSTextField(
            wrappingLabelWithString:
                "Select a virtual machine from the sidebar or create a new one."
        )
        subtitle.font = .preferredFont(forTextStyle: .body)
        subtitle.textColor = .secondaryLabelColor
        subtitle.alignment = .center

        let cta = NSButton(title: "New Virtual Machine", target: self, action: #selector(createNew(_:)))
        cta.bezelStyle = .rounded
        cta.controlSize = .large

        let stack = NSStackView(views: [icon, title, subtitle, cta])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
        ])

        view = container
    }

    @objc private func createNew(_ sender: Any?) {
        viewModel.showCreationWizard = true
    }
}
