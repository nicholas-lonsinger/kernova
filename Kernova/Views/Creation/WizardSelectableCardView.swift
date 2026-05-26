import AppKit

/// A clickable, selectable card used across wizard steps (OS choice in step 1,
/// IPSW source choice in the boot step).
///
/// Wraps caller-supplied content in a rounded `NSBox` that draws an accent
/// fill + border when selected. Selection is driven externally (the owning step
/// VC sets ``isSelected`` after mutating the shared view model); clicks are
/// reported via ``onClick``. Using an `NSBox` (whose `fillColor`/`borderColor`
/// are `NSColor`s) means the chrome adapts to light/dark automatically with no
/// `viewDidChangeEffectiveAppearance` override, and a click gesture recognizer
/// gives native press-then-release semantics (slide-off-to-cancel) — neither
/// requires a `@MainActor @objc` AppKit override.
@MainActor
final class WizardSelectableCardView: NSView {
    /// Invoked when the card is clicked.
    var onClick: (() -> Void)?

    /// Whether the card currently shows the selected (accent) chrome.
    var isSelected: Bool = false {
        didSet {
            guard oldValue != isSelected else { return }
            updateChrome()
        }
    }

    private let box = NSBox()

    init(content: NSView) {
        super.init(frame: .zero)

        // The box is used purely as a chrome layer (rounded fill + border),
        // pinned behind the content. We deliberately do NOT use `box.contentView`
        // to host the content: a custom `NSBox` sizes its content view through
        // the legacy autoresizing path, so it never derives an intrinsic height
        // from Auto Layout content and collapses, spilling the content over
        // neighboring views. Laying the content out as a direct subview makes the
        // card's height a pure function of the content's own constraints.
        box.boxType = .custom
        box.titlePosition = .noTitle
        box.cornerRadius = WizardStyle.cardCornerRadius
        box.borderWidth = 1
        addFullSizeSubview(box)

        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        let padding = WizardStyle.contentPadding
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor, constant: padding),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -padding),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padding),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padding),
        ])

        addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(clicked)))

        updateChrome()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("WizardSelectableCardView does not support NSCoder")
    }

    @objc private func clicked() {
        onClick?()
    }

    private func updateChrome() {
        box.fillColor =
            isSelected
            ? .controlAccentColor.withAlphaComponent(WizardStyle.selectedFillOpacity)
            : .clear
        box.borderColor = isSelected ? .controlAccentColor : .separatorColor
    }
}
