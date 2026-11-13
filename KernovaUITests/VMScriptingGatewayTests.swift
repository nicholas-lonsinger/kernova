import Cocoa
import CoreServices
import Foundation
import KernovaKit
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport
@testable import KernovaUI

/// The Apple event front door: which verb a script runs, what it waits for
/// before running one, how it addresses a VM by name, and how the consent a
/// destructive verb needs is given, and how a command the gateway cannot
/// answer yet — before the library lands, or one reading a VM's storage
/// disks — is suspended and answered.
///
/// A script's own events are dispatched to the test host, in the shape
/// AppleScript sends them (``ScriptEvent``), and answered by the gateway
/// under test (``ScriptHost``).
@Suite("VM scripting gateway", .caseScoped)
@MainActor
struct VMScriptingGatewayTests {
    /// A readiness await the test holds open, so a verb's wait for the first
    /// library read is observable rather than instantaneous.
    @MainActor
    private final class ReadinessGate {
        /// Fires when the gateway starts waiting, and again when it is let go.
        private let gate = AsyncGate()
        private var isOpen = false

        /// Whether the gateway is parked on the readiness await.
        private(set) var isWaiting = false

        /// Suspends until ``open()``, as the app's first library read does.
        ///
        /// A gate no test opens is a test defect, recorded as one — and then
        /// parked for good rather than returned from: a readiness that "lands"
        /// on the backstop resumes whatever the gateway deferred, long after
        /// the test that sent it has ended.
        func wait() async {
            isWaiting = true
            gate.notify()
            do {
                try await gate.wait { self.isOpen }
            } catch {
                Issue.record("readiness gate was never opened: \(error)")
                await VMScriptingGatewayTests.parkForever()
            }
        }

        /// Lands the library read.
        func open() {
            isOpen = true
            gate.notify()
        }

        /// Suspends until the gateway is parked on the await.
        func awaitWaiting() async throws {
            try await gate.wait { self.isWaiting }
        }
    }

    /// A readiness await that never lands and arms no clock, for a deferred
    /// read that must stay parked for the rest of the process's life.
    private static func parkForever() async {
        await withUnsafeContinuation { (_: UnsafeContinuation<Void, Never>) in }
    }

    private func makeGateway(
        _ wired: WiredCommandCore,
        awaitReady: @escaping @Sendable () async -> Void = {},
        prepareToSurface: @escaping @MainActor @Sendable () -> Void = {},
        runtime: VMScriptCommandRuntime = .cocoa
    ) -> VMScriptingGateway {
        VMScriptingGateway(
            commands: wired.core, readiness: LibraryReadiness(awaitReady: awaitReady),
            prepareToSurface: prepareToSurface, runtime: runtime)
    }

    /// A gateway whose library read has already landed, so a command it
    /// answers is suspended for nothing but what that command reads.
    private func makeLandedGateway(
        _ wired: WiredCommandCore, runtime: VMScriptCommandRuntime
    ) async -> VMScriptingGateway {
        let readiness = LibraryReadiness(awaitReady: {})
        await readiness.ready()
        return VMScriptingGateway(
            commands: wired.core, readiness: readiness, prepareToSurface: {}, runtime: runtime)
    }

    /// Cocoa's own `get`, as the command a property read is answered for.
    private func makeGetCommand() throws -> NSScriptCommand {
        let description = try #require(
            NSScriptSuiteRegistry.shared().commandDescription(
                withAppleEventClass: FourCharCode(scriptingCode: "core"),
                andAppleEventCode: FourCharCode(scriptingCode: "getd")))
        return description.createCommandInstance()
    }

    /// Cocoa's own `set`, as the command a property write is answered for.
    private func makeSetCommand() throws -> NSScriptCommand {
        let description = try #require(
            NSScriptSuiteRegistry.shared().commandDescription(
                withAppleEventClass: FourCharCode(scriptingCode: "core"),
                andAppleEventCode: FourCharCode(scriptingCode: "setd")))
        return description.createCommandInstance()
    }

    /// A network list whose one network's kind no kind spells.
    private static let unreadableNetworkList = Data(
        """
        {"networks": [{"id": "6A1F0B2C-3D4E-4F50-8A6B-7C8D9E0F1A2B", "name": "Lab", "kind": "plan9-mode"}]}
        """.utf8)

    private let scratch = TestScratchDirectory(prefix: "VMScriptingGatewayTests")

    // MARK: - Script references

    /// `virtual machine "<name>"`.
    private static func vm(named name: String) -> NSAppleEventDescriptor {
        ScriptEvent.element("KvVM", named: name)
    }

    /// `virtual machine <index>`.
    private static func vm(at index: Int32) -> NSAppleEventDescriptor {
        ScriptEvent.element("KvVM", at: index)
    }

    /// `name of storage disk 1 of it`, as a `whose` test reads it.
    private static let firstDiskName = ScriptEvent.property(
        "pnam", of: ScriptEvent.element("KvSD", at: 1, of: ScriptEvent.examined))

    /// `every virtual machine whose name of storage disk 1 is "<name>"`.
    private static func vms(whoseFirstDiskIs name: String) -> NSAppleEventDescriptor {
        ScriptEvent.every("KvVM", whose: ScriptEvent.equals(firstDiskName, NSAppleEventDescriptor(string: name)))
    }

    /// `every virtual machine whose name of storage disk 1 is not "<name>"`.
    private static func vms(whoseFirstDiskIsNot name: String) -> NSAppleEventDescriptor {
        ScriptEvent.every(
            "KvVM",
            whose: ScriptEvent.not(ScriptEvent.equals(firstDiskName, NSAppleEventDescriptor(string: name))))
    }

    /// `network "<name>"`.
    private static func network(named name: String) -> NSAppleEventDescriptor {
        ScriptEvent.element("KvNw", named: name)
    }

    // MARK: - Reads

    @Test("Every property answers from the VM's own read")
    func propertiesAnswerFromTheRead() async throws {
        let wired = WiredCommandCore()
        let lab = try wired.core.createNetwork(name: "Lab", kind: .nat)
        wired.vmnet.join(.common(.nat), on: "192.168.64.0")
        let baseline = VMSnapshot(name: "Baseline", createdAt: Date(timeIntervalSince1970: 1), macAddress: nil)
        let later = VMSnapshot(name: "Later", createdAt: Date(timeIntervalSince1970: 2), macAddress: nil)
        let alpha = wired.register(
            name: "Alpha", phase: .running(sessionID: UUID()), guestOS: .macOS, snapshots: [baseline, later],
            hostState: VMHostState(ephemeralModeEnabled: true, ephemeralBaselineSnapshotID: baseline.id)
        ) {
            $0.cpuCount = 6
            $0.memorySizeInGB = .gibibytes(8)
            $0.networkEnabled = true
            $0.networkMode = .nat
            $0.macAddress = "aa:bb:cc:dd:ee:ff"
        }
        alpha.beginSessionContextForTesting().hasAgentTransport = true
        let beta = wired.register(name: "Beta", phase: .suspended)
        try VMInstanceFixture.writeSaveFile(for: beta)
        wired.register(name: "Gamma") {
            $0.networkEnabled = true
            $0.networkMode = .nat
            $0.networkMembership = .network(lab.id)
            $0.applyNetworkMode($0.networkMode)
        }
        wired.arpTable.setTable([
            .scripted("192.168.64.3", mac: "aa:bb:cc:dd:ee:ff", expiry: ARPEntry.freshExpiry)
        ])
        await wired.library.guestAddresses.readForTesting()

        let vms = makeGateway(wired).virtualMachines()
        try #require(vms.count == 3)
        let (vm, suspended, onLab) = (vms[0], vms[1], vms[2])

        #expect(vm.name == "Alpha")
        #expect(vm.state == NSNumber(value: VMScriptState.running.code))
        #expect(vm.guestOperatingSystem == "macOS")
        #expect(vm.processorCount == 6)
        #expect(vm.memory == 8)
        #expect(vm.networkMode == "nat")
        #expect(vm.networkMembership == "common")
        #expect(vm.networkName == nil)
        #expect(vm.macAddress == "aa:bb:cc:dd:ee:ff")
        #expect(vm.ipAddress == "192.168.64.3")
        #expect(vm.agentStatus == "waiting")
        #expect(!vm.hasSavedState)
        #expect(vm.ephemeral)
        #expect(vm.snapshotCount == 2)
        #expect(vm.bundlePath == alpha.bundleURL.path(percentEncoded: false))
        #expect(suspended.state == NSNumber(value: VMScriptState.suspended.code))
        #expect(suspended.hasSavedState)
        // No session, so the agent status reaches a script as missing value.
        #expect(suspended.agentStatus == nil)
        #expect(!suspended.ephemeral)
        #expect(onLab.networkMembership == lab.id.uuidString)
        #expect(onLab.networkName == "Lab")
    }

    @Test("A VM's network name reads as unreadable while the list can't be read, and missing while unlisted")
    func networkNameReadsEachCase() throws {
        func networkName(_ networks: VMNetworkDirectory) throws -> String? {
            let wired = WiredCommandCore(networks: networks)
            wired.register(name: "Alpha") {
                $0.networkEnabled = true
                $0.networkMode = .nat
                $0.networkMembership = .network(UUID())
                $0.applyNetworkMode($0.networkMode)
            }
            return try #require(makeGateway(wired).virtualMachines().first).networkName
        }
        try FileManager.default.createDirectory(at: scratch.url, withIntermediateDirectories: true)
        let unreadable = scratch.url.appendingPathComponent("Networks.json")
        try Self.unreadableNetworkList.write(to: unreadable)

        #expect(try networkName(VMNetworkDirectory(fileURL: unreadable)) == "Network List Can\u{2019}t Be Read")
        #expect(try networkName(VMNetworkDirectory(fileURL: nil)) == nil)
    }

    @Test("A VM with nothing to report on a field answers with missing value")
    func absentFieldsAnswerWithMissingValue() throws {
        let wired = WiredCommandCore()
        wired.register(name: "Alpha") { $0.macAddress = nil }

        let vm = try #require(makeGateway(wired).virtualMachines().first)

        #expect(vm.networkMode == nil)
        #expect(vm.macAddress == nil)
        #expect(vm.ipAddress == nil)
    }

    // MARK: - Configuration

    /// A VM on `mode`'s common network at a known MAC address, attaching
    /// `disks`, or its bundle's main disk alone when `disks` is empty.
    @discardableResult
    private func registerNetworked(
        _ wired: WiredCommandCore, name: String, mode: VMNetworkMode = .nat, disks: [StorageDisk] = []
    ) -> VMInstance {
        wired.register(name: name) {
            $0.networkEnabled = true
            $0.networkMode = mode
            $0.macAddress = "02:4b:4e:56:0c:01"
            $0.storageDisks = disks.isEmpty ? nil : disks
        }
    }

    @Test("A scripted write carries no consent, so one that asks for it is refused and changes nothing")
    func scriptedWriteCarriesNoConsent() async throws {
        let wired = WiredCommandCore()
        let alpha = wired.register(name: "Alpha", guestOS: .macOS) { $0.clipboardSharingEnabled = true }
        let standIn = ScriptCommandStandIn()
        let gateway = await makeLandedGateway(wired, runtime: standIn.runtime)
        let command = try makeSetCommand()
        standIn.command = command

        gateway.setConfiguration(
            alpha.id, key: VMConfigurationKeyRegistry.clipboardPassthrough, value: "true")

        let refusal = CommandError.confirmationRequired(
            ClipboardPassthroughConsent.prompt(vmName: "Alpha"))
        #expect(command.scriptErrorNumber == refusal.appleEventErrorNumber)
        #expect(command.scriptErrorString == refusal.appleEventErrorString)
        #expect(!alpha.configuration.clipboardPassthroughEnabled)
    }

    @Test("Missing value writes none to a VM's network mode, and empty to its membership and MAC address")
    func missingValueWrites() async throws {
        let wired = WiredCommandCore()
        let alpha = registerNetworked(wired, name: "Alpha")
        let standIn = ScriptCommandStandIn()
        let gateway = await makeLandedGateway(wired, runtime: standIn.runtime)
        let vm = try #require(gateway.virtualMachines().first)
        let membership = try makeSetCommand()

        // The core takes no empty membership, and its refusal quotes what was
        // written.
        standIn.command = membership
        vm.networkMembership = nil
        standIn.command = nil
        vm.networkMode = nil
        vm.macAddress = nil

        #expect(
            membership.scriptErrorString
                == "network.membership takes common, isolated, or a network\u{2019}s name or identifier, "
                + "not \u{201C}\u{201D}.")
        #expect(alpha.configuration.networkMembership == .common)
        #expect(!alpha.configuration.networkEnabled)
        #expect(alpha.configuration.macAddress == nil)
    }

    // MARK: - Verb dispatch

    @Test("A refusal stops the run where it happened")
    func aRefusalStopsTheRun() async throws {
        let wired = WiredCommandCore()
        let beta = wired.register(name: "Beta", phase: .running(sessionID: UUID()))

        await #expect(throws: CommandError.notFound(.name("Alpha"))) {
            try await makeGateway(wired).pause([.name("Alpha"), .name("Beta")])
        }

        #expect(beta.status == .running)
    }

    // MARK: - Stop methods

    /// `<verb> virtual machine "<name>" [method <method>] [with confirmation]`,
    /// as AppleScript sends it.
    private static func stopEvent(
        _ verb: String, _ name: String, method: VMScriptStopMethod, confirmation: Bool
    ) -> NSAppleEventDescriptor {
        let event = ScriptEvent.verb(verb, vm(named: name))
        event.setParam(NSAppleEventDescriptor(enumCode: method.code), forKeyword: ScriptEvent.code("KpSm"))
        if confirmation {
            event.setParam(NSAppleEventDescriptor(boolean: true), forKeyword: ScriptEvent.code("Kpcf"))
        }
        return event
    }

    @Test(
        "Each stop method a script names reaches the core as its way down, for stop and restart alike",
        arguments: ["Stop", "Rstr"])
    func eachStopMethodReachesTheCore(verb: String) async throws {
        let virtualization = MockVirtualizationService()
        let wired = WiredCommandCore(virtualization: virtualization)
        let normal = wired.register(name: "Normal", phase: .running(sessionID: UUID()))
        let anyway = wired.register(name: "Anyway", phase: .running(sessionID: UUID()), guestOS: .macOS)
        let forced = wired.register(name: "Forced", phase: .running(sessionID: UUID()))
        let host = ScriptHost()
        let gateway = await makeLandedGateway(wired, runtime: host.runtime)
        let restarts = verb == "Rstr"

        let normalReply = try await host.send(
            Self.stopEvent(verb, "Normal", method: .normal, confirmation: false), to: gateway)
        #expect(normalReply.errorNumber == 0)
        #expect(virtualization.stopCallCount == 1)
        #expect(virtualization.forceStopCallCount == 0)
        #expect(normal.status == (restarts ? .running : .stopped))

        // No agent can take it, so the refusal names the install it needs.
        let anywayReply = try await host.send(
            Self.stopEvent(verb, "Anyway", method: .anyway, confirmation: true), to: gateway)
        #expect(anywayReply.errorString?.contains("\u{201C}For everyone\u{201D}") == true)
        #expect(virtualization.stopCallCount == 1)
        #expect(anyway.status == .running)

        let forcedReply = try await host.send(
            Self.stopEvent(verb, "Forced", method: .force, confirmation: true), to: gateway)
        #expect(forcedReply.errorNumber == 0)
        #expect(virtualization.forceStopCallCount == 1)
        #expect(virtualization.stopCallCount == 1)
        #expect(virtualization.startCallCount == (restarts ? 2 : 0))
        #expect(forced.status == (restarts ? .running : .stopped))
    }

    // MARK: - Addressing

    @Test("A verb's addressing reaches the script with what the core refused")
    func addressingRecordsRefusalsInTheReply() async throws {
        let wired = WiredCommandCore()
        wired.register(name: "Alpha")
        wired.register(name: "Alpha")
        let refusal = try #require(throws: CommandError.self) { try wired.core.info(.name("Alpha")) }
        let host = ScriptHost()
        let gateway = await makeLandedGateway(wired, runtime: host.runtime)

        // `pause storage disk 1 of virtual machine "Alpha"`: the name is
        // evaluated as the disk's container, which the core refuses.
        let reply = try await host.send(
            ScriptEvent.verb("Paus", ScriptEvent.element("KvSD", at: 1, of: Self.vm(named: "Alpha"))),
            to: gateway)

        #expect(reply.errorNumber == Int(errAENoSuchObject))
        #expect(reply.errorString == refusal.message)
        #expect(reply.offendingObject != nil)
    }

    @Test("A verb naming nothing is refused, naming the verb")
    func aVerbNamingNothingIsRefused() async throws {
        let host = ScriptHost()
        let gateway = await makeLandedGateway(WiredCommandCore(), runtime: host.runtime)

        let reply = try await host.send(ScriptEvent.verb("Paus", .null()), to: gateway)

        #expect(reply.errorNumber == Int(errAEWrongNumberArgs))
        #expect(reply.errorString == "Name the virtual machine to pause.")
    }

    // MARK: - A command before the library has landed

    @Test("A read arriving before the library lands is suspended once, however often it reads the element")
    func aColdReadIsDeferredOnce() async throws {
        let wired = WiredCommandCore()
        wired.register(name: "Alpha")
        // Never lands, so the deferred read stays parked.
        let standIn = ScriptCommandStandIn()
        let command = try makeGetCommand()
        standIn.command = command
        var runtime = standIn.runtime
        var suspensions: [ObjectIdentifier] = []
        runtime.suspend = { suspensions.append(ObjectIdentifier($0)) }
        let gateway = makeGateway(wired, awaitReady: { await Self.parkForever() }, runtime: runtime)

        #expect(gateway.virtualMachines().isEmpty)
        #expect(gateway.virtualMachine(named: "Alpha") == nil)
        #expect(gateway.suspended.map { ObjectIdentifier($0.command) } == [ObjectIdentifier(command)])
        #expect(suspensions == [ObjectIdentifier(command)])
    }

    @Test("A cold read of a name no VM answers to reaches the script in the core's words")
    func aColdReadCarriesTheCoresRefusal() async throws {
        let wired = WiredCommandCore()
        wired.register(name: "Alpha")
        let readiness = ReadinessGate()
        let host = ScriptHost()
        let gateway = makeGateway(wired, awaitReady: { await readiness.wait() }, runtime: host.runtime)

        _ = try host.dispatch(
            ScriptEvent.get(ScriptEvent.property("pnam", of: Self.vm(named: "Nope"))), to: gateway)
        try await readiness.awaitWaiting()
        readiness.open()
        let reply = try await host.answer()

        #expect(reply.errorNumber == Int(errAENoSuchObject))
        #expect(reply.errorString == CommandError.notFound(.name("Nope")).message)
    }

    @Test("A set arriving before the library lands writes the key the script named")
    func aColdSetWritesItsKey() async throws {
        let wired = WiredCommandCore()
        let alpha = registerNetworked(wired, name: "Alpha")
        let readiness = ReadinessGate()
        let host = ScriptHost()
        let gateway = makeGateway(wired, awaitReady: { await readiness.wait() }, runtime: host.runtime)

        _ = try host.dispatch(
            ScriptEvent.set(
                ScriptEvent.property("KvNm", of: Self.vm(named: "Alpha")),
                to: NSAppleEventDescriptor(string: "hostOnly")),
            to: gateway)
        #expect(alpha.configuration.networkMode == .nat)
        try await readiness.awaitWaiting()
        readiness.open()
        let reply = try await host.answer()

        #expect(reply.errorNumber == 0)
        #expect(alpha.configuration.networkMode == .hostOnly)
        #expect(host.suspensions == 1)
    }

    @Test("A delete arriving before the library lands deletes the network it named")
    func aColdDeleteDeletesItsNetwork() async throws {
        let wired = WiredCommandCore()
        try wired.core.createNetwork(name: "Lab", kind: .nat)
        let test = try wired.core.createNetwork(name: "Test", kind: .nat)
        let readiness = ReadinessGate()
        let host = ScriptHost()
        let gateway = makeGateway(wired, awaitReady: { await readiness.wait() }, runtime: host.runtime)

        _ = try host.dispatch(ScriptEvent.delete(Self.network(named: "Lab")), to: gateway)
        try await readiness.awaitWaiting()
        readiness.open()
        let reply = try await host.answer()

        #expect(reply.errorNumber == 0)
        #expect(try wired.core.networks().map(\.id) == [test.id])
    }

    @Test("A make arriving before the library lands makes the network once")
    func aColdMakeMakesOnce() async throws {
        let wired = WiredCommandCore()
        let readiness = ReadinessGate()
        let host = ScriptHost()
        let gateway = makeGateway(wired, awaitReady: { await readiness.wait() }, runtime: host.runtime)

        // `make new network at end of networks with properties {name:"Lab"}`:
        // the location reads the networks, which suspends the make, and Cocoa
        // asks for the new element in the same dispatch.
        _ = try host.dispatch(
            ScriptEvent.make(
                new: "KvNw", at: ScriptEvent.end(of: ScriptEvent.every("KvNw")),
                properties: ["pnam": NSAppleEventDescriptor(string: "Lab")]),
            to: gateway)
        #expect(try wired.core.networks().isEmpty)
        try await readiness.awaitWaiting()
        readiness.open()
        let reply = try await host.answer()

        #expect(reply.errorNumber == 0)
        #expect(try wired.core.networks().map(\.name) == ["Lab"])
        #expect(host.suspensions == 1)
    }

    // MARK: - Storage disks

    /// One `storage disk` as `get properties` answers it.
    private struct DiskRow {
        let id: String?
        let name: String?
        let kind: FourCharCode?
        let readOnly: Bool?
        let path: String?
        let notes: String?
        /// `nil` for missing value.
        let capacity: Double?
        let usedSpace: Double?

        init(_ record: NSAppleEventDescriptor) {
            func field(_ code: String) -> NSAppleEventDescriptor? {
                record.forKeyword(ScriptEvent.code(code))
            }
            func number(_ code: String) -> Double? {
                guard let value = field(code), value.descriptorType != typeType else { return nil }
                return value.doubleValue
            }
            id = field("ID  ")?.stringValue
            name = field("pnam")?.stringValue
            kind = field("KvKd")?.enumCodeValue
            readOnly = field("KvRo")?.booleanValue
            path = field("KvPa")?.stringValue
            notes = field("KvNo")?.stringValue
            capacity = number("KvCa")
            usedSpace = number("KvUs")
        }
    }

    /// `get properties of <disks>`, one row per disk, in the order answered.
    private func diskRows(_ reply: ScriptReply) -> [DiskRow] {
        reply.items.map(DiskRow.init)
    }

    /// `properties of every storage disk of virtual machine 1`.
    private static let firstVMDiskProperties = ScriptEvent.property(
        "pALL", of: ScriptEvent.every("KvSD", of: vm(at: 1)))

    private static func measured(capacity: UInt64, used: UInt64) -> VMBundleLayout.DiskSizes {
        VMBundleLayout.DiskSizes(onDiskBytes: used, capacityBytes: capacity)
    }

    @Test("A get reaching a VM's disks suspends, then answers every disk in order, measured")
    func aDiskReadSuspendsThenAnswersMeasured() async throws {
        let wired = WiredCommandCore()
        let installer = StorageDisk(path: "/Volumes/Media/installer.iso", readOnly: true, label: "Installer")
        let main = StorageDisk(path: "Disk.asif", label: "Main Disk", isInternal: true, kind: .virtio, notes: "boot")
        let alpha = wired.register(name: "Alpha") { $0.storageDisks = [installer, main] }
        wired.machineFiles.setDiskSizes(Self.measured(capacity: 100_000_000_000, used: 2_500_000_000), for: main.id)
        let host = ScriptHost()
        let gateway = await makeLandedGateway(wired, runtime: host.runtime)

        let suspended = try host.dispatch(ScriptEvent.get(Self.firstVMDiskProperties), to: gateway)
        let reply = try await host.answer()

        #expect(suspended == nil)
        #expect(host.suspensions == 1)
        #expect(reply.errorNumber == 0)
        let rows = diskRows(reply)
        try #require(rows.count == 2)
        let (iso, disk) = (rows[0], rows[1])
        #expect(iso.id == installer.id.uuidString)
        #expect(iso.name == "Installer")
        #expect(iso.kind == VMScriptStorageDiskKind.usbMassStorage.code)
        #expect(iso.readOnly == true)
        #expect(iso.path == "/Volumes/Media/installer.iso")
        #expect(disk.id == main.id.uuidString)
        #expect(disk.name == "Main Disk")
        #expect(disk.kind == VMScriptStorageDiskKind.virtio.code)
        #expect(disk.readOnly == false)
        #expect(disk.path == alpha.bundleURL.appendingPathComponent("Disk.asif").path(percentEncoded: false))
        #expect(disk.notes == "boot")
        #expect(disk.capacity == 100)
        #expect(disk.usedSpace == 2.5)
        #expect(gateway.suspended.isEmpty)
    }

    @Test("A disk whose image can't be read answers its sizes with missing value")
    func anUnreadableImageAnswersMissingValue() async throws {
        let wired = WiredCommandCore()
        // An image no test seeded reads as unreadable.
        wired.register(name: "Alpha")
        let host = ScriptHost()
        let gateway = await makeLandedGateway(wired, runtime: host.runtime)

        let reply = try await host.send(ScriptEvent.get(Self.firstVMDiskProperties), to: gateway)

        let disk = try #require(diskRows(reply).first)
        #expect(disk.name == "Main Disk")
        #expect(disk.capacity == nil)
        #expect(disk.usedSpace == nil)
    }

    @Test("A verb filtering on disks reaches the core with exactly the VMs whose measured lists pass")
    func aVerbFilteringOnDisksAddressesWhatPasses() async throws {
        let wired = WiredCommandCore()
        let installer = StorageDisk(path: "/Volumes/Media/installer.iso", readOnly: true, label: "Installer")
        let main = StorageDisk(path: "Disk.asif", label: "Main Disk", isInternal: true, kind: .virtio)
        let alpha = wired.register(name: "Alpha", phase: .running(sessionID: UUID())) {
            $0.storageDisks = [installer, main]
        }
        // Its one disk is the main disk its bundle holds.
        let beta = wired.register(name: "Beta", phase: .running(sessionID: UUID()))
        let host = ScriptHost()
        let gateway = await makeLandedGateway(wired, runtime: host.runtime)

        // `pause (every virtual machine whose name of storage disk 1 is
        // "Installer")`: the first dispatch that reads the lists reads them
        // unmeasured, so nothing passes it.
        let reply = try await host.send(ScriptEvent.verb("Paus", Self.vms(whoseFirstDiskIs: "Installer")), to: gateway)

        #expect(reply.errorNumber == 0)
        #expect(reply.errorString == nil)
        #expect(alpha.status == .paused)
        #expect(beta.status == .running)
        #expect(wired.machineFiles.diskSizeReads == 2)
        // The verb's own event, and nothing more.
        #expect(host.suspensions == 1)
    }

    /// `set network membership of <reference> to "isolated"`.
    private static func isolate(_ reference: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
        ScriptEvent.set(ScriptEvent.property("KvMb", of: reference), to: NSAppleEventDescriptor(string: "isolated"))
    }

    @Test("A set filtering on disks writes only to the VMs whose first disk is the one it names")
    func aSetFilteringOnDisksWritesWhatPasses() async throws {
        let wired = WiredCommandCore()
        let installer = StorageDisk(path: "/Volumes/Media/installer.iso", readOnly: true, label: "Installer")
        let main = StorageDisk(path: "Disk.asif", label: "Main Disk", isInternal: true, kind: .virtio)
        let alpha = registerNetworked(wired, name: "Alpha", disks: [installer, main])
        let beta = registerNetworked(wired, name: "Beta")
        let host = ScriptHost()
        let gateway = await makeLandedGateway(wired, runtime: host.runtime)

        let reply = try await host.send(Self.isolate(Self.vms(whoseFirstDiskIs: "Installer")), to: gateway)

        #expect(reply.errorNumber == 0)
        #expect(alpha.configuration.networkMembership == .isolated)
        #expect(beta.configuration.networkMembership == .common)
        #expect(host.suspensions == 1)
    }

    @Test("A make of a storage disk is refused, in the reply the script reads")
    func aMakeOfAStorageDiskIsRefused() async throws {
        let wired = WiredCommandCore()
        wired.register(name: "Alpha")
        let host = ScriptHost()
        let gateway = await makeLandedGateway(wired, runtime: host.runtime)

        let reply = try await host.send(ScriptEvent.make(new: "KvSD", at: Self.vm(at: 1)), to: gateway)

        #expect(reply.errorNumber == Int(errAECantHandleClass))
        #expect(reply.errorString == VMScriptingGateway.cannotMakeStorageDisk)
    }

    @Test("A disk names itself back by identifier, of its VM by identifier")
    func aDiskSpecifierNamesItsVMByID() async throws {
        let wired = WiredCommandCore()
        let alpha = wired.register(name: "Alpha")
        let host = ScriptHost()
        let gateway = await makeLandedGateway(wired, runtime: host.runtime)

        let reply = try await host.send(ScriptEvent.get(ScriptEvent.every("KvSD", of: Self.vm(at: 1))), to: gateway)
        let properties = try await host.send(ScriptEvent.get(Self.firstVMDiskProperties), to: gateway)
        let read = try #require(diskRows(properties).first)

        let disk = try #require(reply.items.first)
        let specifier = try #require(NSScriptObjectSpecifier(descriptor: disk) as? NSUniqueIDSpecifier)
        let container = try #require(specifier.container as? NSUniqueIDSpecifier)
        #expect(specifier.key == VMScriptObject.storageDisksKey)
        #expect(specifier.uniqueID as? String == read.id)
        #expect(container.key == VMScriptingRoot.virtualMachinesKey)
        #expect(container.uniqueID as? String == alpha.id.uuidString)
        #expect(container.container == nil)
    }

    // MARK: - Preparation

    /// A tally a preparation closure writes and the test reads.
    @MainActor
    private final class Tally {
        var count = 0
    }

    @Test("A verb that puts a window up readies the app")
    func surfacingVerbsPrepare() async throws {
        let wired = WiredCommandCore()
        let alpha = wired.register(name: "Alpha", phase: .running(sessionID: UUID()))
        let preparations = Tally()
        let gateway = makeGateway(wired, prepareToSurface: { preparations.count += 1 })

        try await gateway.reveal([.name("Alpha")])

        #expect(preparations.count == 1)
        #expect(wired.surfacedDisplays == [alpha.id])
    }

    // MARK: - Readiness

    @Test("No verb reaches the core until the app's first library read has landed")
    func verbsWaitForTheFirstLibraryRead() async throws {
        let virtualization = MockVirtualizationService()
        let wired = WiredCommandCore(virtualization: virtualization)
        let alpha = wired.register(name: "Alpha", phase: .running(sessionID: UUID()))
        let readiness = ReadinessGate()
        let gateway = makeGateway(wired, awaitReady: { await readiness.wait() })

        let run = Task { try await gateway.pause([.name("Alpha")]) }
        try await readiness.awaitWaiting()
        #expect(virtualization.pauseCallCount == 0)
        #expect(alpha.status == .running)

        readiness.open()
        try await run.value
        #expect(virtualization.pauseCallCount == 1)
        #expect(alpha.status == .paused)
    }
}
