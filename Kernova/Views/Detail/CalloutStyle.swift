import AppKit

/// Shared design tokens for callout-style popovers.
///
/// All popover content view controllers across the app (missing-attachment,
/// info, create-disk, agent-status, …) should reference these constants
/// when building their layout. Visual consistency comes from shared tokens,
/// **not** from a shared container class — each popover is its own concrete
/// `NSViewController` that owns its full `loadView()`.
enum CalloutStyle {
    /// Standard popover content width.
    ///
    /// Matches the SwiftUI predecessor.
    static let width: CGFloat = 340

    /// Inset from popover edges to the content stack.
    static let padding: CGFloat = 16

    /// Vertical spacing between rows in the content stack.
    static let verticalSpacing: CGFloat = 10

    /// Width available to body content inside the padded callout (`width - 2 * padding`).
    ///
    /// Use for `preferredMaxLayoutWidth` on wrapping labels so they grow
    /// vertically instead of horizontally.
    static let bodyWidth: CGFloat = width - padding * 2

    /// Font for headline rows (e.g. the bold title at the top of a callout).
    static var headlineFont: NSFont { .preferredFont(forTextStyle: .headline) }

    /// Font for body rows.
    static var bodyFont: NSFont { .preferredFont(forTextStyle: .callout) }

    /// Default body-row text color.
    ///
    /// Use `.labelColor` for the lead body row, `.secondaryLabelColor`
    /// (this default) for explanatory tail rows.
    static let bodyColor: NSColor = .secondaryLabelColor
}

/// Builds a headline `NSTextField` configured for a callout's leading row.
///
/// Used by every concrete callout popover content view controller so they
/// look identical without inheriting from a shared base class.
@MainActor
func makeCalloutHeadline(_ text: String) -> NSTextField {
    let label = NSTextField(labelWithString: text)
    label.font = CalloutStyle.headlineFont
    label.lineBreakMode = .byWordWrapping
    label.maximumNumberOfLines = 0
    label.preferredMaxLayoutWidth = CalloutStyle.bodyWidth
    return label
}

/// Builds a wrapping body `NSTextField` configured for a callout row.
///
/// - Parameters:
///   - text: Row text content.
///   - color: Pass `.labelColor` for the primary body row (lead sentence
///     after the headline), `.secondaryLabelColor` (the default) for
///     explanatory tail rows.
/// - Returns: A configured `NSTextField` ready to add to an `NSStackView`.
@MainActor
func makeCalloutBody(_ text: String, color: NSColor = CalloutStyle.bodyColor) -> NSTextField {
    let label = NSTextField(wrappingLabelWithString: text)
    label.font = CalloutStyle.bodyFont
    label.textColor = color
    label.preferredMaxLayoutWidth = CalloutStyle.bodyWidth
    label.lineBreakMode = .byWordWrapping
    label.maximumNumberOfLines = 0
    return label
}

/// Builds a monospaced, selectable `NSTextField` for code snippets (shell
/// commands, paths, identifiers the user is expected to copy).
///
/// Matches the SwiftUI predecessor's `.font(.system(.callout, design: .monospaced))`
/// plus `.textSelection(.enabled)` for the same intent — the snippet
/// remains legible and copy-able inside the popover.
@MainActor
func makeCalloutCode(_ text: String) -> NSTextField {
    let label = NSTextField(wrappingLabelWithString: text)
    label.font = .monospacedSystemFont(
        ofSize: NSFont.preferredFont(forTextStyle: .callout).pointSize,
        weight: .regular
    )
    label.textColor = .labelColor
    label.preferredMaxLayoutWidth = CalloutStyle.bodyWidth
    label.lineBreakMode = .byCharWrapping
    label.maximumNumberOfLines = 0
    label.isSelectable = true
    return label
}
