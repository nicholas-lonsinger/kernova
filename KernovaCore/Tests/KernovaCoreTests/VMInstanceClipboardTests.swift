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

/// Which guests share a VM's clipboard, what carries it, and the policy its agent hears.
@MainActor
@Suite("VM clipboard", .caseScoped)
struct VMInstanceClipboardTests {
    private static let peer = PeerHandle(rawValue: 4)

    private static func snapshot(consolePeer: PeerHandle?) -> AgentHubSnapshot {
        AgentHubSnapshot(
            peers: [], features: FeatureStatus.merge([]), consolePeers: consolePeer.map { [.clipboard: $0] } ?? [:])
    }

    @Test("A CLIPBOARD console peer gives the VM its clipboard service, and takes it away when it goes")
    func consolePeerCarriesTheClipboard() {
        let instance = VMInstanceFixture.make(guestOS: .macOS, phase: .running(sessionID: UUID()))
        instance.beginSessionContextForTesting()
        #expect(instance.clipboardService == nil)

        instance.publishAgentHubSnapshotForTesting(Self.snapshot(consolePeer: Self.peer))
        #expect(instance.clipboardService === instance.hubClipboard)

        instance.publishAgentHubSnapshotForTesting(Self.snapshot(consolePeer: nil))
        #expect(instance.clipboardService == nil)
    }

    @Test("Only a macOS guest shares the clipboard: a Linux guest's stored flags offer and send nothing")
    func onlyMacOSSharesTheClipboard() {
        let ceiling = ClipboardPasteLimit.choices[0]
        for guestOS in VMGuestOS.allCases {
            var configuration = VMInstanceFixture.makeConfiguration(name: "Shared VM", guestOS: guestOS)
            configuration.clipboardSharingEnabled = true
            configuration.clipboardPassthroughEnabled = true
            let shares = guestOS == .macOS
            #expect(configuration.sharesClipboard == shares, "\(guestOS)")
            #expect(configuration.clipboardPassthroughIsEffective == shares, "\(guestOS)")
            #expect(VMConfigurationKeyRegistry.clipboardSharing.applies(configuration) == shares, "\(guestOS)")
            #expect(VMConfigurationKeyRegistry.clipboardPassthrough.applies(configuration) == shares, "\(guestOS)")
            let policy = VMInstance.agentHubPolicy(for: configuration, maxPasteBytes: ceiling)
            #expect(policy.isEnabled(.clipboard) == shares, "\(guestOS)")
        }
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
