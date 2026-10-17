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
/// destructive verb needs is given.
///
/// A read that arrives before the library has landed is suspended and
/// re-issued through Cocoa's own Apple event handling, which only a live
/// script exercises; what is tested here is everything short of that.
@Suite("VM scripting gateway", .caseScoped)
@MainActor
struct VMScriptingGatewayTests {
    /// A readiness await the test holds open, so a verb's wait for the first
    /// library read is observable rather than instantaneous.
    private final class ReadinessGate: @unchecked Sendable {
        /// Fires when the gateway starts waiting, and again when it is let go.
        private let gate = AsyncGate()
        private let lock = NSLock()
        private var waiting = false
        private var isOpen = false

        /// Whether the gateway is parked on the readiness await.
        var isWaiting: Bool { lock.withLock { waiting } }

        /// Suspends until ``open()``, as the app's first library read does.
        ///
        /// A gate no test opens is a test defect, recorded as one — and then
        /// parked for good rather than returned from: a readiness that "lands"
        /// on the backstop resumes whatever the gateway deferred, and a
        /// re-issued command reaches Cocoa on the main actor with no Apple
        /// event behind it.
        func wait() async {
            lock.withLock { waiting = true }
            gate.notify()
            do {
                try await gate.wait { self.lock.withLock { self.isOpen } }
            } catch {
                Issue.record("readiness gate was never opened: \(error)")
                await VMScriptingGatewayTests.parkForever()
            }
        }

        /// Lands the library read.
        func open() {
            lock.withLock { isOpen = true }
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
        currentCommand: @escaping @MainActor () -> NSScriptCommand? = { NSScriptCommand.current() }
    ) -> VMScriptingGateway {
        VMScriptingGateway(
            commands: wired.core, readiness: LibraryReadiness(awaitReady: awaitReady),
            prepareToSurface: prepareToSurface, currentCommand: currentCommand)
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

    private func makeContainer() throws -> NSScriptClassDescription {
        try #require(NSScriptClassDescription(for: NSApplication.self))
    }

    private func makeNameSpecifier(_ name: String) throws -> NSNameSpecifier {
        NSNameSpecifier(
            containerClassDescription: try makeContainer(), containerSpecifier: nil,
            key: AppDelegate.virtualMachinesKey, name: name)
    }

    /// A specifier whose evaluation reads the library by name through the
    /// gateway, as Cocoa's evaluation of a name it cannot read unevaluated does
    /// through the element accessor.
    private final class NameReadingSpecifier: NSScriptObjectSpecifier {
        var read: (() -> Any?)?

        override func objectsByEvaluating(withContainers containers: Any) -> Any? {
            read?()
        }
    }

    private func makeNameReadingSpecifier(
        _ read: @escaping () -> Any?
    ) throws -> NameReadingSpecifier {
        let specifier = NameReadingSpecifier(
            containerClassDescription: try makeContainer(), containerSpecifier: nil,
            key: AppDelegate.virtualMachinesKey)
        specifier.read = read
        return specifier
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
    func anAmbiguousNameIsRefusedByTheCore() throws {
        let wired = WiredCommandCore()
        wired.register(name: "Alpha")
        wired.register(name: "Alpha")
        let refusal = try #require(throws: CommandError.self) { try wired.core.info(.name("Alpha")) }
        let gateway = makeGateway(wired)
        let command = try makeGetCommand()
        gateway.answeringCommand = command

        // Cocoa's own accessor would answer with the first, describing whichever
        // VM the library happens to list first as though it were the one asked
        // for.
        #expect(gateway.virtualMachine(named: "Alpha") == nil)

        #expect(Self.isAmbiguous(refusal))
        #expect(command.scriptErrorNumber == Int(errAENoSuchObject))
        #expect(command.scriptErrorString == refusal.message)
    }

    @Test("A name no VM answers to is refused in the core's words")
    func anUnknownNameIsRefusedByTheCore() throws {
        let wired = WiredCommandCore()
        wired.register(name: "Alpha")
        let gateway = makeGateway(wired)
        let command = try makeGetCommand()
        gateway.answeringCommand = command

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
        wired.vmnet.materialize(.common(.nat), on: "192.168.64.0")
        let baseline = VMSnapshot(name: "Baseline", createdAt: Date(timeIntervalSince1970: 1), macAddress: nil)
        let later = VMSnapshot(name: "Later", createdAt: Date(timeIntervalSince1970: 2), macAddress: nil)
        let alpha = wired.register(
            name: "Alpha", phase: .running(sessionID: UUID()), guestOS: .macOS, snapshots: [baseline, later],
            hostState: VMHostState(ephemeralModeEnabled: true, ephemeralBaselineSnapshotID: baseline.id)
        ) {
            $0.cpuCount = 6
            $0.memorySizeInGB = .gibibytes(8)
            $0.diskSizeInGB = 128
            $0.networkEnabled = true
            $0.networkMode = .nat
            $0.macAddress = "aa:bb:cc:dd:ee:ff"
        }
        let beta = wired.register(name: "Beta", phase: .suspended)
        try VMInstanceFixture.writeSaveFile(for: beta)
        wired.register(name: "Gamma") {
            $0.networkEnabled = true
            $0.networkMode = .nat
            $0.networkMembership = .network(lab.id)
            $0.applyNetworkMode($0.networkMode)
        }
        wired.arpTable.table = [
            .scripted("192.168.64.3", mac: "aa:bb:cc:dd:ee:ff", expiry: ARPEntry.freshExpiry)
        ]
        await wired.library.guestAddresses.readForTesting()

        let vms = makeGateway(wired).virtualMachines()
        try #require(vms.count == 3)
        let (vm, suspended, onLab) = (vms[0], vms[1], vms[2])

        #expect(vm.name == "Alpha")
        #expect(vm.state == NSNumber(value: VMScriptState.running.code))
        #expect(vm.guestOperatingSystem == "macOS")
        #expect(vm.processorCount == 6)
        #expect(vm.memory == 8)
        #expect(vm.diskSize == 128)
        #expect(vm.networkMode == "nat")
        #expect(vm.networkMembership == "common")
        #expect(vm.networkName == nil)
        #expect(vm.macAddress == "aa:bb:cc:dd:ee:ff")
        #expect(vm.ipAddress == "192.168.64.3")
        #expect(vm.agentStatus == alpha.agentStatus.wireName)
        #expect(!vm.hasSavedState)
        #expect(vm.ephemeral)
        #expect(vm.snapshotCount == 2)
        #expect(vm.bundlePath == alpha.bundleURL.path(percentEncoded: false))
        #expect(suspended.state == NSNumber(value: VMScriptState.suspended.code))
        #expect(suspended.hasSavedState)
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

    /// A VM on NAT's common network at a known MAC address.
    @discardableResult
    private func registerNetworked(
        _ wired: WiredCommandCore, name: String, mode: VMNetworkMode = .nat
    ) -> VMInstance {
        wired.register(name: name) {
            $0.networkEnabled = true
            $0.networkMode = mode
            $0.macAddress = "02:4b:4e:56:0c:01"
        }
    }

    @Test("Setting a VM's network membership, network mode or MAC address writes its key by identifier")
    func settingANetworkPropertyWritesItsKey() throws {
        let wired = WiredCommandCore()
        let alpha = registerNetworked(wired, name: "Alpha")
        let twin = registerNetworked(wired, name: "Alpha")
        // The object holds its gateway weakly; the app's lives as long as it does.
        let gateway = makeGateway(wired)
        let vm = try #require(gateway.virtualMachines().first)
        let command = try makeSetCommand()
        gateway.answeringCommand = command

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
    func scriptedWriteCarriesNoConsent() throws {
        let wired = WiredCommandCore()
        let alpha = wired.register(name: "Alpha") { $0.clipboardSharingEnabled = true }
        let gateway = makeGateway(wired)
        let command = try makeSetCommand()
        gateway.answeringCommand = command

        gateway.setConfiguration(
            alpha.id, key: VMConfigurationKeyRegistry.clipboardPassthrough, value: "true")

        let refusal = CommandError.confirmationRequired(
            ClipboardPassthroughConsent.prompt(vmName: "Alpha"))
        #expect(command.scriptErrorNumber == refusal.appleEventErrorNumber)
        #expect(command.scriptErrorString == refusal.appleEventErrorString)
        #expect(!alpha.configuration.clipboardPassthroughEnabled)
    }

    @Test("Missing value writes none to a VM's network mode, and empty to its membership and MAC address")
    func missingValueWrites() throws {
        let wired = WiredCommandCore()
        let alpha = registerNetworked(wired, name: "Alpha")
        let gateway = makeGateway(wired)
        let vm = try #require(gateway.virtualMachines().first)
        let membership = try makeSetCommand()

        // The core takes no empty membership, and its refusal quotes what was
        // written.
        gateway.answeringCommand = membership
        vm.networkMembership = nil
        gateway.answeringCommand = nil
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
    func aRefusedSettingIsRecorded() throws {
        let wired = WiredCommandCore()
        let alpha = registerNetworked(wired, name: "Alpha")
        let refusal = try #require(throws: CommandError.self) {
            try wired.core.setConfiguration(
                .id(alpha.id), assignments: [VMConfigurationKeyRegistry.networkMembership.assigning("Nowhere")],
                consent: .none)
        }
        let gateway = makeGateway(wired)
        let command = try makeSetCommand()
        let vm = try #require(gateway.virtualMachines().first)
        gateway.answeringCommand = command

        vm.networkMembership = "Nowhere"

        #expect(command.scriptErrorNumber == refusal.appleEventErrorNumber)
        #expect(command.scriptErrorString == refusal.message)
        #expect(alpha.configuration.networkMembership == .common)
    }

    @Test("A set addressing several VMs stops at the first refusal, which stands")
    func aRefusedSettingStopsTheRun() throws {
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
        let gateway = makeGateway(wired)
        let command = try makeSetCommand()
        let vms = gateway.virtualMachines()
        gateway.answeringCommand = command

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

        try await gateway.suspend([.name("Suspending")])
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

    @Test("A verb's evaluation records what the core refused on the verb's own command")
    func addressingRecordsRefusalsOnTheCommand() async throws {
        let wired = WiredCommandCore()
        wired.register(name: "Alpha")
        wired.register(name: "Alpha")
        let refusal = try #require(throws: CommandError.self) { try wired.core.info(.name("Alpha")) }
        let gateway = makeGateway(wired)
        let command = try makeGetCommand()
        let specifier = try makeNameReadingSpecifier { gateway.virtualMachine(named: "Alpha") }

        await #expect(throws: VMScriptEvaluationFailure.self) {
            try await gateway.address(specifier, for: command)
        }

        #expect(command.scriptErrorNumber == Int(errAENoSuchObject))
        #expect(command.scriptErrorString == refusal.message)
        #expect(gateway.answeringCommand == nil)
    }

    // MARK: - A read before the library has landed

    @Test("A read arriving before the library lands is deferred once, however often it reads the element")
    func aColdReadIsDeferredOnce() throws {
        let wired = WiredCommandCore()
        wired.register(name: "Alpha")
        // Never lands, so the deferred read stays parked: only Cocoa's Apple
        // event handling can answer a resumed command, and a readiness that
        // landed on a backstop instead re-issued this one on the main actor —
        // Cocoa threw, HIToolbox swallowed it, and every main-actor test after
        // it froze (#1196).
        let command = try makeGetCommand()
        let gateway = makeGateway(
            wired, awaitReady: { await Self.parkForever() }, currentCommand: { command })

        #expect(gateway.virtualMachines().isEmpty)
        #expect(gateway.virtualMachine(named: "Alpha") == nil)
        #expect(gateway.coldReads.map { ObjectIdentifier($0) } == [ObjectIdentifier(command)])
    }

    @Test("A re-issued get every virtual machine answers an empty library rather than refusing it")
    func aReissuedReadAnswers() throws {
        let command = try makeGetCommand()
        // As Cocoa builds a `get every virtual machine`: the specifier is the
        // direct parameter, and `setDirectParameter:` forwards a specifier to
        // the receivers slot, which is what the re-issue pre-evaluates.
        command.directParameter = NSPropertySpecifier(
            containerClassDescription: try makeContainer(), containerSpecifier: nil,
            key: AppDelegate.virtualMachinesKey)
        #expect(command.receiversSpecifier != nil)

        let result = makeGateway(WiredCommandCore()).reissue(command)

        // The test host's element evaluates to nothing, which the pre-evaluation
        // tells from a failure: the script reads Cocoa's own answer for it.
        #expect(result != nil)
        #expect(command.scriptErrorNumber == 0)
        #expect(command.scriptErrorOffendingObjectDescriptor == nil)
    }

    @Test("A re-issued read of a name no VM answers to carries the failure as Cocoa reports it")
    func aReissuedReadCarriesItsFailure() throws {
        let command = try makeGetCommand()
        let specifier = try makeNameSpecifier("Nope")
        specifier.evaluationErrorNumber = NSInternalSpecifierError
        command.directParameter = specifier
        #expect(command.receiversSpecifier != nil)

        _ = makeGateway(WiredCommandCore()).reissue(command)

        // The stale failure was cleared and the re-evaluation failed afresh —
        // which `execute()` reports as no receivers, the same as the empty
        // answer above, so the pre-evaluation is what tells the two apart.
        #expect(command.scriptErrorNumber == Int(errAENoSuchObject))
        #expect(command.scriptErrorOffendingObjectDescriptor != nil)
    }

    @Test("A re-issued exists answers false for what it cannot resolve")
    func aReissuedExistsAnswersFalse() throws {
        let description = try #require(
            NSScriptSuiteRegistry.shared().commandDescription(
                withAppleEventClass: FourCharCode(scriptingCode: "core"),
                andAppleEventCode: FourCharCode(scriptingCode: "doex")))
        let command = description.createCommandInstance()
        let specifier = try makeNameSpecifier("Nope")
        command.directParameter = specifier.descriptor
        command.receiversSpecifier = specifier

        let result = makeGateway(WiredCommandCore()).reissue(command)

        #expect((result as? NSNumber)?.boolValue == false)
        #expect(command.scriptErrorNumber == 0)
    }

    @Test("Clearing an evaluation failure clears the whole container chain")
    func clearingAFailureClearsTheChain() throws {
        let container = try makeNameSpecifier("Alpha")
        let property = NSPropertySpecifier(
            containerClassDescription: try makeContainer(), containerSpecifier: container,
            key: "name")
        container.evaluationErrorNumber = NSInternalSpecifierError
        property.evaluationErrorNumber = NSContainerSpecifierError

        VMScriptingGateway.clearEvaluationFailure(property)

        #expect(property.evaluationErrorNumber == 0)
        #expect(container.evaluationErrorNumber == 0)
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
        try await gateway.suspend([.name("Suspending")])
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

    /// How many times the gateway awaited the library read.
    private actor AwaitCount {
        private(set) var value = 0

        func increment() { value += 1 }
    }

    @Test("Nothing an event addressed is resolved until the app's first library read has landed")
    func addressingWaitsForTheFirstLibraryRead() async throws {
        let readiness = ReadinessGate()
        let gateway = makeGateway(WiredCommandCore(), awaitReady: { await readiness.wait() })
        let specifier = try makeNameSpecifier("Alpha")

        let command = try makeGetCommand()
        let run = Task { try await gateway.address(specifier, for: command) }
        try await readiness.awaitWaiting()
        readiness.open()

        #expect(try await run.value == [.name("Alpha")])
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
