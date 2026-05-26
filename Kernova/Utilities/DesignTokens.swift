import AppKit

/// Centralized design tokens for the AppKit UI.
///
/// These replace scattered magic numbers and ad-hoc `NSColor` choices so the
/// visual language lives in one place. They are the AppKit realization of the
/// design rhythm described in `SPEC.md`. Prefer these over inline literals when
/// building view hierarchies.

/// Standard inter-element spacing for `NSStackView`s and manual layout.
///
/// The names describe magnitude, not a single fixed purpose — the same value is
/// reused across contexts. Values are the deliberate tiers already in use across
/// the app; do not introduce off-scale values without a reason.
enum Spacing {
    /// Flush — no gap (`0`).
    static let none: CGFloat = 0
    /// Hairline gap between tightly-related text lines, e.g. title over subtitle (`2`).
    static let hairline: CGFloat = 2
    /// Tight grouping, e.g. a field and its stepper (`4`).
    static let tight: CGFloat = 4
    /// Small gap, e.g. icon-to-label or section-header elements (`6`).
    static let small: CGFloat = 6
    /// Standard inline / row spacing — the default (`8`).
    static let standard: CGFloat = 8
    /// Relaxed spacing for grouped card content rows (`10`).
    static let relaxed: CGFloat = 10
    /// Medium gap between grouped elements and containers (`12`).
    static let medium: CGFloat = 12
    /// Large gap between major wizard options / blocks (`16`).
    static let large: CGFloat = 16
    /// Spacing between settings-form sections (`18`).
    static let section: CGFloat = 18
    /// Major separation, e.g. install-progress hero blocks (`20`).
    static let major: CGFloat = 20
}

/// Status → color mapping shared by VM-status and guest-agent-status indicators.
///
/// Single source of truth for the semantic status palette so VM-status dots and
/// the agent-status icon stay visually consistent and can be retuned in one place.
enum StatusColor {
    /// Inert / not-yet-connected (stopped VM, agent waiting/connecting).
    static let inactive = NSColor.secondaryLabelColor
    /// Transitional or attention-needed (preparing/starting/saving/restoring/
    /// installing/cold-paused; agent outdated/unresponsive/expected-missing).
    static let warning = NSColor.systemOrange
    /// Healthy / running (running VM, agent current).
    static let running = NSColor.systemGreen
    /// Paused in memory.
    static let pausedInMemory = NSColor.systemYellow
    /// Error state.
    static let error = NSColor.systemRed
}

/// Shared text styles.
///
/// Wraps the common `NSFont.preferredFont(forTextStyle:)` choices that were
/// otherwise duplicated inline across view controllers.
enum Typography {
    /// Primary body text — the default for form labels and list-row titles.
    static var body: NSFont { .preferredFont(forTextStyle: .body) }
}
