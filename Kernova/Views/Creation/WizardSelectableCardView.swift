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

        box.boxType = .custom
        box.titlePosition = .noTitle
        box.cornerRadius = WizardStyle.cardCornerRadius
        box.borderWidth = 1
        box.contentViewMargins = NSSize(
            width: WizardStyle.contentPadding, height: WizardStyle.contentPadding)
        // The content must use Auto Layout, otherwise `NSBox` falls back to
        // frame/autoresizing sizing for its content view and never derives an
        // intrinsic height from it — the box collapses and the content spills
        // out over neighboring views.
        content.translatesAutoresizingMaskIntoConstraints = false
        box.contentView = content

        addFullSizeSubview(box)

        // Hug content vertically so the card is sized by its content (+ box
        // margins) rather than stretched to fill a containing stack — otherwise
        // a card in a vertical stack (the IPSW source list) balloons.
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .vertical)

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
