import Foundation
import KernovaKit
import KernovaTestSupport
import Testing

@testable import Kernova

/// The Apple event front door: which verb a script runs, what it waits for
/// before running one, and how the consent a destructive verb needs is given.
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
        awaitReady: @escaping @Sendable () async -> Void = {}
    ) -> VMScriptingGateway {
        VMScriptingGateway(
            commands: commands, readiness: LibraryReadiness(awaitReady: awaitReady))
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

    @Test("A name one VM answers to resolves to that VM")
    func aUniqueNameResolves() throws {
        let commands = MockVMCommanding()
        let wanted = makeSummary(name: "Alpha")
        commands.library = [wanted, makeSummary(name: "Beta")]

        let found = try #require(makeGateway(commands).virtualMachine(named: "Alpha"))

        #expect(found.uniqueID == wanted.id.uuidString)
    }

    @Test("A name several VMs answer to resolves to none of them")
    func anAmbiguousNameResolvesToNothing() throws {
        let commands = MockVMCommanding()
        commands.library = [makeSummary(name: "Alpha"), makeSummary(name: "Alpha")]

        // Cocoa's own accessor would answer with the first, describing whichever
        // VM the library happens to list first as though it were the one asked
        // for.
        #expect(makeGateway(commands).virtualMachine(named: "Alpha") == nil)
    }

    @Test("A name no VM answers to resolves to nothing")
    func anUnknownNameResolvesToNothing() throws {
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

    // MARK: - Readiness

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
