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

    /// The containers a script names a VM by name under, for a `delete`.
    enum NameForm: CaseIterable, Sendable {
        /// `delete virtual machine "Build"`.
        case application
        /// `delete virtual machine "Build" of network "Lab"`.
        case network
        /// `delete snapshot "Clean" of virtual machine "Build" of network "Lab"`.
        case snapshotOfNetwork
        /// `delete virtual machine "Solo" of network "Lab"`, where the one VM
        /// called Solo is on no network.
        case notOnTheNetwork
        /// `delete virtual machine "Build" of folder "Lab"`.
        case folder
        /// `delete virtual machine "Solo" of folder "Lab"`, where the one VM
        /// called Solo is in no folder.
        case notInTheFolder

        /// The event's reference.
        @MainActor
        func reference() -> NSAppleEventDescriptor {
            let lab = ScriptEvent.element("KvNw", named: "Lab")
            let folder = ScriptEvent.element("KvGF", named: "Lab")
            return switch self {
            case .application: VMLibraryScriptingTests.vm(named: "Build")
            case .network: ScriptEvent.element("KvVM", named: "Build", of: lab)
            case .snapshotOfNetwork:
                ScriptEvent.element("KvSn", named: "Clean", of: ScriptEvent.element("KvVM", named: "Build", of: lab))
            case .notOnTheNetwork: ScriptEvent.element("KvVM", named: "Solo", of: lab)
            case .folder: ScriptEvent.element("KvVM", named: "Build", of: folder)
            case .notInTheFolder: ScriptEvent.element("KvVM", named: "Solo", of: folder)
            }
        }

        /// Whether the one VM called Solo is the name the form refuses.
        var namesSolo: Bool { self == .notOnTheNetwork || self == .notInTheFolder }
    }

    @Test(
        "A delete naming a VM by a name two VMs share, or by one its container doesn't hold, is refused and deletes nothing",
        arguments: NameForm.allCases)
    func aNameResolvesOnlyAmongItsContainer(form: NameForm) async throws {
        let wired = WiredCommandCore()
        let lab = try wired.core.createNetwork(name: "Lab", kind: .nat)
        func member(_ configuration: inout VMConfiguration) {
            configuration.networkEnabled = true
            configuration.networkMode = .nat
            configuration.networkMembership = .network(lab.id)
            configuration.applyNetworkMode(configuration.networkMode)
        }
        let clean = VMSnapshot(name: "Clean", kind: .cold, macAddress: nil)
        let builds = [
            wired.register(name: "Build", snapshots: [clean], mutate: member),
            wired.register(name: "build", snapshots: [clean], mutate: member),
        ]
        let solo = wired.register(name: "Solo")
        try wired.library.organization.createFolder(named: "Lab", members: builds.map(\.id))
        let host = ScriptHost()
        let gateway = await makeGateway(wired, host: host)

        // A snapshot's delete refuses immediate deletion whatever it names.
        let reply = try await host.send(
            ScriptEvent.delete(
                form.reference(), confirmation: true, immediateDeletion: form != .snapshotOfNetwork),
            to: gateway)

        #expect(reply.errorNumber == Int(errAENoSuchObject))
        let named = form.namesSolo ? [solo] : builds
        for vm in named {
            #expect(reply.errorString?.contains(form.namesSolo ? vm.name : vm.id.uuidString) == true)
        }
        #expect(Set(wired.library.instances.map(\.id)) == Set((builds + [solo]).map(\.id)))
        #expect(wired.storage.deleteVMBundleCallCount + wired.storage.permanentlyDeleteVMBundleCallCount == 0)
        #expect(wired.machineFiles.discardedIDs.isEmpty)
    }

    /// The containers a script names VMs under.
    enum NameContainer: CaseIterable, Sendable {
        case application
        /// The network "Lab".
        case network
        /// The folder "Lab".
        case folder

        /// `virtual machine "<name>"` of the container.
        @MainActor
        func vm(named name: String) -> NSAppleEventDescriptor {
            ScriptEvent.element("KvVM", named: name, of: container)
        }

        @MainActor
        fileprivate var container: NSAppleEventDescriptor {
            switch self {
            case .application: ScriptEvent.application
            case .network: ScriptEvent.element("KvNw", named: "Lab")
            case .folder: ScriptEvent.element("KvGF", named: "Lab")
            }
        }
    }

    /// The references a name bounds without naming the VM itself.
    enum BoundedForm: CaseIterable, Sendable {
        /// `virtual machines "<name>" thru "Solo"`.
        case range
        /// `virtual machine after virtual machine "<name>"`.
        case relative

        /// The reference `name` bounds, under `container`.
        @MainActor
        func reference(bounding name: String, in container: NameContainer) -> NSAppleEventDescriptor {
            switch self {
            case .range:
                ScriptEvent.range(
                    "KvVM", from: ScriptEvent.rangeEnd("KvVM", named: name),
                    thru: ScriptEvent.rangeEnd("KvVM", named: "Solo"), of: container.container)
            case .relative:
                ScriptEvent.element("KvVM", after: container.vm(named: name))
            }
        }

        /// The names of the VMs a delete of the reference "Alpha" bounds
        /// leaves, of Alpha, Build, build, Solo and Zed.
        var leavesAfterAlpha: [String] {
            switch self {
            case .range: ["Zed"]
            case .relative: ["Alpha", "build", "Solo", "Zed"]
            }
        }
    }

    @Test(
        "A delete of VMs a name two VMs share bounds is refused as that name alone is, and deletes nothing; one VM's name bounds exactly what it says",
        arguments: NameContainer.allCases, BoundedForm.allCases)
    func aBoundingNameResolvesByTheNameRule(container: NameContainer, form: BoundedForm) async throws {
        let wired = WiredCommandCore()
        let lab = try wired.core.createNetwork(name: "Lab", kind: .nat)
        func member(_ configuration: inout VMConfiguration) {
            configuration.networkEnabled = true
            configuration.networkMode = .nat
            configuration.networkMembership = .network(lab.id)
            configuration.applyNetworkMode(configuration.networkMode)
        }
        let vms = ["Alpha", "Build", "build", "Solo", "Zed"].map { wired.register(name: $0, mutate: member) }
        let builds = vms.filter { $0.name.lowercased() == "build" }
        try wired.library.organization.createFolder(named: "Lab", members: vms.map(\.id))
        let host = ScriptHost()
        let gateway = await makeGateway(wired, host: host)
        let alone = try await host.send(
            ScriptEvent.delete(container.vm(named: "Build"), confirmation: true, immediateDeletion: true), to: gateway)

        let ambiguous = try await host.send(
            ScriptEvent.delete(
                form.reference(bounding: "Build", in: container), confirmation: true, immediateDeletion: true),
            to: gateway)

        #expect(alone.errorNumber == Int(errAENoSuchObject))
        #expect(ambiguous.errorNumber == alone.errorNumber)
        #expect(ambiguous.errorString == alone.errorString)
        for build in builds {
            #expect(ambiguous.errorString?.contains(build.id.uuidString) == true)
        }
        #expect(wired.library.instances.map(\.id) == vms.map(\.id))
        #expect(wired.storage.deleteVMBundleCallCount + wired.storage.permanentlyDeleteVMBundleCallCount == 0)

        let named = try await host.send(
            ScriptEvent.delete(
                form.reference(bounding: "Alpha", in: container), confirmation: true, immediateDeletion: true),
            to: gateway)

        #expect(named.errorNumber == 0, "\(named.errorString ?? "")")
        #expect(wired.library.instances.map(\.name) == form.leavesAfterAlpha)
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
