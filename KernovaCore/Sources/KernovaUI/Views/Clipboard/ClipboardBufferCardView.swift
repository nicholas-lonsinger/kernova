import AppKit

/// The clipboard window's content well: an inset card holding whichever preview
/// is showing, with a chip naming the buffer's content type in its top corner.
///
/// The card rounds and clips its content, so each preview keeps painting its own
/// square background and inherits the corner treatment from here.
@MainActor
final class ClipboardBufferCardView: NSView {
    /// Hosts the preview views; exactly one of them is visible at a time.
    let contentContainer = NSView()

    private let chip = ContentTypeChip()
    /// Holds the content below the chip; swapped for ``contentFillsCard`` when
    /// there is no content type to state, since a hidden view still satisfies
    /// its constraints and would leave the band blank.
    private var contentBelowChip = NSLayoutConstraint()
    private var contentFillsCard = NSLayoutConstraint()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentContainer)
        // Above the content, so a preview scrolling under it can't paint over it.
        addSubview(chip)

        // Below the chip, so it never overlaps the editor's first line or the
        // scroller's track — and flush to the top whenever the chip is away.
        contentBelowChip = contentContainer.topAnchor.constraint(
            equalTo: chip.bottomAnchor, constant: Spacing.small)
        contentFillsCard = contentContainer.topAnchor.constraint(equalTo: topAnchor)

        NSLayoutConstraint.activate([
            chip.topAnchor.constraint(equalTo: topAnchor, constant: Spacing.small),
            chip.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Spacing.small),
            chip.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: Spacing.small),

            contentBelowChip,
            contentContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        // A card opens with nothing named — a VM whose agent has not connected
        // never names one at all — so start in the collapsed state rather than
        // reserving a band for a chip that isn't there.
        setContentType("")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ClipboardBufferCardView does not support NSCoder")
    }

    /// Names the buffer's content type — kind, dimensions, size — in the chip,
    /// which stands down (band and all) when there is nothing to name.
    func setContentType(_ text: String) {
        chip.setText(text)
        let showsChip = !text.isEmpty
        guard contentBelowChip.isActive != showsChip else { return }
        contentBelowChip.isActive = showsChip
        contentFillsCard.isActive = !showsChip
    }

    #if DEBUG
    var chipTextForTesting: String { chip.text }

    /// The band the chip reserves above the content, `0` when it is away.
    ///
    /// Measured as the height the content does not get, so it reads the same
    /// whichever way the card's coordinate system runs.
    var chipBandHeightForTesting: CGFloat {
        layoutSubtreeIfNeeded()
        return bounds.height - contentContainer.frame.height
    }
    #endif

    // MARK: - Drawing

    nonisolated override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = CornerRadius.card
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
    }
}

/// The capsule naming the buffer's content type.
@MainActor
private final class ContentTypeChip: NSView {
    private static let height: CGFloat = 18

    private let label = NSTextField(labelWithString: "")

    var text: String { label.stringValue }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        label.font = .preferredFont(forTextStyle: .caption1)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.isSelectable = false
        label.translatesAutoresizingMaskIntoConstraints = false
        // A long description truncates rather than dictating the window's width.
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(label)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Spacing.small),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Spacing.small),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ContentTypeChip does not support NSCoder")
    }

    func setText(_ text: String) {
        label.stringValue = text
        isHidden = text.isEmpty
        toolTip = text.isEmpty ? nil : text
    }

    nonisolated override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = Self.height / 2
        layer?.backgroundColor = NSColor.secondaryLabelColor.withAlphaComponent(0.12).cgColor
    }
}
