import AppKit

/// One remembered USB accessory: what it is called, where it was and when it
/// was placed, and the button that forgets it.
///
/// Built from the pairing alone — the device itself is usually not plugged in,
/// which is the whole reason this row exists rather than a menu item.
@MainActor
final class USBAccessoryPairingRowView: NSView {
    init(pairing: USBAccessoryPairing, target: AnyObject, action: Selector) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: pairing.displayName)
        title.font = Typography.body
        title.isSelectable = false
        title.lineBreakMode = .byTruncatingTail
        title.maximumNumberOfLines = 1
        title.setContentHuggingPriority(.defaultLow, for: .horizontal)
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // The same secondary line the shared-directory rows in this card use.
        let detail = makeGroupedFormSecondaryLabel(Self.detailText(for: pairing))
        detail.font = .preferredFont(forTextStyle: .caption1)
        detail.lineBreakMode = .byTruncatingTail
        detail.maximumNumberOfLines = 1
        detail.setContentHuggingPriority(.defaultLow, for: .horizontal)
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let text = NSStackView(views: [title, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = Spacing.hairline
        text.setContentHuggingPriority(.defaultLow, for: .horizontal)
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // Both lines fill the text column rather than sizing to their own
        // string, so the column is what the row's spare width lands in.
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: text.leadingAnchor),
            title.trailingAnchor.constraint(equalTo: text.trailingAnchor),
            detail.leadingAnchor.constraint(equalTo: text.leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: text.trailingAnchor),
        ])

        let remove = NSButton()
        remove.image = .systemSymbol("minus.circle", accessibilityDescription: "Forget")
        remove.imagePosition = .imageOnly
        remove.isBordered = false
        remove.contentTintColor = .secondaryLabelColor
        // The key travels on the button, which is what the action reads it
        // back off — the row itself is not addressed by anything.
        remove.identifier = NSUserInterfaceItemIdentifier(pairing.key)
        remove.target = target
        remove.action = action
        remove.toolTip = "Stop passing this accessory through automatically"
        // Rigid, so the text column is the only view that stretches and the
        // button lands on the row's trailing edge rather than against the
        // title — the arrangement the attachment rows in this card use.
        remove.setContentHuggingPriority(.required, for: .horizontal)
        remove.setContentCompressionResistancePriority(.required, for: .horizontal)

        let row = NSStackView(views: [text, remove])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = Spacing.standard
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("USBAccessoryPairingRowView does not support NSCoder")
    }

    /// The secondary line: the port the rule names, when it names one, and when
    /// the accessory was last placed.
    static func detailText(for pairing: USBAccessoryPairing) -> String {
        let placed = pairing.pairedAt.formatted(date: .abbreviated, time: .shortened)
        guard let label = pairing.namedReceptacleLabel else { return placed }
        return "\(label) \u{2014} \(placed)"
    }
}
