import AppKit

/// Wizard-scoped design tokens and atom factories for the VM creation wizard.
///
/// Mirrors the `CalloutStyle` pattern: a token `enum` plus free `make*`
/// factory functions, so every wizard step view controller looks consistent
/// without inheriting from a shared base class. Each step is its own concrete
/// `NSViewController` that owns its full `loadView()`.
///
/// The generic grouped-form atoms (cards, rows, banners, scrolling) live in
/// `GroupedFormStyle` and are shared with the settings pane. The tokens and
/// factories here are wizard-scoped on purpose — sheet dimensions, the step
/// title/subtitle, radio options, and the IPSW path badge — and do **not**
/// reach for `CalloutStyle` (which is tuned for narrow 340pt popovers).
enum WizardStyle {
    /// Fixed wizard sheet width.
    static let width: CGFloat = 720

    /// Fixed wizard sheet height.
    static let height: CGFloat = 540

    /// Symmetric inset from a step's view to its content, applied on both sides.
    ///
    /// Used by steps that lay out their content manually (rather than through
    /// ``makeGroupedFormScrollView``) so the margin matches the scrolling steps.
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

// MARK: - Radio options

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
    radio.font = Typography.body
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

// MARK: - Scroll indicator

/// A passive overlay container that lets clicks and scroll-wheel events fall
/// through to the content beneath.
///
/// Used for the "more below" scroll indicator so the chevron never intercepts the
/// scrolling it's prompting.
final class WizardHitTransparentView: NSView {
    // RATIONALE: Returning nil from hitTest removes the whole subtree from mouse/
    // scroll event routing, so events reach the scroll view layered beneath the
    // overlay — the standard AppKit pattern for a non-interactive overlay.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Builds the "more content below — scroll to continue" indicator: a `chevron.down`
/// on a grey disc, sized for the bottom-center of a scrolling wizard step.
///
/// The disc is an `NSBox` so its fill/border are `NSColor`s that adapt to light/dark
/// automatically; the fill sits well above the grouped-form cards' faint tint so the
/// disc reads against the form content, and a hairline border defines its edge. The
/// returned view is hit-transparent (see ``WizardHitTransparentView``), so the caller
/// can layer it over the step's scroll view without blocking scrolling. The caller
/// owns positioning and show/hide (the wizard shell fades it based on
/// `VMCreationViewModel.currentStepScrollGateSatisfied`).
@MainActor
func makeWizardScrollIndicator() -> NSView {
    let diameter: CGFloat = 28

    let disc = NSBox()
    disc.boxType = .custom
    disc.titlePosition = .noTitle
    disc.cornerRadius = diameter / 2
    disc.fillColor = .secondaryLabelColor.withAlphaComponent(0.2)
    disc.borderWidth = 1
    disc.borderColor = .separatorColor

    let chevron = NSImageView(
        image: .systemSymbol(
            "chevron.down", accessibilityDescription: "More content below — scroll to continue"))
    chevron.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
    chevron.contentTintColor = .secondaryLabelColor
    chevron.translatesAutoresizingMaskIntoConstraints = false

    // RATIONALE: a custom NSBox sizes a `contentView` through the legacy autoresizing
    // path and collapses, so it's pinned as a chrome layer behind the chevron sibling
    // (the same pattern as `makeGroupedFormBox`).
    let container = WizardHitTransparentView()
    container.translatesAutoresizingMaskIntoConstraints = false
    container.addFullSizeSubview(disc)
    container.addSubview(chevron)

    NSLayoutConstraint.activate([
        container.widthAnchor.constraint(equalToConstant: diameter),
        container.heightAnchor.constraint(equalToConstant: diameter),
        chevron.centerXAnchor.constraint(equalTo: container.centerXAnchor),
        chevron.centerYAnchor.constraint(equalTo: container.centerYAnchor),
    ])
    return container
}

/// Height of the bottom fade strip (see ``WizardScrollFadeView``).
let wizardScrollFadeHeight: CGFloat = 36

/// A passive bottom-edge fade for a scrolling wizard step.
///
/// The content dissolves into the sheet background as it nears the bottom — a soft
/// "more below" cue that complements the chevron. Drawn with an `NSGradient` in
/// `draw(_:)` (re-evaluated under the current appearance, so it adapts to light/dark
/// without `CGColor` juggling) and hit-transparent so it never blocks scrolling.
final class WizardScrollFadeView: NSView {
    override var isOpaque: Bool { false }

    // RATIONALE: nil from hitTest drops the view from event routing so the scroll
    // view beneath still scrolls under the cursor — same pattern as
    // ``WizardHitTransparentView``.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let opaque = NSColor.windowBackgroundColor
        let clear = opaque.withAlphaComponent(0)
        // 90° runs bottom→top: opaque background at the bottom edge fading to clear,
        // so content shows through above and dissolves into the sheet at the bottom.
        NSGradient(starting: opaque, ending: clear)?.draw(in: bounds, angle: 90)
    }
}

// MARK: - Buttons & badges

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
    row.spacing = Spacing.small

    return makeGroupedFormBox(
        content: row,
        fill: .secondaryLabelColor.withAlphaComponent(0.1),
        border: .clear,
        borderWidth: 0,
        cornerRadius: 6,
        padding: 8
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
