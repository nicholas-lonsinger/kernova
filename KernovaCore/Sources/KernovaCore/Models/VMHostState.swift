import Foundation
import KernovaKit

/// The user's preferred display hosting for a VM on start/resume.
package enum VMDisplayPreference: String, Codable, Sendable, Equatable, CaseIterable {
    case inline
    case popOut
    case fullscreen
}

/// Kernova's own state for one VM — how it starts, reverts and presents it —
/// serialized to `host-state.json` inside the VM bundle, apart from the
/// ``VMConfiguration`` a snapshot captures.
///
/// A snapshot revert restores the configuration and never this, so a per-VM
/// value that the guest's state does not decide belongs here.
package struct VMHostState: Codable, Sendable, Equatable {
    // MARK: - Startup

    /// When `true`, Kernova starts this VM as part of coming up — resuming it
    /// from saved state when one exists, cold-booting it otherwise.
    ///
    /// A VM still awaiting its initial boot is left alone: its start runs an
    /// install or an image download, which never begins unattended.
    package var startsAutomaticallyOnLaunch: Bool

    /// When `true`, the end of every session returns this VM to the snapshot
    /// named by ``ephemeralBaselineSnapshotID`` — its disks and its
    /// ``VMConfiguration`` — discarding the session's guest changes and any
    /// setting edited since the capture.
    ///
    /// Suspend does not end a session: a suspended session survives, reverting
    /// at its next shutdown. Read as a session ends, so it is editable while
    /// the VM runs.
    package var ephemeralModeEnabled: Bool

    /// The snapshot a session's end reverts to while ``ephemeralModeEnabled``;
    /// `nil` once the mode is turned off, which clears the choice.
    ///
    /// Set through ``applyEphemeralMode(enabled:baseline:)``, which holds that
    /// pairing.
    package var ephemeralBaselineSnapshotID: UUID?

    /// `true` from the moment a guest session begins on this bundle — or a
    /// revert begins replacing its files — until what becomes of that session's
    /// changes is settled: the session ends and Ephemeral Mode's revert lands,
    /// or it ends with the mode off, or a suspend parks it, or the revert's
    /// files have all landed.
    ///
    /// Found set while no session is live in any copy, it says a session ended
    /// with that still owed — Kernova died under it, or a revert was cut short.
    /// A revert never restores this file, so the marker outlives one.
    var hasUnsettledSession: Bool

    // MARK: - Presentation

    package var displayPreference: VMDisplayPreference
    package var lastFullscreenDisplayID: UInt32?

    /// When `true`, the user has explicitly dismissed the sidebar "install
    /// guest agent" nudge for this VM.
    ///
    /// Suppresses only the gentle `.waiting` affordance — `.outdated`,
    /// `.unresponsive`, and `.expectedMissing` still surface.
    package var agentInstallNudgeDismissed: Bool

    // MARK: - Organization

    /// The library tags this VM carries, by ``VMTag/id``; the library's
    /// definitions decide which of them it shows (``Swift/Sequence/assigned(_:)``),
    /// so an identifier no definition names is inert.
    package var tags: Set<UUID>

    // MARK: - History

    /// The last moment this VM was running — written as a session first runs
    /// and again as it ends; `nil` means no run is recorded.
    var lastRunAt: Date?

    init(
        startsAutomaticallyOnLaunch: Bool = false,
        ephemeralModeEnabled: Bool = false,
        ephemeralBaselineSnapshotID: UUID? = nil,
        hasUnsettledSession: Bool = false,
        displayPreference: VMDisplayPreference = .inline,
        lastFullscreenDisplayID: UInt32? = nil,
        agentInstallNudgeDismissed: Bool = false,
        tags: Set<UUID> = [],
        lastRunAt: Date? = nil
    ) {
        self.startsAutomaticallyOnLaunch = startsAutomaticallyOnLaunch
        self.ephemeralModeEnabled = ephemeralModeEnabled
        self.ephemeralBaselineSnapshotID = ephemeralBaselineSnapshotID
        self.hasUnsettledSession = hasUnsettledSession
        self.displayPreference = displayPreference
        self.lastFullscreenDisplayID = lastFullscreenDisplayID
        self.agentInstallNudgeDismissed = agentInstallNudgeDismissed
        self.tags = tags
        self.lastRunAt = lastRunAt
    }

    // Custom `init(from:)` so a key absent from the file takes the value a new
    // VM gets, where synthesized `Codable` would fail the whole decode on any
    // missing non-optional field.
    package init(from decoder: Decoder) throws {
        let defaults = VMHostState()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.startsAutomaticallyOnLaunch = try c.decode(
            Bool.self, forKey: .startsAutomaticallyOnLaunch,
            default: defaults.startsAutomaticallyOnLaunch, in: decoder)
        self.ephemeralModeEnabled = try c.decode(
            Bool.self, forKey: .ephemeralModeEnabled, default: defaults.ephemeralModeEnabled,
            in: decoder)
        self.ephemeralBaselineSnapshotID =
            try c.decodeIfPresent(UUID.self, forKey: .ephemeralBaselineSnapshotID)
        self.hasUnsettledSession = try c.decode(
            Bool.self, forKey: .hasUnsettledSession, default: defaults.hasUnsettledSession,
            in: decoder)
        self.displayPreference = try c.decode(
            VMDisplayPreference.self, forKey: .displayPreference,
            default: defaults.displayPreference, in: decoder)
        self.lastFullscreenDisplayID = try c.decode(
            UInt32?.self, forKey: .lastFullscreenDisplayID, default: defaults.lastFullscreenDisplayID,
            in: decoder)
        self.agentInstallNudgeDismissed = try c.decode(
            Bool.self, forKey: .agentInstallNudgeDismissed,
            default: defaults.agentInstallNudgeDismissed, in: decoder)
        // A list, so an identifier that doesn't decode is removed alone and
        // the VM keeps every other tag.
        self.tags = try c.decode(Set<UUID>.self, forKey: .tags, default: defaults.tags, in: decoder)
        // A record whose absence states only that no run is recorded — true
        // of a value nobody can read — so it repairs to that.
        self.lastRunAt = try c.decode(Date?.self, forKey: .lastRunAt, default: defaults.lastRunAt, in: decoder)
    }

    // MARK: - Arrival

    /// Readies host state a copy brings in from another bundle — an import or
    /// an Exact Copy clone.
    ///
    /// Start at launch is the one setting that runs a guest with no user
    /// action, so it is local intent rather than something a copy carries in:
    /// a VM arriving pre-marked would boot on the next launch without ever
    /// being asked for, and an Exact Copy would start beside its source.
    /// The last run is the source's history, not the copy's, so a copy
    /// arrives with `nil`: `nil` means no run is recorded.
    mutating func arriveAsCopy() {
        startsAutomaticallyOnLaunch = false
        lastRunAt = nil
    }

    /// The host state a New Machine clone of a VM holding `source` starts
    /// from: a new VM's, carrying the source's tags.
    static func newMachine(cloning source: VMHostState) -> VMHostState {
        VMHostState(tags: source.tags)
    }

    // MARK: - Ephemeral mode

    /// Turns Ephemeral Mode on with `baseline`, or off — which clears the
    /// baseline choice.
    ///
    /// The pairing lives here so no caller can leave a baseline recorded
    /// against a mode that is off.
    mutating func applyEphemeralMode(enabled: Bool, baseline: UUID?) {
        ephemeralModeEnabled = enabled
        ephemeralBaselineSnapshotID = enabled ? baseline : nil
    }
}
