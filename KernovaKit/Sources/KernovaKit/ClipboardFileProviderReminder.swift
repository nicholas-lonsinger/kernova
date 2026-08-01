import Foundation

/// Decision + copy for the File Provider status-item badge.
///
/// Shared by the host app and the guest agent so the badge-visibility rules
/// live in one place; each side supplies its own direction-specific summaries,
/// since the toggle-off and unavailable fallbacks differ between the two.
public enum ClipboardFileProviderReminder {
    /// Whether the menu's dismissible "Stop Reminding Me" command applies to
    /// the current availability.
    ///
    /// Only `.needsEnabling` — a registered domain the user hasn't flipped the
    /// System-Settings toggle for — is a routine, silenceable nudge, and every
    /// fresh install hits it because the toggle defaults off. `dismissed`
    /// silences the current episode; `dismissalAfterAvailabilityChange` says
    /// when the owner clears it.
    public static func shouldShowReminder(
        availability: FileProviderAvailability, dismissed: Bool
    ) -> Bool {
        availability == .needsEnabling && !dismissed
    }

    /// Whether the proactive status-item badge (and tooltip) should currently
    /// show.
    ///
    /// `.unavailable` is a registration/install failure with no user toggle to
    /// flip, so it badges regardless of `dismissed` until the domain becomes
    /// usable again.
    public static func shouldShowBadge(
        availability: FileProviderAvailability, dismissed: Bool
    ) -> Bool {
        switch availability {
        case .needsEnabling: return !dismissed
        case .unavailable: return true
        case .inactive, .ready: return false
        }
    }

    /// The dismissal value the owner should persist after an availability
    /// change, given the `dismissed` value it currently holds.
    ///
    /// Any availability other than `.needsEnabling` ends the "episode" a
    /// dismissal was silencing, `.inactive`/`.unavailable` included: a
    /// `.needsEnabling` → transient-failure → `.needsEnabling` cycle never
    /// passes through `.ready`, so a narrower reset would leave the badge
    /// suppressed for an episode the user never dismissed.
    public static func dismissalAfterAvailabilityChange(
        _ availability: FileProviderAvailability, dismissed: Bool
    ) -> Bool {
        availability == .needsEnabling ? dismissed : false
    }

    /// Degraded-mode summary for the host side (guest→host "Copy to Mac").
    ///
    /// With the toggle off, a file copy falls back to a synchronous,
    /// deadline-bound path capped at
    /// `ClipboardStreamTuning.maxDeadlineSafeFileBytes`, and an over-cap file is
    /// dropped with its own message — so this summary doesn't restate the byte
    /// figure.
    public static func hostDegradedSummary() -> String {
        "Text and images copy normally. Enable File Provider to copy larger files to your Mac."
    }

    /// Degraded-mode summary for the guest side (host→guest paste).
    ///
    /// Mirrors `hostDegradedSummary`: the paste falls back to a synchronous,
    /// deadline-bound pull capped at
    /// `ClipboardStreamTuning.maxDeadlineSafeFileBytes`, and an over-cap rep is
    /// refused with a `clipboard.paste.too.large` error frame surfaced in the
    /// host's clipboard window.
    public static func guestDegradedSummary() -> String {
        "Text and images paste normally. Enable File Provider to reliably paste files from your Mac."
    }

    /// Unavailable-mode summary for the host side (guest→host "Copy to Mac").
    ///
    /// `.unavailable` is a registration/install failure, not a user toggle —
    /// there is nothing to enable in System Settings, so unlike
    /// `hostDegradedSummary` this doesn't point there; reopening the app retries
    /// domain registration from scratch.
    public static func hostUnavailableSummary() -> String {
        "Text and images copy normally. File sharing for larger files is unavailable — reopen Kernova to restore it."
    }

    /// Unavailable-mode summary for the guest side (host→guest paste).
    ///
    /// Mirrors `hostUnavailableSummary`, but the guest's corrective action is
    /// reinstalling the guest agent rather than reopening an app.
    public static func guestUnavailableSummary() -> String {
        "Text and images paste normally. File sharing from your Mac is unavailable — reinstall the Kernova guest agent to restore it."
    }

    /// Actionable command opening the settings app to enable the extension —
    /// identical wording on both sides.
    ///
    /// Ellipsis: it navigates to the settings app to gather the user's action.
    /// Named for the app the running OS actually has: System Settings on 13+,
    /// System Preferences before.
    public static func enableCommandTitle() -> String {
        if #available(macOS 13.0, *) {
            return "Enable in System Settings…"
        }
        return "Enable in System Preferences…"
    }

    /// Command silencing the proactive status-item badge — identical wording
    /// on both sides.
    ///
    /// No ellipsis: it acts immediately, gathering no further input.
    public static func stopRemindingCommandTitle() -> String {
        "Stop Reminding Me"
    }
}
