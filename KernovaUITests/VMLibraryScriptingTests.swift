import Cocoa
import CoreServices
import Foundation
import KernovaCommandModel
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport
@testable import KernovaUI

/// The library's verbs through the Standard Suite: which virtual machines a
/// script's `delete` lands on, past the Trash or not and with what consent,
/// and which one the reference a `duplicate` answers names.
///
/// A script's own events are dispatched to the test host (``ScriptHost``) and
/// answered by the gateway under test.
@Suite("VM library scripting", .caseScoped)
@MainActor
struct VMLibraryScriptingTests {
    /// A gateway whose library read has landed.
    private func makeGateway(_ wired: WiredCommandCore, host: ScriptHost) async -> VMScriptingGateway {
        let readiness = LibraryReadiness(awaitReady: {})
        await readiness.ready()
        return VMScriptingGateway(
            commands: wired.core, readiness: readiness, prepareToSurface: {}, runtime: host.runtime)
    }

    /// `virtual machine "<name>"`.
    fileprivate static func vm(named name: String) -> NSAppleEventDescriptor {
        ScriptEvent.element("KvVM", named: name)
    }

    // MARK: - Delete

    /// A library of three VMs, the last two on the network "Lab": the first
    /// is `virtual machine 1` of the application, the second `virtual machine
    /// 1` of the network.
    @MainActor
    fileprivate struct Library {
        let wired = WiredCommandCore()
        let alpha: VMInstance
        let beta: VMInstance
        let gamma: VMInstance

        init() throws {
            let lab = try wired.core.createNetwork(name: "Lab", kind: .nat)
            func member(_ configuration: inout VMConfiguration) {
                configuration.networkEnabled = true
                configuration.networkMode = .nat
                configuration.networkMembership = .network(lab.id)
                configuration.applyNetworkMode(configuration.networkMode)
            }
            alpha = wired.register(name: "Alpha")
            beta = wired.register(name: "Beta", mutate: member)
            gamma = wired.register(name: "Gamma", mutate: member)
        }
    }

    /// The ways a script names the VMs a `delete` lands on.
    enum DeleteForm: CaseIterable, Sendable {
        /// `delete virtual machine "Beta"`, which a `tell virtual machine
        /// "Beta" to delete` sends too.
        case named
        /// `delete {virtual machine "Alpha", virtual machine id "<Gamma's>"}`,
        /// as a variable holding a list of references sends it.
        case list
        /// `delete virtual machine 1 of network "Lab"`, which is not the
        /// application's `virtual machine 1`.
        case indexOfNetwork
        /// `delete every virtual machine whose name is "Gamma"`.
        case whose

        /// The event, and the names of the VMs it deletes, in order.
        @MainActor
        fileprivate func event(in library: Library) -> (reference: NSAppleEventDescriptor, deletes: [String]) {
            let lab = ScriptEvent.element("KvNw", named: "Lab")
            switch self {
            case .named:
                return (VMLibraryScriptingTests.vm(named: "Beta"), ["Beta"])
            case .list:
                let list = NSAppleEventDescriptor.list()
                list.insert(VMLibraryScriptingTests.vm(named: "Alpha"), at: 1)
                list.insert(ScriptEvent.element("KvVM", id: library.gamma.id.uuidString), at: 2)
                return (list, ["Alpha", "Gamma"])
            case .indexOfNetwork:
                return (ScriptEvent.element("KvVM", at: 1, of: lab), ["Beta"])
            case .whose:
                let name = ScriptEvent.property("pnam", of: ScriptEvent.examined)
                return (
                    ScriptEvent.every("KvVM", whose: ScriptEvent.equals(name, NSAppleEventDescriptor(string: "Gamma"))),
                    ["Gamma"]
                )
            }
        }
    }

    @Test(
        "delete refuses without with confirmation, naming it, then deletes exactly the VMs named, past the Trash only with immediate deletion",
        arguments: DeleteForm.allCases, [false, true])
    func aDeleteLandsOnWhatItNames(form: DeleteForm, immediately: Bool) async throws {
        let library = try Library()
        let wired = library.wired
        let host = ScriptHost()
        let gateway = await makeGateway(wired, host: host)
        let (reference, deletes) = form.event(in: library)
        let first = try #require([library.alpha, library.beta, library.gamma].first { $0.name == deletes[0] })
        let prompt = VMCommandCore.deletePrompt(first, permanently: immediately, externals: [])

        let unconsented = try await host.send(
            ScriptEvent.delete(reference, confirmation: false, immediateDeletion: immediately), to: gateway)

        #expect(unconsented.errorNumber == Int(errAEEventFailed))
        #expect(
            unconsented.errorString
                == CommandError.confirmationRequired(prompt).appleEventErrorString(
                    consenting: CommandError.withConfirmation))
        #expect(unconsented.errorString?.contains("with confirmation") == true)
        #expect(wired.library.instances.map(\.name) == ["Alpha", "Beta", "Gamma"])
        #expect(wired.storage.deleteVMBundleCallCount + wired.storage.permanentlyDeleteVMBundleCallCount == 0)

        let deleted = try await host.send(
            ScriptEvent.delete(reference, confirmation: true, immediateDeletion: immediately), to: gateway)

        #expect(deleted.errorNumber == 0, "\(deleted.errorString ?? "")")
        #expect(wired.library.instances.map(\.name) == ["Alpha", "Beta", "Gamma"].filter { !deletes.contains($0) })
        #expect(wired.storage.deleteVMBundleCallCount == (immediately ? 0 : deletes.count))
        #expect(wired.storage.permanentlyDeleteVMBundleCallCount == (immediately ? deletes.count : 0))
    }

    /// The containers a script names a VM under that do not hold it, for a
    /// `delete`.
    enum ContainerForm: CaseIterable, Sendable {
        /// `delete virtual machine "Solo" of network "Lab"`.
        case network
        /// `delete virtual machine "Solo" of folder "Lab"`.
        case folder

        /// The event's reference.
        @MainActor
        func reference() -> NSAppleEventDescriptor {
            switch self {
            case .network: ScriptEvent.element("KvVM", named: "Solo", of: ScriptEvent.element("KvNw", named: "Lab"))
            case .folder: ScriptEvent.element("KvVM", named: "Solo", of: ScriptEvent.element("KvGF", named: "Lab"))
            }
        }
    }

    @Test(
        "A delete naming a VM by a name its container's members don't go by is refused and deletes nothing",
        arguments: ContainerForm.allCases)
    func aNameResolvesOnlyAmongItsContainer(form: ContainerForm) async throws {
        let wired = WiredCommandCore()
        let lab = try wired.core.createNetwork(name: "Lab", kind: .nat)
        let build = wired.register(name: "Build") { configuration in
            configuration.networkEnabled = true
            configuration.networkMode = .nat
            configuration.networkMembership = .network(lab.id)
            configuration.applyNetworkMode(configuration.networkMode)
        }
        let solo = wired.register(name: "Solo")
        try wired.library.organization.createFolder(named: "Lab", members: [build.id])
        let host = ScriptHost()
        let gateway = await makeGateway(wired, host: host)

        let reply = try await host.send(
            ScriptEvent.delete(form.reference(), confirmation: true, immediateDeletion: true), to: gateway)

        #expect(reply.errorNumber == Int(errAENoSuchObject))
        #expect(reply.errorString?.contains(solo.name) == true)
        #expect(Set(wired.library.instances.map(\.id)) == [build.id, solo.id])
        #expect(wired.storage.deleteVMBundleCallCount + wired.storage.permanentlyDeleteVMBundleCallCount == 0)
    }

    @Test(
        "With two bundles another copy holds storing one name, a script reads no name twice, each name it reads addresses the virtual machine it read it from, and a range ending at a name starts at that one"
    )
    func everyNameAScriptReadsAddressesItsOwnVM() async throws {
        let wired = WiredCommandCore()
        let builds = [wired.register(name: "Build"), wired.register(name: "Build")]
        wired.register(name: "Other")
        // Held as another copy of Kernova holds them, so neither bundle can be
        // given the name it goes by.
        for build in builds { wired.storage.files.holdElsewhere(build.bundleURL) }
        let host = ScriptHost()
        let gateway = await makeGateway(wired, host: host)

        let names = try host.run("name of every virtual machine", on: gateway).items.compactMap(\.stringValue)
        let ids = try host.run("id of every virtual machine", on: gateway).items.compactMap(\.stringValue)
        let addressed = names.map { (try? host.run("id of virtual machine \"\($0)\"", on: gateway))?.stringValue }
        let ranged = try host.run(#"id of virtual machines "Build" thru "Other""#, on: gateway).items
            .compactMap(\.stringValue)

        try #require(builds.allSatisfy { wired.storage.bundles[$0.bundleURL]?.name == "Build" })
        #expect(names.count == 3 && Set(names).count == names.count, "\(names)")
        #expect(addressed == ids.map(Optional.some), "\(names) addressed \(addressed), read from \(ids)")
        #expect(ranged.first != nil && ranged.first == names.firstIndex(of: "Build").map { ids[$0] })
    }

    /// A container a script names VMs in, as the words that follow a VM's
    /// reference.
    enum NamingContainer: CaseIterable, Sendable {
        case application
        /// A folder holding the VMs in another order than the library's.
        case folder

        var suffix: String {
            switch self {
            case .application: ""
            case .folder: #" of folder "F""#
            }
        }
    }

    @Test(
        "Text that two VMs' names both match names, alone, the VM a range starting at it starts at, in the application and in a folder whose order is not the library's",
        arguments: NamingContainer.allCases)
    func aNameAloneAndARangeStartScanOneOrder(container: NamingContainer) async throws {
        let wired = WiredCommandCore()
        // Cocoa's comparison finds "\u{1FF6}" the same as each of the first
        // two names, which are not one name.
        let first = wired.register(name: "\u{03A9}\u{0399}")
        let second = wired.register(name: "\u{03A9}\u{0342}")
        let other = wired.register(name: "Other")
        try wired.library.organization.createFolder(named: "F", members: [second.id, first.id, other.id])
        let host = ScriptHost()
        let gateway = await makeGateway(wired, host: host)

        let named = try host.run("id of virtual machine \"\u{1FF6}\"\(container.suffix)", on: gateway).stringValue
        let ranged = try host.run(
            "id of virtual machines \"\u{1FF6}\" thru \"Other\"\(container.suffix)", on: gateway
        ).items.compactMap(\.stringValue)

        #expect(named != nil)
        #expect(ranged.first == named, "\(ranged) began elsewhere than \(named ?? "nothing")")
    }

    // MARK: - Duplicate

    @Test(
        "duplicate answers the clone it made, as the outcome as names or else the Clone as setting, and a delete of that answer lands on the clone",
        arguments: [nil, CloneOutcome.newMachine, .exactCopy])
    func aDuplicateAnswersItsClone(outcome: CloneOutcome?) async throws {
        let preferences = makeTestPreferences()
        preferences.cloneOutcome = .exactCopy
        let wired = WiredCommandCore(preferences: preferences)
        let source = wired.register(name: "Alpha") { $0.mintMACAddressIfNeeded() }
        let sourceMAC = try #require(source.configuration.macAddress)
        let host = ScriptHost()
        let gateway = await makeGateway(wired, host: host)
        let code: String? =
            switch outcome {
            case nil: nil
            case .newMachine: "KcNm"
            case .exactCopy: "KcEx"
            }

        let duplicated = try await host.send(ScriptEvent.duplicate(Self.vm(named: "Alpha"), as: code), to: gateway)

        #expect(duplicated.errorNumber == 0, "\(duplicated.errorString ?? "")")
        let answer = try #require(duplicated.descriptor)
        #expect(answer.forKeyword(ScriptEvent.code("want"))?.typeCodeValue == ScriptEvent.code("KvVM"))
        let id = try #require(answer.forKeyword(ScriptEvent.code("seld"))?.stringValue.flatMap(UUID.init(uuidString:)))
        let clone = try #require(wired.library.instances.first { $0.id == id })
        #expect(clone.id != source.id)
        #expect((clone.configuration.macAddress == sourceMAC) == (outcome ?? .exactCopy == .exactCopy))

        let deleted = try await host.send(ScriptEvent.delete(answer, confirmation: true), to: gateway)

        #expect(deleted.errorNumber == 0, "\(deleted.errorString ?? "")")
        #expect(wired.library.instances.map(\.id) == [source.id])
    }
}
