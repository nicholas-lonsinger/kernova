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

    @Test("a VM that has never seen an agent is not a drag destination")
    func neverConnectedIsNotADestination() {
        let harness = Harness(lastSeenAgentVersion: nil)

        #expect(harness.instance.displayDropAvailability == .none)
    }

    @Test("a Linux guest is never a drag destination — the agent is macOS-only")
    func linuxIsNotADestination() {
        // A Linux guest never records an agent version, so this is belt and
        // braces; the guest-OS check is what makes it explicit.
        let harness = Harness(guestOS: .linux, lastSeenAgentVersion: "1.0.0")

        #expect(harness.instance.displayDropAvailability == .none)
    }

    @Test("a VM whose agent has connected before, but isn't now, refuses the drag")
    func previouslyConnectedRefuses() {
        let harness = Harness()

        // Registered as a destination (not `.none`), so the drag participates and
        // springs back rather than passing through to whatever is behind.
        #expect(harness.instance.displayDropAvailability == .disconnected)
    }

    @Test("a hub whose peers offer no DROP still refuses")
    func requiresADropConsolePeer() {
        let harness = Harness()

        harness.publishConsolePeer(nil)

        #expect(harness.instance.displayDropAvailability == .disconnected)
        #expect(!harness.instance.dropOnGuest(FakePasteboard(), promises: []))
    }

    @Test("a DROP console peer makes a running VM a destination that takes the drop")
    func consolePeerMakesItAvailable() {
        let harness = Harness()

        harness.publishConsolePeer(PeerHandle(rawValue: 1))

        #expect(harness.instance.displayDropAvailability == .available)
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

    @Test("drag and drop is independent of clipboard sharing")
    func dropIsIndependentOfClipboardSharing() {
        let harness = Harness(clipboardSharingEnabled: false)

        harness.publishConsolePeer(PeerHandle(rawValue: 1))

        #expect(harness.instance.displayDropAvailability == .available)
        #expect(!harness.instance.configuration.clipboardSharingEnabled)
    }

    @Test("the policy turns DROP on and off with the drag and drop setting", arguments: [true, false])
    func policyFollowsTheSetting(enabled: Bool) {
        let harness = Harness(dropFilesEnabled: enabled)

        let policy = VMInstance.agentHubPolicy(for: harness.instance.configuration)

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

    @Test("losing DROP's console peer downgrades an available VM back to a refusal")
    func losingTheConsolePeerRefusesAgain() {
        let harness = Harness()
        harness.publishConsolePeer(PeerHandle(rawValue: 1))
        #expect(harness.instance.displayDropAvailability == .available)

        harness.publishConsolePeer(nil)

        #expect(harness.instance.displayDropAvailability == .disconnected)
    }

    // MARK: - Reporting a drop the clipboard toggle has no say over

    @Test("a drop reports itself on a VM whose Clipboard Sharing is switched off")
    func dropReportsWithClipboardSharingOff() throws {
        let harness = Harness(clipboardSharingEnabled: false)
        let instance = harness.instance
        // The toggle closes the Clipboard window and disables the toolbar item
        // that carries the ring, which is why the menu-bar status item — driven
        // by this report alone — is where the drop has to show.
        #expect(!instance.activity.admits(.affordance(.clipboard), posture: .offer))

        let operation = ClipboardTransferOperation(
            gesture: .drop, direction: .outbound, peerName: instance.name, revealDelay: 0,
            clock: GatedEngineClock(), onCancelRequested: {},
            reporter: instance.clipboardTransfers)
        let readout = ClipboardProgressSnapshot(
            direction: .outbound, peerName: instance.name, currentItemName: "a.txt",
            filesCompleted: 0, fileCount: 1, bytesTransferred: 10, totalBytes: 100,
            bytesPerSecond: 10, secondsRemaining: 9, gesture: .drop, elapsedSeconds: 5,
            isCancellable: true, operationID: operation.id)
        instance.clipboardTransfers.publish(from: operation, .running(readout, since: Date()))

        guard case .running(let shown, _) = instance.clipboardTransferReport else {
            Issue.record("the drop left the status item's readout empty")
            return
        }
        #expect(shown.gesture == .drop)
        #expect(shown.isCancellable)
        // And that readout reveals itself in the status item's callout, so the
        // drop is seen without the user going looking for it.
        var reveal = ClipboardProgressAutoReveal()
        #expect(reveal.readoutChanged(shown, dropdownIsOpen: false, reveal: { true }) == .shown)
        // The Cancel it carries reaches the drop through the same report.
        #expect(instance.clipboardTransfers.cancel(shown.operationID))
        withExtendedLifetime(operation) {}
    }
}
