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

    /// Vertical spacing between major blocks within a step (title / subtitle / body).
    static let sectionSpacing: CGFloat = 24

    /// Corner radius for selectable cards.
    static let cardCornerRadius: CGFloat = 12

    /// Fill opacity applied to the accent color behind a selected card.
    static let selectedFillOpacity: CGFloat = 0.1

    /// Font for a step's leading title row.
    ///
    /// Equivalent to SwiftUI's `.title2` + `.fontWeight(.semibold)`.
    static var titleFont: NSFont {
        .systemFont(ofSize: NSFont.preferredFont(forTextStyle: .title2).pointSize, weight: .semibold)
    }

    /// Font for a step's explanatory subtitle row.
    static var subtitleFont: NSFont { .preferredFont(forTextStyle: .body) }
}

/// Builds a centered, semibold title label for the top of a wizard step.
@MainActor
func makeWizardTitle(_ text: String) -> NSTextField {
    let label = NSTextField(labelWithString: text)
    label.font = WizardStyle.titleFont
    label.alignment = .center
    label.lineBreakMode = .byWordWrapping
    label.maximumNumberOfLines = 0
    label.isSelectable = false
    return label
}

/// Builds a centered, secondary, wrapping subtitle label for a wizard step.
@MainActor
func makeWizardSubtitle(_ text: String) -> NSTextField {
    let label = NSTextField(wrappingLabelWithString: text)
    label.font = WizardStyle.subtitleFont
    label.textColor = .secondaryLabelColor
    label.alignment = .center
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

/// Builds a full-width form row from a leading view and a trailing view.
///
/// A flexible spacer between them pins the leading label to the left edge and
/// the trailing control/value to the right edge — matching the SwiftUI grouped
/// `Form` rows. The caller pins the row's width to the enclosing form.
@MainActor
func makeWizardRow(leading: NSView, trailing: NSView) -> NSStackView {
    let spacer = NSView()
    spacer.translatesAutoresizingMaskIntoConstraints = false
    spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
    spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    let row = NSStackView(views: [leading, spacer, trailing])
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = 8
    return row
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
