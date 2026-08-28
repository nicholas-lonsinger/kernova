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
    private let back = SettingsBackButtonView()
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
        back.button.target = target
        back.button.action = action
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

        back.button.toolTip = "Show all settings"
        back.button.setAccessibilityLabel("Back")

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
        row.addArrangedSubview(back)
        row.addArrangedSubview(titleLabel)
        row.addArrangedSubview(statusDot)
        row.addArrangedSubview(factsLabel)
        row.setCustomSpacing(Spacing.standard, after: back)
        addFullSizeSubview(row)
    }
}

/// The header's way back: a `chevron.left` in an always-visible rounded well.
///
/// The well's metrics are the wrapper's, the ``InfoButtonView`` pattern: it is
/// the wrapper that occupies the header row at exactly the approved size.
///
/// The button is centered on it rather than pinned to its edges, because AppKit
/// holds an `NSButton` to a minimum height of its own — one that outranks edge
/// pins, explicit size constraints and an `intrinsicContentSize` override alike.
/// Letting the button keep that height and drawing the well at ``wellSize``
/// leaves the well exact; only the hit area is a few points taller.
@MainActor
private final class SettingsBackButtonView: NSView {
    /// The approved well metrics, shared with the fill the button draws.
    static let wellSize = NSSize(width: 28, height: 24)

    let button = SettingsBackButton()

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        button.translatesAutoresizingMaskIntoConstraints = false
        addSubview(button)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.wellSize.width),
            heightAnchor.constraint(equalToConstant: Self.wellSize.height),
            button.centerXAnchor.constraint(equalTo: centerXAnchor),
            button.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SettingsBackButtonView does not support NSCoder")
    }
}

/// Draws the well behind the chevron.
///
/// No stock `NSBezelStyle` draws a persistent bezel at this size — `.toolbar`,
/// the closest, draws its bezel only under the pointer — so the well is filled
/// in `draw(_:)`, where the dynamic fills resolve against the current
/// appearance on every redraw and the pressed state reads from `isHighlighted`.
///
/// The glyph carries no symbol configuration, matching the overview cards'
/// `chevron.right` affordance so the two arrows read as one family.
@MainActor
private final class SettingsBackButton: NSButton {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        image = .systemSymbol("chevron.left", accessibilityDescription: "")
        imagePosition = .imageOnly
        // AppKit draws no bezel of its own; the well below is the whole bezel.
        isBordered = false
        setButtonType(.momentaryPushIn)
        contentTintColor = .secondaryLabelColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SettingsBackButton does not support NSCoder")
    }

    override func draw(_ dirtyRect: NSRect) {
        let size = SettingsBackButtonView.wellSize
        let well = NSRect(
            x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
            width: size.width, height: size.height)
        let fill: NSColor = isHighlighted ? .tertiarySystemFill : .quaternarySystemFill
        fill.setFill()
        NSBezierPath(
            roundedRect: well, xRadius: CornerRadius.control, yRadius: CornerRadius.control
        ).fill()
        super.draw(dirtyRect)
    }
}
