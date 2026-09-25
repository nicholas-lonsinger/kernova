import Foundation
import KernovaTestSupport
import Testing

@testable import Kernova

/// The host-state model and its coding: what a round trip preserves, and what
/// a key the JSON does not carry decodes to.
@Suite("VMHostState Tests", .admissionGated)
struct VMHostStateTests {
    /// Every field away from its default, so a field the custom `init(from:)`
    /// misses fails the round trip instead of decoding to the default.
    private func everyFieldSet() -> VMHostState {
        var hostState = VMHostState(
            startsAutomaticallyOnLaunch: true, displayPreference: .popOut,
            lastFullscreenDisplayID: 0xDEAD_BEEF, agentInstallNudgeDismissed: true)
        hostState.applyEphemeralMode(
            enabled: true, baseline: UUID(uuidString: "DEADBEEF-DEAD-BEEF-DEAD-BEEFDEADBEEF"))
        return hostState
    }

    @Test("A new VM's host state is the defaults")
    func defaults() {
        let hostState = VMHostState()

        #expect(!hostState.startsAutomaticallyOnLaunch)
        #expect(!hostState.ephemeralModeEnabled)
        #expect(hostState.ephemeralBaselineSnapshotID == nil)
        #expect(hostState.displayPreference == .inline)
        #expect(hostState.lastFullscreenDisplayID == nil)
        #expect(!hostState.agentInstallNudgeDismissed)
    }

    @Test("An encoded host state decodes back as itself")
    func roundTrip() throws {
        let written = everyFieldSet()

        let data = try VMConfiguration.makeJSONEncoder().encode(written)

        #expect(try VMConfiguration.makeJSONDecoder().decode(VMHostState.self, from: data) == written)
    }

    @Test("A key the JSON does not carry decodes to its default")
    func absentKeysTakeTheirDefaults() throws {
        let data = Data(#"{"displayPreference":"fullscreen"}"#.utf8)

        #expect(
            try VMConfiguration.makeJSONDecoder().decode(VMHostState.self, from: data)
                == VMHostState(displayPreference: .fullscreen))
    }
}
