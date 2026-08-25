import AppKit

/// Shared design tokens and atom factories for the native macOS *grouped form*
/// look — rounded, subtly-filled cards with hairline-separated rows, section
/// headers, captions, and tinted banners.
///
/// These atoms are context-neutral: tokens specific to one surface (e.g. the
/// wizard's fixed sheet dimensions) stay in that surface's own style file.
enum GroupedFormStyle {
    /// Symmetric inset from a scrolling form's viewport to its content, applied on
    /// both sides so content stays horizontally centered — and the clearance
    /// between content and a trailing overlay scroller.
    static let contentSideInset: CGFloat = 16
}

// MARK: - Scrolling

/// A clip view that reports itself flipped so its document view is anchored at
/// the top-left and scrolls downward.
///
/// Without this, `NSClipView`'s default bottom-left origin anchors short content
/// to the bottom of the viewport — and when content is marginally taller than
/// the viewport, the initial scroll position shows the bottom, clipping the top
/// out of view.
final class FlippedClipView: NSClipView {
    nonisolated override var isFlipped: Bool { true }
}

/// Wraps `content` in a borderless vertical scroll view.
///
/// `content` is hosted inside a full-width document view and inset symmetrically
/// by ``GroupedFormStyle/contentSideInset``, plus `topInset` / `bottomInset`.
/// The document view fills the clip view's width on purpose: pinning it
/// *narrower* than the clip makes `NSClipView` offset its bounds origin to align
/// the under-sized document, which scrolls the content sideways and defeats the
/// inset. Callers add their own per-subview width constraints against `content`.
@MainActor
func makeGroupedFormScrollView(
    documentView content: NSView,
    topInset: CGFloat = 0,
    bottomInset: CGFloat = 0
) -> NSScrollView {
    let scrollView = NSScrollView()
    scrollView.contentView = FlippedClipView()
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = false
    scrollView.borderType = .noBorder
    scrollView.drawsBackground = false
    scrollView.autohidesScrollers = true
    scrollView.automaticallyAdjustsContentInsets = false
    scrollView.contentInsets = NSEdgeInsetsZero
    scrollView.contentView.automaticallyAdjustsContentInsets = false
    scrollView.contentView.contentInsets = NSEdgeInsetsZero

    let docView = NSView()
    docView.translatesAutoresizingMaskIntoConstraints = false
    content.translatesAutoresizingMaskIntoConstraints = false
    docView.addSubview(content)
    scrollView.documentView = docView

    let clip = scrollView.contentView
    let inset = GroupedFormStyle.contentSideInset
    NSLayoutConstraint.activate([
        // Document view fills the clip width; its height flows from the content.
        docView.topAnchor.constraint(equalTo: clip.topAnchor),
        docView.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
        docView.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
        docView.widthAnchor.constraint(equalTo: clip.widthAnchor),
        content.topAnchor.constraint(equalTo: docView.topAnchor, constant: topInset),
        content.bottomAnchor.constraint(equalTo: docView.bottomAnchor, constant: -bottomInset),
        content.leadingAnchor.constraint(equalTo: docView.leadingAnchor, constant: inset),
        content.trailingAnchor.constraint(equalTo: docView.trailingAnchor, constant: -inset),
    ])
    return scrollView
}

// MARK: - Grouped cards (System Settings style)

@MainActor
func makeGroupedFormHairline() -> NSView {
    let line = NSBox()
    line.boxType = .custom
    line.borderWidth = 0
    line.fillColor = .separatorColor
    line.translatesAutoresizingMaskIntoConstraints = false
    line.heightAnchor.constraint(equalToConstant: 1).isActive = true
    return line
}

/// Builds a full-width card row: a leading label and a trailing control/value.
///
/// By default the control is pushed to the trailing edge (for steppers, switches,
/// popups, and read-only values). Pass `fillsControl: true` for an input that
/// should stretch to fill the row (a text field). `titleLabel` hands the
/// freshly-built label back to the caller, for rows whose text has to be
/// restyled later.
@MainActor
func makeGroupedFormCardRow(
    _ labelText: String,
    control: NSView,
    alignment: NSLayoutConstraint.Attribute = .centerY,
    fillsControl: Bool = false,
    titleLabel: ((NSTextField) -> Void)? = nil
) -> NSView {
    let label = NSTextField(labelWithString: labelText)
    label.font = Typography.body
    label.isSelectable = false
    label.setContentHuggingPriority(.defaultHigh, for: .horizontal)
    label.setContentCompressionResistancePriority(.required, for: .horizontal)
    titleLabel?(label)

    let views: [NSView]
    if fillsControl {
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        views = [label, control]
    } else {
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        views = [label, spacer, control]
    }

    let row = NSStackView(views: views)
    row.orientation = .horizontal
    row.alignment = alignment
    row.spacing = Spacing.standard
    return row
}

/// A card row that can be shown and hidden after its card is built.
///
/// ``makeGroupedFormCard(rows:)`` draws a hairline before every row but the
/// first, which a row hidden on its own would leave stranded against the next
/// separator. This carries that hairline instead, so `isHidden` takes both.
/// Never a card's first row — the hairline would have nothing above it.
@MainActor
final class GroupedFormCollapsibleRow: NSStackView {
    init(row: NSView) {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = Spacing.relaxed
        translatesAutoresizingMaskIntoConstraints = false
        for view in [makeGroupedFormHairline(), row] {
            addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("GroupedFormCollapsibleRow does not support NSCoder")
    }
}

@MainActor
func makeGroupedFormCard(rows: [NSView]) -> NSView {
    let content = NSStackView()
    content.orientation = .vertical
    content.alignment = .leading
    content.spacing = Spacing.relaxed
    content.translatesAutoresizingMaskIntoConstraints = false

    for (index, row) in rows.enumerated() {
        // A collapsible row carries its own hairline, so that hiding it takes
        // the separator with it.
        if index > 0, !(row is GroupedFormCollapsibleRow) {
            content.addArrangedSubview(makeGroupedFormHairline())
        }
        content.addArrangedSubview(row)
    }

    let box = NSBox()
    box.boxType = .custom
    box.titlePosition = .noTitle
    box.cornerRadius = 8
    box.borderWidth = 1
    box.fillColor = .secondaryLabelColor.withAlphaComponent(0.06)
    box.borderColor = .separatorColor

    let container = NSView()
    container.addFullSizeSubview(box)
    container.addSubview(content)
    let pad: CGFloat = 12
    NSLayoutConstraint.activate([
        content.topAnchor.constraint(equalTo: container.topAnchor, constant: pad),
        content.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -pad),
        content.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: pad),
        content.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -pad),
    ])
    for view in content.arrangedSubviews {
        view.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
    }
    return container
}

/// Leading indent applied to a sub-option nested beneath its parent row.
let groupedFormSubOptionIndent: CGFloat = 20

/// Composes a primary row and a dependent sub-option into a single grouped-form
/// "row": the sub-option (and the hairline separating it) are indented beneath
/// the primary so the pair reads as a parent → child unit.
///
/// Pass the result to ``makeGroupedFormCard(rows:)`` in place of two sibling
/// rows, so the card's full-width separators land only *around* the pair.
@MainActor
func makeGroupedFormSubOptionGroup(primary: NSView, subOption: NSView) -> NSView {
    let hairline = makeGroupedFormHairline()
    let container = NSView()
    for view in [primary, hairline, subOption] {
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
    }
    let indent = groupedFormSubOptionIndent
    NSLayoutConstraint.activate([
        primary.topAnchor.constraint(equalTo: container.topAnchor),
        primary.leadingAnchor.constraint(equalTo: container.leadingAnchor),
        primary.trailingAnchor.constraint(equalTo: container.trailingAnchor),

        hairline.topAnchor.constraint(equalTo: primary.bottomAnchor, constant: Spacing.relaxed),
        hairline.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: indent),
        hairline.trailingAnchor.constraint(equalTo: container.trailingAnchor),

        subOption.topAnchor.constraint(equalTo: hairline.bottomAnchor, constant: Spacing.relaxed),
        subOption.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: indent),
        subOption.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        subOption.bottomAnchor.constraint(equalTo: container.bottomAnchor),
    ])
    return container
}

// MARK: - Labels

@MainActor
func makeGroupedFormValueLabel(_ text: String) -> NSTextField {
    let label = NSTextField(labelWithString: text)
    label.font = Typography.body
    label.textColor = .secondaryLabelColor
    label.lineBreakMode = .byTruncatingMiddle
    label.isSelectable = false
    return label
}

@MainActor
func makeGroupedFormSectionHeader(_ text: String) -> NSTextField {
    let label = NSTextField(labelWithString: text)
    label.font = .preferredFont(forTextStyle: .subheadline)
    label.textColor = .secondaryLabelColor
    label.isSelectable = false
    // Required so an over-constrained ancestor (e.g. a height-capped pane
    // hugging its content) breaks its own optional constraint instead of
    // resolving the conflict by collapsing the text to zero height.
    label.setContentCompressionResistancePriority(.required, for: .vertical)
    return label
}

@MainActor
func makeGroupedFormCaption(_ text: String) -> NSTextField {
    let label = NSTextField(wrappingLabelWithString: text)
    label.font = .preferredFont(forTextStyle: .caption1)
    label.textColor = .secondaryLabelColor
    label.maximumNumberOfLines = 0
    label.isSelectable = false
    label.setContentCompressionResistancePriority(.required, for: .vertical)
    return label
}

/// A borderless button that reads as a link.
///
/// `.linkColor` barely desaturates when AppKit disables a borderless button, so
/// the tint is driven from `isEnabled` — otherwise a disabled link reads as
/// clickable and clicking it does nothing.
@MainActor
final class LinkButton: NSButton {
    override var isEnabled: Bool {
        didSet { contentTintColor = isEnabled ? .linkColor : .disabledControlTextColor }
    }
}

@MainActor
func makeLinkButton(_ title: String, target: AnyObject, action: Selector) -> NSButton {
    let button = LinkButton(frame: .zero)
    button.setButtonType(.momentaryPushIn)
    button.title = title
    button.target = target
    button.action = action
    button.isBordered = false
    button.bezelStyle = .badge
    button.font = .preferredFont(forTextStyle: .caption1)
    button.contentTintColor = .linkColor
    button.setContentHuggingPriority(.required, for: .horizontal)
    return button
}

// MARK: - Boxes & banners

/// Wraps `content` in a rounded, tinted container drawn by an `NSBox`.
///
/// The box is a chrome layer pinned behind the content rather than its
/// `box.contentView`: a custom `NSBox` sizes its content view through the legacy
/// autoresizing path and never derives an intrinsic height from Auto Layout
/// content, so it collapses. Pinning the content as a sibling makes the
/// container's size a pure function of the content's own constraints.
@MainActor
func makeGroupedFormBox(
    content: NSView,
    fill: NSColor,
    border: NSColor,
    borderWidth: CGFloat,
    cornerRadius: CGFloat,
    padding: CGFloat
) -> NSView {
    let box = NSBox()
    box.boxType = .custom
    box.titlePosition = .noTitle
    box.cornerRadius = cornerRadius
    box.borderWidth = borderWidth
    box.fillColor = fill
    box.borderColor = border

    let container = NSView()
    container.addFullSizeSubview(box)

    content.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(content)
    NSLayoutConstraint.activate([
        content.topAnchor.constraint(equalTo: container.topAnchor, constant: padding),
        content.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -padding),
        content.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: padding),
        content.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -padding),
    ])
    return container
}

@MainActor
func makeGroupedFormBanner(
    symbolName: String,
    tint: NSColor,
    message: String,
    trailingButtons: [NSButton] = []
) -> NSView {
    let icon = NSImageView(image: .systemSymbol(symbolName, accessibilityDescription: ""))
    icon.contentTintColor = tint
    icon.setContentHuggingPriority(.required, for: .horizontal)
    icon.setContentCompressionResistancePriority(.required, for: .horizontal)

    let label = NSTextField(wrappingLabelWithString: message)
    label.font = .preferredFont(forTextStyle: .callout)
    label.maximumNumberOfLines = 0
    label.isSelectable = false

    let spacer = NSView()
    spacer.translatesAutoresizingMaskIntoConstraints = false
    spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

    var views: [NSView] = [icon, label, spacer]
    for button in trailingButtons {
        button.controlSize = .small
        button.setContentHuggingPriority(.required, for: .horizontal)
        views.append(button)
    }

    let row = NSStackView(views: views)
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = Spacing.standard

    return makeGroupedFormBox(
        content: row,
        fill: tint.withAlphaComponent(0.1),
        border: tint.withAlphaComponent(0.3),
        borderWidth: 1,
        cornerRadius: 8,
        padding: 10
    )
}
