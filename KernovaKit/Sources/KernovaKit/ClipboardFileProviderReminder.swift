import Foundation

/// Decision + copy for the File Provider status-item badge (#581) and its
/// `.unavailable` counterpart (#591).
///
/// Shared by the host app (`HostAgentStatusItemController`) and the guest
/// agent (`AgentStatusItemController`) so the badge-visibility rules live in
/// one place; each side supplies its own direction-specific summaries, since
/// the toggle-off (and unavailable) fallback differs between the two
/// directions (see the per-method docs). Free of AppKit so it's unit-testable
/// without a status item — the same pure-mapper convention as `AgentMenuText`
/// and `MicPermissionPresentation`.
public enum ClipboardFileProviderReminder {
    /// Whether the menu's dismissible "Stop Reminding Me" command applies to
    /// the current availability.
    ///
    /// Only `.needsEnabling` — a registered domain the user hasn't flipped the
    /// System-Settings toggle for — is a routine, silenceable nudge (every
    /// fresh install hits it, since the toggle defaults off); `.inactive`
    /// (clipboard sharing off), `.ready`, and `.unavailable` never offer this
    /// command. `dismissed` silences the current `.needsEnabling` episode —
    /// see `dismissalAfterAvailabilityChange` for when the owner should clear
    /// it. For whether the status-item badge itself should show, see
    /// `shouldShowBadge` — `.unavailable` badges too, but isn't dismissible.
    public static func shouldShowReminder(
        availability: FileProviderAvailability, dismissed: Bool
    ) -> Bool {
        availability == .needsEnabling && !dismissed
    }

    /// Whether the proactive status-item badge (and tooltip) should currently
    /// show.
    ///
    /// `.needsEnabling` is the routine, dismissible nudge covered by
    /// `shouldShowReminder` above. `.unavailable` (#591) is a should-never-
    /// happen registration/install failure with no user toggle to flip — it
    /// always badges, regardless of `dismissed`, until the domain becomes
    /// usable again (`dismissalAfterAvailabilityChange` still resets
    /// `dismissed` to `false` on `.unavailable`, so a later `.needsEnabling`
    /// episode isn't pre-silenced). `.inactive` and `.ready` never badge.
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
    /// Resets to `false` whenever `availability` is anything other than
    /// `.needsEnabling` — `.ready` is the common case (the user flipped the
    /// toggle), but `.inactive`/`.unavailable` also end the "episode" a
    /// dismissal was silencing: a `.needsEnabling` → transient-failure →
    /// `.needsEnabling` cycle (e.g. clipboard sharing toggled off and back on)
    /// never passes through `.ready` at all, and without this broader reset
    /// the badge would stay silently suppressed even though the user never
    /// confirmed the newer `.needsEnabling` episode is the same one they
    /// dismissed. Staying in `.needsEnabling` leaves `dismissed` untouched, so
    /// "Stop Reminding Me" keeps silencing the badge across the same episode.
    public static func dismissalAfterAvailabilityChange(
        _ availability: FileProviderAvailability, dismissed: Bool
    ) -> Bool {
        availability == .needsEnabling ? dismissed : false
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
    /// With the toggle off, a file paste falls back to a synchronous,
    /// deadline-bound pull capped at `ClipboardStreamTuning
    /// .maxDeadlineSafeFileBytes` — symmetric with the host direction (#561) —
    /// and an over-cap file is refused with its own `clipboard.paste.too.large`
    /// error frame, surfaced in the host's clipboard window. This summary
    /// deliberately doesn't restate the byte figure, matching
    /// `hostDegradedSummary`.
    public static func guestDegradedSummary() -> String {
        "Text and images paste normally. Enable File Provider to reliably paste files from your Mac."
    }

    /// Unavailable-mode summary for the host side (guest→host "Copy to Mac").
    ///
    /// `.unavailable` (#591) is a registration/install failure, not a user
    /// toggle — there's nothing to enable in System Settings, so unlike
    /// `hostDegradedSummary` this doesn't point there; reopening the app
    /// retries domain registration from scratch.
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

    /// Actionable command opening System Settings to enable the extension —
    /// identical wording on both sides (see `ClipboardFileProviderSettings
    /// .openEnablementSettings()`).
    ///
    /// Ellipsis: it navigates to System Settings to gather the user's action.
    public static func enableCommandTitle() -> String {
        "Enable in System Settings…"
    }

    /// Command silencing the proactive status-item badge — identical wording
    /// on both sides.
    ///
    /// No ellipsis: it acts immediately, gathering no further input. The
    /// passive dropdown line + enable command stay regardless.
    public static func stopRemindingCommandTitle() -> String {
        "Stop Reminding Me"
    }
}
