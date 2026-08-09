import AppKit

/// Shared design tokens for callout-style popovers.
enum CalloutStyle {
    /// Standard popover content width.
    static let width: CGFloat = 340

    /// Inset from popover edges to the content stack.
    static let padding: CGFloat = 16

    /// Vertical spacing between rows in the content stack.
    static let verticalSpacing: CGFloat = 10

    /// Width available to body content inside the padded callout (`width - 2 * padding`).
    ///
    /// Use for `preferredMaxLayoutWidth` on wrapping labels so they grow
    /// vertically instead of horizontally.
    static let bodyWidth: CGFloat = width - padding * 2

    /// Font for headline rows (e.g. the bold title at the top of a callout).
    static var headlineFont: NSFont { .preferredFont(forTextStyle: .headline) }

    /// Font for body rows.
    static var bodyFont: NSFont { .preferredFont(forTextStyle: .callout) }

    /// Default body-row text color.
    ///
    /// Use `.labelColor` for the lead body row, `.secondaryLabelColor`
    /// (this default) for explanatory tail rows.
    static let bodyColor: NSColor = .secondaryLabelColor
}

/// Builds a headline `NSTextField` configured for a callout's leading row.
@MainActor
func makeCalloutHeadline(_ text: String) -> NSTextField {
    let label = NSTextField(labelWithString: text)
    label.font = CalloutStyle.headlineFont
    label.lineBreakMode = .byWordWrapping
    label.maximumNumberOfLines = 0
    label.preferredMaxLayoutWidth = CalloutStyle.bodyWidth
    label.isSelectable = false
    return label
}

/// Builds a wrapping body `NSTextField` configured for a callout row.
@MainActor
func makeCalloutBody(_ text: String, color: NSColor = CalloutStyle.bodyColor) -> NSTextField {
    let label = NSTextField(wrappingLabelWithString: text)
    label.font = CalloutStyle.bodyFont
    label.textColor = color
    label.preferredMaxLayoutWidth = CalloutStyle.bodyWidth
    label.lineBreakMode = .byWordWrapping
    label.maximumNumberOfLines = 0
    // `NSTextField(wrappingLabelWithString:)` returns a label that is selectable
    // by default — surprising for prose-style body text.
    label.isSelectable = false
    return label
}

extension NSViewController {
    /// Installs `rows` as this controller's view: a padded vertical stack inside
    /// a container fixed to the callout width.
    ///
    /// Pair with ``syncCalloutContentSize()`` so the hosting popover tracks the
    /// height the rows measure at that width.
    func installCalloutStack(rows: [NSView]) {
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = CalloutStyle.verticalSpacing
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(stack)
        let padding = CalloutStyle.padding
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: padding),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: padding),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -padding),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -padding),
            container.widthAnchor.constraint(equalToConstant: CalloutStyle.width),
        ])
        view = container
    }

    /// Re-pins the content size so `NSPopover` resizes its frame to the measured
    /// stack height under the configured width.
    ///
    /// Call from `viewDidLayout`.
    func syncCalloutContentSize() {
        let fittingSize = view.fittingSize
        guard preferredContentSize != fittingSize else { return }
        preferredContentSize = fittingSize
    }
}

/// Builds a monospaced, selectable `NSTextField` for code snippets (shell
/// commands, paths, identifiers the user is expected to copy).
@MainActor
func makeCalloutCode(_ text: String) -> NSTextField {
    let label = NSTextField(wrappingLabelWithString: text)
    label.font = .monospacedSystemFont(
        ofSize: NSFont.preferredFont(forTextStyle: .callout).pointSize,
        weight: .regular
    )
    label.textColor = .labelColor
    label.preferredMaxLayoutWidth = CalloutStyle.bodyWidth
    label.lineBreakMode = .byCharWrapping
    label.maximumNumberOfLines = 0
    label.isSelectable = true
    return label
}
