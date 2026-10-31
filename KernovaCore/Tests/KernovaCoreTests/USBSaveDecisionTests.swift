import Foundation
import KernovaCommandModel
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport

/// The one decision a save of a live VM makes about the USB disks it unplugs,
/// row by row, and the words each answer is asked in.
@Suite("USB save decision", .caseScoped)
@MainActor
struct USBSaveDecisionTests {
    nonisolated private static let data = USBSaveDisk(name: "Data.img", writable: true)
    nonisolated private static let tools = USBSaveDisk(name: "Tools.iso", writable: false)

    nonisolated private static let reminder = Consent([.unplugUSBDisks])
    nonisolated private static let atRisk = Consent([.unplugUSBDisksAtRisk])

    /// One row of the state table: the disks, whether the guest is paused,
    /// whether its agent ejects, the consent given, and what is decided.
    struct Row: Sendable, CustomTestStringConvertible {
        let number: Int
        let disks: [USBSaveDisk]
        let isPaused: Bool
        let agentEjects: Bool
        let consent: Consent
        let expected: USBSaveDecision

        var testDescription: String { "row \(number)" }
    }

    nonisolated static let rows: [Row] = [
        // 1. No disk: nothing to ask, whatever else holds.
        Row(number: 1, disks: [], isPaused: false, agentEjects: false, consent: .none, expected: .proceed),
        Row(number: 1, disks: [], isPaused: true, agentEjects: true, consent: .none, expected: .proceed),
        // 2–5. Only read-only disks, no consent: the reminder.
        Row(number: 2, disks: [tools], isPaused: false, agentEjects: true, consent: .none, expected: .remind([tools])),
        Row(number: 4, disks: [tools], isPaused: false, agentEjects: false, consent: .none, expected: .remind([tools])),
        Row(number: 5, disks: [tools], isPaused: true, agentEjects: false, consent: .none, expected: .remind([tools])),
        // 3, 6. Read-only disks under the reminder's consent proceed.
        Row(number: 3, disks: [tools], isPaused: false, agentEjects: true, consent: reminder, expected: .proceed),
        Row(number: 6, disks: [tools], isPaused: true, agentEjects: false, consent: reminder, expected: .proceed),
        // 7–8. A writable disk an agent ejects is not at risk: the reminder.
        Row(
            number: 7, disks: [data], isPaused: false, agentEjects: true, consent: .none,
            expected: .remind([data])),
        Row(number: 8, disks: [data], isPaused: false, agentEjects: true, consent: reminder, expected: .proceed),
        // 10. Running with no agent to eject it: the warning.
        Row(
            number: 10, disks: [data], isPaused: false, agentEjects: false, consent: .none,
            expected: .warn([USBDiskAtRisk(disk: data, risk: .noAgent)])),
        Row(
            number: 10, disks: [data], isPaused: false, agentEjects: false, consent: reminder,
            expected: .warn([USBDiskAtRisk(disk: data, risk: .noAgent)])),
        // 11. Paused, which no agent can eject through.
        Row(
            number: 11, disks: [data], isPaused: true, agentEjects: true, consent: .none,
            expected: .warn([USBDiskAtRisk(disk: data, risk: .paused)])),
        Row(
            number: 11, disks: [data], isPaused: true, agentEjects: false, consent: reminder,
            expected: .warn([USBDiskAtRisk(disk: data, risk: .paused)])),
        // 12. The warning's consent proceeds, and covers the reminder.
        Row(number: 12, disks: [data], isPaused: false, agentEjects: false, consent: atRisk, expected: .proceed),
        Row(number: 12, disks: [data, tools], isPaused: true, agentEjects: false, consent: atRisk, expected: .proceed),
        Row(number: 12, disks: [tools], isPaused: false, agentEjects: false, consent: atRisk, expected: .proceed),
    ]

    @Test("Each row of the state table decides as the table says", arguments: rows)
    func decidesTheRow(_ row: Row) {
        let facts = USBSaveFacts(
            vmName: "Ubuntu", disks: row.disks, isPaused: row.isPaused, agentEjects: row.agentEjects)
        #expect(USBSaveDecision.decide(facts, consent: row.consent) == row.expected)
    }

    @Test("The warning names only the disks at risk; the read-only ones go unnamed")
    func theWarningNamesOnlyTheDisksAtRisk() {
        let facts = USBSaveFacts(
            vmName: "Ubuntu", disks: [Self.tools, Self.data], isPaused: false, agentEjects: false)
        #expect(
            USBSaveDecision.decide(facts, consent: .none) == .warn([USBDiskAtRisk(disk: Self.data, risk: .noAgent)]))
    }

    // MARK: - The words

    @Test("The reminder names every disk and the VM, and offers to stop reminding")
    func theReminderWords() throws {
        let prompt = try #require(
            USBSavePrompt.prompt(for: [("Ubuntu", .remind([Self.data, Self.tools]))], action: .suspend))
        #expect(prompt.kind == .unplugUSBDisks)
        #expect(prompt.title == "Suspending unplugs USB disks")
        #expect(
            prompt.message
                == "Kernova unplugs \u{201C}Data.img\u{201D} and \u{201C}Tools.iso\u{201D} from \u{201C}Ubuntu\u{201D} before it suspends, and plugs them back in when you resume."
        )
        #expect(prompt.confirmTitle == "Suspend")
        #expect(!prompt.confirmIsDestructive)
        #expect(prompt.dismissTitle == "Cancel")
        #expect(prompt.offersSuppression)
    }

    @Test("The warning names each disk at risk with its reason, and its action is destructive")
    func theWarningWords() throws {
        let prompt = try #require(
            USBSavePrompt.prompt(
                for: [("Ubuntu", .warn([USBDiskAtRisk(disk: Self.data, risk: .paused)]))], action: .suspend))
        #expect(prompt.kind == .unplugUSBDisksAtRisk)
        #expect(prompt.title == "\u{201C}Data.img\u{201D} may lose changes")
        #expect(
            prompt.message
                == "Kernova unplugs USB disks from \u{201C}Ubuntu\u{201D} before it suspends.\n\n"
                + "\u{201C}Data.img\u{201D} may lose changes: the guest can\u{2019}t eject it while the virtual machine is paused."
        )
        #expect(prompt.confirmTitle == "Suspend Anyway")
        #expect(prompt.confirmIsDestructive)
        #expect(!prompt.offersSuppression)
    }

    @Test("A disk with no agent to eject it says so")
    func theNoAgentReason() throws {
        let prompt = try #require(
            USBSavePrompt.prompt(
                for: [("Ubuntu", .warn([USBDiskAtRisk(disk: Self.data, risk: .noAgent)]))], action: .clone))
        #expect(prompt.message.hasSuffix("without the guest agent, Kernova can\u{2019}t eject it."))
        #expect(prompt.confirmTitle == "Clone Anyway")
    }

    @Test(
        "Each action names its own verb",
        arguments: [
            (USBSaveAction.suspend, "Suspending unplugs USB disks", "Suspend"),
            (.takeSnapshot, "Taking a snapshot unplugs USB disks", "Take Snapshot"),
            (.clone, "Cloning unplugs USB disks", "Clone"),
            (.quit, "Quitting unplugs USB disks", "Quit"),
        ])
    func eachActionNamesItsVerb(action: USBSaveAction, title: String, confirm: String) throws {
        let prompt = try #require(USBSavePrompt.prompt(for: [("Ubuntu", .remind([Self.tools]))], action: action))
        #expect(prompt.title == title)
        #expect(prompt.confirmTitle == confirm)
    }

    @Test("A quit asks one warning for every VM, naming each disk with its VM, when any disk is at risk")
    func aQuitAsksOneWarning() throws {
        let prompt = try #require(
            USBSavePrompt.prompt(
                for: [
                    ("Ubuntu", .warn([USBDiskAtRisk(disk: Self.data, risk: .noAgent)])),
                    ("Fedora", .remind([Self.tools])),
                    ("Idle", .proceed),
                ], action: .quit))
        #expect(prompt.kind == .unplugUSBDisksAtRisk)
        #expect(prompt.message.contains("\u{201C}Data.img\u{201D} from \u{201C}Ubuntu\u{201D} may lose changes"))
        #expect(!prompt.message.contains("Tools.iso"))
        #expect(prompt.confirmTitle == "Quit Anyway")
    }

    @Test("Nothing is asked when every VM proceeds")
    func nothingWhenEveryVMProceeds() {
        #expect(USBSavePrompt.prompt(for: [("Ubuntu", .proceed)], action: .quit) == nil)
    }

    // MARK: - Facts

    @Test("A VM's facts name its removable media by their labels, writable unless read-only")
    func factsNameTheMediaByLabel() {
        let sessionID = UUID()
        let data = RemovableMediaItem(path: "/Volumes/Data.img", readOnly: false, label: "Work")
        let tools = RemovableMediaItem(path: "/Volumes/Tools.iso", readOnly: true, label: "Tools")
        let instance = VMInstanceFixture.make(name: "Ubuntu", phase: .livePaused(sessionID: sessionID)) {
            $0.removableMedia = [data, tools]
        }
        instance.beginSessionContextForTesting()
        for item in [data, tools] {
            instance.recordAttachedMedia(
                RemovableMediaDeviceInfo(id: item.id, path: item.path, readOnly: item.readOnly), for: sessionID)
        }

        let facts = USBSaveFacts(instance)

        #expect(
            facts
                == USBSaveFacts(
                    vmName: "Ubuntu",
                    disks: [USBSaveDisk(name: "Work", writable: true), USBSaveDisk(name: "Tools", writable: false)],
                    isPaused: true, agentEjects: false))
    }

    @Test("A VM with no live session has no disks to ask about")
    func noSessionNoDisks() {
        let instance = VMInstanceFixture.make(phase: .stopped) {
            $0.removableMedia = [RemovableMediaItem(path: "/Volumes/Data.img", readOnly: false)]
        }
        #expect(USBSaveFacts(instance).disks.isEmpty)
    }

    @Test(
        "An accessory counts as a disk when its device or any interface declares mass storage",
        arguments: [
            (UInt8(0x08), [UInt8](), true),
            (0x00, [0x03, 0x08], true),
            (0x00, [0x03], false),
            (0x09, [0x09], false),
        ])
    func massStorageAccessory(deviceClass: UInt8, interfaceClasses: [UInt8], isDisk: Bool) throws {
        var descriptorBytes = [UInt8](repeating: 0, count: 18)
        descriptorBytes[0] = 18
        descriptorBytes[1] = 1
        descriptorBytes[4] = deviceClass
        // A configuration descriptor, then one interface descriptor per class.
        var configuration: [UInt8] = [9, 2, 0, 0, UInt8(interfaceClasses.count), 1, 0, 0x80, 50]
        for (index, interfaceClass) in interfaceClasses.enumerated() {
            configuration += [9, 4, UInt8(index), 0, 0, interfaceClass, 0, 0, 0]
        }
        let descriptor = USBDeviceDescriptor.parse(Data(descriptorBytes))
        let info = USBAccessoryInfo.make(
            registryID: 1, descriptor: try #require(descriptor), configurationDescriptor: Data(configuration),
            node: nil)
        #expect(info.isMassStorage == isDisk)
    }
}
