import Cocoa
import CoreServices
import Foundation
import KernovaKit
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport
@testable import KernovaUI

/// The dictionary's `network`: what a script reads, and what `make`, `set
/// name` and `delete` do to the library's networks.
///
/// Driven through the gateway and the element objects, with the command Cocoa
/// would be answering standing in as ``VMScriptingGateway/answeringCommand``:
/// the Apple event round trip itself takes a live script.
@Suite("VM network scripting", .caseScoped)
@MainActor
struct VMNetworkScriptingTests {
    private func makeGateway(_ wired: WiredCommandCore) -> VMScriptingGateway {
        VMScriptingGateway(
            commands: wired.core, readiness: LibraryReadiness(awaitReady: {}),
            prepareToSurface: {})
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

    @Test("make new network creates one with the name and kind its properties name")
    func makeCreatesTheNetwork() throws {
        let wired = WiredCommandCore()
        let gateway = makeGateway(wired)
        gateway.answeringCommand = try makeCommand("crel")

        let made = try #require(
            gateway.makeElement(
                forKey: AppDelegate.networksKey, name: "Lab",
                kind: NSNumber(value: VMScriptNetworkKind.hostOnly.code)))

        let listed = try wired.core.networks()
        #expect(listed.map(\.name) == ["Lab"])
        #expect(listed.map(\.kind) == [.hostOnly])
        #expect(made.uniqueID == listed.first?.id.uuidString)
        #expect(gateway.answeringCommand?.scriptErrorNumber == 0)
    }

    @Test("A make that names no kind makes a NAT network")
    func makeDefaultsToNAT() throws {
        let wired = WiredCommandCore()

        _ = makeGateway(wired).makeElement(forKey: AppDelegate.networksKey, name: "Lab", kind: nil)

        #expect(try wired.core.networks().map(\.kind) == [.nat])
    }

    @Test("A kind from no vocabulary this app writes is refused before the core")
    func anUnknownKindIsRefused() throws {
        let wired = WiredCommandCore()
        let gateway = makeGateway(wired)
        let command = try makeCommand("crel")
        gateway.answeringCommand = command

        let made = gateway.makeElement(
            forKey: AppDelegate.networksKey, name: "Lab",
            kind: NSNumber(value: FourCharCode(scriptingCode: "KsSt")))

        #expect(made == nil)
        #expect(try wired.core.networks().isEmpty)
        #expect(command.scriptErrorNumber == Int(errAETypeError))
    }

    @Test("The core's refusal of a make reaches the script in its words")
    func aRefusedMakeReachesTheScript() throws {
        let wired = WiredCommandCore()
        // A make naming no name asks the core for an empty one.
        let refusal = try #require(throws: CommandError.self) {
            try wired.core.createNetwork(name: "", kind: .nat)
        }
        let gateway = makeGateway(wired)
        let command = try makeCommand("crel")
        gateway.answeringCommand = command

        #expect(gateway.makeElement(forKey: AppDelegate.networksKey, name: nil, kind: nil) == nil)

        #expect(try wired.core.networks().isEmpty)
        #expect(command.scriptErrorNumber == refusal.appleEventErrorNumber)
        #expect(command.scriptErrorString == refusal.appleEventErrorString)
    }

    @Test("make new virtual machine is refused rather than allocated")
    func makingAVMIsRefused() throws {
        let wired = WiredCommandCore()
        let gateway = makeGateway(wired)
        let command = try makeCommand("crel")
        gateway.answeringCommand = command

        #expect(gateway.makeElement(forKey: AppDelegate.virtualMachinesKey, name: nil, kind: nil) == nil)

        #expect(try wired.core.networks().isEmpty)
        #expect(wired.core.list(.all).isEmpty)
        #expect(command.scriptErrorNumber == Int(errAECantHandleClass))
        #expect(command.scriptErrorString == VMScriptingGateway.cannotMakeVirtualMachine)
    }

    // MARK: - Rename

    @Test("Setting a network's name renames it by identifier")
    func settingTheNameRenames() throws {
        let wired = WiredCommandCore()
        let bench = try wired.core.createNetwork(name: "Bench", kind: .nat)
        let lab = try wired.core.createNetwork(name: "Lab", kind: .nat)
        // The object holds its gateway weakly; the app's lives as long as it does.
        let gateway = makeGateway(wired)
        let network = try #require(gateway.networks().last)

        network.name = "Test"

        let listed = try wired.core.networks()
        #expect(listed.map(\.id) == [bench.id, lab.id])
        #expect(listed.map(\.name) == ["Bench", "Test"])
    }

    @Test("A refused rename is recorded on the set command")
    func aRefusedRenameIsRecorded() throws {
        let wired = WiredCommandCore()
        let lab = try wired.core.createNetwork(name: "Lab", kind: .nat)
        try wired.core.createNetwork(name: "Test", kind: .nat)
        let refusal = try #require(throws: CommandError.self) {
            try wired.core.renameNetwork(lab.id.uuidString, to: "Test")
        }
        let gateway = makeGateway(wired)
        let command = try makeCommand("setd")
        let network = try #require(gateway.networks().first)
        gateway.answeringCommand = command

        network.name = "Test"

        #expect(command.scriptErrorNumber == refusal.appleEventErrorNumber)
        #expect(command.scriptErrorString == refusal.message)
        #expect(try wired.core.networks().map(\.name) == ["Lab", "Test"])
    }

    @Test("A set of the name of several networks stops at the first refusal")
    func aRefusedRenameStopsTheRun() throws {
        let wired = WiredCommandCore()
        let lab = try wired.core.createNetwork(name: "Lab", kind: .nat)
        try wired.core.createNetwork(name: "Test", kind: .nat)
        // Test already answers to "test", so Lab is refused it; Test itself
        // would take it.
        let refusal = try #require(throws: CommandError.self) {
            try wired.core.renameNetwork(lab.id.uuidString, to: "test")
        }
        let gateway = makeGateway(wired)
        let command = try makeCommand("setd")
        let networks = gateway.networks()
        gateway.answeringCommand = command

        for network in networks { network.name = "test" }

        #expect(command.scriptErrorString == refusal.message)
        #expect(try wired.core.networks().map(\.name) == ["Lab", "Test"])
    }

    // MARK: - Delete

    @Test("A delete removes the network at the index Cocoa evaluated, by identifier")
    func deleteReachesTheCore() throws {
        let wired = WiredCommandCore()
        let lab = try wired.core.createNetwork(name: "Lab", kind: .nat)
        try wired.core.createNetwork(name: "Test", kind: .nat)
        let gateway = makeGateway(wired)
        gateway.answeringCommand = try makeCommand("delo")

        gateway.removeNetwork(at: 1)

        #expect(try wired.core.networks().map(\.id) == [lab.id])
        #expect(gateway.answeringCommand?.scriptErrorNumber == 0)
    }

    @Test("A move's removal is refused, deleting nothing")
    func aMoveDeletesNothing() throws {
        let wired = WiredCommandCore()
        let lab = try wired.core.createNetwork(name: "Lab", kind: .nat)
        let gateway = makeGateway(wired)
        let command = try makeCommand("move")
        gateway.answeringCommand = command

        gateway.removeNetwork(at: 0)

        #expect(try wired.core.networks().map(\.id) == [lab.id])
        #expect(command.scriptErrorNumber == Int(errAEEventNotHandled))
    }

    @Test("A delete addressing several networks stops at the first refusal")
    func aRefusedDeleteStopsTheRun() throws {
        let wired = WiredCommandCore()
        let lab = try wired.core.createNetwork(name: "Lab", kind: .nat)
        let test = try wired.core.createNetwork(name: "Test", kind: .nat)
        registerMember(wired, name: "Alpha", of: test)
        let refusal = try #require(throws: CommandError.self) {
            try wired.core.deleteNetwork(test.id.uuidString)
        }
        let gateway = makeGateway(wired)
        let command = try makeCommand("delo")
        gateway.answeringCommand = command

        // Cocoa removes from the highest index down.
        gateway.removeNetwork(at: 1)
        gateway.removeNetwork(at: 0)

        #expect(try wired.core.networks().map(\.id) == [lab.id, test.id])
        #expect(command.scriptErrorString == refusal.appleEventErrorString)
    }
}
