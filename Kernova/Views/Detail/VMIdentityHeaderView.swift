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
    /// summary — the disk figure is read here and nowhere else.
    private(set) var renderedFactsLine = ""

    private var instance: VMInstance?
    /// Boot-disk capacity, once the off-main read lands.
    private var diskBytes: UInt64?
    /// The VM and disk path the capacity was last read for, so a re-render
    /// re-uses the figure instead of re-reading the file.
    private var diskReadKey: DiskReadKey?
    private var diskReadTask: Task<Void, Never>?

    private struct DiskReadKey: Equatable {
        let instanceID: UUID
        let path: String
        let isInternal: Bool
    }

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

    /// Binds the header to `instance`, painting everything known synchronously
    /// and filling the disk figure in when its off-main read lands.
    ///
    /// `mode` decides what the tile and the title state; a category hosts
    /// `leadingAccessories` beside its title and `trailingAccessories` at the
    /// title row's far edge.
    func configure(
        with instance: VMInstance, mode: Mode = .identity,
        leadingAccessories: [NSView] = [], trailingAccessories: [NSView] = []
    ) {
        self.instance = instance
        self.mode = mode
        setAccessories(leadingAccessories, trailingAccessories)
        let boot = instance.displayedStorageDisks.first
        let key = boot.map {
            DiskReadKey(instanceID: instance.id, path: $0.path, isInternal: $0.isInternal)
        }
        if key != diskReadKey {
            diskReadKey = key
            diskBytes = nil
            readBootDiskCapacity(key: key, bundleLayout: instance.bundleLayout)
        }
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
        wanted.forEach { titleRow.addArrangedSubview($0) }
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
            diskBytes: diskBytes)
        factsLabel.stringValue = renderedFactsLine
    }

    /// Reads the boot disk's capacity off the main thread, re-rendering when it
    /// lands. The key tags the read, so a re-bind to another VM — or another
    /// disk — ignores a result issued for the previous one.
    private func readBootDiskCapacity(key: DiskReadKey?, bundleLayout: VMBundleLayout) {
        diskReadTask?.cancel()
        diskReadTask = nil
        guard let key else { return }
        diskReadTask = Task { [weak self] in
            let sizes = await Task.detached {
                bundleLayout.diskSizes(forRelativePath: key.path, isInternal: key.isInternal)
            }.value
            guard !Task.isCancelled, let self, self.diskReadKey == key else { return }
            self.diskBytes = sizes.capacityBytes
            self.render()
        }
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
            // glyph lands centered either way, and the hit area is the more
            // generous for it.
            backButton.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
            backButton.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
        ])

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
        titleRow.widthAnchor.constraint(lessThanOrEqualTo: column.widthAnchor).isActive = true
        statusRow.widthAnchor.constraint(lessThanOrEqualTo: column.widthAnchor).isActive = true
    }
}

/// The tile's glyph while a category is open: a `chevron.left` at the guest-OS
/// icon's size, so the tile reads the same either way and only its glyph changes.
///
/// Borderless — the tile behind it is the whole bezel, and AppKit's own press
/// dimming is the feedback, which leaves the tile's fill untouched in every
/// state.
@MainActor
private final class HeaderBackButton: NSButton {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        image = NSImage.systemSymbol("chevron.left", accessibilityDescription: "")
            .withSymbolConfiguration(NSImage.SymbolConfiguration(textStyle: .title1))
        imagePosition = .imageOnly
        isBordered = false
        setButtonType(.momentaryPushIn)
        contentTintColor = .secondaryLabelColor
        toolTip = "Show all settings"
        setAccessibilityLabel("Back")
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("HeaderBackButton does not support NSCoder")
    }
}
