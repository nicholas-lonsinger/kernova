import Cocoa
import CoreServices
import Foundation
import KernovaKit
import KernovaTestSupport
import Testing

@testable import Kernova

/// The Apple event front door: which verb a script runs, what it waits for
/// before running one, how it addresses a VM by name, and how the consent a
/// destructive verb needs is given.
///
/// A read that arrives before the library has landed is suspended and
/// re-issued through Cocoa's own Apple event handling, which only a live
/// script exercises; what is tested here is everything short of that.
@Suite("VM scripting gateway", .admissionGated)
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
        func wait() async {
            lock.withLock { waiting = true }
            gate.notify()
            try? await gate.wait { self.lock.withLock { self.isOpen } }
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

    private func makeGateway(
        _ commands: MockVMCommanding,
        awaitReady: @escaping @Sendable () async -> Void = {},
        activate: @escaping @MainActor () -> Void = {}
    ) -> VMScriptingGateway {
        VMScriptingGateway(
            commands: commands, readiness: LibraryReadiness(awaitReady: awaitReady),
            activate: activate)
    }

    /// Cocoa's own `get`, as the command a property read is answered for.
    private func makeGetCommand() throws -> NSScriptCommand {
        let description = try #require(
            NSScriptSuiteRegistry.shared().commandDescription(
                withAppleEventClass: FourCharCode(scriptingCode: "core"),
                andAppleEventCode: FourCharCode(scriptingCode: "getd")))
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

    private func makeSummary(
        name: String = "Sonoma", status: String = "stopped", id: UUID = UUID()
    ) -> VMSummary {
        VMSummary(id: id, name: name, status: status, ipAddress: .unavailable)
    }

    private func makePrompt(kind: ConfirmationKind) -> ConfirmationPrompt {
        ConfirmationPrompt(
            kind: kind, title: "Force stop?", message: "Unsaved guest state is lost.",
            confirmTitle: "Force Stop", dismissTitle: "Keep Running")
    }

    // MARK: - Reads

    @Test("The dictionary's elements are the library, in the order it lists them")
    func elementsAreTheLibraryInOrder() throws {
        let commands = MockVMCommanding()
        commands.library = [makeSummary(name: "Alpha"), makeSummary(name: "Beta")]

        let vms = makeGateway(commands).virtualMachines()

        #expect(vms.map(\.name) == ["Alpha", "Beta"])
        #expect(vms.map(\.uniqueID) == commands.library.map(\.id.uuidString))
    }

    @Test("A name one VM answers to resolves to that VM, through the core")
    func aUniqueNameResolves() throws {
        let commands = MockVMCommanding()
        let wanted = makeSummary(name: "Alpha")
        commands.library = [wanted, makeSummary(name: "Beta")]

        let found = try #require(makeGateway(commands).virtualMachine(named: "Alpha"))

        #expect(found.uniqueID == wanted.id.uuidString)
        #expect(commands.infoSelectors == [.name("Alpha")])
    }

    @Test("A name several VMs answer to is refused in the core's words, with the candidates")
    func anAmbiguousNameIsRefusedByTheCore() throws {
        let commands = MockVMCommanding()
        commands.library = [makeSummary(name: "Alpha"), makeSummary(name: "Alpha")]
        let gateway = makeGateway(commands)
        let command = try makeGetCommand()
        gateway.answeringCommand = command

        // Cocoa's own accessor would answer with the first, describing whichever
        // VM the library happens to list first as though it were the one asked
        // for.
        #expect(gateway.virtualMachine(named: "Alpha") == nil)

        #expect(command.scriptErrorNumber == Int(errAENoSuchObject))
        #expect(
            command.scriptErrorString
                == CommandError.ambiguous(selector: .name("Alpha"), candidates: commands.library)
                .message)
    }

    @Test("A name no VM answers to is refused in the core's words")
    func anUnknownNameIsRefusedByTheCore() throws {
        let commands = MockVMCommanding()
        commands.library = [makeSummary(name: "Alpha")]
        let gateway = makeGateway(commands)
        let command = try makeGetCommand()
        gateway.answeringCommand = command

        #expect(gateway.virtualMachine(named: "Beta") == nil)

        #expect(command.scriptErrorNumber == Int(errAENoSuchObject))
        #expect(command.scriptErrorString == CommandError.notFound(.name("Beta")).message)
    }

    @Test("A refused name with no command to answer records nothing and resolves to nothing")
    func aRefusedNameWithNoCommandResolvesToNothing() throws {
        let commands = MockVMCommanding()
        commands.library = [makeSummary(name: "Alpha")]

        #expect(makeGateway(commands).virtualMachine(named: "Beta") == nil)
    }

    @Test("Every property answers from the VM's own read")
    func propertiesAnswerFromTheRead() throws {
        let commands = MockVMCommanding()
        let summary = makeSummary(name: "Alpha", status: "running")
        commands.library = [summary]
        commands.infoByID[summary.id] = VMInfo(
            id: summary.id, name: "Alpha", status: "running", guestOS: "macOS", cpuCount: 6,
            memoryBytes: 8 << 30, diskSizeInGB: 128, networkMode: "shared",
            macAddress: "aa:bb:cc:dd:ee:ff", ipAddress: .reserved("192.168.64.3"),
            agentStatus: "connected", hasSavedState: true, isEphemeral: true, snapshotCount: 2,
            bundlePath: "/VMs/Alpha.kernova")

        let vm = try #require(makeGateway(commands).virtualMachines().first)

        #expect(vm.name == "Alpha")
        #expect(vm.state == NSNumber(value: VMScriptState.running.code))
        #expect(vm.guestOperatingSystem == "macOS")
        #expect(vm.processorCount == 6)
        #expect(vm.memory == 8)
        #expect(vm.diskSize == 128)
        #expect(vm.networkMode == "shared")
        #expect(vm.macAddress == "aa:bb:cc:dd:ee:ff")
        #expect(vm.ipAddress == "192.168.64.3")
        #expect(vm.agentStatus == "connected")
        #expect(vm.hasSavedState)
        #expect(vm.ephemeral)
        #expect(vm.snapshotCount == 2)
        #expect(vm.bundlePath == "/VMs/Alpha.kernova")
    }

    @Test("A VM with nothing to report on a field answers with missing value")
    func absentFieldsAnswerWithMissingValue() throws {
        let commands = MockVMCommanding()
        commands.library = [makeSummary(name: "Alpha")]

        let vm = try #require(makeGateway(commands).virtualMachines().first)

        #expect(vm.networkMode == nil)
        #expect(vm.macAddress == nil)
        #expect(vm.ipAddress == nil)
    }

    // MARK: - Verb dispatch

    @Test("Each verb reaches the core with the VMs the event addressed")
    func verbsReachTheCore() async throws {
        let commands = MockVMCommanding()
        let gateway = makeGateway(commands)
        let alpha = VMSelector.name("Alpha")

        try await gateway.start([alpha], recoveryMode: true)
        try await gateway.stop([alpha], method: .force, confirmed: true, givingUpAfter: 30)
        try await gateway.restart([alpha], givingUpAfter: nil)
        try await gateway.pause([alpha])
        try await gateway.resume([alpha])
        try await gateway.suspend([alpha])
        try await gateway.reveal([alpha])

        #expect(commands.startCalls.map(\.selector) == [alpha])
        #expect(commands.startCalls.map(\.recovery) == [true])
        #expect(commands.stopCalls.map(\.disposition) == [.force])
        #expect(commands.stopCalls.map(\.timeout) == [30])
        #expect(commands.restartCalls.map(\.timeout) == [nil])
        #expect(commands.pauseSelectors == [alpha])
        #expect(commands.resumeCalls.map(\.selector) == [alpha])
        #expect(commands.suspendSelectors == [alpha])
        #expect(commands.revealSelectors == [alpha])
    }

    @Test("An event addressing several VMs runs the verb on each of them")
    func aVerbRunsOnEveryAddressedVM() async throws {
        let commands = MockVMCommanding()
        let selectors: [VMSelector] = [.name("Alpha"), .name("Beta")]

        try await makeGateway(commands).pause(selectors)

        #expect(commands.pauseSelectors == selectors)
    }

    @Test("A refusal stops the run where it happened")
    func aRefusalStopsTheRun() async throws {
        let commands = MockVMCommanding()
        let refusal = CommandError.notFound(.name("Alpha"))
        commands.pauseError = refusal

        await #expect(throws: refusal) {
            try await makeGateway(commands).pause([.name("Alpha"), .name("Beta")])
        }

        #expect(commands.pauseSelectors == [.name("Alpha")])
    }

    @Test("A verb's refusal reaches the script untouched")
    func aRefusalReachesTheScript() async throws {
        let commands = MockVMCommanding()
        let refusal = CommandError.ambiguous(
            selector: .name("Alpha"), candidates: [makeSummary(), makeSummary()])
        commands.startError = refusal

        await #expect(throws: refusal) {
            try await makeGateway(commands).start([.name("Alpha")], recoveryMode: false)
        }
    }

    // MARK: - Addressing

    @Test("A verb's evaluation records what the core refused on the verb's own command")
    func addressingRecordsRefusalsOnTheCommand() async throws {
        let commands = MockVMCommanding()
        commands.library = [makeSummary(name: "Alpha"), makeSummary(name: "Alpha")]
        let gateway = makeGateway(commands)
        let command = try makeGetCommand()
        let specifier = try makeNameReadingSpecifier { gateway.virtualMachine(named: "Alpha") }

        await #expect(throws: VMScriptEvaluationFailure.self) {
            try await gateway.address(specifier, for: command)
        }

        #expect(command.scriptErrorNumber == Int(errAENoSuchObject))
        #expect(
            command.scriptErrorString
                == CommandError.ambiguous(selector: .name("Alpha"), candidates: commands.library)
                .message)
        #expect(gateway.answeringCommand == nil)
    }

    @Test("A list of specifiers addresses each VM it names, in order")
    func aListAddressesEachVM() async throws {
        let gateway = makeGateway(MockVMCommanding())
        let list: [Any] = [try makeNameSpecifier("Alpha"), try makeNameSpecifier("Beta")]

        #expect(try await gateway.address(list, for: try makeGetCommand()) == [.name("Alpha"), .name("Beta")])
        #expect(try await gateway.address([Any](), for: try makeGetCommand()).isEmpty)
    }

    // MARK: - A read before the library has landed

    @Test("A read arriving before the library lands is deferred once, however often it reads the element")
    func aColdReadIsDeferredOnce() throws {
        let commands = MockVMCommanding()
        commands.library = [makeSummary(name: "Alpha")]
        // Never landed, so the deferred read stays parked: resuming a command
        // Cocoa never suspended is undefined, and only Cocoa's Apple event
        // handling can suspend one.
        let gateway = makeGateway(commands, awaitReady: { await ReadinessGate().wait() })
        let command = try makeGetCommand()
        gateway.currentCommandForTesting = { command }

        #expect(gateway.virtualMachines().isEmpty)
        #expect(gateway.virtualMachine(named: "Alpha") == nil)
        #expect(gateway.coldReads.map { ObjectIdentifier($0) } == [ObjectIdentifier(command)])
    }

    @Test("A re-issued read answers from the landed library")
    func aReissuedReadAnswers() throws {
        let command = try makeGetCommand()
        // As Cocoa builds a `get`: the specifier is the direct parameter, and
        // the receivers follow from it.
        command.directParameter = NSPropertySpecifier(
            containerClassDescription: try makeContainer(), containerSpecifier: nil,
            key: AppDelegate.virtualMachinesKey)

        let result = makeGateway(MockVMCommanding()).reissue(command)

        // The test host's element is empty, which is an answer, not a failure.
        #expect(result != nil)
        #expect(command.scriptErrorNumber == 0)
    }

    @Test("A re-issued read whose specifier fails carries the failure as Cocoa reports it")
    func aReissuedReadCarriesItsFailure() throws {
        let command = try makeGetCommand()
        let specifier = try makeNameSpecifier("Nope")
        specifier.evaluationErrorNumber = NSInternalSpecifierError
        command.directParameter = specifier

        _ = makeGateway(MockVMCommanding()).reissue(command)

        // The stale failure was cleared and the re-evaluation failed afresh.
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

        let result = makeGateway(MockVMCommanding()).reissue(command)

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

    // MARK: - Activation

    @Test("A verb that puts a window up brings the app forward first")
    func surfacingVerbsActivate() async throws {
        let commands = MockVMCommanding()
        var activations = 0
        let gateway = makeGateway(commands, activate: { activations += 1 })
        let alpha = VMSelector.name("Alpha")

        try await gateway.start([alpha], recoveryMode: false)
        try await gateway.resume([alpha])
        try await gateway.restart([alpha], givingUpAfter: nil)
        try await gateway.reveal([alpha])

        #expect(activations == 4)
    }

    @Test("A verb that puts nothing up leaves the app where it is, as does one addressing no VM")
    func nonSurfacingVerbsDoNotActivate() async throws {
        let commands = MockVMCommanding()
        var activations = 0
        let gateway = makeGateway(commands, activate: { activations += 1 })
        let alpha = VMSelector.name("Alpha")

        try await gateway.stop([alpha], method: .graceful, confirmed: false, givingUpAfter: nil)
        try await gateway.pause([alpha])
        try await gateway.suspend([alpha])
        try await gateway.reveal([])

        #expect(activations == 0)
    }

    @Test("The app comes forward before the verb, so a refused verb has already activated")
    func activationPrecedesTheVerb() async throws {
        let commands = MockVMCommanding()
        commands.revealError = CommandError.notFound(.name("Alpha"))
        var activations = 0
        let gateway = makeGateway(commands, activate: { activations += 1 })

        await #expect(throws: CommandError.self) {
            try await gateway.reveal([.name("Alpha")])
        }

        #expect(activations == 1)
    }

    // MARK: - Readiness

    @Test("Nothing an event addressed is resolved until the app's first library read has landed")
    func addressingWaitsForTheFirstLibraryRead() async throws {
        let readiness = ReadinessGate()
        let gateway = makeGateway(MockVMCommanding(), awaitReady: { await readiness.wait() })
        let specifier = try makeNameSpecifier("Alpha")

        let command = try makeGetCommand()
        let run = Task { try await gateway.address(specifier, for: command) }
        try await readiness.awaitWaiting()
        readiness.open()

        #expect(try await run.value == [.name("Alpha")])
    }

    @Test("No verb reaches the core until the app's first library read has landed")
    func verbsWaitForTheFirstLibraryRead() async throws {
        let commands = MockVMCommanding()
        let readiness = ReadinessGate()
        let gateway = makeGateway(commands, awaitReady: { await readiness.wait() })

        let run = Task { try await gateway.pause([.name("Alpha")]) }
        try await readiness.awaitWaiting()
        #expect(commands.pauseSelectors.isEmpty)

        readiness.open()
        try await run.value
        #expect(commands.pauseSelectors == [.name("Alpha")])
    }

    @Test("The library read is awaited once, however many events pile onto it")
    func readinessIsMemoized() async throws {
        let commands = MockVMCommanding()
        let awaits = Counter()
        let gateway = makeGateway(commands, awaitReady: { await awaits.increment() })

        try await gateway.pause([.name("Alpha")])
        try await gateway.resume([.name("Alpha")])

        #expect(await awaits.value == 1)
    }

    // MARK: - Consent

    @Test("A destructive stop with no confirmation is refused, and runs nothing")
    func anUnconfirmedStopIsRefused() async throws {
        let commands = MockVMCommanding()
        let prompt = makePrompt(kind: .forceStop)
        commands.stopConsentPrompt = prompt

        await #expect(throws: CommandError.confirmationRequired(prompt)) {
            try await makeGateway(commands).stop(
                [.name("Alpha")], method: .force, confirmed: false, givingUpAfter: nil)
        }

        #expect(commands.stopCalls.map(\.confirmed) == [false])
    }

    @Test("A stop with confirmation re-issues the verb, consented")
    func aConfirmedStopIsReIssued() async throws {
        let commands = MockVMCommanding()
        commands.stopConsentPrompt = makePrompt(kind: .forceStop)

        try await makeGateway(commands).stop(
            [.name("Alpha")], method: .force, confirmed: true, givingUpAfter: nil)

        #expect(commands.stopCalls.map(\.confirmed) == [false, true])
    }

    @Test("A stop a paused guest cannot receive is refused even with confirmation")
    func aPausedStopIsRefusedEvenWithConfirmation() async throws {
        let commands = MockVMCommanding()
        let prompt = makePrompt(kind: .stopPaused)
        commands.stopConsentPrompt = prompt

        // Confirming would substitute a stop that was not asked for, so the
        // script is told to name the method it means instead.
        await #expect(throws: CommandError.confirmationRequired(prompt)) {
            try await makeGateway(commands).stop(
                [.name("Alpha")], method: .graceful, confirmed: true, givingUpAfter: nil)
        }

        #expect(commands.stopCalls.map(\.confirmed) == [false])
    }
}
