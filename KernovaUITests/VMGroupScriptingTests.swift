import Cocoa
import CoreServices
import Foundation
import KernovaCommandModel
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport
@testable import KernovaUI

/// The dictionary's `smart group` and `folder` given to a lifecycle command:
/// which VMs the group action lands on, what it answers, and how it fails for
/// a VM it left undone.
///
/// A script's own events are dispatched to the test host (``ScriptHost``) and
/// answered by the gateway under test.
@Suite("VM group scripting", .caseScoped)
@MainActor
struct VMGroupScriptingTests {
    /// A gateway whose library read has landed.
    private func makeGateway(_ wired: WiredCommandCore, host: ScriptHost) async -> VMScriptingGateway {
        let readiness = LibraryReadiness(awaitReady: {})
        await readiness.ready()
        return VMScriptingGateway(
            commands: wired.core, readiness: readiness, prepareToSurface: {}, runtime: host.runtime)
    }

    /// `smart group "<name>"` or `folder "<name>"`.
    private static func group(_ kind: VMGroupKind, named name: String) -> NSAppleEventDescriptor {
        ScriptEvent.element(kind == .folder ? "KvGF" : "KvGS", named: name)
    }

    /// The identifiers of the VMs `reply` answers, in its order.
    private static func answered(_ reply: ScriptReply) -> [UUID] {
        reply.items.compactMap { $0.forKeyword(ScriptEvent.code("seld"))?.stringValue.flatMap(UUID.init(uuidString:)) }
    }

    @Test(
        "stop of a group asks only its own running members to shut down, not another kind's of the same name, and answers just those",
        arguments: VMGroupKind.allCases)
    func aGroupActionLandsOnItsOwnGroup(kind: VMGroupKind) async throws {
        let virtualization = MockVirtualizationService()
        let wired = WiredCommandCore(virtualization: virtualization)
        let beta = wired.register(name: "Beta", phase: .running(sessionID: UUID()))
        let delta = wired.register(name: "Delta", phase: .running(sessionID: UUID()))
        let alpha = wired.register(name: "Alpha")
        // Two groups called Lab: the folder holds Beta and Alpha, the smart
        // group every running VM, Beta and Delta.
        try wired.library.organization.createFolder(named: "Lab", members: [beta.id, alpha.id])
        try wired.library.organization.createSmartGroup(named: "Lab", filter: VMLibraryFilter(states: [.running]))
        let host = ScriptHost()
        let gateway = await makeGateway(wired, host: host)
        let stopped = kind == .folder ? [beta] : [beta, delta]

        let reply = try await host.send(ScriptEvent.verb("Stop", Self.group(kind, named: "Lab")), to: gateway)

        #expect(reply.errorNumber == 0, "\(reply.errorString ?? "")")
        #expect(Self.answered(reply) == stopped.map(\.id))
        #expect(virtualization.stopCallCount == stopped.count)
        #expect(virtualization.forceStopCallCount == 0)
        #expect(beta.status == .stopped)
        #expect(delta.status == (kind == .folder ? .running : .stopped))
        #expect(alpha.status == .stopped)
    }

    @Test("A group start that leaves a VM undone starts the rest, then fails naming that VM in AppleScript's words")
    func aVMLeftUndoneFailsTheGroupAction() async throws {
        let preferences = makeTestPreferences()
        preferences.allowsDuplicateMachineIDOverride = true
        let wired = WiredCommandCore(virtualization: MockVirtualizationService(), preferences: preferences)
        let identity = Data([7, 7, 7])
        wired.register(name: "Live", phase: .running(sessionID: UUID())) { $0.genericMachineIdentifierData = identity }
        let twin = wired.register(name: "Twin") { $0.genericMachineIdentifierData = identity }
        let other = wired.register(name: "Other")
        try wired.library.organization.createFolder(named: "Pair", members: [twin.id, other.id])
        let host = ScriptHost()
        let gateway = await makeGateway(wired, host: host)

        let reply = try await host.send(ScriptEvent.verb("Strt", Self.group(.folder, named: "Pair")), to: gateway)

        #expect(reply.errorNumber == Int(errAEEventFailed))
        let message = try #require(reply.errorString)
        #expect(message.hasPrefix("Skipped Twin: "))
        #expect(message.hasSuffix(" To answer, use start on Twin alone."))
        #expect(!message.contains("Other"))
        #expect(twin.status == .stopped)
        #expect(other.status == .running)
    }
}
