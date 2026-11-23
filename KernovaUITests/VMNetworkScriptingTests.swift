import Cocoa
import CoreServices
import Foundation
import KernovaCommandModel
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport
@testable import KernovaUI

/// The dictionary's `network`: what a script reads, and what `make` and `move` do to the
/// library's networks.
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
}
