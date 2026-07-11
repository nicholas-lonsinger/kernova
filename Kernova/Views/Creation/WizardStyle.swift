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

// MARK: - Buttons & badges

// The borderless link-styled button used here lives in `GroupedFormStyle` as
// `makeLinkButton(_:target:action:)`, shared with the Detail layer.

/// Builds the IPSW path badge: a doc icon, a middle-truncating path, and an
/// optional trailing "Change…" button, in a subtle rounded container.
@MainActor
func makeWizardPathBadge(path: String, changeButton: NSButton? = nil) -> NSView {
    let icon = NSImageView(image: .systemSymbol("doc.fill", accessibilityDescription: ""))
    icon.contentTintColor = .secondaryLabelColor
    icon.setContentHuggingPriority(.required, for: .horizontal)

    let pathLabel = NSTextField(labelWithString: wizardAbbreviateWithTilde(path))
    pathLabel.font = .preferredFont(forTextStyle: .caption1)
    pathLabel.lineBreakMode = .byTruncatingMiddle
    pathLabel.maximumNumberOfLines = 1
    pathLabel.isSelectable = false
    pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    let row = NSStackView(views: [icon, pathLabel] + (changeButton.map { [$0] } ?? []))
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

/// Abbreviates a path with a leading `~` when it lives under a home
/// directory the user would read as "mine".
///
/// Tries the process home first — under the App Sandbox that is the
/// container, so container-internal paths like the default IPSW destination
/// (whose `Downloads` component is the container's symlink to the real
/// folder) read as `~/Downloads/…` — then the real user home (`getpwuid`),
/// so panel-picked files outside the container abbreviate too. The process
/// home is checked first because it is the longer, more specific prefix
/// (the container lives inside the real home). Unsandboxed, the two are
/// identical. Manual logic rather than
/// `NSString.abbreviatingWithTildeInPath`, which keys only on
/// `NSHomeDirectory()`.
func wizardAbbreviateWithTilde(_ path: String) -> String {
    let processHome = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
    for home in [processHome, realUserHomePath] where path.hasPrefix(home) {
        return "~" + path.dropFirst(home.count)
    }
    return path
}

/// The user's real home directory, which differs from the process home (the
/// sandbox container) in a sandboxed app.
private var realUserHomePath: String {
    guard let dir = getpwuid(getuid())?.pointee.pw_dir else {
        return FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
    }
    return String(cString: dir)
}
