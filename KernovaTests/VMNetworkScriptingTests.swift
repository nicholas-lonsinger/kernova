import Cocoa
import CoreServices
import Foundation
import KernovaKit
import KernovaTestSupport
import Testing

@testable import Kernova

/// The dictionary's `network`: what a script reads, and what `make`, `set
/// name` and `delete` reach the core with.
///
/// Driven through the gateway and the element objects, with the command Cocoa
/// would be answering standing in as ``VMScriptingGateway/answeringCommand``:
/// the Apple event round trip itself takes a live script.
@Suite("VM network scripting", .caseScoped)
@MainActor
struct VMNetworkScriptingTests {
    private func makeGateway(_ commands: MockVMCommanding) -> VMScriptingGateway {
        VMScriptingGateway(
            commands: commands, readiness: LibraryReadiness(awaitReady: {}),
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

    private func makeSummary(name: String) -> VMSummary {
        VMSummary(id: UUID(), name: name, status: "stopped", ipAddress: .unavailable, heldByAnotherCopy: false)
    }

    // MARK: - Reads

    @Test("The elements are the core's networks, each with its kind and the VMs on it")
    func elementsAreTheNetworks() throws {
        let commands = MockVMCommanding()
        let alpha = makeSummary(name: "Alpha")
        commands.library = [alpha]
        let lab = NetworkSummary(id: UUID(), name: "Lab", kind: .hostOnly, members: [alpha])
        let test = NetworkSummary(id: UUID(), name: "Test", kind: .shared, members: [])
        commands.networksToReturn = [lab, test]

        let networks = makeGateway(commands).networks()

        #expect(networks.map(\.uniqueID) == [lab.id.uuidString, test.id.uuidString])
        #expect(networks.map(\.name) == ["Lab", "Test"])
        #expect(
            networks.map(\.kind)
                == [
                    NSNumber(value: VMScriptNetworkKind.hostOnly.code),
                    NSNumber(value: VMScriptNetworkKind.sharedNetwork.code),
                ])
        #expect(networks[0].virtualMachines.map(\.uniqueID) == [alpha.id.uuidString])
        #expect(networks[1].virtualMachines.isEmpty)
    }

    // MARK: - Make

    @Test("make new network reaches the core with the name and kind its properties name")
    func makeCreatesTheNetwork() throws {
        let commands = MockVMCommanding()
        let gateway = makeGateway(commands)
        gateway.answeringCommand = try makeCommand("crel")

        let made = try #require(
            gateway.makeElement(
                forKey: AppDelegate.networksKey, name: "Lab",
                kind: NSNumber(value: VMScriptNetworkKind.hostOnly.code)))

        #expect(commands.createNetworkCalls.map(\.name) == ["Lab"])
        #expect(commands.createNetworkCalls.map(\.kind) == [.hostOnly])
        #expect(made.uniqueID == commands.networksToReturn.first?.id.uuidString)
        #expect(gateway.answeringCommand?.scriptErrorNumber == 0)
    }

    @Test("A make that names no kind makes a Shared Network")
    func makeDefaultsToShared() throws {
        let commands = MockVMCommanding()

        _ = makeGateway(commands).makeElement(forKey: AppDelegate.networksKey, name: "Lab", kind: nil)

        #expect(commands.createNetworkCalls.map(\.kind) == [.shared])
    }

    @Test("A kind from no vocabulary this app writes is refused before the core")
    func anUnknownKindIsRefused() throws {
        let commands = MockVMCommanding()
        let gateway = makeGateway(commands)
        let command = try makeCommand("crel")
        gateway.answeringCommand = command

        let made = gateway.makeElement(
            forKey: AppDelegate.networksKey, name: "Lab",
            kind: NSNumber(value: FourCharCode(scriptingCode: "KsSt")))

        #expect(made == nil)
        #expect(commands.createNetworkCalls.isEmpty)
        #expect(command.scriptErrorNumber == Int(errAETypeError))
    }

    @Test("The core's refusal of a make reaches the script in its words")
    func aRefusedMakeReachesTheScript() throws {
        let commands = MockVMCommanding()
        let refusal = CommandError.invalidArgument("A network needs a name.")
        commands.networkError = refusal
        let gateway = makeGateway(commands)
        let command = try makeCommand("crel")
        gateway.answeringCommand = command

        #expect(gateway.makeElement(forKey: AppDelegate.networksKey, name: nil, kind: nil) == nil)

        #expect(commands.createNetworkCalls.map(\.name) == [""])
        #expect(command.scriptErrorNumber == refusal.appleEventErrorNumber)
        #expect(command.scriptErrorString == refusal.appleEventErrorString)
    }

    @Test("make new virtual machine is refused rather than allocated")
    func makingAVMIsRefused() throws {
        let commands = MockVMCommanding()
        let gateway = makeGateway(commands)
        let command = try makeCommand("crel")
        gateway.answeringCommand = command

        #expect(gateway.makeElement(forKey: AppDelegate.virtualMachinesKey, name: nil, kind: nil) == nil)

        #expect(commands.createNetworkCalls.isEmpty)
        #expect(command.scriptErrorNumber == Int(errAECantHandleClass))
        #expect(command.scriptErrorString == VMScriptingGateway.cannotMakeVirtualMachine)
    }

    // MARK: - Rename

    @Test("Setting a network's name renames it by identifier")
    func settingTheNameRenames() throws {
        let commands = MockVMCommanding()
        let lab = NetworkSummary(id: UUID(), name: "Lab", kind: .shared, members: [])
        commands.networksToReturn = [lab]
        // The object holds its gateway weakly; the app's lives as long as it does.
        let gateway = makeGateway(commands)
        let network = try #require(gateway.networks().first)

        network.name = "Test"

        #expect(commands.renameNetworkCalls.map(\.network) == [lab.id.uuidString])
        #expect(commands.renameNetworkCalls.map(\.newName) == ["Test"])
    }

    @Test("A refused rename is recorded on the set command")
    func aRefusedRenameIsRecorded() throws {
        let commands = MockVMCommanding()
        commands.networksToReturn = [NetworkSummary(id: UUID(), name: "Lab", kind: .shared, members: [])]
        let refusal = CommandError.invalidArgument("A network named “Test” already exists.")
        commands.networkError = refusal
        let gateway = makeGateway(commands)
        let command = try makeCommand("setd")
        let network = try #require(gateway.networks().first)
        gateway.answeringCommand = command

        network.name = "Test"

        #expect(command.scriptErrorNumber == refusal.appleEventErrorNumber)
        #expect(command.scriptErrorString == refusal.message)
    }

    // MARK: - Delete

    @Test("A delete removes the network at the index Cocoa evaluated, by identifier")
    func deleteReachesTheCore() throws {
        let commands = MockVMCommanding()
        let lab = NetworkSummary(id: UUID(), name: "Lab", kind: .shared, members: [])
        let test = NetworkSummary(id: UUID(), name: "Test", kind: .shared, members: [])
        commands.networksToReturn = [lab, test]
        let gateway = makeGateway(commands)
        gateway.answeringCommand = try makeCommand("delo")

        gateway.removeNetwork(at: 1)

        #expect(commands.deleteNetworkCalls == [test.id.uuidString])
    }

    @Test("A move's removal is refused, deleting nothing")
    func aMoveDeletesNothing() throws {
        let commands = MockVMCommanding()
        commands.networksToReturn = [NetworkSummary(id: UUID(), name: "Lab", kind: .shared, members: [])]
        let gateway = makeGateway(commands)
        let command = try makeCommand("move")
        gateway.answeringCommand = command

        gateway.removeNetwork(at: 0)

        #expect(commands.deleteNetworkCalls.isEmpty)
        #expect(command.scriptErrorNumber == Int(errAEEventNotHandled))
    }

    @Test("A delete addressing several networks stops at the first refusal")
    func aRefusedDeleteStopsTheRun() throws {
        let commands = MockVMCommanding()
        let lab = NetworkSummary(id: UUID(), name: "Lab", kind: .shared, members: [])
        let test = NetworkSummary(id: UUID(), name: "Test", kind: .shared, members: [])
        commands.networksToReturn = [lab, test]
        let refusal = CommandError.operationFailed(
            verb: .deleteNetwork, message: "“Alpha” takes no change to its network right now.")
        commands.networkError = refusal
        let gateway = makeGateway(commands)
        let command = try makeCommand("delo")
        gateway.answeringCommand = command

        // Cocoa removes from the highest index down.
        gateway.removeNetwork(at: 1)
        gateway.removeNetwork(at: 0)

        #expect(commands.deleteNetworkCalls == [test.id.uuidString])
        #expect(command.scriptErrorString == refusal.appleEventErrorString)
    }
}
