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
