import Cocoa
import CoreServices
import Foundation
import KernovaCommandModel
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport
@testable import KernovaUI

/// The dictionary's `shared directory`, `USB accessory` and `remembered USB
/// accessory`: which VM and which item `make`, `delete`, `attach` and
/// `detach` land on, and what the USB terms answer on a Mac or build that
/// can't pass accessories through.
///
/// A script's own events are dispatched to the test host (``ScriptHost``) and
/// answered by the gateway under test.
@Suite("VM sharing scripting", .caseScoped)
@MainActor
struct VMSharingScriptingTests {
    private let scratch = TestScratchDirectory(prefix: "VMSharingScriptingTests")

    /// A gateway whose library read has landed.
    private func makeGateway(_ wired: WiredCommandCore, host: ScriptHost) async -> VMScriptingGateway {
        let readiness = LibraryReadiness(awaitReady: {})
        await readiness.ready()
        return VMScriptingGateway(
            commands: wired.core, readiness: readiness, prepareToSurface: {}, runtime: host.runtime)
    }

    /// A harness whose host passes accessories through, with no USB
    /// controller behind it.
    private func makeUSBHarness() throws -> (wired: WiredCommandCore, service: MockUSBAccessoryService) {
        let wired = WiredCommandCore(usbAccessoryPassthrough: .available(MockUSBAccessoryService()))
        return (wired, try #require(wired.usbAccessories))
    }

    /// A running VM, with the session an accessory attaches to.
    @discardableResult
    private func registerRunning(_ name: String, in wired: WiredCommandCore) -> VMInstance {
        let instance = wired.register(name: name, phase: .running(sessionID: UUID()))
        instance.beginSessionContextForTesting()
        return instance
    }

    /// `virtual machine "<name>"`.
    fileprivate static func vm(named name: String) -> NSAppleEventDescriptor {
        ScriptEvent.element("KvVM", named: name)
    }

    /// The paths of `instance`'s shares, in the one spelling the core
    /// compares them in.
    private static func sharedPaths(of instance: VMInstance) -> [String] {
        (instance.configuration.sharedDirectories ?? []).map { VMCommandCore.comparablePath($0.path) }
    }

    // MARK: - Shared directories

    /// The ways a script names the VM a `make new shared directory` is made
    /// at.
    enum MakeForm: CaseIterable, Sendable {
        /// `make new shared directory at virtual machine "Beta" …`
        case atTheVM
        /// `make new shared directory at end of shared directories of
        /// virtual machine "Beta" …`
        case atTheEndOfItsShares
        /// `tell virtual machine "Beta" to make new shared directory …`
        case toldTheVM

        /// The event, as AppleScript sends this form, with `properties`.
        @MainActor
        func event(properties: [String: NSAppleEventDescriptor]) -> NSAppleEventDescriptor {
            let beta = VMSharingScriptingTests.vm(named: "Beta")
            return switch self {
            case .atTheVM: ScriptEvent.make(new: "KvSh", at: beta, properties: properties)
            case .atTheEndOfItsShares:
                ScriptEvent.make(
                    new: "KvSh", at: ScriptEvent.end(of: ScriptEvent.every("KvSh", of: beta)), properties: properties)
            case .toldTheVM: ScriptEvent.told(ScriptEvent.make(new: "KvSh", properties: properties), to: beta)
            }
        }
    }

    @Test(
        "make new shared directory shares the folder named with the VM named, read only as asked, and a delete of its answer stops sharing that folder alone",
        arguments: MakeForm.allCases)
    func aShareLandsOnTheVMAndFolderItNames(form: MakeForm) async throws {
        let wired = WiredCommandCore()
        let kept = "/Volumes/Archive/Kept"
        let alpha = wired.register(name: "Alpha")
        let beta = wired.register(name: "Beta") { $0.sharedDirectories = [SharedDirectory(path: kept)] }
        let folder = VMCommandCore.comparablePath(
            scratch.url.appendingPathComponent("Projects").path(percentEncoded: false))
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let host = ScriptHost()
        let gateway = await makeGateway(wired, host: host)

        let made = try await host.send(
            form.event(properties: [
                "KvPa": NSAppleEventDescriptor(string: folder), "KvRo": NSAppleEventDescriptor(boolean: true),
            ]),
            to: gateway)

        try #require(made.errorNumber == 0, "\(form): \(made.errorString ?? "")")
        // The folder reached the core's add, which asks the sandbox for it.
        #expect(wired.authority.requests.map(\.source) == [.sharedDirectory])
        #expect(Self.sharedPaths(of: beta) == [kept, folder])
        #expect(beta.configuration.sharedDirectories?.map(\.readOnly) == [false, true])
        #expect(Self.sharedPaths(of: alpha).isEmpty)
        let reference = try #require(made.descriptor)

        let deleted = try await host.send(ScriptEvent.delete(reference), to: gateway)

        #expect(deleted.errorNumber == 0, "\(deleted.errorString ?? "")")
        #expect(Self.sharedPaths(of: beta) == [kept])
        #expect(FileManager.default.fileExists(atPath: folder))
    }

    // MARK: - USB accessories

    @Test(
        "attach passes the accessory named through to the VM named and remembers it there; a delete of that forgets it, and detach takes it back"
    )
    func attachAndDetachLandOnTheAccessoryAndVMNamed() async throws {
        let (wired, service) = try makeUSBHarness()
        let alpha = registerRunning("Alpha", in: wired)
        let beta = registerRunning("Beta", in: wired)
        let drive = MockUSBAccessoryService.accessory(
            registryID: 7, serial: "AAAA", vendorName: "SanDisk", productName: "Ultra")
        let stick = MockUSBAccessoryService.accessory(
            registryID: 8, serial: "BBBB", vendorName: "Kingston", productName: "DataTraveler")
        service.accessories = [drive, stick]
        let device = UUID()
        service.nextDeviceID = device
        let host = ScriptHost()
        let gateway = await makeGateway(wired, host: host)

        let attached = try await host.send(
            ScriptEvent.attach(ScriptEvent.element("KvUA", named: "Kingston DataTraveler"), to: Self.vm(named: "Beta")),
            to: gateway)

        try #require(attached.errorNumber == 0, "\(attached.errorString ?? "")")
        #expect(service.attachedRegistryIDs == [stick.registryID])
        #expect(beta.liveUSBAccessories.map(\.accessory.registryID) == [stick.registryID])
        #expect(alpha.liveUSBAccessories.isEmpty)
        let remembered = try await host.send(
            ScriptEvent.get(ScriptEvent.property("KvKy", of: ScriptEvent.every("KvRA", of: Self.vm(named: "Beta")))),
            to: gateway)
        #expect(remembered.items.map(\.stringValue) == [stick.identity?.key])

        let forgotten = try await host.send(
            ScriptEvent.delete(ScriptEvent.element("KvRA", at: 1, of: Self.vm(named: "Beta"))), to: gateway)
        #expect(forgotten.errorNumber == 0, "\(forgotten.errorString ?? "")")
        #expect(beta.usbPairings.isEmpty)
        #expect(beta.liveUSBAccessories.count == 1)

        let held = ScriptEvent.element("KvUA", named: "Kingston DataTraveler", of: Self.vm(named: "Beta"))
        let detached = try await host.send(ScriptEvent.verb("Dtch", held), to: gateway)

        #expect(detached.errorNumber == 0, "\(detached.errorString ?? "")")
        #expect(service.detachedDeviceIDs == [device])
    }

    @Test(
        "Every USB term refuses with the core's message naming what keeps passthrough from this Mac or build",
        arguments: [USBAccessoryPassthrough.Gap.needsEntitlement, .needsMacOS(27)])
    func theUSBTermsNameTheMissingPrerequisite(gap: USBAccessoryPassthrough.Gap) async throws {
        let wired = WiredCommandCore(usbAccessoryPassthrough: .unavailable(gap))
        registerRunning("Alpha", in: wired)
        let host = ScriptHost()
        let gateway = await makeGateway(wired, host: host)
        let alpha = Self.vm(named: "Alpha")
        let events = [
            ScriptEvent.get(ScriptEvent.every("KvUA")),
            ScriptEvent.get(ScriptEvent.every("KvUA", of: alpha)),
            ScriptEvent.get(ScriptEvent.every("KvRA", of: alpha)),
            ScriptEvent.attach(ScriptEvent.element("KvUA", at: 1), to: alpha),
            ScriptEvent.verb("Dtch", ScriptEvent.element("KvUA", at: 1, of: alpha)),
            ScriptEvent.delete(ScriptEvent.element("KvRA", at: 1, of: alpha)),
        ]

        for event in events {
            let reply = try await host.send(event, to: gateway)
            #expect(reply.errorNumber == Int(errAEEventFailed), "\(event)")
            #expect(
                reply.errorString == VMCommandCore.usbPassthroughRefusal(gap).message(in: .appleScript), "\(event)")
        }
    }

    // MARK: - Names

    /// The listed things a script names by a name several of them can carry.
    enum Listed: CaseIterable, Sendable {
        /// Two shares of folders called Projects.
        case sharedDirectory
        /// Two remembered accessories called Drive.
        case rememberedUSBAccessory
        /// Two attached accessories called SanDisk Ultra.
        case usbAccessory
    }

    @Test(
        "A name two of a VM's items carry refuses, naming what names each alone, and changes nothing; that names the one",
        arguments: Listed.allCases)
    func aSharedNameRefuses(listed: Listed) async throws {
        let (wired, service) = try makeUSBHarness()
        let first = "/Volumes/One/Projects"
        let second = "/Volumes/Two/Projects"
        let pairings = ["0403:6001:0100:AAAA", "0403:6001:0100:BBBB"].map {
            USBAccessoryPairing(key: $0, form: .serialNumber, displayName: "Drive", receptacleLabel: nil)
        }
        let devices = [UUID(), UUID()]
        let alpha: VMInstance
        switch listed {
        case .sharedDirectory:
            alpha = wired.register(name: "Alpha") {
                $0.sharedDirectories = [SharedDirectory(path: first), SharedDirectory(path: second)]
            }
        case .rememberedUSBAccessory:
            alpha = wired.register(name: "Alpha")
            for pairing in pairings {
                try alpha.activity.edit(.pairingRules) { try wired.library.pairUSBAccessory(pairing, $0) }
            }
        case .usbAccessory:
            alpha = registerRunning("Alpha", in: wired)
            let units = [7, 8].map {
                MockUSBAccessoryService.accessory(
                    registryID: UInt64($0), serial: "\($0)", vendorName: "SanDisk", productName: "Ultra")
            }
            service.accessories = units
            for (unit, device) in zip(units, devices) {
                service.nextDeviceID = device
                try await wired.core.attachUSBAccessory(.id(alpha.id), accessory: unit.registryID)
            }
        }
        let host = ScriptHost()
        let gateway = await makeGateway(wired, host: host)
        let vm = Self.vm(named: "Alpha")

        let (shared, alone, identifiers): (String, String, [String]) =
            switch listed {
            case .sharedDirectory: ("projects", "\(second)/", [first, second])
            case .rememberedUSBAccessory: ("drive", pairings[1].key, pairings.map(\.key))
            case .usbAccessory: ("sanDisk ultra", "8", ["7", "8"])
            }
        let event = { (name: String) -> NSAppleEventDescriptor in
            switch listed {
            case .sharedDirectory: ScriptEvent.delete(ScriptEvent.element("KvSh", named: name, of: vm))
            case .rememberedUSBAccessory: ScriptEvent.delete(ScriptEvent.element("KvRA", named: name, of: vm))
            case .usbAccessory: ScriptEvent.verb("Dtch", ScriptEvent.element("KvUA", named: name, of: vm))
            }
        }
        let state = {
            (Self.sharedPaths(of: alpha), alpha.usbPairings.pairings.map(\.key), service.detachedDeviceIDs)
        }
        let before = state()

        let refused = try await host.send(event(shared), to: gateway)

        #expect(refused.errorNumber == Int(errAENoSuchObject))
        for identifier in identifiers {
            #expect(refused.errorString?.contains(identifier) == true, "\(refused.errorString ?? "")")
        }
        #expect(state() == before)

        let named = try await host.send(event(alone), to: gateway)

        #expect(named.errorNumber == 0, "\(named.errorString ?? "")")
        switch listed {
        case .sharedDirectory: #expect(Self.sharedPaths(of: alpha) == [first])
        case .rememberedUSBAccessory: #expect(alpha.usbPairings.pairings.map(\.key) == [pairings[0].key])
        case .usbAccessory: #expect(service.detachedDeviceIDs == [devices[1]])
        }
    }
}
