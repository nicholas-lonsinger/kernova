import AppKit

/// Centered empty state shown in the detail pane when no VM is selected.
///
/// The AppKit replacement for the SwiftUI `ContentUnavailableView` in
/// `MainDetailView`: a large symbol, a title, a description, and a button that
/// opens the creation wizard.
@MainActor
final class DetailEmptyStateView: NSView {
    private let onNewVM: () -> Void

    init(onNewVM: @escaping () -> Void) {
        self.onNewVM = onNewVM
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("DetailEmptyStateView does not support NSCoder")
    }

    private func build() {
        let icon = NSImageView(
            image: .systemSymbol("desktopcomputer", accessibilityDescription: ""))
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 48, weight: .regular)
        icon.contentTintColor = .secondaryLabelColor

        let title = NSTextField(labelWithString: "No Virtual Machine Selected")
        title.font = .preferredFont(forTextStyle: .title2)
        title.alignment = .center
        title.isSelectable = false

        let description = NSTextField(
            wrappingLabelWithString: "Select a virtual machine from the sidebar or create a new one.")
        description.font = .preferredFont(forTextStyle: .body)
        description.textColor = .secondaryLabelColor
        description.alignment = .center
        description.isSelectable = false
        description.maximumNumberOfLines = 0

        let button = NSButton(title: "New Virtual Machine", target: self, action: #selector(newVMTapped))
        button.bezelStyle = .rounded

        let stack = NSStackView(views: [icon, title, description, button])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.setCustomSpacing(16, after: description)
        stack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
        ])
    }

    @objc private func newVMTapped() {
        onNewVM()
    }
}
