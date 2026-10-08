import AppKit

/// Leaf-row cell for a bundle Kernova can't read: the icon and name dimmed, a
/// yellow warning at the trailing edge, and the reason as the tooltip.
@MainActor
final class SidebarUnreadableRowCellView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("SidebarUnreadableRowCell")

    /// The same insets and slot as ``SidebarVMRowCellView``, so the name sits
    /// where it does once the bundle reads as a VM.
    private static let rowLeadingInset: CGFloat = 4
    private static let rowTrailingInset: CGFloat = 8
    private static let iconSlotWidth: CGFloat = 20
    /// The warning glyph's slot, which a readable VM's row holding an
    /// unreadable file shows too (``SidebarVMRowCellView``).
    static let warningWidth: CGFloat = 16

    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let warningView = NSImageView()

    init() {
        super.init(frame: .zero)
        identifier = Self.reuseIdentifier
        buildLayout()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SidebarUnreadableRowCellView does not support NSCoder")
    }

    private func buildLayout() {
        iconView.imageScaling = .scaleProportionallyDown
        iconView.setContentHuggingPriority(.required, for: .horizontal)

        nameLabel.font = Typography.body
        nameLabel.textColor = .tertiaryLabelColor
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        warningView.imageScaling = .scaleProportionallyDown
        warningView.setContentHuggingPriority(.required, for: .horizontal)
        warningView.setContentCompressionResistancePriority(.required, for: .horizontal)

        let row = NSStackView(views: [iconView, nameLabel, warningView])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Spacing.small
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        textField = nameLabel

        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.rowLeadingInset),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.rowTrailingInset),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: Self.iconSlotWidth),
            warningView.widthAnchor.constraint(equalToConstant: Self.warningWidth),
        ])
        applySymbols()
    }

    func configure(bundle: UnreadableVM) {
        nameLabel.stringValue = bundle.name
        toolTip = bundle.toolTip
    }

    /// Bakes each symbol's color in and marks it non-template, as
    /// ``SidebarVMRowCellView`` does for its icon, so the source list's
    /// selection vibrancy leaves the warning yellow.
    private func applySymbols() {
        iconView.image = Self.symbol(
            "desktopcomputer", pointSize: 18, color: .tertiaryLabelColor,
            description: "Virtual machine")
        warningView.image = Self.warningSymbol(
            description: "Kernova can\u{2019}t read this virtual machine\u{2019}s settings")
    }

    /// The yellow warning glyph, colored and non-template as
    /// ``applySymbols()`` bakes it — re-made at each appearance change.
    static func warningSymbol(description: String) -> NSImage {
        symbol(
            "exclamationmark.triangle.fill", pointSize: 13, color: .systemYellow,
            description: description)
    }

    private static func symbol(
        _ name: String, pointSize: CGFloat, color: NSColor, description: String
    ) -> NSImage {
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        let symbol = NSImage.systemSymbol(name, accessibilityDescription: description)
        let colored = symbol.withSymbolConfiguration(configuration) ?? symbol
        colored.isTemplate = false
        return colored
    }

    /// Re-resolves the baked colors for the new light/dark appearance.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applySymbols()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        toolTip = nil
    }

    /// The cell content width at which `name` stops truncating, excluding the
    /// outline view's indentation.
    static func contentWidth(forName name: String) -> CGFloat {
        SidebarVMRowCellView.contentWidth(
            forName: name, showsAgentAccessory: false, showsEphemeralAccessory: false,
            showsUnreadableWarning: true)
    }
}
