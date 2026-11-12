import Foundation
import KernovaCommandModel
import KernovaAgentCore
import KernovaAgentHost
import KernovaKit
import KernovaTestSupport
import KernovaWire
import SwiftProtobuf
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport

/// The three-state gate on dragging files onto a VM display: a VM that has never
/// run the agent is not a drag destination at all, one whose agent is away takes
/// part and refuses, and a reachable one accepts.
@Suite("VMInstance display drop availability", .caseScoped)
@MainActor
struct VMInstanceDisplayDropTests {
    /// A VM instance in a running session.
    private final class Harness {
        let instance: VMInstance

        @MainActor
        init(
            guestOS: VMGuestOS = .macOS, lastSeenAgentVersion: String? = "1.0.0",
            clipboardSharingEnabled: Bool = true, dropFilesEnabled: Bool = true,
            phase: VMLifecyclePhase = .running(sessionID: UUID())
        ) {
            instance = VMInstanceFixture.make(name: "Drop VM", guestOS: guestOS, phase: phase) {
                $0.lastSeenAgentVersion = lastSeenAgentVersion
                $0.clipboardSharingEnabled = clipboardSharingEnabled
                $0.dropFilesEnabled = dropFilesEnabled
            }
            instance.beginSessionContextForTesting()
        }

        /// Publishes a hub snapshot whose DROP console peer is `peer`.
        @MainActor
        func publishConsolePeer(_ peer: PeerHandle?) {
            instance.publishAgentHubSnapshotForTesting(
                AgentHubSnapshot(
                    peers: [], features: FeatureStatus.merge([]), consolePeers: peer.map { [.drop: $0] } ?? [:]))
        }
    }

    // MARK: - The per-VM toggle

    @Test("a VM with drag and drop switched off is not a drag destination")
    func dropToggleOffIsNotADestination() {
        let harness = Harness(dropFilesEnabled: false)
        harness.publishConsolePeer(PeerHandle(rawValue: 1))

        // `.none` rather than `.disconnected`: the display unregisters, so a drag
        // over it behaves as if Kernova were not there at all.
        #expect(harness.instance.displayDropAvailability == .none)
        #expect(!harness.instance.dropOnGuest(FakePasteboard(), promises: []))
    }

    @Test("the policy turns DROP on and off with the drag and drop setting", arguments: [true, false])
    func policyFollowsTheSetting(enabled: Bool) {
        let harness = Harness(dropFilesEnabled: enabled)

        let policy = harness.instance.agentHubPolicy(for: harness.instance.configuration)

        #expect(policy.isEnabled(.drop) == enabled)
    }

    // MARK: - A VM that isn't running

    @Test("a paused VM refuses the drag — its guest is frozen, not gone")
    func pausedRefusesTheDrag() {
        let harness = Harness()
        harness.publishConsolePeer(PeerHandle(rawValue: 1))

        // Pausing ends no connection, so the hub still names DROP's console
        // peer — only the phase says the guest cannot answer.
        harness.instance.activity.placeForTesting(.suspended)

        #expect(harness.instance.displayDropAvailability == .disconnected)
        #expect(!harness.instance.dropOnGuest(FakePasteboard(), promises: []))
    }
}
