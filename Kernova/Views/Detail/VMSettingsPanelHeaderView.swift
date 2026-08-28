import AppKit

/// The pinned header shown while a settings category is open: the panel title
/// and a compact status line.
///
/// The way back is the window toolbar's back button, and the VM's name is in the
/// window title, so the header states neither — only what the title bar does not
/// carry, which is the VM's status.
///
/// A single-section category folds that section's own header into this one, so
/// the category name is stated once — the info affordance and any readout it
/// carries are handed over as accessories.
@MainActor
final class VMSettingsPanelHeaderView: NSView {
    private let statusDot = NSImageView()
    private let factsLabel = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(labelWithString: "")
    private let titleRow = NSStackView()
    private let trailingSpacer = NSView()
    /// Views handed over by the open panel, removed when another one opens.
    private var accessories: [NSView] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buildLayout()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("VMSettingsPanelHeaderView does not support NSCoder")
    }

    /// Paints the header for `title`, hosting `leadingAccessories` beside the
    /// title and `trailingAccessories` at the row's far edge.
    func configure(
        statusColor: NSColor, statusText: String, facts: String, title: String,
        leadingAccessories: [NSView] = [], trailingAccessories: [NSView] = []
    ) {
        statusDot.contentTintColor = statusColor
        statusDot.setAccessibilityLabel(statusText)
        factsLabel.stringValue = facts
        titleLabel.stringValue = title

        let wanted = leadingAccessories + [trailingSpacer] + trailingAccessories
        guard wanted.map(ObjectIdentifier.init) != accessories.map(ObjectIdentifier.init) else {
            return
        }
        accessories.forEach { $0.removeFromSuperview() }
        accessories = wanted
        wanted.forEach { titleRow.addArrangedSubview($0) }
    }

    private func buildLayout() {
        translatesAutoresizingMaskIntoConstraints = false

        statusDot.image = .systemSymbol("circle.fill", accessibilityDescription: "")
        statusDot.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 8, weight: .regular)
        statusDot.setContentHuggingPriority(.required, for: .horizontal)

        factsLabel.font = .preferredFont(forTextStyle: .caption1)
        factsLabel.textColor = .secondaryLabelColor
        factsLabel.lineBreakMode = .byTruncatingTail
        factsLabel.maximumNumberOfLines = 1
        factsLabel.isSelectable = false
        factsLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let statusSpacer = NSView()
        statusSpacer.translatesAutoresizingMaskIntoConstraints = false
        statusSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let statusRow = NSStackView(views: [statusDot, factsLabel, statusSpacer])
        statusRow.orientation = .horizontal
        statusRow.alignment = .centerY
        statusRow.spacing = Spacing.small

        titleLabel.font = Typography.title
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.isSelectable = false

        trailingSpacer.translatesAutoresizingMaskIntoConstraints = false
        trailingSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = Spacing.small
        titleRow.addArrangedSubview(titleLabel)

        let column = NSStackView(views: [statusRow, titleRow])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = Spacing.small
        column.translatesAutoresizingMaskIntoConstraints = false
        addFullSizeSubview(column)
        for row in [statusRow, titleRow] {
            row.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        }
    }
}
