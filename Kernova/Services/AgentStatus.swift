import Foundation

/// Whether the guest agent is installed and current relative to what the host bundles,
/// and whether it's actively responding.
///
/// For macOS guests this is sourced from `VsockControlService` — the always-on
/// control channel that carries the version handshake and a bidirectional
/// heartbeat. For Linux guests it's sourced from `SpiceClipboardService`
/// (`spice-vdagent` is user-installed, so the host has no install/update flow
/// to drive — `.current` is reported once the SPICE handshake completes).
///
/// The single read site for the UI is `VMInstance.agentStatus`, which dispatches
/// to the right service based on `configuration.guestOS`.
enum AgentStatus: Equatable, Sendable {

    /// No version handshake has been received yet. The guest agent may not be
    /// installed, or the VM may simply still be booting. The UI uses this state
    /// to offer an install affordance for macOS guests.
    case waiting

    /// The guest agent is connected and its version matches what the host bundles.
    /// `version` is the guest-reported string (`Hello.agent_info.agent_version`).
    case current(version: String)

    /// The guest agent is connected but reports a version older than what the
    /// host bundles. The UI uses this state to offer an update affordance.
    case outdated(installed: String, bundled: String)

    /// The guest agent completed a handshake but has stopped responding to
    /// heartbeats. The control-channel socket may still be open, but the agent
    /// itself appears hung. Distinct from `.waiting` (never seen): `version` is
    /// the last-known agent version reported on the most recent successful
    /// handshake. The UI uses this state to surface a "guest agent
    /// unresponsive" indicator while the channel is reconnecting.
    case unresponsive(version: String)

    /// The host has previously seen the guest agent connect on this VM
    /// (`VMConfiguration.lastSeenAgentVersion` is set), but after the VM
    /// reached `.running` the post-start grace period elapsed without a
    /// fresh `Hello`. The UI uses this state to surface a louder
    /// "didn't reconnect" affordance — distinct from the gentler `.waiting`
    /// nudge shown on VMs that have never had an agent.
    ///
    /// Synthesized only at `VMInstance.agentStatus`; `VsockControlService`
    /// (which has no access to persisted state) never returns it.
    /// `expected` is the last-known agent version we have on record.
    case expectedMissing(expected: String)
}
