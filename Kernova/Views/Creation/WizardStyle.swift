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

/// Resolves an `NSColor` to a `CGColor` in the given appearance.
///
/// Layer-backed views need explicit `CGColor`s, which do not auto-update when
/// the effective appearance changes between light and dark. Call this from
/// `viewDidChangeEffectiveAppearance()` (and on first build) so layer colors
/// track the current appearance.
@MainActor
func wizardResolvedCGColor(_ color: NSColor, in appearance: NSAppearance) -> CGColor {
    var resolved = color.cgColor
    appearance.performAsCurrentDrawingAppearance {
        resolved = color.cgColor
    }
    return resolved
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

/// Appends a leading-aligned, full-width section header row to a two-column form grid.
///
/// Adds an explicit empty second cell so the grid always has two columns to
/// merge — otherwise a header added as the grid's *first* row (before any
/// two-cell row exists) would index a column that doesn't exist yet and trap.
@MainActor
func addWizardSectionHeader(to grid: NSGridView, _ title: String) {
    let row = grid.addRow(with: [makeWizardSectionHeader(title), NSGridCell.emptyContentView])
    row.mergeCells(in: NSRange(location: 0, length: 2))
    row.cell(at: 0).xPlacement = .leading
    row.topPadding = 8
}

/// Appends a leading-aligned, full-width row spanning both columns of a form grid.
///
/// Like ``addWizardSectionHeader(to:_:)``, includes an explicit empty second
/// cell so the span is valid even when this is the grid's first row.
@MainActor
func addWizardSpanningRow(to grid: NSGridView, _ content: NSView) {
    let row = grid.addRow(with: [content, NSGridCell.emptyContentView])
    row.mergeCells(in: NSRange(location: 0, length: 2))
    row.cell(at: 0).xPlacement = .leading
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
