import AppKit

/// Centered state shown in the detail pane when it has no VM to show: none
/// selected, or a selected bundle Kernova can't read — a symbol, a title, an
/// optional line under it, and one push button.
@MainActor
final class DetailEmptyStateView: NSView {
    private let action: () -> Void
    private let titleLabel = NSTextField(labelWithString: "")

    init(
        symbolName: String, title: String, message: String?, buttonTitle: String,
        action: @escaping () -> Void
    ) {
        self.action = action
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        build(symbolName: symbolName, title: title, message: message, buttonTitle: buttonTitle)
    }

    /// No VM selected, offering a new one.
    static func noSelection(onNewVM: @escaping () -> Void) -> DetailEmptyStateView {
        DetailEmptyStateView(
            symbolName: "desktopcomputer", title: "No Virtual Machine Selected",
            message: "Select a virtual machine from the sidebar or create a new one.",
            buttonTitle: "New Virtual Machine", action: onNewVM)
    }

    /// A selected bundle Kernova can't read, offering the config check; its
    /// title is set per bundle through ``setTitle(_:)``.
    static func unreadable(onCheck: @escaping () -> Void) -> DetailEmptyStateView {
        DetailEmptyStateView(
            symbolName: "exclamationmark.triangle", title: "", message: nil,
            buttonTitle: "Check Config Files\u{2026}", action: onCheck)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("DetailEmptyStateView does not support NSCoder")
    }

    var title: String { titleLabel.stringValue }

    func setTitle(_ title: String) {
        titleLabel.stringValue = title
    }

    private func build(symbolName: String, title: String, message: String?, buttonTitle: String) {
        let icon = NSImageView(image: .systemSymbol(symbolName, accessibilityDescription: ""))
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 48, weight: .regular)
        icon.contentTintColor = .secondaryLabelColor

        titleLabel.stringValue = title
        titleLabel.font = .preferredFont(forTextStyle: .title2)
        titleLabel.alignment = .center
        titleLabel.isSelectable = false
        titleLabel.lineBreakMode = .byWordWrapping
        titleLabel.maximumNumberOfLines = 0

        var views: [NSView] = [icon, titleLabel]
        if let message {
            let description = NSTextField(wrappingLabelWithString: message)
            description.font = Typography.body
            description.textColor = .secondaryLabelColor
            description.alignment = .center
            description.isSelectable = false
            description.maximumNumberOfLines = 0
            views.append(description)
        }

        let button = NSButton(title: buttonTitle, target: self, action: #selector(buttonTapped))
        button.bezelStyle = .push

        let stack = NSStackView(views: views + [button])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = Spacing.standard
        if let last = views.last { stack.setCustomSpacing(16, after: last) }
        stack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
        ])
    }

    @objc private func buttonTapped() {
        action()
    }
}
