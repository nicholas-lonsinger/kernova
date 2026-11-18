import Foundation
import KernovaAgentCore
import KernovaAgentHost
import KernovaClipboardItems
import KernovaCommandModel
import KernovaKit
import KernovaTestSupport
import KernovaWire
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport

/// Which guests share a VM's clipboard, when its commands are offered, what its clipboard's events report, and the
/// policy its agent hears.
@MainActor
@Suite("VM clipboard", .caseScoped)
struct VMInstanceClipboardTests {
    private static let peer = PeerHandle(rawValue: 4)

    /// Whether each clipboard command is named on `instance`, Copy to Mac's first.
    private static func commandsNamed(on instance: VMInstance) -> [Bool] {
        [VMCapability.copyGuestClipboardToMac, .copyMacClipboardToGuest].map { $0.request(on: instance) != nil }
    }

    @Test("The clipboard commands are named only while an agent carries the clipboard and passthrough is off")
    func commandsFollowTheLinkAndTheSetting() {
        let instance = VMInstanceFixture.make(guestOS: .macOS, phase: .running(sessionID: UUID())) {
            $0.clipboardSharingEnabled = true
            $0.clipboardPassthroughEnabled = true
        }
        instance.beginSessionContextForTesting()
        #expect(Self.commandsNamed(on: instance) == [false, false])

        instance.hubClipboard.setConsolePeer(Self.peer)
        #expect(Self.commandsNamed(on: instance) == [false, false])

        var off = instance.configuration
        off.clipboardPassthroughEnabled = false
        instance.applyLivePolicy(oldConfig: instance.configuration, newConfig: off)
        #expect(Self.commandsNamed(on: instance) == [true, true])

        instance.hubClipboard.setConsolePeer(nil)
        #expect(Self.commandsNamed(on: instance) == [false, false])
    }

    @Test("Each of the clipboard's events reports what passthrough and the commands report, or nothing")
    func eventsReport() {
        let expected: [(ClipboardEndEvent, ClipboardTransferGesture?, ClipboardTransferFailure?)] = [
            (.readBegan(.copy), nil, nil),
            (.readEnded(.copy, .offered(skipped: 0)), nil, nil),
            (.readEnded(.copy, .offered(skipped: 2)), .forward, .itemsSkipped(count: 2)),
            (.readEnded(.copy, .nothingToCopy), nil, nil),
            (.readEnded(.copy, .unreadable), .forward, .itemsUnreadable),
            (.readEnded(.copy, .heldByFarSide), nil, nil),
            (.readEnded(.copy, .superseded), nil, nil),
            (.readEnded(.command, .offered(skipped: 0)), nil, nil),
            (.readEnded(.command, .offered(skipped: 1)), .forward, .itemsSkipped(count: 1)),
            (.readEnded(.command, .nothingToCopy), .forward, .nothingToCopy),
            (.readEnded(.command, .unreadable), .forward, .itemsUnreadable),
            (.readEnded(.command, .heldByFarSide), nil, nil),
            (.readEnded(.command, .superseded), nil, nil),
            (.notAdmitted(.command), nil, nil),
            (.published(.written), nil, nil),
            (.published(.nothingToWrite), nil, nil),
            (.published(.writtenWithoutFiles(count: 2, limitBytes: 9)), .copy, .filesLeftOut(count: 2, limitBytes: 9)),
            (.published(.tooLarge(limitBytes: 9)), .copy, .tooLarge(limitBytes: 9)),
            (.published(.writeFailed), .copy, .transferFailed),
            (.retracted(.cleared, .byFarSide(hasSuccessor: false)), nil, nil),
            (.retracted(.keptPart, .linkLost), nil, nil),
            (.retracted(.cleared, .settingChanged), nil, nil),
            (.requestRefused(.nothingToCopy), .copy, .nothingToCopy),
            (.requestRefused(.unreadable), .copy, .itemsUnreadable),
            (.requestRefused(.failed(WireError(.cancelled))), .copy, .transferFailed),
            (.served, nil, nil),
            (.landed, nil, nil),
            (.pullFailed(WireError(.tooLarge)), nil, nil),
            (.pasteRefused, .paste, .transferFailed),
        ]
        for (event, gesture, failure) in expected {
            let refusal = HubClipboardService.refusal(for: event)
            #expect(refusal?.gesture == gesture, "\(event)")
            #expect(refusal?.failure == failure, "\(event)")
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
