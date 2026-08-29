import AppKit

/// The header above the settings form.
///
/// The overview states the VM: an icon tile beside its name, over a status dot
/// and a one-line facts summary. A category states itself on a single row — a
/// bezeled back button, the category's title, its own affordances, and the same
/// facts line trailing.
///
/// A plain view plus a pure summary function, holding no concern of the surface
/// that hosts it.
@MainActor
final class VMIdentityHeaderView: NSView {
    /// What the header states.
    enum Mode: Equatable {
        /// The VM's name, over its own icon tile.
        case identity
        /// The open category's name, on one row behind the way back.
        case category(String)
    }

    /// Side of the square icon tile.
    private static let tileSize: CGFloat = 44

    /// What a category's accessory text resists being squeezed at, one step
    /// below the facts line's own `.defaultLow`.
    ///
    /// Panel chrome is built for a section header, where a trailing hint holds
    /// its width against a section title, so a narrow pane would take the whole
    /// shortfall out of the facts line and leave a static hint at full width.
    /// On this row the VM's live state outranks the panel's fixed text.
    private static let accessoryCompressionResistance = NSLayoutConstraint.Priority(
        NSLayoutConstraint.Priority.defaultLow.rawValue - 1)

    private let iconView = NSImageView()
    private let tile = NSBox()
    /// Carries the tile, so hiding it takes the glyph with it.
    private let tileWell = NSView()
    private let backButton = HeaderBackButton()
    private let nameLabel = NSTextField(labelWithString: "")
    private let headerRow = NSStackView()
    private let titleRow = NSStackView()
    private let column = NSStackView()
    private let statusRow = NSStackView()
    private let trailingSpacer = NSView()
    private let statusDot = NSImageView()
    private let factsLabel = NSTextField(labelWithString: "")

    private var mode: Mode = .identity
    /// Views handed over by the open panel, removed when another one opens.
    private var leadingAccessories: [NSView] = []
    private var trailingAccessories: [NSView] = []

    /// The facts line as currently rendered, for a surface stating the same
    /// summary — the disk figure is read here and nowhere else.
    private(set) var renderedFactsLine = ""

    /// Fires when the off-main disk read lands, so another surface stating the
    /// same figure repaints with it.
    var onBootDiskCapacityResolved: (() -> Void)?

    private var instance: VMInstance?
    /// Boot-disk capacity, once the off-main read lands.
    private(set) var bootDiskCapacityBytes: UInt64?
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

    /// Routes the back button to the host that owns the way out of a panel.
    func setBackAction(target: AnyObject?, action: Selector) {
        backButton.target = target
        backButton.action = action
    }

    /// Binds the header to `instance`, painting everything known synchronously
    /// and filling the disk figure in when its off-main read lands.
    ///
    /// `mode` decides the anatomy and the title; a category hosts
    /// `leadingAccessories` beside its title and `trailingAccessories` before
    /// the facts line at the row's far edge.
    func configure(
        with instance: VMInstance, mode: Mode = .identity,
        leadingAccessories: [NSView] = [], trailingAccessories: [NSView] = []
    ) {
        self.instance = instance
        self.mode = mode
        self.leadingAccessories = leadingAccessories
        self.trailingAccessories = trailingAccessories
        let boot = instance.displayedStorageDisks.first
        let key = boot.map {
            DiskReadKey(instanceID: instance.id, path: $0.path, isInternal: $0.isInternal)
        }
        if key != diskReadKey {
            diskReadKey = key
            bootDiskCapacityBytes = nil
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
        let drilledIn = mode != .identity
        tileWell.isHidden = drilledIn
        backButton.isHidden = !drilledIn
        arrange(drilledIn: drilledIn)
        statusDot.contentTintColor = instance.statusDisplayNSColor
        statusDot.setAccessibilityLabel(instance.statusDisplayName)
        renderedFactsLine = Self.factsLine(
            status: instance.statusDisplayName,
            osVersion: instance.guestOSVersionDisplay,
            cores: config.cpuCount,
            memoryGB: config.memorySizeInGB,
            diskBytes: bootDiskCapacityBytes)
        factsLabel.stringValue = renderedFactsLine
    }

    /// Puts the title row's contents in the order the current state states them,
    /// the facts line trailing that row inside a panel and sitting below it on
    /// the overview.
    private func arrange(drilledIn: Bool) {
        let wanted: [NSView] =
            drilledIn
            ? [nameLabel] + leadingAccessories + [trailingSpacer] + trailingAccessories
                + [statusRow]
            : [nameLabel]
        guard wanted.map(ObjectIdentifier.init) != titleRow.arrangedSubviews.map(ObjectIdentifier.init)
        else { return }
        (leadingAccessories + trailingAccessories).forEach(applySqueezePolicy)
        detach(statusRow, from: column)
        titleRow.arrangedSubviews.forEach { detach($0, from: titleRow) }
        wanted.forEach { titleRow.addArrangedSubview($0) }
        if !drilledIn { column.addArrangedSubview(statusRow) }
    }

    /// Sets the row's squeeze order on an accessory: its text truncates tail at
    /// ``accessoryCompressionResistance``, so a narrow pane takes the width it
    /// is short out of the accessories before the facts line.
    ///
    /// Fixed-size affordances — the info button's 16-point square — are held by
    /// their own constraints and give up nothing either way.
    private func applySqueezePolicy(to view: NSView) {
        if let label = view as? NSTextField {
            label.maximumNumberOfLines = 1
            label.lineBreakMode = .byTruncatingTail
        }
        if view is NSTextField || view is NSStackView {
            view.setContentCompressionResistancePriority(
                Self.accessoryCompressionResistance, for: .horizontal)
        }
        view.subviews.forEach(applySqueezePolicy)
    }

    /// Takes `view` out of `stack` and out of the view tree, so re-adding it
    /// elsewhere lands it in one arranged list only.
    private func detach(_ view: NSView, from stack: NSStackView) {
        if stack.arrangedSubviews.contains(where: { $0 === view }) {
            stack.removeArrangedSubview(view)
        }
        view.removeFromSuperview()
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
            self.bootDiskCapacityBytes = sizes.capacityBytes
            self.render()
            self.onBootDiskCapacityResolved?()
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

        tileWell.translatesAutoresizingMaskIntoConstraints = false
        tileWell.addSubview(tile)
        tileWell.addSubview(iconView)
        NSLayoutConstraint.activate([
            tile.widthAnchor.constraint(equalToConstant: Self.tileSize),
            tile.heightAnchor.constraint(equalToConstant: Self.tileSize),
            tile.leadingAnchor.constraint(equalTo: tileWell.leadingAnchor),
            tile.trailingAnchor.constraint(equalTo: tileWell.trailingAnchor),
            tile.topAnchor.constraint(equalTo: tileWell.topAnchor),
            tile.bottomAnchor.constraint(equalTo: tileWell.bottomAnchor),
            iconView.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
        ])

        nameLabel.font = Typography.title
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.maximumNumberOfLines = 1
        nameLabel.isSelectable = false
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        nameLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        statusDot.image = .systemSymbol("circle.fill", accessibilityDescription: "")
        statusDot.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 8, weight: .regular)
        statusDot.setContentHuggingPriority(.required, for: .horizontal)

        factsLabel.font = .preferredFont(forTextStyle: .caption1)
        factsLabel.textColor = .secondaryLabelColor
        factsLabel.lineBreakMode = .byTruncatingTail
        factsLabel.maximumNumberOfLines = 1
        factsLabel.isSelectable = false
        factsLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        statusRow.orientation = .horizontal
        statusRow.alignment = .centerY
        statusRow.spacing = Spacing.small
        statusRow.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        statusRow.addArrangedSubview(statusDot)
        statusRow.addArrangedSubview(factsLabel)

        trailingSpacer.translatesAutoresizingMaskIntoConstraints = false
        trailingSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        // A category's affordances sit beside its title, where a section's info
        // button sits beside a section title.
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = Spacing.small
        titleRow.addArrangedSubview(nameLabel)

        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = Spacing.tight
        column.setContentHuggingPriority(.defaultLow, for: .horizontal)
        column.addArrangedSubview(titleRow)
        column.addArrangedSubview(statusRow)

        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        headerRow.spacing = Spacing.medium
        headerRow.translatesAutoresizingMaskIntoConstraints = false
        headerRow.addArrangedSubview(tileWell)
        headerRow.addArrangedSubview(backButton)
        headerRow.addArrangedSubview(column)
        headerRow.setCustomSpacing(Spacing.standard, after: backButton)
        backButton.isHidden = true

        addSubview(headerRow)
        NSLayoutConstraint.activate([
            headerRow.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerRow.trailingAnchor.constraint(equalTo: trailingAnchor),
            headerRow.topAnchor.constraint(equalTo: topAnchor),
            headerRow.bottomAnchor.constraint(equalTo: bottomAnchor),
            // The title row spans the column, so a category's trailing spacer
            // has the width to push the facts line to the header's far edge.
            titleRow.widthAnchor.constraint(equalTo: column.widthAnchor),
        ])
    }
}

/// The way back out of a category: a small bezeled button carrying a
/// `chevron.left` in the accent color, as a navigation control reads elsewhere
/// on the system.
@MainActor
private final class HeaderBackButton: NSButton {
    /// The bezel, sized for a chevron beside a title rather than for a label.
    private static let size = NSSize(width: 28, height: 24)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        image = NSImage.systemSymbol("chevron.left", accessibilityDescription: "")
            .withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold))
        imagePosition = .imageOnly
        bezelStyle = .push
        isBordered = true
        setButtonType(.momentaryPushIn)
        contentTintColor = .controlAccentColor
        toolTip = "Show all settings"
        setAccessibilityLabel("Back")
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.size.width),
            heightAnchor.constraint(equalToConstant: Self.size.height),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("HeaderBackButton does not support NSCoder")
    }
}
