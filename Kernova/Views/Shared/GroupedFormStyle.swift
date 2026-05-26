import AppKit

/// Shared design tokens and atom factories for the native macOS *grouped form*
/// look — rounded, subtly-filled cards with hairline-separated rows, section
/// headers, captions, and tinted banners.
///
/// Mirrors the `CalloutStyle` / `WizardStyle` pattern: a token `enum` plus free
/// `make*` factory functions, so every view controller composing a grouped form
/// looks consistent without inheriting from a shared base class.
///
/// These atoms are deliberately context-neutral: both the creation wizard
/// (`WizardStyle` builds on them) and the VM settings pane consume them. Tokens
/// that are specific to one surface (e.g. the wizard's fixed sheet dimensions)
/// stay in that surface's own style file.
enum GroupedFormStyle {
    /// Symmetric inset from a scrolling form's viewport to its content, applied
    /// on both sides so content stays horizontally centered — and, on scrolling
    /// forms, also the clearance between content and the overlay scroller at the
    /// trailing edge.
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
private final class FlippedClipView: NSClipView {
    override var isFlipped: Bool { true }
}

/// A scroll view that keeps its clip view spanning the full width even when the
/// system shows always-on (legacy) scroll bars.
///
/// `scrollerStyle = .overlay` alone isn't honored when the user sets "Show
/// scroll bars: Always", so a legacy scroller would reserve width on the right,
/// shrink the clip view, and shift symmetrically-inset content off-center.
/// Forcing the clip view to fill `bounds` in `tile()` makes the scroller overlay
/// the right content margin instead — content stays centered, and the margin
/// inset keeps it clear of the floating scroller.
private final class GroupedFormScrollView: NSScrollView {
    override func tile() {
        super.tile()
        contentView.frame = bounds
    }
}

/// Wraps `content` in a borderless, autohiding vertical scroll view.
///
/// `content` is hosted inside a full-width document view and inset symmetrically
/// by ``GroupedFormStyle/contentSideInset`` on both sides, so it stays
/// horizontally centered, and by `topInset` / `bottomInset` so a scrolling form
/// can keep a margin from the viewport's top and/or bottom edges. The
/// document view fills the clip view's width on purpose: pinning it *narrower*
/// than the clip makes `NSClipView` offset its bounds origin to align the
/// under-sized document, which scrolls the content sideways and defeats the
/// inset. With the flipped clip view short content sits at the top and tall
/// content scrolls. Callers add their own per-subview width constraints against
/// `content`.
@MainActor
func makeGroupedFormScrollView(
    documentView content: NSView,
    topInset: CGFloat = 0,
    bottomInset: CGFloat = 0,
    overlaysScroller: Bool = true
) -> NSScrollView {
    // When `overlaysScroller` is true (the wizard), force the clip view full
    // width (via `GroupedFormScrollView.tile()`) and overlay scrollers so the
    // scroller floats over the side margin and centered content never shifts —
    // even with "Always show scroll bars" on. When false (the settings pane),
    // use a stock scroll view whose scroller style follows the system: a legacy
    // always-on scroller reserves a gutter (so the trailing margin grows when
    // it shows) while overlay scrollers float and auto-hide.
    let scrollView: NSScrollView = overlaysScroller ? GroupedFormScrollView() : NSScrollView()
    scrollView.contentView = FlippedClipView()
    if overlaysScroller {
        scrollView.scrollerStyle = .overlay
    }
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
        // Content inset symmetrically within the document view → centered,
        // with optional top/bottom margins so scrolling content clears the edges.
        content.topAnchor.constraint(equalTo: docView.topAnchor, constant: topInset),
        content.bottomAnchor.constraint(equalTo: docView.bottomAnchor, constant: -bottomInset),
        content.leadingAnchor.constraint(equalTo: docView.leadingAnchor, constant: inset),
        content.trailingAnchor.constraint(equalTo: docView.trailingAnchor, constant: -inset),
    ])
    return scrollView
}

// MARK: - Grouped cards (System Settings style)

/// Builds a 1pt, appearance-adaptive horizontal hairline for separating card rows.
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
/// should stretch to fill the row (a text field).
@MainActor
func makeGroupedFormCardRow(
    _ labelText: String,
    control: NSView,
    alignment: NSLayoutConstraint.Attribute = .centerY,
    fillsControl: Bool = false
) -> NSView {
    let label = NSTextField(labelWithString: labelText)
    label.font = .preferredFont(forTextStyle: .body)
    label.isSelectable = false
    label.setContentHuggingPriority(.defaultHigh, for: .horizontal)
    label.setContentCompressionResistancePriority(.required, for: .horizontal)

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
    row.spacing = 8
    return row
}

/// Wraps rows in a rounded, subtly-filled card with hairline separators between
/// them — the native macOS grouped-form look.
@MainActor
func makeGroupedFormCard(rows: [NSView]) -> NSView {
    let content = NSStackView()
    content.orientation = .vertical
    content.alignment = .leading
    content.spacing = 10
    content.translatesAutoresizingMaskIntoConstraints = false

    for (index, row) in rows.enumerated() {
        if index > 0 { content.addArrangedSubview(makeGroupedFormHairline()) }
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

// MARK: - Labels

/// Builds a secondary value label for a form/review row (the trailing value).
@MainActor
func makeGroupedFormValueLabel(_ text: String) -> NSTextField {
    let label = NSTextField(labelWithString: text)
    label.font = .preferredFont(forTextStyle: .body)
    label.textColor = .secondaryLabelColor
    label.lineBreakMode = .byTruncatingMiddle
    label.isSelectable = false
    return label
}

/// Builds a secondary section-header label for a grouped form section.
@MainActor
func makeGroupedFormSectionHeader(_ text: String) -> NSTextField {
    let label = NSTextField(labelWithString: text)
    label.font = .preferredFont(forTextStyle: .subheadline)
    label.textColor = .secondaryLabelColor
    label.isSelectable = false
    return label
}

/// Builds a secondary, wrapping caption label (explanatory footnote under a row).
@MainActor
func makeGroupedFormCaption(_ text: String) -> NSTextField {
    let label = NSTextField(wrappingLabelWithString: text)
    label.font = .preferredFont(forTextStyle: .caption1)
    label.textColor = .secondaryLabelColor
    label.maximumNumberOfLines = 0
    label.isSelectable = false
    return label
}

// MARK: - Boxes & banners

/// Wraps `content` in a rounded, tinted container drawn by an `NSBox`.
///
/// The `NSBox` draws its `fillColor`/`borderColor` (`NSColor`s) and adapts to
/// light/dark automatically — no layer-backed `CGColor` juggling or
/// `viewDidChangeEffectiveAppearance` override needed. It is used purely as a
/// chrome layer pinned behind the content rather than via `box.contentView`: a
/// custom `NSBox` sizes its content view through the legacy autoresizing path
/// and never derives an intrinsic height from Auto Layout content, so it
/// collapses. Pinning the content as a sibling makes the container's size a
/// pure function of the content's own constraints.
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

/// Builds a tinted warning/info banner: a symbol, a message, and optional
/// trailing action buttons, in a rounded tinted container.
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
    row.spacing = 8

    return makeGroupedFormBox(
        content: row,
        fill: tint.withAlphaComponent(0.1),
        border: tint.withAlphaComponent(0.3),
        borderWidth: 1,
        cornerRadius: 8,
        padding: 10
    )
}
