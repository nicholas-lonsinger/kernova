import Foundation
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport

/// The host-state model and its coding: what a round trip preserves, and what
/// a key the JSON does not carry decodes to.
@Suite("VMHostState Tests", .caseScoped)
struct VMHostStateTests {
    /// Every field away from its default, so a field the custom `init(from:)`
    /// misses fails the round trip instead of decoding to the default.
    private func everyFieldSet() -> VMHostState {
        var hostState = VMHostState(
            startsAutomaticallyOnLaunch: true, displayPreference: .popOut,
            lastFullscreenDisplayID: 0xDEAD_BEEF, agentInstallNudgeDismissed: true,
            tags: [UUID(), UUID()],
            lastRunAt: Date(timeIntervalSince1970: 1_700_000_000))
        hostState.applyEphemeralMode(
            enabled: true, baseline: UUID(uuidString: "DEADBEEF-DEAD-BEEF-DEAD-BEEFDEADBEEF"))
        return hostState
    }

    @Test("A key the JSON does not carry decodes to its default")
    func absentKeysTakeTheirDefaults() throws {
        let data = Data(#"{"displayPreference":"fullscreen"}"#.utf8)

        #expect(
            try VMConfiguration.makeJSONDecoder().decode(VMHostState.self, from: data)
                == VMHostState(displayPreference: .fullscreen))
    }

    @Test("A New Machine clone starts from a new VM's host state, carrying the source's tags")
    func newMachineCarriesTags() {
        let source = everyFieldSet()

        #expect(VMHostState.newMachine(cloning: source) == VMHostState(tags: source.tags))
    }

    @Test("A copy arrives with no run recorded and not starting at launch, keeping everything else")
    func copyArrivesWithNoRunRecorded() {
        var copied = everyFieldSet()
        var expected = copied
        expected.startsAutomaticallyOnLaunch = false
        expected.lastRunAt = nil

        copied.arriveAsCopy()

        #expect(copied == expected)
    }
}
