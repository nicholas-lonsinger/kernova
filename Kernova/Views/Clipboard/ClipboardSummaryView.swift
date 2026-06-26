import AppKit
import KernovaKit

/// Non-editable generic representation of clipboard content.
///
/// Used when the window can't (or shouldn't) render the content inline:
/// unknown formats, or text too large for the editor. Shows an icon, a
/// headline, and capped per-representation rows.
@MainActor
final class ClipboardSummaryView: NSView {
    private let iconView: NSImageView
    private let headlineLabel: NSTextField
    private let rowsStack: NSStackView

    init() {
        let iconView = NSImageView(
            image: .systemSymbol("doc.on.clipboard", accessibilityDescription: "Clipboard content")
        )
        iconView.symbolConfiguration = .init(pointSize: 36, weight: .regular)
        iconView.contentTintColor = .tertiaryLabelColor
        // See ClipboardImagePreviewView: keep this read-only view's image view
        // from intercepting drags so the whole area bubbles to the container.
        iconView.unregisterDraggedTypes()
        self.iconView = iconView

        let headline = NSTextField(labelWithString: "")
        headline.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        headline.textColor = .secondaryLabelColor
        headline.alignment = .center
        headline.lineBreakMode = .byTruncatingMiddle
        // Truncate rather than dictate window width through Auto Layout.
        headline.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        self.headlineLabel = headline

        let rowsStack = NSStackView()
        rowsStack.orientation = .vertical
        rowsStack.alignment = .centerX
        rowsStack.spacing = Spacing.tight
        self.rowsStack = rowsStack

        super.init(frame: .zero)
        wantsLayer = true

        let stack = NSStackView(views: [iconView, headline, rowsStack])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = Spacing.standard
        stack.setCustomSpacing(Spacing.medium, after: iconView)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(
                greaterThanOrEqualTo: leadingAnchor, constant: Spacing.large),
            stack.trailingAnchor.constraint(
                lessThanOrEqualTo: trailingAnchor, constant: -Spacing.large),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Matches the text editor's background — see `ClipboardImagePreviewView`.
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
    }

    func configure(content: ClipboardContent) {
        headlineLabel.stringValue = ClipboardContentDescriber.indicatorText(for: content)

        rowsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for row in ClipboardContentDescriber.summaryRows(for: content.representations) {
            let label = NSTextField(labelWithString: row)
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            label.textColor = .tertiaryLabelColor
            label.lineBreakMode = .byTruncatingMiddle
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            rowsStack.addArrangedSubview(label)
        }
    }
}
