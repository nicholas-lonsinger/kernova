import AppKit

/// Lays out a list row built on ``EditableRowTitleView`` inside `host`:
/// `icon`, then `title` over `subtitle`, then `trailing`, edge to edge.
///
/// The text column is the one view that stretches, and the title line's own
/// spacer takes what it gains, so the name and note keep their text's width
/// until the row runs out. `icon` and `trailing` keep their size.
@MainActor
func layOutEditableListRow(
    in host: NSView, icon: NSView, title: EditableRowTitleView, subtitle: NSTextField,
    trailing: [NSView]
) {
    host.translatesAutoresizingMaskIntoConstraints = false

    let textColumn = NSStackView(views: [title, subtitle])
    textColumn.orientation = .vertical
    textColumn.alignment = .leading
    textColumn.spacing = Spacing.hairline
    for view in [title, subtitle, textColumn] as [NSView] {
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }
    // Both lines span the column: the title line so its spacer can take the
    // slack, the subtitle so it truncates at the column's edge.
    NSLayoutConstraint.activate([
        title.leadingAnchor.constraint(equalTo: textColumn.leadingAnchor),
        title.trailingAnchor.constraint(equalTo: textColumn.trailingAnchor),
        subtitle.leadingAnchor.constraint(equalTo: textColumn.leadingAnchor),
        subtitle.trailingAnchor.constraint(equalTo: textColumn.trailingAnchor),
    ])

    for fixed in [icon] + trailing {
        fixed.setContentHuggingPriority(.required, for: .horizontal)
        fixed.setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    let row = NSStackView(views: [icon, textColumn] + trailing)
    row.orientation = .horizontal
    row.alignment = .centerY
    row.distribution = .fill
    row.spacing = Spacing.standard
    row.translatesAutoresizingMaskIntoConstraints = false
    host.addSubview(row)
    NSLayoutConstraint.activate([
        row.leadingAnchor.constraint(equalTo: host.leadingAnchor),
        row.trailingAnchor.constraint(equalTo: host.trailingAnchor),
        row.topAnchor.constraint(equalTo: host.topAnchor),
        row.bottomAnchor.constraint(equalTo: host.bottomAnchor),
    ])
}
