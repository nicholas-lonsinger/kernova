import Cocoa
import CoreServices
import Foundation
import KernovaCommandModel
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport
@testable import KernovaUI

/// The dictionary's `network`: what a script reads, and what `make`, `set
/// name` and `delete` do to the library's networks.
///
/// Driven through the gateway and the element objects, with the command Cocoa
/// would be answering stood in by a ``ScriptCommandStandIn``.
@Suite("VM network scripting", .caseScoped)
@MainActor
struct VMNetworkScriptingTests {
    private func makeGateway(_ wired: WiredCommandCore) -> VMScriptingGateway {
        VMScriptingGateway(
            commands: wired.core, readiness: LibraryReadiness(awaitReady: {}),
            prepareToSurface: {})
    }

    /// A gateway whose library read has landed, answering for `standIn`'s
    /// command — which a read before the landing would suspend.
    private func makeLandedGateway(
        _ wired: WiredCommandCore, answering standIn: ScriptCommandStandIn
    ) async -> VMScriptingGateway {
        let readiness = LibraryReadiness(awaitReady: {})
        await readiness.ready()
        return VMScriptingGateway(
            commands: wired.core, readiness: readiness, prepareToSurface: {}, runtime: standIn.runtime)
    }

    /// One of Cocoa's own Standard Suite commands, as the command a KVC call
    /// is answered for.
    private func makeCommand(_ code: String) throws -> NSScriptCommand {
        let description = try #require(
            NSScriptSuiteRegistry.shared().commandDescription(
                withAppleEventClass: FourCharCode(scriptingCode: "core"),
                andAppleEventCode: FourCharCode(scriptingCode: code)))
        return description.createCommandInstance()
    }

    /// A VM set to join `network`, in its kind's mode.
    @discardableResult
    private func registerMember(
        _ wired: WiredCommandCore, name: String, of network: NetworkSummary
    ) -> VMInstance {
        wired.register(name: name) {
            $0.networkEnabled = true
            $0.networkMode = network.kind == .hostOnly ? .hostOnly : .nat
            $0.networkMembership = .network(network.id)
            $0.applyNetworkMode($0.networkMode)
        }
    }

    // MARK: - Reads

    @Test("The elements are the core's networks, each with its kind and the VMs on it")
    func elementsAreTheNetworks() throws {
        let wired = WiredCommandCore()
        let test = try wired.core.createNetwork(name: "Test", kind: .nat)
        let lab = try wired.core.createNetwork(name: "Lab", kind: .hostOnly)
        let alpha = registerMember(wired, name: "Alpha", of: lab)
        wired.register(name: "Beta")

        let networks = makeGateway(wired).networks()

        #expect(networks.map(\.uniqueID) == [lab.id.uuidString, test.id.uuidString])
        #expect(networks.map(\.name) == ["Lab", "Test"])
        #expect(
            networks.map(\.kind)
                == [
                    NSNumber(value: VMScriptNetworkKind.hostOnly.code),
                    NSNumber(value: VMScriptNetworkKind.nat.code),
                ])
        #expect(networks[0].virtualMachines.map(\.uniqueID) == [alpha.id.uuidString])
        #expect(networks[1].virtualMachines.isEmpty)
    }

    // MARK: - Make

    @Test("A make that names no kind makes a NAT network")
    func makeDefaultsToNAT() throws {
        let wired = WiredCommandCore()

        _ = makeGateway(wired).makeElement(forKey: VMScriptingRoot.networksKey, name: "Lab", kind: nil)

        #expect(try wired.core.networks().map(\.kind) == [.nat])
    }

    @Test("A kind from no vocabulary this app writes is refused before the core")
    func anUnknownKindIsRefused() async throws {
        let wired = WiredCommandCore()
        let standIn = ScriptCommandStandIn()
        let gateway = await makeLandedGateway(wired, answering: standIn)
        let command = try makeCommand("crel")
        standIn.command = command

        let made = gateway.makeElement(
            forKey: VMScriptingRoot.networksKey, name: "Lab",
            kind: NSNumber(value: FourCharCode(scriptingCode: "KsSt")))

        #expect(made == nil)
        #expect(try wired.core.networks().isEmpty)
        #expect(command.scriptErrorNumber == Int(errAETypeError))
    }

    @Test("The core's refusal of a make reaches the script in its words")
    func aRefusedMakeReachesTheScript() async throws {
        let wired = WiredCommandCore()
        // A make naming no name asks the core for an empty one.
        let refusal = try #require(throws: CommandError.self) {
            try wired.core.createNetwork(name: "", kind: .nat)
        }
        let standIn = ScriptCommandStandIn()
        let gateway = await makeLandedGateway(wired, answering: standIn)
        let command = try makeCommand("crel")
        standIn.command = command

        #expect(gateway.makeElement(forKey: VMScriptingRoot.networksKey, name: nil, kind: nil) == nil)

        #expect(try wired.core.networks().isEmpty)
        #expect(command.scriptErrorNumber == refusal.appleEventErrorNumber)
        #expect(command.scriptErrorString == refusal.appleEventErrorString)
    }

    @Test("make new virtual machine is refused rather than allocated")
    func makingAVMIsRefused() async throws {
        let wired = WiredCommandCore()
        let standIn = ScriptCommandStandIn()
        let gateway = await makeLandedGateway(wired, answering: standIn)
        let command = try makeCommand("crel")
        standIn.command = command

        #expect(gateway.makeElement(forKey: VMScriptingRoot.virtualMachinesKey, name: nil, kind: nil) == nil)

        #expect(try wired.core.networks().isEmpty)
        #expect(wired.core.list(.all).isEmpty)
        #expect(command.scriptErrorNumber == Int(errAECantHandleClass))
        #expect(command.scriptErrorString == VMScriptingGateway.cannotMakeVirtualMachine)
    }

    // MARK: - Rename

    @Test("A set of the name of several networks stops at the first refusal")
    func aRefusedRenameStopsTheRun() async throws {
        let wired = WiredCommandCore()
        let lab = try wired.core.createNetwork(name: "Lab", kind: .nat)
        try wired.core.createNetwork(name: "Test", kind: .nat)
        // Test already answers to "test", so Lab is refused it; Test itself
        // would take it.
        let refusal = try #require(throws: CommandError.self) {
            try wired.core.renameNetwork(lab.id.uuidString, to: "test")
        }
        let standIn = ScriptCommandStandIn()
        let gateway = await makeLandedGateway(wired, answering: standIn)
        let command = try makeCommand("setd")
        let networks = gateway.networks()
        standIn.command = command

        for network in networks { network.name = "test" }

        #expect(command.scriptErrorString == refusal.message)
        #expect(try wired.core.networks().map(\.name) == ["Lab", "Test"])
    }

    // MARK: - Delete

    @Test("A move's removal is refused, deleting nothing")
    func aMoveDeletesNothing() async throws {
        let wired = WiredCommandCore()
        let lab = try wired.core.createNetwork(name: "Lab", kind: .nat)
        let standIn = ScriptCommandStandIn()
        let gateway = await makeLandedGateway(wired, answering: standIn)
        let command = try makeCommand("move")
        standIn.command = command

        gateway.removeNetwork(at: 0)

        #expect(try wired.core.networks().map(\.id) == [lab.id])
        #expect(command.scriptErrorNumber == Int(errAEEventNotHandled))
    }

    @Test("A delete addressing several networks stops at the first refusal")
    func aRefusedDeleteStopsTheRun() async throws {
        let wired = WiredCommandCore()
        let lab = try wired.core.createNetwork(name: "Lab", kind: .nat)
        let test = try wired.core.createNetwork(name: "Test", kind: .nat)
        registerMember(wired, name: "Alpha", of: test)
        let refusal = try #require(throws: CommandError.self) {
            try wired.core.deleteNetwork(test.id.uuidString)
        }
        let standIn = ScriptCommandStandIn()
        let gateway = await makeLandedGateway(wired, answering: standIn)
        let command = try makeCommand("delo")
        standIn.command = command

        // Cocoa removes from the highest index down.
        gateway.removeNetwork(at: 1)
        gateway.removeNetwork(at: 0)

        #expect(try wired.core.networks().map(\.id) == [lab.id, test.id])
        #expect(command.scriptErrorString == refusal.appleEventErrorString)
    }
}
