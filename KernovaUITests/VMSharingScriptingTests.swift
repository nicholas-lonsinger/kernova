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

    /// The paths of `instance`'s shares, each as ``FileIdentity/spelling(_:)``
    /// spells it.
    private static func sharedPaths(of instance: VMInstance) -> [String] {
        (instance.configuration.sharedDirectories ?? []).map { FileIdentity.spelling(URL(fileURLWithPath: $0.path)) }
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
        let folder = FileIdentity.spelling(scratch.url.appendingPathComponent("Projects"))
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

    @Test(
        "A configuration storing one name on two shares reads as names of their own, each addressing the share it was read from, and a range ending at a name starts at that one"
    )
    func everyNameAScriptReadsAddressesItsOwnShare() async throws {
        let wired = WiredCommandCore()
        let alpha = wired.register(name: "Alpha") {
            $0.sharedDirectories = [
                SharedDirectory(path: "/Volumes/One/Projects"), SharedDirectory(path: "/Volumes/Two/Projects"),
                SharedDirectory(path: "/Volumes/Three/Other"),
            ]
        }
        // As a build that compared mount names exactly could have stored them.
        alpha.seedConfigurationJSON { config in
            guard var shares = config["sharedDirectories"] as? [[String: Any]] else { return }
            shares[1]["mountName"] = "projects"
            config["sharedDirectories"] = shares
        }
        let host = ScriptHost()
        let gateway = await makeGateway(wired, host: host)
        let of = #" of virtual machine "Alpha""#

        let names = try host.run("name of every shared directory\(of)", on: gateway).items.compactMap(\.stringValue)
        let paths = try host.run("path of every shared directory\(of)", on: gateway).items.compactMap(\.stringValue)
        let addressed = names.map {
            (try? host.run("path of shared directory \"\($0)\"\(of)", on: gateway))?.stringValue
        }
        let ranged = try host.run(#"path of shared directories "Projects" thru "Other""# + of, on: gateway).items
            .compactMap(\.stringValue)

        #expect(names.count == 3, "\(names)")
        for (index, name) in names.enumerated() {
            for later in names[(index + 1)...] {
                // Cocoa Scripting's own comparison, which finds a script's
                // element by name.
                let related =
                    (name as NSString).caseInsensitiveCompare(later) == .orderedSame
                    || (later as NSString).caseInsensitiveCompare(name) == .orderedSame
                #expect(!related, "\(names)")
            }
        }
        #expect(addressed == paths.map(Optional.some), "\(names) addressed \(addressed), read from \(paths)")
        #expect(ranged.first != nil && ranged.first == names.firstIndex(of: "Projects").map { paths[$0] })
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
                reply.errorString == gap.refusal.message(in: .appleScript), "\(event)")
        }
    }

    // MARK: - Names

    /// The listed things whose names their devices give.
    enum Listed: CaseIterable, Sendable {
        /// Two remembered accessories a device calls Drive.
        case rememberedUSBAccessory
        /// Two attached accessories a device calls SanDisk Ultra.
        case usbAccessory
    }

    @Test(
        "Two of a VM's items a device names alike list under names of their own, each addressing the one it was read from, and a range ending at a name starts at that one",
        arguments: Listed.allCases)
    func everyNameAScriptReadsAddressesItsOwnAccessory(listed: Listed) async throws {
        let (wired, service) = try makeUSBHarness()
        let alpha: VMInstance
        switch listed {
        case .rememberedUSBAccessory:
            alpha = wired.register(name: "Alpha")
            for key in ["0403:6001:0100:AAAA", "0403:6001:0100:BBBB"] {
                let pairing = USBAccessoryPairing(
                    key: key, form: .serialNumber, displayName: "Drive", receptacleLabel: nil)
                try alpha.activity.edit(.pairingRules) { try wired.library.pairUSBAccessory(pairing, $0) }
            }
        case .usbAccessory:
            alpha = registerRunning("Alpha", in: wired)
            let units = [7, 8].map {
                MockUSBAccessoryService.accessory(
                    registryID: UInt64($0), serial: "\($0)", vendorName: "SanDisk", productName: "Ultra")
            }
            service.accessories = units
            for unit in units {
                service.nextDeviceID = UUID()
                try await wired.core.attachUSBAccessory(.id(alpha.id), accessory: unit.registryID)
            }
        }
        let host = ScriptHost()
        let gateway = await makeGateway(wired, host: host)
        let vm = Self.vm(named: "Alpha")
        let (element, identifier) = listed == .usbAccessory ? ("KvUA", "ID  ") : ("KvRA", "KvKy")
        func read(_ property: String, _ reference: NSAppleEventDescriptor) async throws -> ScriptReply {
            try await host.send(ScriptEvent.get(ScriptEvent.property(property, of: reference)), to: gateway)
        }

        let names = try await read("pnam", ScriptEvent.every(element, of: vm)).items.compactMap(\.stringValue)
        let ids = try await read(identifier, ScriptEvent.every(element, of: vm)).items.compactMap(\.stringValue)
        var addressed: [String?] = []
        for name in names {
            addressed.append(
                try await read(identifier, ScriptEvent.element(element, named: name, of: vm)).descriptor?.stringValue)
        }
        let range = ScriptEvent.elements(element, named: names.first ?? "", through: names.last ?? "", of: vm)
        let ranged = try await read(identifier, range).items.compactMap(\.stringValue)

        try #require(names.count == 2, "\(names)")
        // Cocoa Scripting's own comparison, which finds a script's element by
        // name.
        #expect(
            (names[0] as NSString).caseInsensitiveCompare(names[1]) != .orderedSame
                && (names[1] as NSString).caseInsensitiveCompare(names[0]) != .orderedSame, "\(names)")
        #expect(addressed == ids.map(Optional.some), "\(names) addressed \(addressed), read from \(ids)")
        #expect(ranged == ids, "\(names) ranged over \(ranged), read from \(ids)")
    }
}
