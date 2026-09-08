import Cocoa
import Foundation
import KernovaKit
import Testing

@testable import Kernova

/// How an Apple event's addressing becomes the core's ``VMSelector``.
///
/// Driven through a real ``VMScriptCommand`` built from the dictionary's own
/// description, so the two slots an event can carry its addressing in are read
/// the way Cocoa fills them.
@Suite("VM script selector", .admissionGated)
@MainActor
struct VMScriptSelectorTests {
    private func makeCommand() throws -> VMScriptCommand {
        let description = try #require(
            NSScriptSuiteRegistry.shared().commandDescription(
                withAppleEventClass: FourCharCode(scriptingCode: "Krnv"),
                andAppleEventCode: FourCharCode(scriptingCode: "Paus")))
        return VMScriptCommand(commandDescription: description)
    }

    private func makeContainer() throws -> NSScriptClassDescription {
        try #require(NSScriptClassDescription(for: NSApplication.self))
    }

    private func makeObject(id: UUID = UUID(), name: String = "Alpha") -> VMScriptObject {
        VMScriptObject(
            VMInfo(
                id: id, name: name, status: "stopped", guestOS: "linux", cpuCount: 2,
                memoryBytes: 4 << 30, diskSizeInGB: 64, networkMode: nil, macAddress: nil,
                ipAddress: .unavailable, agentStatus: "notInstalled", hasSavedState: false,
                isEphemeral: false, snapshotCount: 0, bundlePath: "/VMs/\(name).kernova"))
    }

    @Test("An identifier the event named is read without evaluating it")
    func aUniqueIDSpecifierIsReadDirectly() throws {
        let id = UUID()
        let command = try makeCommand()
        command.receiversSpecifier = NSUniqueIDSpecifier(
            containerClassDescription: try makeContainer(), containerSpecifier: nil,
            key: AppDelegate.virtualMachinesKey, uniqueID: id.uuidString)

        #expect(command.addressedVMs == [.id(id)])
    }

    @Test("A name the event named reaches the core as a name, not as what it resolves to")
    func aNameSpecifierIsReadDirectly() throws {
        let command = try makeCommand()
        command.receiversSpecifier = NSNameSpecifier(
            containerClassDescription: try makeContainer(), containerSpecifier: nil,
            key: AppDelegate.virtualMachinesKey, name: "Alpha")

        // The core is what refuses a name several VMs answer to, with the
        // candidates listed; resolving here would lose that.
        #expect(command.addressedVMs == [.name("Alpha")])
    }

    @Test("An identifier Kernova never issued is left to the evaluation to refuse")
    func anUnparsableIdentifierReadsAsNoSelector() throws {
        let command = try makeCommand()
        command.receiversSpecifier = NSUniqueIDSpecifier(
            containerClassDescription: try makeContainer(), containerSpecifier: nil,
            key: AppDelegate.virtualMachinesKey, uniqueID: "not-a-uuid")

        #expect(command.addressedVMs.isEmpty)
    }

    @Test("A position only Cocoa can read carries no selector of its own")
    func anIndexSpecifierCarriesNoSelector() throws {
        let specifier = NSIndexSpecifier(
            containerClassDescription: try makeContainer(), containerSpecifier: nil,
            key: AppDelegate.virtualMachinesKey, index: 0)

        // What is left is the evaluation — the branch a running app takes for
        // `every`, a range, and a `whose` test too.
        #expect(VMScriptSelector.selectors(addressing: specifier, resolving: nil).isEmpty)
    }

    @Test("A VM Cocoa resolved is addressed by its identifier")
    func aResolvedObjectIsAddressedByIdentifier() throws {
        let id = UUID()
        let command = try makeCommand()
        command.directParameter = makeObject(id: id)

        #expect(command.addressedVMs == [.id(id)])
    }

    @Test("Several resolved VMs are addressed in the order the event named them")
    func resolvedObjectsKeepTheirOrder() throws {
        let first = UUID()
        let second = UUID()

        let selectors = VMScriptSelector.selectors(
            addressing: nil, resolving: [makeObject(id: first), makeObject(id: second)])

        #expect(selectors == [.id(first), .id(second)])
    }

    @Test("An event addressing nothing this app knows carries no selector")
    func anUnknownReceiverCarriesNoSelector() throws {
        let command = try makeCommand()
        command.directParameter = "Alpha"

        #expect(command.addressedVMs.isEmpty)
    }
}
