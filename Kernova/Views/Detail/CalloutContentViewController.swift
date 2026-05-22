import AppKit

/// Shared container for `NSPopover` content rendered in callout style.
///
/// 340-pt-wide popover container with `.callout` body font and 16-pt
/// insets. Use directly as an ``NSPopover``'s `contentViewController`,
/// populated with one or more views via ``addArrangedContent(_:)``.
///
/// Sizing strategy: AppKit ``NSPopover`` honors `preferredContentSize` on
/// its content view controller. ``CalloutContentViewController`` measures its
/// arranged stack inside `viewDidLayout` and pins `preferredContentSize` to
/// the result so the popover never floats the content inside a too-large
/// frame.
@MainActor
final class CalloutContentViewController: NSViewController {
    nonisolated static let defaultWidth: CGFloat = 340
    nonisolated static let padding: CGFloat = 16
    nonisolated static let verticalSpacing: CGFloat = 10

    private let stack = NSStackView()
    private let contentWidth: CGFloat

    init(width: CGFloat = CalloutContentViewController.defaultWidth) {
        self.contentWidth = width
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("CalloutContentViewController does not support NSCoder")
    }

    override func loadView() {
        let container = NSView()

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Self.verticalSpacing
        stack.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(stack)
        let padding = Self.padding
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: padding),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: padding),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -padding),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -padding),
            container.widthAnchor.constraint(equalToConstant: contentWidth),
        ])

        view = container
    }

    /// Append a view to the callout body.
    ///
    /// Caller is responsible for setting
    /// `translatesAutoresizingMaskIntoConstraints = false` on `view` and any
    /// width-constrained subviews.
    func addArrangedContent(_ view: NSView) {
        stack.addArrangedSubview(view)
    }

    /// Append a headline label using the platform `.headline` text style.
    func addHeadline(_ text: String) {
        let label = NSTextField(labelWithString: text)
        label.font = .preferredFont(forTextStyle: .headline)
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.preferredMaxLayoutWidth = bodyWidth
        stack.addArrangedSubview(label)
    }

    /// Append a wrapping body label using the platform `.callout` text style.
    func addBody(_ text: String, color: NSColor = .secondaryLabelColor) {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .preferredFont(forTextStyle: .callout)
        label.textColor = color
        label.preferredMaxLayoutWidth = bodyWidth
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        stack.addArrangedSubview(label)
    }

    /// Width available to body content inside the padded callout (i.e.
    /// `contentWidth - 2 * padding`).
    var bodyWidth: CGFloat {
        contentWidth - Self.padding * 2
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // Recompute preferred size so the popover resizes to fit the
        // measured stack height under the configured width.
        let fittingSize = view.fittingSize
        if preferredContentSize != fittingSize {
            preferredContentSize = fittingSize
        }
    }
}
