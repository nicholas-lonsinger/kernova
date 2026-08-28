import AppKit

/// The pinned header shown while a settings category is open — one row: the way
/// back, the panel title, and a compact status line at the trailing edge.
///
/// The VM's name is in the window title, so the header states only what the
/// title bar does not carry, which is the VM's status.
///
/// A single-section category folds that section's own header into this one, so
/// the category name is stated once — the info affordance and any readout it
/// carries are handed over as accessories.
@MainActor
final class VMSettingsPanelHeaderView: NSView {
    private let backButton = NSButton()
    private let statusDot = NSImageView()
    private let factsLabel = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(labelWithString: "")
    private let row = NSStackView()
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

    /// Routes the back button to the host that owns the way out of a panel.
    func setBackAction(target: AnyObject?, action: Selector) {
        backButton.target = target
        backButton.action = action
    }

    /// Paints the header for `title`, hosting `leadingAccessories` beside the
    /// title and `trailingAccessories` ahead of the status cluster.
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
        // Ahead of the status cluster, which stays pinned to the trailing edge.
        var index = row.arrangedSubviews.firstIndex(of: statusDot) ?? row.arrangedSubviews.count
        for view in wanted {
            row.insertArrangedSubview(view, at: index)
            index += 1
        }
    }

    private func buildLayout() {
        translatesAutoresizingMaskIntoConstraints = false

        backButton.image = .systemSymbol("chevron.left", accessibilityDescription: "")
        backButton.imagePosition = .imageOnly
        backButton.isBordered = true
        backButton.bezelStyle = .toolbar
        backButton.controlSize = .small
        backButton.toolTip = "Show all settings"
        backButton.setAccessibilityLabel("Back")
        backButton.setContentHuggingPriority(.required, for: .horizontal)
        backButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        titleLabel.font = Typography.title
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.isSelectable = false
        titleLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        statusDot.image = .systemSymbol("circle.fill", accessibilityDescription: "")
        statusDot.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 8, weight: .regular)
        statusDot.setContentHuggingPriority(.required, for: .horizontal)

        factsLabel.font = .preferredFont(forTextStyle: .caption1)
        factsLabel.textColor = .secondaryLabelColor
        factsLabel.lineBreakMode = .byTruncatingTail
        factsLabel.maximumNumberOfLines = 1
        factsLabel.isSelectable = false
        factsLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        // The title wins the row: on a narrow pane the facts give their width up
        // first and truncate, rather than squeezing the category name.
        factsLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        trailingSpacer.translatesAutoresizingMaskIntoConstraints = false
        trailingSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Spacing.small
        row.addArrangedSubview(backButton)
        row.addArrangedSubview(titleLabel)
        row.addArrangedSubview(statusDot)
        row.addArrangedSubview(factsLabel)
        row.setCustomSpacing(Spacing.standard, after: backButton)
        addFullSizeSubview(row)
    }
}
