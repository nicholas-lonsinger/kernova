import KernovaTestSupport
import Testing

@testable import KernovaCore

/// Unit tests for `AgentStatus.synthesize(...)` — the pure function that
/// folds the hub's agents' status and persisted host context into the final
/// UI-facing `AgentStatus` of a session.
@Suite("AgentStatus.synthesize", .caseScoped)
struct AgentStatusTests {
    // MARK: - Pass-through (no synthesis)

    // MARK: - .waiting → .connecting synthesis

    // MARK: - .expectedMissing precedence

    // MARK: - .disconnected

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
}
