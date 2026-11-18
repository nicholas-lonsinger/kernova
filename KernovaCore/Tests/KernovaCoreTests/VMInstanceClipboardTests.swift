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

/// Which guests share a VM's clipboard, when its commands are offered, and the policy its agent hears.
@MainActor
@Suite("VM clipboard", .caseScoped)
struct VMInstanceClipboardTests {
    private static let peer = PeerHandle(rawValue: 4)

    /// Whether each clipboard command is named on `instance`, Copy to Mac's first.
    private static func commandsNamed(on instance: VMInstance) -> [Bool] {
        [VMCapability.copyGuestClipboardToMac, .copyMacClipboardToGuest].map { $0.request(on: instance) != nil }
    }

    /// The hub's clipboard entries a test stands, each with the absence the hub names for no agent at the guest's
    /// screen carrying it: the entry's own, or `NOT_ON_CONSOLE` where some agent offers it.
    private static let hubEntries: [(status: Availability<Data>, absence: AbsenceReason)] = [
        (.absent(.noAgent, debugDetail: ""), .noAgent),
        (.absent(.versionMismatch, debugDetail: ""), .versionMismatch),
        (.absent(.notServedByRole, debugDetail: ""), .notServedByRole),
        (.available(Data()), .notOnConsole),
    ]

    @Test("The clipboard commands are held back by sharing, then passthrough, then no agent at the guest's screen")
    func gapFollowsTheSettingsThenTheAgent() {
        for sharing in [false, true] {
            for passthrough in [false, true] {
                for connected in [false, true] {
                    for entry in Self.hubEntries {
                        let instance = VMInstanceFixture.make(guestOS: .macOS, phase: .running(sessionID: UUID())) {
                            $0.clipboardSharingEnabled = sharing
                            $0.clipboardPassthroughEnabled = passthrough
                        }
                        instance.publishAgentHubSnapshotForTesting(
                            AgentHubSnapshot(
                                peers: [], features: FeatureStatusTable([(feature: .clipboard, status: entry.status)])))
                        instance.hubClipboard.setConsolePeer(connected ? Self.peer : nil)
                        let expected: ClipboardCommandsGap? =
                            if !sharing {
                                .notCarried(.disabledByPolicy)
                            } else if passthrough {
                                .passthroughOn
                            } else if connected {
                                nil
                            } else {
                                .notCarried(entry.absence)
                            }
                        let label = "sharing \(sharing), passthrough \(passthrough), connected \(connected), \(entry)"
                        #expect(instance.clipboardCommandsGap == expected, "\(label)")
                        #expect(Self.commandsNamed(on: instance) == [expected == nil, expected == nil], "\(label)")
                    }
                }
            }
        }
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
