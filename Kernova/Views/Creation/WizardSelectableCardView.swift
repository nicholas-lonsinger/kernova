import AppKit

/// A clickable, selectable card used across wizard steps (OS choice in step 1,
/// IPSW source choice in the boot step).
///
/// Wraps caller-supplied content in a rounded container that draws an accent
/// fill + border when selected. Selection is driven externally (the owning
/// step VC sets ``isSelected`` after mutating the shared view model), and clicks
/// are reported via ``onClick`` — the AppKit analog of the SwiftUI predecessor's
/// `Button { } label: { … }.buttonStyle(.plain)`.
@MainActor
final class WizardSelectableCardView: NSView {
    /// Invoked when the card is clicked.
    var onClick: (() -> Void)?

    /// Whether the card currently shows the selected (accent) chrome.
    var isSelected: Bool = false {
        didSet {
            guard oldValue != isSelected else { return }
            updateAppearance()
        }
    }

    init(content: NSView) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = WizardStyle.cardCornerRadius
        layer?.borderWidth = 1

        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        let inset = WizardStyle.contentPadding
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor, constant: inset),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset),
        ])

        updateAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("WizardSelectableCardView does not support NSCoder")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    /// Treat the whole card as one click target so taps on the label/icon
    /// subviews (which are display-only) still register as a card click.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return bounds.contains(local) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    private func updateAppearance() {
        let fill: NSColor =
            isSelected
            ? .controlAccentColor.withAlphaComponent(WizardStyle.selectedFillOpacity)
            : .clear
        let border: NSColor = isSelected ? .controlAccentColor : .separatorColor
        layer?.backgroundColor = wizardResolvedCGColor(fill, in: effectiveAppearance)
        layer?.borderColor = wizardResolvedCGColor(border, in: effectiveAppearance)
    }
}
