import AppKit

/// Wizard-scoped design tokens and atom factories for the VM creation wizard.
///
/// The generic grouped-form atoms (cards, rows, banners, scrolling) live in
/// `GroupedFormStyle` and are shared with the settings pane. The tokens here are
/// wizard-scoped on purpose and do **not** reach for `CalloutStyle`, which is
/// tuned for narrow 340pt popovers.
enum WizardStyle {
    static let width: CGFloat = 720

    static let height: CGFloat = 540

    /// Symmetric inset from a step's view to its content, applied on both sides.
    ///
    /// Used by steps that lay out their content manually, so the margin matches
    /// the scrolling steps.
    static let contentSideInset: CGFloat = 16

    /// Inset from the content area edges to a step's content.
    static let contentPadding: CGFloat = 20

    /// Inset around the chrome rows (step indicator, navigation bar).
    static let chromePadding: CGFloat = 20

    /// Font for a step's leading title row.
    static var titleFont: NSFont {
        .systemFont(ofSize: NSFont.preferredFont(forTextStyle: .title2).pointSize, weight: .semibold)
    }

    /// Font for a step's explanatory subtitle row.
    static var subtitleFont: NSFont { .preferredFont(forTextStyle: .body) }
}

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
/// The caller creates the radio, so it owns target/action and can track it for
/// selection state; this only arranges the icon/description around it.
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

/// Builds the IPSW path badge: a doc icon, a middle-truncating path, and an
/// optional trailing "Change…" button, in a subtle rounded container.
@MainActor
func makeWizardPathBadge(path: String, changeButton: NSButton? = nil) -> NSView {
    makeWizardBadge(
        symbolName: "doc.fill",
        text: wizardAbbreviateWithTilde(path),
        lineBreakMode: .byTruncatingMiddle,
        trailingButton: changeButton
    )
}

/// Builds a wizard badge: a symbol, one or two lines of caption text, and an
/// optional trailing button, in a subtle rounded container.
///
/// The two-line form exists so a download source states its image and its
/// destination in one badge. As two separate badges they cost more height than
/// the fixed-size wizard sheet has once there are four sources to list.
@MainActor
func makeWizardBadge(
    symbolName: String,
    text: String,
    secondaryText: String? = nil,
    lineBreakMode: NSLineBreakMode = .byTruncatingTail,
    trailingButton: NSButton? = nil
) -> NSView {
    let icon = NSImageView(image: .systemSymbol(symbolName, accessibilityDescription: ""))
    icon.contentTintColor = .secondaryLabelColor
    icon.setContentHuggingPriority(.required, for: .horizontal)

    let label = NSTextField(labelWithString: text)
    label.font = .preferredFont(forTextStyle: .caption1)
    label.lineBreakMode = lineBreakMode
    label.maximumNumberOfLines = 1
    label.isSelectable = false
    label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    let textContent: NSView
    if let secondaryText {
        let secondary = NSTextField(labelWithString: secondaryText)
        secondary.font = .preferredFont(forTextStyle: .caption2)
        secondary.textColor = .tertiaryLabelColor
        secondary.lineBreakMode = .byTruncatingMiddle
        secondary.maximumNumberOfLines = 1
        secondary.isSelectable = false
        secondary.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let column = NSStackView(views: [label, secondary])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = Spacing.hairline
        textContent = column
    } else {
        textContent = label
    }

    let row = NSStackView(views: [icon, textContent] + (trailingButton.map { [$0] } ?? []))
    row.orientation = .horizontal
    row.alignment = secondaryText == nil ? .firstBaseline : .centerY
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

/// Renders a size the wizard only knows approximately.
///
/// A Linux catalog entry records the size of the image the catalog was
/// generated against; the file the mirror serves at download time is a near
/// neighbour of it, so the wizard never states it as exact.
func wizardApproximateSize(_ bytes: UInt64) -> String {
    "About \(DataFormatters.formatBytes(bytes))"
}

/// States what a user-supplied image URL's download will be checked against.
///
/// The one phrase the boot step's badge and the Review step's row both use, so
/// a pick reads the same at both.
func wizardVerificationSummary(sha256: String?) -> String {
    sha256 == nil ? "Not verified" : "Verified with your checksum"
}

/// Abbreviates a path with a leading `~` when it lives under a home
/// directory the user would read as "mine".
///
/// Tries the process home first — under the App Sandbox that is the container,
/// the longer and more specific prefix — then the real user home (`getpwuid`),
/// so panel-picked files outside the container abbreviate too. Manual logic
/// rather than `NSString.abbreviatingWithTildeInPath`, which keys only on
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
