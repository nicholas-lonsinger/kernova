import Foundation

/// Decision + copy for the "enable File Provider" status-item reminder (#581).
///
/// Shared by the host app (`HostAgentStatusItemController`) and the guest
/// agent (`AgentStatusItemController`) so the badge-visibility rule lives in
/// one place; each side supplies its own direction-specific degraded-mode
/// summary, since the toggle-off fallback differs between the two directions
/// (see the per-method docs). Free of AppKit so it's unit-testable without a
/// status item — the same pure-mapper convention as `AgentMenuText` and
/// `MicPermissionPresentation`.
public enum ClipboardFileProviderReminder {
    /// Whether the status-item badge (and its menu "Stop Reminding Me"
    /// command) should currently show.
    ///
    /// Only `.needsEnabling` — a registered domain the user hasn't flipped the
    /// System-Settings toggle for — is actionable; `.inactive` (clipboard
    /// sharing off), `.ready`, and `.unavailable` (an install/signing problem,
    /// not a user toggle) never show a badge. `dismissed` silences the current
    /// `.needsEnabling` episode; the owner resets it back to `false` once
    /// availability reaches `.ready`, so a later, genuinely new disablement
    /// nags again rather than staying silenced forever.
    public static func shouldShowReminder(
        availability: FileProviderAvailability, dismissed: Bool
    ) -> Bool {
        availability == .needsEnabling && !dismissed
    }

    /// Degraded-mode summary for the host side (guest→host "Copy to Mac").
    ///
    /// With the toggle off, a file copy falls back to a synchronous,
    /// deadline-bound path capped at `ClipboardStreamTuning
    /// .maxDeadlineSafeFileBytes`, and an over-cap file is dropped with its own
    /// message (`ClipboardContentViewController.dropMessage`) — so this
    /// summary deliberately doesn't restate the byte figure. Text and images
    /// are unaffected regardless of the toggle (docs/CLIPBOARD.md §2).
    public static func hostDegradedSummary() -> String {
        "Text and images copy normally. Enable File Provider to copy larger files to your Mac."
    }

    /// Degraded-mode summary for the guest side (host→guest paste).
    ///
    /// Deliberately makes no size promise: unlike the host direction, this
    /// mirror-image fallback has no deadline-safe cap yet (open #561) — an
    /// over-cap paste with the toggle off can fail without any drop message,
    /// so this must not claim a size ceiling a user could rely on.
    public static func guestDegradedSummary() -> String {
        "Text and images paste normally. Enable File Provider to reliably paste files from your Mac."
    }
}
