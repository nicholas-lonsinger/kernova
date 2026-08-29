import AppKit

/// The header above the settings form: a tile, a title, and a status dot beside
/// a one-line facts summary.
///
/// One anatomy serves both states, so drilling into a category morphs the header
/// in place rather than swapping in a second view laid out to match by hand: the
/// tile's glyph turns from the guest OS's into the way back, and the title from
/// the VM's name into the category's. The facts line is the same line in both.
///
/// A plain view plus a pure summary function, holding no concern of the surface
/// that hosts it.
@MainActor
final class VMIdentityHeaderView: NSView {
    /// What the header states.
    enum Mode: Equatable {
        /// The VM's name, over its own icon tile.
        case identity
        /// The open category's name, the tile becoming the way back.
        case category(String)
    }

    /// Side of the square icon tile.
    private static let tileSize: CGFloat = 44

    /// What a category's accessory text resists being squeezed at, one step
    /// below the title's own `.defaultLow`.
    ///
    /// Panel chrome is built for a section header, where a trailing hint holds
    /// its width against a section title, so on this row a narrow pane would
    /// otherwise truncate the category's name away and keep a static hint whole.
    private static let accessoryCompressionResistance = NSLayoutConstraint.Priority(
        NSLayoutConstraint.Priority.defaultLow.rawValue - 1)

    private let iconView = NSImageView()
    private let tile = NSBox()
    private let backButton = HeaderBackButton()
    private let nameLabel = NSTextField(labelWithString: "")
    private let titleRow = NSStackView()
    private let trailingSpacer = NSView()
    private let statusDot = NSImageView()
    private let factsLabel = NSTextField(labelWithString: "")

    private var mode: Mode = .identity
    /// Views handed over by the open panel, removed when another one opens.
    private var accessories: [NSView] = []

    /// The facts line as currently rendered, for a surface stating the same
    /// summary.
    private(set) var renderedFactsLine = ""

    private var instance: VMInstance?
    /// The boot disk's capacity as last configured, `nil` while its read is
    /// still out.
    private var bootDiskBytes: UInt64?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buildLayout()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("VMIdentityHeaderView does not support NSCoder")
    }

    /// Routes the tile's back button to the host that owns the way out of a
    /// panel.
    func setBackAction(target: AnyObject?, action: Selector) {
        backButton.target = target
        backButton.action = action
    }

    /// Binds the header to `instance`, painting what the facts line states —
    /// `bootDiskBytes` among it, once the pane's off-main read has landed.
    ///
    /// `mode` decides what the tile and the title state; a category hosts
    /// `leadingAccessories` beside its title and `trailingAccessories` at the
    /// title row's far edge.
    func configure(
        with instance: VMInstance, mode: Mode = .identity, bootDiskBytes: UInt64? = nil,
        leadingAccessories: [NSView] = [], trailingAccessories: [NSView] = []
    ) {
        self.instance = instance
        self.mode = mode
        self.bootDiskBytes = bootDiskBytes
        setAccessories(leadingAccessories, trailingAccessories)
        render()
    }

    /// How the facts line reads, skipping every segment this VM has no answer
    /// for rather than standing a placeholder in its place.
    static func factsLine(
        status: String, osVersion: String?, cores: Int, memoryGB: Int, diskBytes: UInt64?
    ) -> String {
        var parts = [status]
        if let osVersion { parts.append(osVersion) }
        parts.append(cores == 1 ? "1 core" : "\(cores) cores")
        parts.append("\(memoryGB) GB memory")
        if let diskBytes { parts.append("\(DataFormatters.formatBytes(diskBytes)) disk") }
        return parts.joined(separator: " · ")
    }

    // MARK: - Rendering

    /// Hands the title row the panel's views, in place of the previous panel's.
    private func setAccessories(_ leading: [NSView], _ trailing: [NSView]) {
        let wanted = leading.isEmpty && trailing.isEmpty ? [] : leading + [trailingSpacer] + trailing
        guard wanted.map(ObjectIdentifier.init) != accessories.map(ObjectIdentifier.init) else {
            return
        }
        accessories.forEach { $0.removeFromSuperview() }
        accessories = wanted
        (leading + trailing).forEach(applySqueezePolicy)
        wanted.forEach { titleRow.addArrangedSubview($0) }
    }

    /// Sets the title row's squeeze order on an accessory: its text truncates
    /// tail below the title's own resistance, so a narrow pane takes the width
    /// it is short out of the accessories rather than out of the name of the
    /// thing the header states.
    ///
    /// Fixed-size affordances — the info button's 16-point square — are held by
    /// their own constraints and give up nothing either way.
    private func applySqueezePolicy(to view: NSView) {
        if let label = view as? NSTextField {
            label.maximumNumberOfLines = 1
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(
                Self.accessoryCompressionResistance, for: .horizontal)
        }
        view.subviews.forEach(applySqueezePolicy)
    }

    private func render() {
        guard let instance else { return }
        let config = instance.configuration
        iconView.image = .systemSymbol(
            config.guestOS.iconName, accessibilityDescription: config.guestOS.displayName)
        switch mode {
        case .identity:
            nameLabel.stringValue = instance.name
        case .category(let title):
            nameLabel.stringValue = title
        }
        // The tile is the same tile either way — only what it carries changes.
        iconView.isHidden = mode != .identity
        backButton.isHidden = mode == .identity
        statusDot.contentTintColor = instance.statusDisplayNSColor
        statusDot.setAccessibilityLabel(instance.statusDisplayName)
        renderedFactsLine = Self.factsLine(
            status: instance.statusDisplayName,
            osVersion: instance.guestOSVersionDisplay,
            cores: config.cpuCount,
            memoryGB: config.memorySizeInGB,
            diskBytes: bootDiskBytes)
        factsLabel.stringValue = renderedFactsLine
    }

    // MARK: - Layout

    private func buildLayout() {
        translatesAutoresizingMaskIntoConstraints = false

        tile.boxType = .custom
        tile.titlePosition = .noTitle
        tile.cornerRadius = CornerRadius.card
        tile.borderWidth = 0
        tile.fillColor = GroupedFormStyle.cardFill
        tile.borderColor = .clear
        tile.translatesAutoresizingMaskIntoConstraints = false

        iconView.contentTintColor = .secondaryLabelColor
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(textStyle: .title1)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(tile)
        addSubview(iconView)
        addSubview(backButton)
        NSLayoutConstraint.activate([
            tile.widthAnchor.constraint(equalToConstant: Self.tileSize),
            tile.heightAnchor.constraint(equalToConstant: Self.tileSize),
            tile.leadingAnchor.constraint(equalTo: leadingAnchor),
            tile.topAnchor.constraint(greaterThanOrEqualTo: topAnchor),
            tile.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
            // Centered on the tile, not pinned to it: AppKit holds an NSButton
            // to a minimum size derived from its image, which outranks edge
            // pins, so a title1 chevron stands a little proud of the tile. The
            // floors keep the hit area at least the tile — the visible bezel is
            // the button, not just the glyph.
            backButton.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
            backButton.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
            backButton.widthAnchor.constraint(greaterThanOrEqualTo: tile.widthAnchor),
            backButton.heightAnchor.constraint(greaterThanOrEqualTo: tile.heightAnchor),
        ])
        backButton.isHidden = true

        nameLabel.font = Typography.title
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.maximumNumberOfLines = 1
        nameLabel.isSelectable = false
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        statusDot.image = .systemSymbol("circle.fill", accessibilityDescription: "")
        statusDot.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 8, weight: .regular)
        statusDot.setContentHuggingPriority(.required, for: .horizontal)

        factsLabel.font = .preferredFont(forTextStyle: .caption1)
        factsLabel.textColor = .secondaryLabelColor
        factsLabel.lineBreakMode = .byTruncatingTail
        factsLabel.maximumNumberOfLines = 1
        factsLabel.isSelectable = false
        factsLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let statusRow = NSStackView(views: [statusDot, factsLabel])
        statusRow.orientation = .horizontal
        statusRow.alignment = .centerY
        statusRow.spacing = Spacing.small

        trailingSpacer.translatesAutoresizingMaskIntoConstraints = false
        trailingSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        // A category's affordances sit beside its title, where a section's info
        // button sits beside a section title.
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = Spacing.small
        titleRow.addArrangedSubview(nameLabel)

        let column = NSStackView(views: [titleRow, statusRow])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = Spacing.tight
        column.translatesAutoresizingMaskIntoConstraints = false

        addSubview(column)
        // The header is as tall as the taller of the two — the tile at ordinary
        // text sizes, the column once the system scales type past it — with a
        // weak height pulling it no taller than that.
        let hugsContent = heightAnchor.constraint(equalToConstant: 0)
        hugsContent.priority = .defaultLow
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: tile.trailingAnchor, constant: Spacing.medium),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.centerYAnchor.constraint(equalTo: centerYAnchor),
            column.topAnchor.constraint(greaterThanOrEqualTo: topAnchor),
            hugsContent,
        ])
        // The title row spans the column, so a category's trailing spacer has
        // the width to push its trailing accessories to the header's far edge.
        titleRow.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        statusRow.widthAnchor.constraint(lessThanOrEqualTo: column.widthAnchor).isActive = true
    }
}

/// The tile's glyph while a category is open: a `chevron.left` at the guest-OS
/// icon's size, so the tile reads the same either way and only its glyph changes.
///
/// Accent-tinted, as the navigation control it is — the same tint the cards'
/// Edit affordances carry. Borderless: the tile behind it is the whole bezel,
/// and AppKit's own press dimming is the feedback, which leaves the tile's fill
/// untouched in every state.
@MainActor
private final class HeaderBackButton: NSButton {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        image = NSImage.systemSymbol("chevron.left", accessibilityDescription: "")
            .withSymbolConfiguration(NSImage.SymbolConfiguration(textStyle: .title1))
        imagePosition = .imageOnly
        isBordered = false
        setButtonType(.momentaryPushIn)
        contentTintColor = .controlAccentColor
        toolTip = "Show all settings"
        setAccessibilityLabel("Back")
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("HeaderBackButton does not support NSCoder")
    }
}
