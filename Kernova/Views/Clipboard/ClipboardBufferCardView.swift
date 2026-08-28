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

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentContainer)
        // Above the content, so a preview scrolling under it can't paint over it.
        addSubview(chip)

        NSLayoutConstraint.activate([
            chip.topAnchor.constraint(equalTo: topAnchor, constant: Spacing.small),
            chip.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Spacing.small),
            chip.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: Spacing.small),

            // Below the chip, so it never overlaps the editor's first line or the
            // scroller's track.
            contentContainer.topAnchor.constraint(
                equalTo: chip.bottomAnchor, constant: Spacing.small),
            contentContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ClipboardBufferCardView does not support NSCoder")
    }

    /// Names the buffer's content type — kind, dimensions, size — in the chip.
    func setContentType(_ text: String) {
        chip.setText(text)
    }

    #if DEBUG
    var chipTextForTesting: String { chip.text }
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
