import AppKit

/// A rounded, tinted container that wraps arbitrary content — used for the
/// IPSW path badge and the overwrite/resume warning banners.
///
/// Layer-backed with explicit fill/border colors re-resolved on appearance
/// changes, mirroring the `WizardSelectableCardView` pattern (a baked `cgColor`
/// otherwise wouldn't follow light/dark switches).
@MainActor
final class WizardTintedBox: NSView {
    private let fill: NSColor
    private let border: NSColor

    init(
        content: NSView,
        fill: NSColor,
        border: NSColor,
        padding: CGFloat,
        cornerRadius: CGFloat,
        borderWidth: CGFloat = 1
    ) {
        self.fill = fill
        self.border = border
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        layer?.borderWidth = borderWidth

        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor, constant: padding),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padding),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padding),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -padding),
        ])

        updateAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("WizardTintedBox does not support NSCoder")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    private func updateAppearance() {
        layer?.backgroundColor = wizardResolvedCGColor(fill, in: effectiveAppearance)
        layer?.borderColor = wizardResolvedCGColor(border, in: effectiveAppearance)
    }
}
