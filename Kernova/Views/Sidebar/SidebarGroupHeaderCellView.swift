import AppKit

/// Group-row cell for a sidebar section header (e.g. "Virtual Machines").
///
/// `NSOutlineView` in `.sourceList` style draws the group-row background and
/// the hover disclosure control; this cell only supplies the title label,
/// styled to match the standard Finder-style source-list header. Assigning
/// the label to ``NSTableCellView/textField`` lets the row view treat it as
/// the cell's primary text.
@MainActor
final class SidebarGroupHeaderCellView: NSTableCellView {
    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)

        label.translatesAutoresizingMaskIntoConstraints = false
        label.isSelectable = false
        label.lineBreakMode = .byTruncatingTail
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        label.textColor = .secondaryLabelColor

        addSubview(label)
        textField = label

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SidebarGroupHeaderCellView does not support NSCoder")
    }

    func configure(title: String) {
        label.stringValue = title
    }
}
