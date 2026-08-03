import Foundation
import KernovaKit

/// Whether the guest agent is installed and current relative to what the host
/// bundles, and whether it's actively responding.
enum AgentStatus: Equatable, Sendable {
    /// No version handshake has been received yet — the agent may not be
    /// installed, or the VM may still be booting.
    case waiting

    /// The guest agent is connected and its version matches what the host bundles.
    case current(version: String)

    /// The guest agent is connected but reports a version older than what the
    /// host bundles.
    case outdated(installed: String, bundled: String)

    /// The guest agent completed a handshake but has stopped responding to
    /// heartbeats.
    ///
    /// The control-channel socket may still be open. `version` is the
    /// last-known agent version, from the most recent successful handshake.
    case unresponsive(version: String)

    /// The host has seen the agent connect on this VM before
    /// (`VMConfiguration.lastSeenAgentVersion` is set), but a grace period
    /// elapsed with no `Hello` — after the VM started or resumed, or after the
    /// control channel died mid-session.
    ///
    /// Synthesized only at `VMInstance.agentStatus`; `VsockControlService`,
    /// which has no access to persisted state, never returns it.
    case expectedMissing(expected: String)

    /// Live session for a VM that has had an agent connect before
    /// (`VMConfiguration.lastSeenAgentVersion` is set), with no handshaken
    /// control channel right now — the agent has yet to arrive, or arrived and
    /// then went away.
    ///
    /// Resolves to `.current` once a handshake completes, or to
    /// `.expectedMissing` if the agent-arrival watchdog fires. Synthesized only
    /// at `VMInstance.agentStatus`; `VsockControlService` never returns it.
    case connecting(expected: String)

    var isConnecting: Bool {
        if case .connecting = self { return true }
        return false
    }

    /// Resolves an upstream `AgentStatus` plus persisted host-side context into
    /// the final status the UI should render.
    ///
    /// Precedence: `.expectedMissing` (the watchdog fired) beats `.connecting`
    /// (live session, agent seen before) beats `upstream` unchanged. Both
    /// synthesized cases require a non-empty `lastSeenAgentVersion` — with an
    /// empty one the UI renders "guest agent  didn't reconnect", so upstream
    /// wins instead.
    static func synthesize(
        upstream: AgentStatus,
        lastSeenAgentVersion: String?,
        isInLiveSession: Bool,
        agentExpectedButMissing: Bool
    ) -> AgentStatus {
        if agentExpectedButMissing,
            let expected = lastSeenAgentVersion,
            !expected.isEmpty
        {
            return .expectedMissing(expected: expected)
        }
        if case .waiting = upstream,
            let lastSeen = lastSeenAgentVersion,
            !lastSeen.isEmpty,
            isInLiveSession
        {
            return .connecting(expected: lastSeen)
        }
        return upstream
    }

    /// Whether a freshly-observed agent `version` is at least the `bundled`
    /// version — i.e. resolves to `.current` rather than `.outdated`.
    ///
    /// A `nil` `bundled` (the host's version sidecar is missing) counts as
    /// current, so the host doesn't prompt "outdated" off a comparison it
    /// cannot make.
    static func isObservedVersionCurrent(_ version: String, bundled: String?) -> Bool {
        guard let bundled else { return true }
        return KernovaVersionComparison.isAtLeast(version, bundled)
    }
}
