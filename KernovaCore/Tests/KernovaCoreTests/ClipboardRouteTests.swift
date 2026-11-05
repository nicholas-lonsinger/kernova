import Foundation
import KernovaAgentCore
import KernovaAgentHost
import KernovaCommandModel
import KernovaKit
import KernovaTestSupport
import KernovaWire
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport

/// Which peer carries a VM's clipboard: the guest agent's CLIPBOARD console peer over SPICE, and SPICE over
/// nothing.
@MainActor
@Suite("Clipboard route", .caseScoped)
struct ClipboardRouteTests {
    private static let peer = PeerHandle(rawValue: 4)

    @Test("A CLIPBOARD console peer gets the hub, a SPICE port without one gets SPICE, and neither gets nothing")
    func choice() {
        #expect(ClipboardRoute.choose(hasSpicePort: true, consolePeer: Self.peer) == .hub(Self.peer))
        #expect(ClipboardRoute.choose(hasSpicePort: false, consolePeer: Self.peer) == .hub(Self.peer))
        #expect(ClipboardRoute.choose(hasSpicePort: true, consolePeer: nil) == .spice)
        #expect(ClipboardRoute.choose(hasSpicePort: false, consolePeer: nil) == ClipboardRoute.none)
    }

    /// A Linux VM's running session with its SPICE clipboard service started.
    private func linuxWithSpice() -> (VMInstance, SpiceClipboardService) {
        let instance = VMInstanceFixture.make(guestOS: .linux, phase: .running(sessionID: UUID()))
        let context = instance.beginSessionContextForTesting()
        let spice = SpiceClipboardService(inputPipe: Pipe(), outputPipe: Pipe())
        context.clipboardService = spice
        return (instance, spice)
    }

    private static func snapshot(consolePeer: PeerHandle?) -> AgentHubSnapshot {
        AgentHubSnapshot(
            peers: [], features: FeatureStatus.merge([]), consolePeers: consolePeer.map { [.clipboard: $0] } ?? [:])
    }

    @Test("A Linux guest with a SPICE port and no CLIPBOARD peer is carried by SPICE")
    func linuxWithoutPeerIsSpice() {
        let (instance, spice) = linuxWithSpice()
        #expect(instance.clipboardRoute == .spice)
        #expect(instance.clipboardService === spice)
    }

    @Test("A CLIPBOARD console peer takes the clipboard from SPICE, and gives it back when it goes")
    func peerTakesTheClipboard() {
        let (instance, spice) = linuxWithSpice()

        instance.publishAgentHubSnapshotForTesting(Self.snapshot(consolePeer: Self.peer))
        #expect(instance.clipboardRoute == .hub(Self.peer))
        #expect(instance.clipboardService === instance.hubClipboard)
        #expect(!spice.carriesClipboard)

        instance.publishAgentHubSnapshotForTesting(Self.snapshot(consolePeer: nil))
        #expect(instance.clipboardService === spice)
        #expect(spice.carriesClipboard)
    }

    @Test("A macOS guest with no CLIPBOARD peer has no clipboard service")
    func macOSWithoutPeerHasNone() {
        let instance = VMInstanceFixture.make(guestOS: .macOS, phase: .running(sessionID: UUID()))
        instance.beginSessionContextForTesting()
        #expect(instance.clipboardService == nil)
        instance.publishAgentHubSnapshotForTesting(Self.snapshot(consolePeer: Self.peer))
        #expect(instance.clipboardService === instance.hubClipboard)
    }

    @Test("CLIPBOARD's policy follows the clipboard-sharing setting and carries the paste ceiling and passthrough")
    func policyFollowsSharing() {
        var configuration = VMInstanceFixture.makeConfiguration(name: "Policy VM", guestOS: .macOS)
        let ceiling = ClipboardPasteLimit.choices[0]
        configuration.clipboardSharingEnabled = true
        let shared = VMInstance.agentHubPolicy(for: configuration, maxPasteBytes: ceiling)
        #expect(shared.isEnabled(.clipboard))
        #expect(
            ClipboardPolicyValue(shared) == ClipboardPolicyValue(maxPasteBytes: UInt64(ceiling), passthrough: false))
        configuration.clipboardPassthroughEnabled = true
        #expect(
            ClipboardPolicyValue(VMInstance.agentHubPolicy(for: configuration, maxPasteBytes: ceiling))?.passthrough
                == true)
        configuration.clipboardSharingEnabled = false
        let unshared = VMInstance.agentHubPolicy(for: configuration, maxPasteBytes: ceiling)
        #expect(!unshared.isEnabled(.clipboard))
        #expect(ClipboardPolicyValue(unshared)?.passthrough == false)
    }
}
