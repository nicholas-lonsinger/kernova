import Foundation

/// The user's preferred display hosting for a VM on start/resume.
enum VMDisplayPreference: String, Codable, Sendable, Equatable, CaseIterable {
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
struct VMHostState: Codable, Sendable, Equatable {
    // MARK: - Startup

    /// When `true`, Kernova starts this VM as part of coming up — resuming it
    /// from saved state when one exists, cold-booting it otherwise.
    ///
    /// A VM still awaiting its initial boot is left alone: its start runs an
    /// install or an image download, which never begins unattended.
    var startsAutomaticallyOnLaunch: Bool

    /// When `true`, every power-off returns this VM to the snapshot named by
    /// ``ephemeralBaselineSnapshotID`` — its disks and its ``VMConfiguration``
    /// — discarding the session's guest changes and any setting edited since
    /// the capture.
    ///
    /// Suspend is not a power-off: a suspended session survives, reverting at
    /// its next shutdown. Read at power-off, so it is editable while the VM runs.
    var ephemeralModeEnabled: Bool

    /// The snapshot a power-off reverts to while ``ephemeralModeEnabled``;
    /// `nil` once the mode is turned off, which clears the choice.
    ///
    /// Set through ``applyEphemeralMode(enabled:baseline:)``, which holds that
    /// pairing.
    var ephemeralBaselineSnapshotID: UUID?

    // MARK: - Presentation

    var displayPreference: VMDisplayPreference
    var lastFullscreenDisplayID: UInt32?

    /// When `true`, the user has explicitly dismissed the sidebar "install
    /// guest agent" nudge for this VM.
    ///
    /// Suppresses only the gentle `.waiting` affordance — `.outdated`,
    /// `.unresponsive`, and `.expectedMissing` still surface.
    var agentInstallNudgeDismissed: Bool

    // MARK: - History

    /// The last moment this VM was running — written as a session first runs
    /// and again as it ends — `nil` for a VM that has never run.
    var lastRunAt: Date?

    init(
        startsAutomaticallyOnLaunch: Bool = false,
        ephemeralModeEnabled: Bool = false,
        ephemeralBaselineSnapshotID: UUID? = nil,
        displayPreference: VMDisplayPreference = .inline,
        lastFullscreenDisplayID: UInt32? = nil,
        agentInstallNudgeDismissed: Bool = false,
        lastRunAt: Date? = nil
    ) {
        self.startsAutomaticallyOnLaunch = startsAutomaticallyOnLaunch
        self.ephemeralModeEnabled = ephemeralModeEnabled
        self.ephemeralBaselineSnapshotID = ephemeralBaselineSnapshotID
        self.displayPreference = displayPreference
        self.lastFullscreenDisplayID = lastFullscreenDisplayID
        self.agentInstallNudgeDismissed = agentInstallNudgeDismissed
        self.lastRunAt = lastRunAt
    }

    // Custom `init(from:)` so a key absent from the file takes the value a new
    // VM gets, where synthesized `Codable` would fail the whole decode on any
    // missing non-optional field.
    init(from decoder: Decoder) throws {
        let defaults = VMHostState()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.startsAutomaticallyOnLaunch =
            try c.decodeIfPresent(Bool.self, forKey: .startsAutomaticallyOnLaunch)
            ?? defaults.startsAutomaticallyOnLaunch
        self.ephemeralModeEnabled =
            try c.decodeIfPresent(Bool.self, forKey: .ephemeralModeEnabled)
            ?? defaults.ephemeralModeEnabled
        self.ephemeralBaselineSnapshotID =
            try c.decodeIfPresent(UUID.self, forKey: .ephemeralBaselineSnapshotID)
        self.displayPreference =
            try c.decodeIfPresent(VMDisplayPreference.self, forKey: .displayPreference)
            ?? defaults.displayPreference
        self.lastFullscreenDisplayID =
            try c.decodeIfPresent(UInt32.self, forKey: .lastFullscreenDisplayID)
        self.agentInstallNudgeDismissed =
            try c.decodeIfPresent(Bool.self, forKey: .agentInstallNudgeDismissed)
            ?? defaults.agentInstallNudgeDismissed
        self.lastRunAt = try c.decodeIfPresent(Date.self, forKey: .lastRunAt)
    }

    // MARK: - Arrival

    /// Readies host state a copy brings in from another bundle — an import or
    /// an Exact Copy clone.
    ///
    /// Start at launch is the one setting that runs a guest with no user
    /// action, so it is local intent rather than something a copy carries in:
    /// a VM arriving pre-marked would boot on the next launch without ever
    /// being asked for, and an Exact Copy would start beside its source.
    /// The last run is the source's history, not the copy's: a copy arrives
    /// never run.
    mutating func arriveAsCopy() {
        startsAutomaticallyOnLaunch = false
        lastRunAt = nil
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
