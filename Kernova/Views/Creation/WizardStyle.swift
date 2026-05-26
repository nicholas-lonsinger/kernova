import AppKit

/// Shared design tokens for the VM creation wizard.
///
/// Mirrors the `CalloutStyle` pattern: a token `enum` plus free `make*`
/// factory functions, so every wizard step view controller looks consistent
/// without inheriting from a shared base class. Each step is its own concrete
/// `NSViewController` that owns its full `loadView()`.
///
/// These tokens are wizard-scoped on purpose — do **not** reach for
/// `CalloutStyle` (which is tuned for narrow 340pt popovers).
enum WizardStyle {
    /// Fixed wizard sheet width.
    static let width: CGFloat = 720

    /// Fixed wizard sheet height.
    static let height: CGFloat = 540

    /// Gap from the window edge to a step's view.
    ///
    /// Also the distance to the vertical scroller on scrolling steps. Kept small
    /// so the scrollbar sits close to the window edge; steps inset their content
    /// symmetrically the rest of the way via ``contentSideInset``.
    static let edgeInset: CGFloat = 10

    /// Symmetric inset from a step's view to its content, applied on both sides.
    ///
    /// On scrolling steps it also serves as the clearance between content and the
    /// scroller (which sits at the step view's trailing edge), so content stays
    /// centered — same left/right margin — whether or not the step is scrolling.
    static let contentSideInset: CGFloat = 16

    /// Inset from the content area edges to a step's content.
    static let contentPadding: CGFloat = 20

    /// Inset around the chrome rows (step indicator, navigation bar).
    static let chromePadding: CGFloat = 20

    /// Font for a step's leading title row.
    ///
    /// Equivalent to SwiftUI's `.title2` + `.fontWeight(.semibold)`.
    static var titleFont: NSFont {
        .systemFont(ofSize: NSFont.preferredFont(forTextStyle: .title2).pointSize, weight: .semibold)
    }

    /// Font for a step's explanatory subtitle row.
    static var subtitleFont: NSFont { .preferredFont(forTextStyle: .body) }
}

/// Builds a left-aligned, semibold heading label for the top of a wizard step.
@MainActor
func makeWizardTitle(_ text: String) -> NSTextField {
    let label = NSTextField(labelWithString: text)
    label.font = WizardStyle.titleFont
    label.alignment = .left
    label.lineBreakMode = .byWordWrapping
    label.maximumNumberOfLines = 0
    label.isSelectable = false
    return label
}

/// Builds a left-aligned, secondary, wrapping subtitle label for a wizard step.
@MainActor
func makeWizardSubtitle(_ text: String) -> NSTextField {
    let label = NSTextField(wrappingLabelWithString: text)
    label.font = WizardStyle.subtitleFont
    label.textColor = .secondaryLabelColor
    label.alignment = .left
    label.lineBreakMode = .byWordWrapping
    label.maximumNumberOfLines = 0
    label.isSelectable = false
    return label
}

// MARK: - Layout helpers

/// A clip view that reports itself flipped so its document view is anchored at
/// the top-left and scrolls downward.
///
/// Without this, `NSClipView`'s default bottom-left origin anchors short content
/// to the bottom of the viewport — and when content is marginally taller than
/// the viewport, the initial scroll position shows the bottom, clipping the top
/// (the step title) out of view.
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
private final class WizardScrollView: NSScrollView {
    override func tile() {
        super.tile()
        contentView.frame = bounds
    }
}

/// Wraps `content` in a borderless, autohiding vertical scroll view.
///
/// `content` is hosted inside a full-width document view and inset symmetrically
/// by ``contentSideInset`` on both sides, so it stays horizontally centered. The
/// document view fills the clip view's width on purpose: pinning it *narrower*
/// than the clip makes `NSClipView` offset its bounds origin to align the
/// under-sized document, which scrolls the content sideways and defeats the
/// inset. Height flows from `content` (no bottom pin), so with the flipped clip
/// view short content sits at the top and tall content scrolls.
///
/// Used by the taller wizard steps, whose content can exceed the fixed sheet
/// height. Callers add their own per-subview width constraints against `content`.
@MainActor
func makeWizardScrollView(documentView content: NSView) -> NSScrollView {
    let scrollView = WizardScrollView()
    scrollView.contentView = FlippedClipView()
    // Overlay style plus the WizardScrollView full-width clip view keep the
    // scroller floating over the right margin instead of reserving width, so
    // the centered content isn't shifted.
    scrollView.scrollerStyle = .overlay
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
    let inset = WizardStyle.contentSideInset
    NSLayoutConstraint.activate([
        // Document view fills the clip width; its height flows from the content.
        docView.topAnchor.constraint(equalTo: clip.topAnchor),
        docView.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
        docView.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
        docView.widthAnchor.constraint(equalTo: clip.widthAnchor),
        // Content inset symmetrically within the document view → centered.
        content.topAnchor.constraint(equalTo: docView.topAnchor),
        content.bottomAnchor.constraint(equalTo: docView.bottomAnchor),
        content.leadingAnchor.constraint(equalTo: docView.leadingAnchor, constant: inset),
        content.trailingAnchor.constraint(equalTo: docView.trailingAnchor, constant: -inset),
    ])
    return scrollView
}

// MARK: - Form atoms

/// Width of the right-aligned label column in wizard forms.
///
/// Labels align and the controls/values all start at a common x — the native
/// macOS aligned-form layout, as in System Settings.
let wizardFormLabelColumnWidth: CGFloat = 130

/// Builds an aligned form row: a fixed-width, right-aligned label paired with a
/// trailing control or value that starts at the shared column edge.
///
/// Rows are left-aligned (intrinsic width) in the step's stack, so the label
/// column lines up across rows. Use `.firstBaseline` for value/text rows and
/// `.centerY` for control rows (steppers, switches, popups).
@MainActor
func makeWizardFormRow(
    _ labelText: String, control: NSView, alignment: NSLayoutConstraint.Attribute = .firstBaseline
) -> NSStackView {
    let label = NSTextField(labelWithString: labelText)
    label.font = .preferredFont(forTextStyle: .body)
    label.alignment = .right
    label.isSelectable = false
    label.setContentHuggingPriority(.required, for: .horizontal)
    label.widthAnchor.constraint(equalToConstant: wizardFormLabelColumnWidth).isActive = true

    let row = NSStackView(views: [label, control])
    row.orientation = .horizontal
    row.alignment = alignment
    row.spacing = 12
    return row
}

// MARK: - Grouped cards (System Settings style)

/// Builds a 1pt, appearance-adaptive horizontal hairline for separating card rows.
@MainActor
func makeWizardHairline() -> NSView {
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
func makeWizardCardRow(
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
func makeWizardCard(rows: [NSView]) -> NSView {
    let content = NSStackView()
    content.orientation = .vertical
    content.alignment = .leading
    content.spacing = 10
    content.translatesAutoresizingMaskIntoConstraints = false

    for (index, row) in rows.enumerated() {
        if index > 0 { content.addArrangedSubview(makeWizardHairline()) }
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

/// Indent (radio circle + gap) so a radio option's description aligns under its
/// title.
let wizardRadioDescriptionIndent: CGFloat = 20

/// Lays out a caller-supplied radio button as a native option row: a leading
/// symbol icon, the radio (with its title), and a secondary description wrapped
/// beneath the title.
///
/// The caller creates the radio (so it owns target/action and can track it for
/// selection state); this only arranges the icon/description around it.
@MainActor
func makeWizardRadioOption(radio: NSButton, iconSymbol: String, description descriptionText: String)
    -> NSView
{
    radio.font = .preferredFont(forTextStyle: .body)
    radio.translatesAutoresizingMaskIntoConstraints = false

    let icon = NSImageView(image: .systemSymbol(iconSymbol, accessibilityDescription: ""))
    icon.symbolConfiguration = NSImage.SymbolConfiguration(textStyle: .title3)
    icon.contentTintColor = .secondaryLabelColor
    icon.translatesAutoresizingMaskIntoConstraints = false
    icon.setContentHuggingPriority(.required, for: .horizontal)

    let description = NSTextField(wrappingLabelWithString: descriptionText)
    description.font = .preferredFont(forTextStyle: .subheadline)
    description.textColor = .secondaryLabelColor
    description.maximumNumberOfLines = 0
    description.isSelectable = false
    description.translatesAutoresizingMaskIntoConstraints = false

    let option = NSView()
    option.addSubview(icon)
    option.addSubview(radio)
    option.addSubview(description)
    NSLayoutConstraint.activate([
        icon.leadingAnchor.constraint(equalTo: option.leadingAnchor),
        icon.centerYAnchor.constraint(equalTo: radio.centerYAnchor),
        icon.widthAnchor.constraint(equalToConstant: 22),

        radio.topAnchor.constraint(equalTo: option.topAnchor),
        radio.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
        radio.trailingAnchor.constraint(lessThanOrEqualTo: option.trailingAnchor),

        description.topAnchor.constraint(equalTo: radio.bottomAnchor, constant: 2),
        description.leadingAnchor.constraint(
            equalTo: radio.leadingAnchor, constant: wizardRadioDescriptionIndent),
        description.trailingAnchor.constraint(equalTo: option.trailingAnchor),
        description.bottomAnchor.constraint(equalTo: option.bottomAnchor),
    ])
    return option
}

/// Builds a primary body label for a form row (the leading "Name"-style label).
@MainActor
func makeWizardFormLabel(_ text: String) -> NSTextField {
    let label = NSTextField(labelWithString: text)
    label.font = .preferredFont(forTextStyle: .body)
    label.isSelectable = false
    return label
}

/// Builds a secondary value label for a form/review row (the trailing value).
@MainActor
func makeWizardValueLabel(_ text: String) -> NSTextField {
    let label = NSTextField(labelWithString: text)
    label.font = .preferredFont(forTextStyle: .body)
    label.textColor = .secondaryLabelColor
    label.lineBreakMode = .byTruncatingMiddle
    label.isSelectable = false
    return label
}

/// Builds a secondary section-header label for a grouped form section.
@MainActor
func makeWizardSectionHeader(_ text: String) -> NSTextField {
    let label = NSTextField(labelWithString: text)
    label.font = .preferredFont(forTextStyle: .subheadline)
    label.textColor = .secondaryLabelColor
    label.isSelectable = false
    return label
}

/// Builds a secondary, wrapping caption label (explanatory footnote under a row).
@MainActor
func makeWizardCaption(_ text: String) -> NSTextField {
    let label = NSTextField(wrappingLabelWithString: text)
    label.font = .preferredFont(forTextStyle: .caption1)
    label.textColor = .secondaryLabelColor
    label.maximumNumberOfLines = 0
    label.isSelectable = false
    return label
}

/// Builds a borderless, link-styled push button (caption font, link color).
@MainActor
func makeWizardLinkButton(_ title: String, target: AnyObject, action: Selector) -> NSButton {
    let button = NSButton(title: title, target: target, action: action)
    button.isBordered = false
    button.bezelStyle = .inline
    button.font = .preferredFont(forTextStyle: .caption1)
    button.contentTintColor = .linkColor
    button.setContentHuggingPriority(.required, for: .horizontal)
    return button
}

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
private func makeWizardBox(
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

/// Builds the IPSW path badge: a doc icon, a middle-truncating path, and a
/// trailing "Change…" button, in a subtle rounded container.
@MainActor
func makeWizardPathBadge(path: String, changeButton: NSButton) -> NSView {
    let icon = NSImageView(image: .systemSymbol("doc.fill", accessibilityDescription: ""))
    icon.contentTintColor = .secondaryLabelColor
    icon.setContentHuggingPriority(.required, for: .horizontal)

    let pathLabel = NSTextField(labelWithString: wizardAbbreviateWithTilde(path))
    pathLabel.font = .preferredFont(forTextStyle: .caption1)
    pathLabel.lineBreakMode = .byTruncatingMiddle
    pathLabel.maximumNumberOfLines = 1
    pathLabel.isSelectable = false
    pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    let row = NSStackView(views: [icon, pathLabel, changeButton])
    row.orientation = .horizontal
    row.alignment = .firstBaseline
    row.spacing = 6

    return makeWizardBox(
        content: row,
        fill: .secondaryLabelColor.withAlphaComponent(0.1),
        border: .clear,
        borderWidth: 0,
        cornerRadius: 6,
        padding: 8
    )
}

/// Builds a tinted warning/info banner: a symbol, a message, and optional
/// trailing action buttons, in a rounded tinted container.
@MainActor
func makeWizardBanner(
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

    return makeWizardBox(
        content: row,
        fill: tint.withAlphaComponent(0.1),
        border: tint.withAlphaComponent(0.3),
        borderWidth: 1,
        cornerRadius: 8,
        padding: 10
    )
}

/// Abbreviates a path with a leading `~` when it lives under the user's home
/// directory.
///
/// Matches the SwiftUI predecessor's manual logic (keyed on
/// `homeDirectoryForCurrentUser`) rather than `NSString.abbreviatingWithTildeInPath`,
/// which keys on `NSHomeDirectory()` and can differ for a sandboxed app.
func wizardAbbreviateWithTilde(_ path: String) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
    if path.hasPrefix(home) {
        return "~" + path.dropFirst(home.count)
    }
    return path
}
