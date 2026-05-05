import Testing
@testable import Kernova

/// Unit tests for `AgentStatus.synthesize(...)` — the pure function that
/// folds the upstream service value, persisted host context, and live-
/// session flag into the final UI-facing `AgentStatus`. The function is
/// extracted from `VMInstance.agentStatus` specifically to make this logic
/// testable without standing up a `VZVirtualMachine`.
@Suite("AgentStatus.synthesize")
struct AgentStatusTests {

    // MARK: - Pass-through (no synthesis)

    @Test(".current passes through unchanged")
    func currentPassesThrough() {
        let result = AgentStatus.synthesize(
            upstream: .current(version: "0.9.2"),
            lastSeenAgentVersion: "0.9.2",
            isInLiveSession: true,
            agentExpectedButMissing: false
        )
        #expect(result == .current(version: "0.9.2"))
    }

    @Test(".outdated passes through unchanged")
    func outdatedPassesThrough() {
        let result = AgentStatus.synthesize(
            upstream: .outdated(installed: "0.9.1", bundled: "0.9.2"),
            lastSeenAgentVersion: "0.9.1",
            isInLiveSession: true,
            agentExpectedButMissing: false
        )
        #expect(result == .outdated(installed: "0.9.1", bundled: "0.9.2"))
    }

    @Test(".unresponsive passes through unchanged")
    func unresponsivePassesThrough() {
        let result = AgentStatus.synthesize(
            upstream: .unresponsive(version: "0.9.2"),
            lastSeenAgentVersion: "0.9.2",
            isInLiveSession: true,
            agentExpectedButMissing: false
        )
        #expect(result == .unresponsive(version: "0.9.2"))
    }

    // MARK: - .waiting → .connecting synthesis

    @Test(".waiting + prior version + live session → .connecting (the gap fix)")
    func waitingWithPriorVersionInLiveSessionBecomesConnecting() {
        // The motivating case for this synthesis path: VM has a known
        // prior agent (`lastSeenAgentVersion` set) and is in a live
        // session, but the upstream service hasn't seen Hello yet. The
        // sidebar should surface "connecting" rather than the install
        // nudge.
        let result = AgentStatus.synthesize(
            upstream: .waiting,
            lastSeenAgentVersion: "0.9.2",
            isInLiveSession: true,
            agentExpectedButMissing: false
        )
        #expect(result == .connecting(expected: "0.9.2"))
    }

    @Test(".waiting + no prior version + live session → .waiting (fresh VM)")
    func waitingWithoutPriorVersionStaysWaiting() {
        // Fresh VM that's been started but never had an agent. The
        // install nudge is the right signal here.
        let result = AgentStatus.synthesize(
            upstream: .waiting,
            lastSeenAgentVersion: nil,
            isInLiveSession: true,
            agentExpectedButMissing: false
        )
        #expect(result == .waiting)
    }

    @Test(".waiting + prior version + not live → .waiting (stopped VM)")
    func waitingWithPriorVersionButNotLiveStaysWaiting() {
        // Stopped VM with a previously-installed agent. The synthesizer
        // returns `.waiting` here; the VMRowView further suppresses the
        // sidebar icon for stopped/cold-paused VMs with a prior agent
        // so the user doesn't see a nag.
        let result = AgentStatus.synthesize(
            upstream: .waiting,
            lastSeenAgentVersion: "0.9.2",
            isInLiveSession: false,
            agentExpectedButMissing: false
        )
        #expect(result == .waiting)
    }

    @Test(".waiting + no prior version + not live → .waiting")
    func waitingWithoutPriorVersionAndNotLiveStaysWaiting() {
        // Stopped fresh VM. The most basic case.
        let result = AgentStatus.synthesize(
            upstream: .waiting,
            lastSeenAgentVersion: nil,
            isInLiveSession: false,
            agentExpectedButMissing: false
        )
        #expect(result == .waiting)
    }

    // MARK: - .expectedMissing precedence

    @Test("Missing flag + version → .expectedMissing regardless of upstream")
    func missingFlagWinsOverWaiting() {
        let result = AgentStatus.synthesize(
            upstream: .waiting,
            lastSeenAgentVersion: "0.9.2",
            isInLiveSession: true,
            agentExpectedButMissing: true
        )
        #expect(result == .expectedMissing(expected: "0.9.2"))
    }

    @Test("Missing flag + version overrides .current upstream (defensive)")
    func missingFlagOverridesCurrent() {
        // In practice the agent calling Hello clears the missing flag
        // before the upstream value can flip to `.current`, but if
        // sequencing ever diverges the watchdog flag wins. Locking that
        // precedence in keeps the behavior explicit if a future refactor
        // changes ordering.
        let result = AgentStatus.synthesize(
            upstream: .current(version: "0.9.2"),
            lastSeenAgentVersion: "0.9.2",
            isInLiveSession: true,
            agentExpectedButMissing: true
        )
        #expect(result == .expectedMissing(expected: "0.9.2"))
    }

    @Test("Missing flag without persisted version falls through to upstream")
    func missingFlagWithoutVersionFallsThrough() {
        // Defensive: the watchdog only arms when `lastSeenAgentVersion`
        // is set, so this combination shouldn't happen in production —
        // but synthesizing `.expectedMissing("")` would be worse than
        // returning `.waiting`, so the synthesizer falls through to the
        // upstream value.
        let result = AgentStatus.synthesize(
            upstream: .waiting,
            lastSeenAgentVersion: nil,
            isInLiveSession: true,
            agentExpectedButMissing: true
        )
        #expect(result == .waiting)
    }

    @Test("Missing flag wins over what would otherwise be .connecting")
    func missingFlagWinsOverConnectingPath() {
        // All the inputs that would trigger .connecting are present, but
        // the watchdog has fired — `.expectedMissing` is the louder, more
        // urgent signal and takes precedence.
        let result = AgentStatus.synthesize(
            upstream: .waiting,
            lastSeenAgentVersion: "0.9.2",
            isInLiveSession: true,
            agentExpectedButMissing: true
        )
        #expect(result == .expectedMissing(expected: "0.9.2"))
    }
}
