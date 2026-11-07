import KernovaTestSupport
import Testing

@testable import KernovaCore

/// Unit tests for `AgentStatus.synthesize(...)` — the pure function that
/// folds the hub's agents' status and persisted host context into the final
/// UI-facing `AgentStatus` of a session.
@Suite("AgentStatus.synthesize", .caseScoped)
struct AgentStatusTests {
    // MARK: - Pass-through (no synthesis)

    @Test(".current passes through unchanged")
    func currentPassesThrough() {
        let result = AgentStatus.synthesize(
            upstream: .current(version: "0.9.2"),
            lastSeenAgentVersion: "0.9.2",
            agentExpectedButMissing: false,
            departedVersion: nil
        )
        #expect(result == .current(version: "0.9.2"))
    }

    // MARK: - .waiting → .connecting synthesis

    @Test(".waiting + prior version → .connecting (the gap fix)")
    func waitingWithPriorVersionInLiveSessionBecomesConnecting() {
        // The motivating case for this synthesis path: VM has a known
        // prior agent (`lastSeenAgentVersion` set) and is in a live
        // session, but the upstream service hasn't seen Hello yet. The
        // sidebar should surface "connecting" rather than the install
        // nudge.
        let result = AgentStatus.synthesize(
            upstream: .waiting,
            lastSeenAgentVersion: "0.9.2",
            agentExpectedButMissing: false,
            departedVersion: nil
        )
        #expect(result == .connecting(expected: "0.9.2"))
    }

    @Test(".waiting + no prior version → .waiting (fresh VM)")
    func waitingWithoutPriorVersionStaysWaiting() {
        // Fresh VM that's been started but never had an agent. The
        // install nudge is the right signal here.
        let result = AgentStatus.synthesize(
            upstream: .waiting,
            lastSeenAgentVersion: nil,
            agentExpectedButMissing: false,
            departedVersion: nil
        )
        #expect(result == .waiting)
    }

    // MARK: - .expectedMissing precedence

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
            agentExpectedButMissing: true,
            departedVersion: nil
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
            agentExpectedButMissing: true,
            departedVersion: nil
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
            agentExpectedButMissing: true,
            departedVersion: nil
        )
        #expect(result == .expectedMissing(expected: "0.9.2"))
    }

    // MARK: - .disconnected

    @Test(".waiting + a departed scope with nothing awaited → .disconnected, over .connecting")
    func departedBecomesDisconnected() {
        let result = AgentStatus.synthesize(
            upstream: .waiting,
            lastSeenAgentVersion: "0.9.2",
            agentExpectedButMissing: false,
            departedVersion: "0.9.1"
        )
        #expect(result == .disconnected(last: "0.9.1"))
    }

    @Test("A connected agent's status beats a departed scope")
    func upstreamBeatsDeparted() {
        let result = AgentStatus.synthesize(
            upstream: .current(version: "1.0"),
            lastSeenAgentVersion: "1.0",
            agentExpectedButMissing: false,
            departedVersion: "1.0"
        )
        #expect(result == .current(version: "1.0"))
    }

    @Test("The missing flag beats a departed scope")
    func missingBeatsDeparted() {
        let result = AgentStatus.synthesize(
            upstream: .waiting,
            lastSeenAgentVersion: "1.0",
            agentExpectedButMissing: true,
            departedVersion: "0.9"
        )
        #expect(result == .expectedMissing(expected: "1.0"))
    }

    @Test("An empty departed version falls through to .connecting")
    func emptyDepartedFallsThrough() {
        let result = AgentStatus.synthesize(
            upstream: .waiting,
            lastSeenAgentVersion: "1.0",
            agentExpectedButMissing: false,
            departedVersion: ""
        )
        #expect(result == .connecting(expected: "1.0"))
    }

    // MARK: - Empty-version defensive fall-through

    @Test("Empty lastSeenAgentVersion is treated like nil for .expectedMissing")
    func missingFlagWithEmptyVersionFallsThrough() {
        // An agent reporting no version label, or a hand-edited config.json,
        // leaves `""` in `lastSeenAgentVersion`. Synthesizing
        // `.expectedMissing("")` would render as an empty-version-string
        // badge in the UI ("guest agent  didn't reconnect"), so the
        // synthesizer treats `""` the same as `nil` and falls through.
        let result = AgentStatus.synthesize(
            upstream: .waiting,
            lastSeenAgentVersion: "",
            agentExpectedButMissing: true,
            departedVersion: nil
        )
        #expect(result == .waiting)
    }

    @Test("Empty lastSeenAgentVersion is treated like nil for .connecting")
    func waitingWithEmptyVersionFallsThrough() {
        // Same defense as the `.expectedMissing` empty-version case:
        // `.connecting("")` would render with an empty version, so an
        // empty `lastSeenAgentVersion` falls through to upstream
        // (`.waiting`) and the install nudge surfaces normally.
        let result = AgentStatus.synthesize(
            upstream: .waiting,
            lastSeenAgentVersion: "",
            agentExpectedButMissing: false,
            departedVersion: nil
        )
        #expect(result == .waiting)
    }
}
