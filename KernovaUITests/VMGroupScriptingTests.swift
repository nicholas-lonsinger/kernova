import Cocoa
import CoreServices
import Foundation
import KernovaCommandModel
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport
@testable import KernovaUI

/// The verbs of a group action — `start`, `suspend`, `stop`, `restart` —
/// given VMs or a smart group or folder: which VMs they land on, what they
/// answer, and how a group action fails for a VM it left undone.
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

    /// The ways a script names the VMs a verb lands on, and the names of
    /// those VMs, in order. The library holds Alpha, Beta and Gamma, and the
    /// folder One holds Beta alone.
    enum VMForm: CaseIterable, Sendable {
        /// `virtual machine "alpha"`, a name the core resolves ignoring case.
        case named
        /// `virtual machine 2`, an index Cocoa evaluates.
        case indexed
        /// `{virtual machine id "<Beta's>", virtual machine "Alpha"}`.
        case list
        /// `every virtual machine whose name is "Beta"`.
        case whose
        /// `every virtual machine of folder "One"`.
        case every
        /// `virtual machine 1 of every folder whose name is "One"`.
        case ofEvery
        /// `virtual machines "Beta" thru "Beta"`.
        case namedRange

        /// The event's reference, and the names of the VMs it lands on.
        @MainActor
        fileprivate func reference(beta: UUID) -> (NSAppleEventDescriptor, [String]) {
            let one = ScriptEvent.every(
                "KvGF",
                whose: ScriptEvent.equals(
                    ScriptEvent.property("pnam", of: ScriptEvent.examined), NSAppleEventDescriptor(string: "One")))
            switch self {
            case .named:
                return (ScriptEvent.element("KvVM", named: "alpha"), ["Alpha"])
            case .indexed:
                return (ScriptEvent.element("KvVM", at: 2), ["Beta"])
            case .list:
                let list = NSAppleEventDescriptor.list()
                list.insert(ScriptEvent.element("KvVM", id: beta.uuidString), at: 1)
                list.insert(ScriptEvent.element("KvVM", named: "Alpha"), at: 2)
                return (list, ["Beta", "Alpha"])
            case .whose:
                let name = ScriptEvent.property("pnam", of: ScriptEvent.examined)
                return (
                    ScriptEvent.every("KvVM", whose: ScriptEvent.equals(name, NSAppleEventDescriptor(string: "Beta"))),
                    ["Beta"]
                )
            case .every:
                return (ScriptEvent.every("KvVM", of: ScriptEvent.element("KvGF", named: "One")), ["Beta"])
            case .ofEvery:
                return (ScriptEvent.element("KvVM", at: 1, of: one), ["Beta"])
            case .namedRange:
                return (
                    ScriptEvent.range(
                        "KvVM", from: ScriptEvent.rangeEnd("KvVM", named: "Beta"),
                        thru: ScriptEvent.rangeEnd("KvVM", named: "Beta")),
                    ["Beta"]
                )
            }
        }

        /// Whether the form names a list, which a verb answers as one however
        /// many VMs it acted on.
        var namesAList: Bool {
            switch self {
            case .named, .indexed: false
            case .list, .whose, .every, .ofEvery, .namedRange: true
            }
        }
    }

    @Test(
        "A verb given VMs answers each one it acted on by identifier: a reference for one named alone, a list in order for a list, a range, every or whose",
        arguments: ["Strt", "Stop", "Susp", "Rstr"], VMForm.allCases)
    func aVerbAnswersTheVMsItActedOn(verb: String, form: VMForm) async throws {
        let wired = WiredCommandCore(virtualization: MockVirtualizationService())
        let phase: VMLifecyclePhase = verb == "Strt" ? .stopped : .running(sessionID: UUID())
        let vms = ["Alpha", "Beta", "Gamma"].map { wired.register(name: $0, phase: phase) }
        try wired.library.organization.createFolder(named: "One", members: [vms[1].id])
        let host = ScriptHost()
        let gateway = await makeGateway(wired, host: host)
        let (reference, named) = form.reference(beta: vms[1].id)

        let reply = try await host.send(ScriptEvent.verb(verb, reference), to: gateway)

        #expect(reply.errorNumber == 0, "\(reply.errorString ?? "")")
        let answer = try #require(reply.descriptor)
        #expect(answer.descriptorType == (form.namesAList ? typeAEList : typeObjectSpecifier))
        for item in answer.items {
            #expect(item.forKeyword(ScriptEvent.code("form"))?.enumCodeValue == ScriptEvent.code("ID  "))
        }
        #expect(Self.answered(reply) == named.compactMap { name in vms.first { $0.name == name }?.id })
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
