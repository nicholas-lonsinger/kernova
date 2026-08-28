import AppKit

/// The pinned header shown while a settings category is open: a back
/// affordance carrying the VM name, a compact status line, and the panel title.
///
/// A single-section category folds that section's own header into this one, so
/// the category name is stated once — the info affordance and any readout it
/// carries are handed over as accessories.
@MainActor
final class VMSettingsPanelHeaderView: NSView {
    /// Fires when the back affordance is activated.
    var onBack: (() -> Void)?

    private let backButton = NSButton()
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
        vmName: String, statusColor: NSColor, statusText: String, facts: String, title: String,
        leadingAccessories: [NSView] = [], trailingAccessories: [NSView] = []
    ) {
        backButton.title = vmName
        backButton.toolTip = "Back to \(vmName)"
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

        backButton.image = .systemSymbol("chevron.left", accessibilityDescription: "")
        backButton.imagePosition = .imageLeading
        backButton.isBordered = false
        backButton.bezelStyle = .badge
        backButton.font = Typography.body
        backButton.contentTintColor = .controlAccentColor
        backButton.target = self
        backButton.action = #selector(backTapped)
        backButton.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        backButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        statusDot.image = .systemSymbol("circle.fill", accessibilityDescription: "")
        statusDot.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 8, weight: .regular)
        statusDot.setContentHuggingPriority(.required, for: .horizontal)

        factsLabel.font = .preferredFont(forTextStyle: .caption1)
        factsLabel.textColor = .secondaryLabelColor
        factsLabel.lineBreakMode = .byTruncatingTail
        factsLabel.maximumNumberOfLines = 1
        factsLabel.isSelectable = false
        factsLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let navSpacer = NSView()
        navSpacer.translatesAutoresizingMaskIntoConstraints = false
        navSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let navRow = NSStackView(views: [backButton, navSpacer, statusDot, factsLabel])
        navRow.orientation = .horizontal
        navRow.alignment = .centerY
        navRow.spacing = Spacing.small

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

        let column = NSStackView(views: [navRow, titleRow])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = Spacing.small
        column.translatesAutoresizingMaskIntoConstraints = false
        addFullSizeSubview(column)
        for row in [navRow, titleRow] {
            row.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        }
    }

    @objc private func backTapped() {
        onBack?()
    }
}
