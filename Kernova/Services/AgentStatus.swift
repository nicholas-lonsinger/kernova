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

    /// Live session for a VM that has previously had a guest agent connect
    /// (`VMConfiguration.lastSeenAgentVersion` is set), but no `Hello` has
    /// arrived yet on this session. Distinct from `.waiting` (no prior
    /// install) so the UI can surface a softer "connecting…" indicator
    /// instead of the install nudge while the agent is expected to
    /// reconnect. Resolves to `.current` once the handshake completes, or
    /// to `.expectedMissing` if the post-start watchdog fires.
    ///
    /// Synthesized only at `VMInstance.agentStatus`; `VsockControlService`
    /// never returns it. `expected` is the last-known agent version.
    case connecting(expected: String)

    /// True when this case carries the "actively trying to reconnect"
    /// semantic. Convenience for UI code that wants to attach a continuous
    /// rotation `.symbolEffect` to the icon.
    var isConnecting: Bool {
        if case .connecting = self { return true }
        return false
    }

    /// Resolves an upstream `AgentStatus` (sourced from `VsockControlService`
    /// or a SPICE service) plus persisted host-side context into the final
    /// `AgentStatus` the UI should render. Pure function — given the same
    /// inputs, always produces the same output — so it can be unit-tested
    /// without standing up a `VZVirtualMachine`.
    ///
    /// Precedence (top wins):
    ///   1. **`.expectedMissing`** when `agentExpectedButMissing == true`
    ///      *and* `lastSeenAgentVersion` is non-nil. This overrides any
    ///      upstream value because the watchdog fires only after the
    ///      post-start grace and represents host knowledge the upstream
    ///      service can't have. If the persisted version is missing the
    ///      branch falls through (defensive — the watchdog shouldn't fire
    ///      without a version, but synthesizing `.expectedMissing("")`
    ///      would be worse than letting upstream win).
    ///   2. **`.connecting`** when upstream is `.waiting`, the VM is in a
    ///      live session (`isInLiveSession == true`), and we have a prior
    ///      `lastSeenAgentVersion`. Surfaces the "we're aware and we're
    ///      waiting" reconnect indicator instead of the install nudge
    ///      during the post-start window for VMs that have had an agent
    ///      before. Resolves to `.current` once Hello arrives, or to
    ///      `.expectedMissing` (case 1) if the watchdog fires.
    ///   3. **upstream** otherwise — pass through `.current`, `.outdated`,
    ///      `.unresponsive`, and `.waiting` (when none of the synthesis
    ///      conditions apply) unchanged.
    ///
    /// Used by `VMInstance.agentStatus` for macOS guests. Linux guests get
    /// their value directly from `SpiceClipboardService` and bypass this
    /// helper — `spice-vdagent` is user-installed, so there's no install
    /// nudge / reconnect window for the host to model.
    static func synthesize(
        upstream: AgentStatus,
        lastSeenAgentVersion: String?,
        isInLiveSession: Bool,
        agentExpectedButMissing: Bool
    ) -> AgentStatus {
        if agentExpectedButMissing, let expected = lastSeenAgentVersion {
            return .expectedMissing(expected: expected)
        }
        if case .waiting = upstream,
           let lastSeen = lastSeenAgentVersion,
           isInLiveSession {
            return .connecting(expected: lastSeen)
        }
        return upstream
    }
}
