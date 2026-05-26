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
    ///
    /// Matches the SwiftUI predecessor's `.frame(width:)`.
    static let width: CGFloat = 550

    /// Fixed wizard sheet height.
    ///
    /// Matches the SwiftUI predecessor's `.frame(height:)`.
    static let height: CGFloat = 480

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

/// Wraps `documentView` in a borderless, autohiding vertical scroll view with
/// the clip-view content insets zeroed, and pins the document to the clip view
/// (width-matched; bottom at `.defaultHigh` so short content doesn't stretch).
///
/// Used by the taller wizard steps, whose content can exceed the fixed sheet
/// height. Callers add their own per-subview width constraints against
/// `documentView`.
@MainActor
func makeWizardScrollView(documentView: NSView) -> NSScrollView {
    let scrollView = NSScrollView()
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = false
    scrollView.borderType = .noBorder
    scrollView.drawsBackground = false
    scrollView.autohidesScrollers = true
    scrollView.automaticallyAdjustsContentInsets = false
    scrollView.contentInsets = NSEdgeInsetsZero
    scrollView.contentView.automaticallyAdjustsContentInsets = false
    scrollView.contentView.contentInsets = NSEdgeInsetsZero

    documentView.translatesAutoresizingMaskIntoConstraints = false
    scrollView.documentView = documentView

    let bottomPin = documentView.bottomAnchor.constraint(equalTo: scrollView.contentView.bottomAnchor)
    bottomPin.priority = .defaultHigh
    NSLayoutConstraint.activate([
        documentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
        documentView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
        documentView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
        documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
        bottomPin,
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

/// Wraps `content` in a rounded, tinted `NSBox`.
///
/// `NSBox` draws its `fillColor`/`borderColor` (`NSColor`s) and adapts to
/// light/dark automatically — no layer-backed `CGColor` juggling or
/// `viewDidChangeEffectiveAppearance` override needed.
@MainActor
private func makeWizardBox(
    content: NSView,
    fill: NSColor,
    border: NSColor,
    borderWidth: CGFloat,
    cornerRadius: CGFloat,
    padding: CGFloat
) -> NSBox {
    let box = NSBox()
    box.boxType = .custom
    box.titlePosition = .noTitle
    box.cornerRadius = cornerRadius
    box.borderWidth = borderWidth
    box.fillColor = fill
    box.borderColor = border
    box.contentViewMargins = NSSize(width: padding, height: padding)
    box.contentView = content
    return box
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
