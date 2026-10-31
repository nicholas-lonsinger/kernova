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

    private static func isAmbiguous(_ error: CommandError) -> Bool {
        if case .ambiguous = error { return true }
        return false
    }

    // MARK: - Script references

    /// `virtual machine "<name>"`.
    private static func vm(named name: String) -> NSAppleEventDescriptor {
        ScriptEvent.element("KvVM", named: name)
    }

    /// `virtual machine <index>`.
    private static func vm(at index: Int32) -> NSAppleEventDescriptor {
        ScriptEvent.element("KvVM", at: index)
    }

    /// `every virtual machine`.
    private static let everyVM = ScriptEvent.every("KvVM")

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

    @Test("The dictionary's elements are the library, in the order it lists them")
    func elementsAreTheLibraryInOrder() throws {
        let wired = WiredCommandCore()
        let alpha = wired.register(name: "Alpha")
        let beta = wired.register(name: "Beta")

        let vms = makeGateway(wired).virtualMachines()

        #expect(vms.map(\.name) == ["Alpha", "Beta"])
        #expect(vms.map(\.uniqueID) == [alpha.id.uuidString, beta.id.uuidString])
    }

    @Test("A name one VM answers to resolves to that VM, through the core")
    func aUniqueNameResolves() throws {
        let wired = WiredCommandCore()
        let alpha = wired.register(name: "Alpha")
        wired.register(name: "Beta")
        let gateway = makeGateway(wired)

        let found = try #require(gateway.virtualMachine(named: "Alpha"))
        // The core matches a whole name without regard to case.
        let unfolded = try #require(gateway.virtualMachine(named: "alpha"))

        #expect(found.uniqueID == alpha.id.uuidString)
        #expect(unfolded.uniqueID == alpha.id.uuidString)
    }

    @Test("A name several VMs answer to is refused in the core's words, with the candidates")
    func anAmbiguousNameIsRefusedByTheCore() async throws {
        let wired = WiredCommandCore()
        wired.register(name: "Alpha")
        wired.register(name: "Alpha")
        let refusal = try #require(throws: CommandError.self) { try wired.core.info(.name("Alpha")) }
        let standIn = ScriptCommandStandIn()
        let gateway = await makeLandedGateway(wired, runtime: standIn.runtime)
        let command = try makeGetCommand()
        standIn.command = command

        // Cocoa's own accessor would answer with the first, describing whichever
        // VM the library happens to list first as though it were the one asked
        // for.
        #expect(gateway.virtualMachine(named: "Alpha") == nil)

        #expect(Self.isAmbiguous(refusal))
        #expect(command.scriptErrorNumber == Int(errAENoSuchObject))
        #expect(command.scriptErrorString == refusal.message)
    }

    @Test("A name no VM answers to is refused in the core's words")
    func anUnknownNameIsRefusedByTheCore() async throws {
        let wired = WiredCommandCore()
        wired.register(name: "Alpha")
        let standIn = ScriptCommandStandIn()
        let gateway = await makeLandedGateway(wired, runtime: standIn.runtime)
        let command = try makeGetCommand()
        standIn.command = command

        #expect(gateway.virtualMachine(named: "Beta") == nil)

        #expect(command.scriptErrorNumber == Int(errAENoSuchObject))
        #expect(command.scriptErrorString == CommandError.notFound(.name("Beta")).message)
    }

    @Test("A refused name with no command to answer records nothing and resolves to nothing")
    func aRefusedNameWithNoCommandResolvesToNothing() throws {
        let wired = WiredCommandCore()
        wired.register(name: "Alpha")

        #expect(makeGateway(wired).virtualMachine(named: "Beta") == nil)
    }

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
        alpha.beginSessionContextForTesting()
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

    @Test("Setting a VM's network membership, network mode or MAC address writes its key by identifier")
    func settingANetworkPropertyWritesItsKey() async throws {
        let wired = WiredCommandCore()
        let alpha = registerNetworked(wired, name: "Alpha")
        let twin = registerNetworked(wired, name: "Alpha")
        // The object holds its gateway weakly; the app's lives as long as it does.
        let standIn = ScriptCommandStandIn()
        let gateway = await makeLandedGateway(wired, runtime: standIn.runtime)
        let vm = try #require(gateway.virtualMachines().first)
        let command = try makeSetCommand()
        standIn.command = command

        vm.networkMembership = "isolated"
        vm.networkMode = "hostOnly"
        vm.macAddress = "new"

        #expect(command.scriptErrorNumber == 0)
        #expect(alpha.configuration.networkMembership == .isolated)
        #expect(alpha.configuration.networkMode == .hostOnly)
        #expect(alpha.configuration.macAddress != "02:4b:4e:56:0c:01")
        #expect(alpha.configuration.macAddress != nil)
        // The name both answer to addresses neither: the write went by identifier.
        #expect(twin.configuration.networkMembership == .common)
        #expect(twin.configuration.networkMode == .nat)
        #expect(twin.configuration.macAddress == "02:4b:4e:56:0c:01")
    }

    @Test("A scripted write carries no consent, so one that asks for it is refused and changes nothing")
    func scriptedWriteCarriesNoConsent() async throws {
        let wired = WiredCommandCore()
        let alpha = wired.register(name: "Alpha") { $0.clipboardSharingEnabled = true }
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

    @Test("A refused setting is recorded on the set command")
    func aRefusedSettingIsRecorded() async throws {
        let wired = WiredCommandCore()
        let alpha = registerNetworked(wired, name: "Alpha")
        let refusal = try #require(throws: CommandError.self) {
            try wired.core.setConfiguration(
                .id(alpha.id), assignments: [VMConfigurationKeyRegistry.networkMembership.assigning("Nowhere")],
                consent: .none)
        }
        let standIn = ScriptCommandStandIn()
        let gateway = await makeLandedGateway(wired, runtime: standIn.runtime)
        let command = try makeSetCommand()
        let vm = try #require(gateway.virtualMachines().first)
        standIn.command = command

        vm.networkMembership = "Nowhere"

        #expect(command.scriptErrorNumber == refusal.appleEventErrorNumber)
        #expect(command.scriptErrorString == refusal.message)
        #expect(alpha.configuration.networkMembership == .common)
    }

    @Test("A set addressing several VMs stops at the first refusal, which stands")
    func aRefusedSettingStopsTheRun() async throws {
        let wired = WiredCommandCore()
        try wired.core.createNetwork(name: "Lab", kind: .hostOnly)
        // Lab runs its VMs host-only, so the NAT VM is refused it and the
        // host-only one would take it.
        let alpha = registerNetworked(wired, name: "Alpha", mode: .nat)
        let beta = registerNetworked(wired, name: "Beta", mode: .hostOnly)
        let refusal = try #require(throws: CommandError.self) {
            try wired.core.setConfiguration(
                .id(alpha.id), assignments: [VMConfigurationKeyRegistry.networkMembership.assigning("Lab")],
                consent: .none)
        }
        let standIn = ScriptCommandStandIn()
        let gateway = await makeLandedGateway(wired, runtime: standIn.runtime)
        let command = try makeSetCommand()
        let vms = gateway.virtualMachines()
        standIn.command = command

        for vm in vms { vm.networkMembership = "Lab" }

        #expect(command.scriptErrorString == refusal.message)
        #expect(alpha.configuration.networkMembership == .common)
        #expect(beta.configuration.networkMembership == .common)
    }

    // MARK: - Verb dispatch

    @Test("Each verb reaches the core with the VMs the event addressed")
    func verbsReachTheCore() async throws {
        let virtualization = MockVirtualizationService()
        let wired = WiredCommandCore(virtualization: virtualization, clock: TestEngineClock())
        let booting = wired.register(name: "Booting", guestOS: .macOS)
        let forced = wired.register(name: "Forced", phase: .running(sessionID: UUID()))
        let stubborn = wired.register(name: "Stubborn", phase: .running(sessionID: UUID()))
        let restarting = wired.register(name: "Restarting", phase: .running(sessionID: UUID()))
        let pausing = wired.register(name: "Pausing", phase: .running(sessionID: UUID()))
        let resuming = wired.register(name: "Resuming", phase: .livePaused(sessionID: UUID()))
        let suspending = wired.register(name: "Suspending", phase: .running(sessionID: UUID()))
        let revealed = wired.register(name: "Revealed", phase: .running(sessionID: UUID()))
        let gateway = makeGateway(wired)

        try await gateway.start([.name("Booting")], recoveryMode: true, confirmation: false)
        #expect(virtualization.lastStartBootIntoRecovery)
        #expect(booting.status == .running)

        try await gateway.stop([.name("Forced")], method: .force, confirmation: true, givingUpAfter: 30)
        #expect(virtualization.forceStopCallCount == 1)
        #expect(virtualization.stopCallCount == 0)
        #expect(forced.status == .stopped)

        // A guest that ignores the request leaves the deadline to end the wait.
        virtualization.guestIgnoresShutdownRequest = true
        let timedOut = try await #require(throws: CommandError.self) {
            try await gateway.stop([.name("Stubborn")], method: .graceful, confirmation: false, givingUpAfter: 30)
        }
        virtualization.guestIgnoresShutdownRequest = false
        #expect(timedOut == .timedOut(vm: wired.core.summary(stubborn), verb: .stop, seconds: 30))
        #expect(virtualization.stopCallCount == 1)

        try await gateway.restart([.name("Restarting")], confirmation: false, givingUpAfter: nil)
        #expect(virtualization.stopCallCount == 2)
        #expect(virtualization.startCallCount == 2)
        #expect(restarting.status == .running)

        try await gateway.pause([.name("Pausing")])
        #expect(pausing.status == .paused)

        try await gateway.resume([.name("Resuming")], confirmation: false)
        #expect(virtualization.resumeCallCount == 1)
        #expect(resuming.status == .running)

        try await gateway.suspend([.name("Suspending")], confirmation: false)
        #expect(virtualization.saveCallCount == 1)
        #expect(suspending.status == .suspended)

        try await gateway.reveal([.name("Revealed")])
        #expect(wired.surfacedDisplays == [revealed.id])
    }

    @Test("An event addressing several VMs runs the verb on each of them")
    func aVerbRunsOnEveryAddressedVM() async throws {
        let wired = WiredCommandCore()
        let alpha = wired.register(name: "Alpha", phase: .running(sessionID: UUID()))
        let beta = wired.register(name: "Beta", phase: .running(sessionID: UUID()))

        try await makeGateway(wired).pause([.name("Alpha"), .name("Beta")])

        #expect(alpha.status == .paused)
        #expect(beta.status == .paused)
    }

    @Test("A refusal stops the run where it happened")
    func aRefusalStopsTheRun() async throws {
        let wired = WiredCommandCore()
        let beta = wired.register(name: "Beta", phase: .running(sessionID: UUID()))

        await #expect(throws: CommandError.notFound(.name("Alpha"))) {
            try await makeGateway(wired).pause([.name("Alpha"), .name("Beta")])
        }

        #expect(beta.status == .running)
    }

    @Test("A verb's refusal reaches the script untouched")
    func aRefusalReachesTheScript() async throws {
        let virtualization = MockVirtualizationService()
        let wired = WiredCommandCore(virtualization: virtualization)
        wired.register(name: "Alpha")
        wired.register(name: "Alpha")
        let refusal = try #require(throws: CommandError.self) { try wired.core.info(.name("Alpha")) }

        await #expect(throws: refusal) {
            try await makeGateway(wired).start([.name("Alpha")], recoveryMode: false, confirmation: false)
        }
        #expect(Self.isAmbiguous(refusal))
        #expect(virtualization.startCallCount == 0)
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

    @Test("A get arriving before the library lands answers the landed library")
    func aColdReadAnswersTheLandedLibrary() async throws {
        let wired = WiredCommandCore()
        wired.register(name: "Alpha")
        wired.register(name: "Beta")
        let readiness = ReadinessGate()
        let host = ScriptHost()
        let gateway = makeGateway(wired, awaitReady: { await readiness.wait() }, runtime: host.runtime)

        let suspended = try host.dispatch(
            ScriptEvent.get(ScriptEvent.property("pnam", of: Self.everyVM)), to: gateway)
        #expect(suspended == nil)
        try await readiness.awaitWaiting()
        readiness.open()
        let reply = try await host.answer()

        #expect(reply.errorNumber == 0)
        #expect(reply.texts == ["Alpha", "Beta"])
        #expect(host.suspensions == 1)
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

    @Test("A cold exists answers false for what it cannot resolve, and true for what it can")
    func aColdExistsAnswers() async throws {
        let wired = WiredCommandCore()
        wired.register(name: "Alpha")
        func coldExists(_ index: Int32) async throws -> ScriptReply {
            let host = ScriptHost()
            let readiness = ReadinessGate()
            let gateway = makeGateway(wired, awaitReady: { await readiness.wait() }, runtime: host.runtime)
            _ = try host.dispatch(ScriptEvent.exists(Self.vm(at: index)), to: gateway)
            try await readiness.awaitWaiting()
            readiness.open()
            return try await host.answer()
        }

        let missing = try await coldExists(2)
        let present = try await coldExists(1)

        #expect(missing.errorNumber == 0)
        #expect((missing.result as? NSNumber)?.boolValue == false)
        #expect(present.errorNumber == 0)
        #expect((present.result as? NSNumber)?.boolValue == true)
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

    @Test("A get reaching no disk list suspends nothing")
    func aReadOfNoDiskListDoesNotSuspend() async throws {
        let wired = WiredCommandCore()
        wired.register(name: "Alpha")
        wired.register(name: "Beta")
        let host = ScriptHost()
        let gateway = await makeLandedGateway(wired, runtime: host.runtime)

        let reply = try #require(
            try host.dispatch(ScriptEvent.get(ScriptEvent.property("pnam", of: Self.everyVM)), to: gateway))

        #expect(reply.texts == ["Alpha", "Beta"])
        #expect(host.suspensions == 0)
        #expect(gateway.suspended.isEmpty)
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

    @Test("A verb whose addressing reaches no disk list measures nothing")
    func aVerbReachingNoDiskListMeasuresNothing() async throws {
        let wired = WiredCommandCore()
        let alpha = wired.register(name: "Alpha", phase: .running(sessionID: UUID()))
        let host = ScriptHost()
        let gateway = await makeLandedGateway(wired, runtime: host.runtime)

        let reply = try await host.send(ScriptEvent.verb("Paus", Self.everyVM), to: gateway)

        #expect(reply.errorNumber == 0)
        #expect(alpha.status == .paused)
        #expect(wired.machineFiles.diskSizeReads == 0)
    }

    @Test("A get across several VMs' disks measures each VM it reaches")
    func aReadAcrossVMsMeasuresEach() async throws {
        let wired = WiredCommandCore()
        let alphaDisk = StorageDisk(path: "Disk.asif", label: "Alpha Disk", isInternal: true, kind: .virtio)
        let betaDisk = StorageDisk(path: "Disk.asif", label: "Beta Disk", isInternal: true, kind: .virtio)
        wired.register(name: "Alpha") { $0.storageDisks = [alphaDisk] }
        wired.register(name: "Beta") { $0.storageDisks = [betaDisk] }
        wired.machineFiles.setDiskSizes(Self.measured(capacity: 64_000_000_000, used: 1_000_000_000), for: alphaDisk.id)
        wired.machineFiles.setDiskSizes(Self.measured(capacity: 32_000_000_000, used: 3_000_000_000), for: betaDisk.id)
        let host = ScriptHost()
        let gateway = await makeLandedGateway(wired, runtime: host.runtime)

        // `get properties of storage disk 1 of every virtual machine`.
        let reply = try await host.send(
            ScriptEvent.get(ScriptEvent.property("pALL", of: ScriptEvent.element("KvSD", at: 1, of: Self.everyVM))),
            to: gateway)

        let rows = diskRows(reply)
        #expect(rows.map(\.name) == ["Alpha Disk", "Beta Disk"])
        #expect(rows.map(\.capacity) == [64, 32])
        #expect(rows.map(\.usedSpace) == [1, 3])
        #expect(rows.map(\.id) == [alphaDisk.id.uuidString, betaDisk.id.uuidString])
        #expect(host.suspensions == 1)
    }

    @Test("A read of a VM's first disk arriving before the library lands answers it, measured")
    func aColdReadMeasuresTheDisksItReaches() async throws {
        let wired = WiredCommandCore()
        let disk = StorageDisk(path: "Disk.asif", label: "Main Disk", isInternal: true, kind: .virtio)
        wired.register(name: "Alpha") { $0.storageDisks = [disk] }
        wired.machineFiles.setDiskSizes(Self.measured(capacity: 50_000_000_000, used: 5_000_000_000), for: disk.id)
        let readiness = ReadinessGate()
        let host = ScriptHost()
        let gateway = makeGateway(wired, awaitReady: { await readiness.wait() }, runtime: host.runtime)

        // `get capacity of storage disk 1 of virtual machine "Alpha"`: the
        // first dispatch reads no library, so it reaches no disk list, and
        // the next reads the list unmeasured and fails on its first disk.
        _ = try host.dispatch(
            ScriptEvent.get(
                ScriptEvent.property("KvCa", of: ScriptEvent.element("KvSD", at: 1, of: Self.vm(named: "Alpha")))),
            to: gateway)
        try await readiness.awaitWaiting()
        readiness.open()
        let reply = try await host.answer()

        #expect(reply.errorNumber == 0)
        #expect(reply.descriptor?.doubleValue == 50)
        #expect(host.suspensions == 1)
    }

    @Test("Each command answers from a measurement of its own")
    func commandsShareNoMeasurement() async throws {
        let wired = WiredCommandCore()
        let disk = StorageDisk(path: "Disk.asif", label: "Main Disk", isInternal: true, kind: .virtio)
        wired.register(name: "Alpha") { $0.storageDisks = [disk] }
        wired.machineFiles.setDiskSizes(Self.measured(capacity: 64_000_000_000, used: 1_000_000_000), for: disk.id)
        let host = ScriptHost()
        let gateway = await makeLandedGateway(wired, runtime: host.runtime)
        let first = try await host.send(ScriptEvent.get(Self.firstVMDiskProperties), to: gateway)

        wired.machineFiles.setDiskSizes(Self.measured(capacity: 64_000_000_000, used: 9_000_000_000), for: disk.id)
        let second = try await host.send(ScriptEvent.get(Self.firstVMDiskProperties), to: gateway)

        #expect(diskRows(first).map(\.usedSpace) == [1])
        #expect(diskRows(second).map(\.usedSpace) == [9])
        #expect(host.suspensions == 2)
    }

    /// `set network membership of <reference> to "isolated"`.
    private static func isolate(_ reference: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
        ScriptEvent.set(ScriptEvent.property("KvMb", of: reference), to: NSAppleEventDescriptor(string: "isolated"))
    }

    @Test("A first dispatch's write is held back, and the answering one writes only to the VMs that match")
    func aFirstPassWriteIsHeldBack() async throws {
        let wired = WiredCommandCore()
        let installer = StorageDisk(path: "/Volumes/Media/installer.iso", readOnly: true, label: "Installer")
        let main = StorageDisk(path: "Disk.asif", label: "Main Disk", isInternal: true, kind: .virtio)
        let alpha = registerNetworked(wired, name: "Alpha", disks: [installer, main])
        let beta = registerNetworked(wired, name: "Beta")
        let host = ScriptHost()
        let gateway = await makeLandedGateway(wired, runtime: host.runtime)

        // The first dispatch answers every list empty, which fails every
        // VM's first disk name, so every VM is not the installer's.
        let suspended = try host.dispatch(Self.isolate(Self.vms(whoseFirstDiskIsNot: "Installer")), to: gateway)

        #expect(suspended == nil)
        #expect(alpha.configuration.networkMembership == .common)
        #expect(beta.configuration.networkMembership == .common)
        let reply = try await host.answer()
        #expect(reply.errorNumber == 0)
        #expect(alpha.configuration.networkMembership == .common)
        #expect(beta.configuration.networkMembership == .isolated)
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

    @Test("A first dispatch reaching several VMs' lists after it suspends answers them all, measured")
    func aFirstPassReachingSeveralListsAnswersAll() async throws {
        let wired = WiredCommandCore()
        let alphaDisk = StorageDisk(path: "Disk.asif", label: "Alpha Disk", isInternal: true, kind: .virtio)
        let betaDisk = StorageDisk(path: "Disk.asif", label: "Beta Disk", isInternal: true, kind: .virtio)
        wired.register(name: "Alpha") { $0.storageDisks = [alphaDisk] }
        wired.register(name: "Beta") { $0.storageDisks = [betaDisk] }
        let host = ScriptHost()
        let gateway = await makeLandedGateway(wired, runtime: host.runtime)

        // `get name of every storage disk of every virtual machine`: the
        // first VM's list suspends the command, and Cocoa reads the second's
        // with no current command.
        let reply = try await host.send(
            ScriptEvent.get(ScriptEvent.property("pnam", of: ScriptEvent.every("KvSD", of: Self.everyVM))),
            to: gateway)

        #expect(reply.items.map { $0.items.compactMap(\.stringValue) } == [["Alpha Disk"], ["Beta Disk"]])
        #expect(wired.machineFiles.diskSizeReads == 2)
        #expect(host.suspensions == 1)
    }

    @Test("Several properties of one VM's disks, read in one command, answer from one measurement")
    func severalPropertiesOfOneListAnswer() async throws {
        let wired = WiredCommandCore()
        let disk = StorageDisk(path: "Disk.asif", label: "Main Disk", isInternal: true, kind: .virtio)
        wired.register(name: "Alpha") { $0.storageDisks = [disk] }
        wired.machineFiles.setDiskSizes(Self.measured(capacity: 64_000_000_000, used: 4_000_000_000), for: disk.id)
        let host = ScriptHost()
        let gateway = await makeLandedGateway(wired, runtime: host.runtime)

        // `get properties` reads the list once per property.
        let reply = try await host.send(ScriptEvent.get(Self.firstVMDiskProperties), to: gateway)

        let rows = diskRows(reply)
        #expect(rows.map(\.name) == ["Main Disk"])
        #expect(rows.map(\.capacity) == [64])
        #expect(rows.map(\.usedSpace) == [4])
        #expect(wired.machineFiles.diskSizeReads == 1)
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

    @Test("A script can't make a storage disk")
    func makingAStorageDiskIsRefused() throws {
        let wired = WiredCommandCore()
        wired.register(name: "Alpha")
        let vm = try #require(makeGateway(wired).virtualMachines().first)

        let made = vm.newScriptingObject(
            of: VMStorageDiskScriptObject.self, forValueForKey: VMScriptObject.storageDisksKey,
            withContentsValue: nil, properties: [:])

        #expect(made == nil)
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

    @Test("A MAC address step refusal reaches a script as its message, taking no step")
    func macAddressRefusalTakesNoStep() async throws {
        let virtualization = MockVirtualizationService()
        let wired = WiredCommandCore(virtualization: virtualization)
        let sharedMAC = "02:4b:4e:56:0c:01"
        let source = wired.register(name: "Source", phase: .running(sessionID: UUID())) {
            $0.networkEnabled = true
            $0.networkMode = .nat
            $0.macAddress = sharedMAC
        }
        // Its routes discard the saved state, which a script's confirmation
        // does not answer.
        let alpha = wired.register(name: "Alpha", phase: .suspended) {
            $0.networkEnabled = true
            $0.networkMode = .nat
            $0.macAddress = sharedMAC
        }
        try VMInstanceFixture.writeSaveFile(for: alpha)
        let gateway = makeGateway(wired)

        let refusal = try await #require(throws: CommandError.self) {
            try await gateway.start([.name("Alpha")], recoveryMode: false, confirmation: true)
        }

        let requirement = try #require(refusal.stepRequirement)
        #expect(requirement.title == "Duplicate MAC Address")
        #expect(refusal.appleEventErrorString == requirement.message)
        #expect(virtualization.startCallCount == 0)
        #expect(virtualization.stopCallCount == 0)
        #expect(source.status == .running)
        #expect(alpha.hasSaveFile)
        #expect(alpha.configuration.macAddress == sharedMAC)
        #expect(alpha.configuration.networkMembership == .common)
        #expect(alpha.configuration.networkEnabled)
    }

    /// Bringing a guest up is not a request to look at it.
    @Test("A verb that puts nothing up readies nothing, as does one addressing no VM")
    func nonSurfacingVerbsDoNotPrepare() async throws {
        let wired = WiredCommandCore()
        wired.register(name: "Starting")
        wired.register(name: "Resuming", phase: .livePaused(sessionID: UUID()))
        wired.register(name: "Restarting", phase: .running(sessionID: UUID()))
        let stopping = wired.register(name: "Stopping", phase: .running(sessionID: UUID()))
        wired.register(name: "Pausing", phase: .running(sessionID: UUID()))
        let suspending = wired.register(name: "Suspending", phase: .running(sessionID: UUID()))
        let preparations = Tally()
        let gateway = makeGateway(wired, prepareToSurface: { preparations.count += 1 })

        try await gateway.start([.name("Starting")], recoveryMode: false, confirmation: false)
        try await gateway.resume([.name("Resuming")], confirmation: false)
        try await gateway.restart([.name("Restarting")], confirmation: false, givingUpAfter: nil)
        try await gateway.stop([.name("Stopping")], method: .graceful, confirmation: false, givingUpAfter: nil)
        try await gateway.pause([.name("Pausing")])
        try await gateway.suspend([.name("Suspending")], confirmation: false)
        try await gateway.reveal([])

        #expect(preparations.count == 0)
        #expect(stopping.status == .stopped)
        #expect(suspending.status == .suspended)
        #expect(wired.surfacedDisplays.isEmpty)
        #expect(wired.revealedInLibrary.isEmpty)
    }

    @Test("A refused verb readies nothing")
    func refusedVerbDoesNotPrepare() async throws {
        let wired = WiredCommandCore()
        let preparations = Tally()
        let gateway = makeGateway(wired, prepareToSurface: { preparations.count += 1 })

        await #expect(throws: CommandError.notFound(.name("Alpha"))) {
            try await gateway.reveal([.name("Alpha")])
        }

        #expect(preparations.count == 0)
    }

    // MARK: - Readiness

    @Test("A verb arriving before the library lands addresses and runs once it has")
    func aColdVerbRunsOnceTheLibraryLands() async throws {
        let wired = WiredCommandCore()
        let alpha = wired.register(name: "Alpha", phase: .running(sessionID: UUID()))
        let readiness = ReadinessGate()
        let host = ScriptHost()
        let gateway = makeGateway(wired, awaitReady: { await readiness.wait() }, runtime: host.runtime)

        _ = try host.dispatch(ScriptEvent.verb("Paus", Self.vm(named: "Alpha")), to: gateway)
        try await readiness.awaitWaiting()
        #expect(alpha.status == .running)
        readiness.open()
        let reply = try await host.answer()

        #expect(reply.errorNumber == 0)
        #expect(alpha.status == .paused)
    }

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

    // MARK: - Consent

    @Test("A destructive stop with no confirmation is refused, and runs nothing")
    func anUnconfirmedStopIsRefused() async throws {
        let virtualization = MockVirtualizationService()
        let wired = WiredCommandCore(virtualization: virtualization)
        let alpha = wired.register(name: "Alpha", phase: .running(sessionID: UUID()))

        await #expect(throws: CommandError.confirmationRequired(VMCommandCore.forceStopPrompt(alpha))) {
            try await makeGateway(wired).stop(
                [.name("Alpha")], method: .force, confirmation: false, givingUpAfter: nil)
        }

        #expect(virtualization.forceStopCallCount == 0)
        #expect(alpha.status == .running)
    }

    @Test("A stop with confirmation re-issues the verb, consented")
    func aConfirmedStopIsReIssued() async throws {
        let virtualization = MockVirtualizationService()
        let wired = WiredCommandCore(virtualization: virtualization)
        wired.register(name: "Alpha", phase: .running(sessionID: UUID()))

        try await makeGateway(wired).stop(
            [.name("Alpha")], method: .force, confirmation: true, givingUpAfter: nil)

        #expect(virtualization.forceStopCallCount == 1)
    }

    @Test("A stop a paused guest cannot receive is refused as a step even with confirmation")
    func aPausedStopIsRefusedAsAStep() async throws {
        let virtualization = MockVirtualizationService()
        let wired = WiredCommandCore(virtualization: virtualization)
        let alpha = wired.register(name: "Alpha", phase: .livePaused(sessionID: UUID()))

        // No confirmation names a resume, so the script is told the step to
        // take first.
        await #expect(throws: CommandError.stepRequired(wired.core.pausedStopRefusal(alpha))) {
            try await makeGateway(wired).stop(
                [.name("Alpha")], method: .graceful, confirmation: true, givingUpAfter: nil)
        }

        #expect(virtualization.stopCallCount == 0)
        #expect(virtualization.resumeCallCount == 0)
        #expect(alpha.status == .paused)
    }
}
