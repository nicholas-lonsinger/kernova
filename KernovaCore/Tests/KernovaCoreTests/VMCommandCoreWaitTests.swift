import Foundation
import KernovaCommandModel
import KernovaKit
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport

/// The wait verb, driven against a wired library: what ends a wait besides
/// the condition, and what does not.
///
/// Each wait is armed before the change it waits through. Its deadline is the
/// sleep it parks on the gated clock, which it arms in the step that first
/// reads the condition, so a parked sleep is the proof the wait is running.
@Suite("VMCommandCore wait", .caseScoped)
@MainActor
struct VMCommandCoreWaitTests {
    private let preferences = makeTestPreferences()

    private typealias Harness = WiredCommandCore.Scripted<MockVirtualizationService>

    private func makeHarness(
        virtualization: MockVirtualizationService = MockVirtualizationService(),
        install: any MacOSInstallProviding = MockMacOSInstallService(), clock: GatedEngineClock
    ) -> Harness {
        Harness(
            WiredCommandCore(
                virtualization: virtualization, installService: install, preferences: preferences, clock: clock))
    }

    /// A wait for `condition` on the VM `id` names, bounded by `seconds`,
    /// returned once it is armed.
    private func armedWait(
        in harness: Harness, on id: UUID, until condition: WaitCondition, seconds: TimeInterval = 60,
        clock: GatedEngineClock
    ) async throws -> Task<VMInfo, any Error> {
        let wait = Task { try await harness.core.wait(.id(id), until: condition, timeout: seconds) }
        try await clock.sleepRequested.wait { !clock.parked.isEmpty }
        return wait
    }

    /// An install-pending macOS VM: its start dispatches the setup and returns,
    /// so whatever happens next has no caller waiting on it.
    private func makeSetupPendingVM(in harness: Harness) -> VMInstance {
        harness.wired.register(name: "Fresh", phase: .initialBoot, guestOS: .macOS) {
            $0.installContext = MacOSInstallContext(source: .localFile, localIPSWPath: "/tmp/restore.ipsw")
        }
    }

    // MARK: - A Failure Ends the Wait

    @Test("A Start failing while the wait runs ends it with the start's message; the failure before it began does not")
    func aStartFailureEndsTheWaitButNotTheOneBeforeIt() async throws {
        let virtualization = MockVirtualizationService()
        virtualization.startError = VirtualizationError.noVirtualMachine
        let clock = GatedEngineClock()
        let harness = makeHarness(virtualization: virtualization, clock: clock)
        let vm = harness.wired.register(name: "Flaky")
        _ = try? await harness.core.start(.id(vm.id), recovery: false, consent: .none)
        #expect(vm.status == .error)

        let wait = try await armedWait(in: harness, on: vm.id, until: .running, clock: clock)
        // Transient, so the VM rests stopped rather than in the error status:
        // the failure is what ends the wait, not where the VM rests.
        virtualization.startError = makeVMLimitExceededError()
        let started = try await #require(throws: CommandError.self) {
            try await harness.core.start(.id(vm.id), recovery: false, consent: .none)
        }
        #expect(vm.status == .stopped)

        let ended = try await #require(throws: CommandError.self) { try await wait.joined() }
        #expect(ended == .operationFailed(verb: .wait, message: started.message(in: .log)))
    }

    @Test("A Suspend that fails ends the wait with the words its caller was told")
    func aSuspendFailureEndsTheWait() async throws {
        let virtualization = MockVirtualizationService()
        virtualization.saveError = NSError(
            domain: "VZErrorDomain", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "The virtual machine's state could not be saved."])
        let clock = GatedEngineClock()
        let harness = makeHarness(virtualization: virtualization, clock: clock)
        let vm = harness.wired.register(name: "Unsaved", phase: .running(sessionID: UUID()))

        let wait = try await armedWait(in: harness, on: vm.id, until: .stopped, clock: clock)
        let thrown = try await #require(throws: CommandError.self) {
            try await harness.core.suspend(.id(vm.id))
        }

        let ended = try await #require(throws: CommandError.self) { try await wait.joined() }
        #expect(ended == .operationFailed(verb: .wait, message: thrown.message(in: .log)))
    }

    @Test("A guest setup nobody awaits that fails transiently ends the wait with what its alert says")
    func aTransientSetupFailureEndsTheWait() async throws {
        let install = MockMacOSInstallService()
        install.installError = makeInstallVMLimitExceededError()
        let clock = GatedEngineClock()
        let harness = makeHarness(install: install, clock: clock)
        let vm = makeSetupPendingVM(in: harness)

        let wait = try await armedWait(in: harness, on: vm.id, until: .running, clock: clock)
        try await harness.core.start(.id(vm.id), recovery: false, consent: .none)
        try await vm.setupOperationTask?.joined()
        // Back where a retry starts: nothing about where it rests says it failed.
        #expect(vm.status == .initialBoot)

        let alert = try #require(harness.failures.first)
        let ended = try await #require(throws: CommandError.self) { try await wait.joined() }
        #expect(ended == .operationFailed(verb: .wait, message: alert.message(in: .app)))
    }

    @Test("A guest setup cancelled while the wait runs leaves it running to its deadline")
    func aCancelledSetupLeavesTheWaitRunning() async throws {
        let install = MockMacOSInstallService()
        install.installError = CancellationError()
        let clock = GatedEngineClock()
        let harness = makeHarness(install: install, clock: clock)
        let vm = makeSetupPendingVM(in: harness)

        let wait = try await armedWait(in: harness, on: vm.id, until: .running, clock: clock)
        try await harness.core.start(.id(vm.id), recovery: false, consent: .none)
        try await vm.setupOperationTask?.joined()
        #expect(vm.status == .initialBoot)
        // A cancel is somebody's decision, not a failure to tell anyone of.
        #expect(harness.failures.isEmpty)

        // Letting the deadline expire is what proves the wait was still
        // running: had the cancel ended it, it would already have thrown
        // something other than its expiry.
        clock.release(try #require(clock.parked.first))
        let ended = try await #require(throws: CommandError.self) { try await wait.joined() }
        guard case .waitEnded(_, .running, .timedOut(60)) = ended else {
            Issue.record("Expected the wait's expiry, got \(ended)")
            return
        }
    }

    @Test("A restore a group start runs that fails, resting the VM suspended again, ends the wait")
    func aGroupMembersRestoreFailureEndsTheWait() async throws {
        let virtualization = MockVirtualizationService()
        virtualization.restoreError = VirtualizationError.restoreFailed(
            underlying: NSError(domain: "test", code: 1))
        let clock = GatedEngineClock()
        let harness = makeHarness(virtualization: virtualization, clock: clock)
        let suspended = harness.wired.register(name: "Suspended", phase: .suspended)
        try VMInstanceFixture.writeSaveFile(for: suspended)
        try harness.library.organization.createFolder(named: "Lab", members: [suspended.id])

        let wait = try await armedWait(in: harness, on: suspended.id, until: .running, clock: clock)
        let report = try await harness.core.groupAction(.start, on: VMGroupReference(.folder, named: "Lab"))
        guard case .failed(let error)? = report.results.first?.outcome else {
            Issue.record("reported \(String(describing: report.results.first?.outcome))")
            return
        }
        #expect(suspended.status == .suspended)

        let ended = try await #require(throws: CommandError.self) { try await wait.joined() }
        #expect(ended == .operationFailed(verb: .wait, message: error.message(in: .log)))
    }

    @Test("A clone whose copy fails ends a wait on it with the copy's failure, not as a removal")
    func aCopyFailureEndsTheWaitOnTheClone() async throws {
        let clock = GatedEngineClock()
        let harness = makeHarness(clock: clock)
        let cloneError = VMStorageError.bundleAlreadyExists(URL(filePath: "/tmp/occupied.kernova"))
        let hold = DispatchSemaphore(value: 0)
        harness.storage.setCloneHold(hold)
        harness.storage.setCloneVMBundleError(cloneError)
        let source = harness.wired.register(name: "Source")
        let copy = try harness.core.beginClone(.id(source.id), outcome: .newMachine)

        let wait = try await armedWait(in: harness, on: copy.id, until: .stopped, clock: clock)
        hold.signal()

        let ended = try await #require(throws: CommandError.self) { try await wait.joined() }
        #expect(ended == .operationFailed(verb: .wait, message: cloneError.localizedDescription))
    }

    // MARK: - Other Endings

    @Test("A VM that leaves the library ends the wait as a removal")
    func aRemovedVMEndsTheWait() async throws {
        let clock = GatedEngineClock()
        let harness = makeHarness(clock: clock)
        let vm = harness.wired.register(name: "Doomed")

        let wait = try await armedWait(in: harness, on: vm.id, until: .running, clock: clock)
        try await harness.core.delete(.id(vm.id), permanently: false, alsoRemoving: [], consent: .all)

        let ended = try await #require(throws: CommandError.self) { try await wait.joined() }
        guard case .waitEnded(let summary, .running, .removed) = ended else {
            Issue.record("Expected a removal, got \(ended)")
            return
        }
        #expect(summary.id == vm.id)
    }

    @Test("Another VM failing and leaving the library ends nothing; the wait ends on its own VM")
    func anotherVMsEndingsAreNotThisWaits() async throws {
        let virtualization = MockVirtualizationService()
        let clock = GatedEngineClock()
        let harness = makeHarness(virtualization: virtualization, clock: clock)
        let alpha = harness.wired.register(name: "Alpha")
        let beta = harness.wired.register(name: "Beta")

        let wait = try await armedWait(in: harness, on: alpha.id, until: .running, clock: clock)
        virtualization.startError = VirtualizationError.noVirtualMachine
        _ = try? await harness.core.start(.id(beta.id), recovery: false, consent: .none)
        #expect(beta.status == .error)
        try await harness.core.delete(.id(beta.id), permanently: false, alsoRemoving: [], consent: .all)
        virtualization.startError = nil
        try await harness.core.start(.id(alpha.id), recovery: false, consent: .none)

        let met = try await wait.joined()
        #expect(met.id == alpha.id)
        #expect(met.status == VMStatus.running.rawValue)
    }

    @Test("The deadline ends a wait nothing else does, naming the condition and the seconds")
    func theDeadlineEndsTheWait() async throws {
        let clock = GatedEngineClock()
        let harness = makeHarness(clock: clock)
        let vm = harness.wired.register(name: "Idle")

        let wait = try await armedWait(in: harness, on: vm.id, until: .running, seconds: 45, clock: clock)
        clock.release(try #require(clock.parked.first))

        let ended = try await #require(throws: CommandError.self) { try await wait.joined() }
        guard case .waitEnded(let summary, .running, .timedOut(45)) = ended else {
            Issue.record("Expected the wait's expiry, got \(ended)")
            return
        }
        #expect(summary.id == vm.id)
    }

    @Test(
        "Waiting for an address refuses at once where Kernova can see none, naming why",
        arguments: [
            (mode: VMNetworkMode.bridged, absence: GuestAddressAbsence.externallyAssigned),
            (mode: VMNetworkMode.nat, absence: GuestAddressAbsence.unavailable),
        ])
    func anAddressNoWaitCanSeeRefusesAtOnce(_ c: (mode: VMNetworkMode, absence: GuestAddressAbsence)) async throws {
        let clock = GatedEngineClock()
        let harness = makeHarness(clock: clock)
        let vm = harness.wired.register(name: "Unseen") {
            $0.networkEnabled = true
            $0.networkMode = c.mode
        }

        let wait = Task { try await harness.core.wait(.id(vm.id), until: .address, timeout: 60) }
        let ended = try await #require(throws: CommandError.self) { try await wait.joined() }
        guard case .waitEnded(_, .address, .noAddressToWaitFor(let absence)) = ended else {
            Issue.record("Expected a refusal, got \(ended)")
            return
        }
        #expect(absence == c.absence)
        // At once: no deadline was ever armed.
        #expect(clock.parked.isEmpty)
    }

    // MARK: - The Agent

    @Test("Only an agent connected and current ends a wait for the agent")
    func onlyACurrentAgentEndsTheAgentWait() {
        #expect(AgentStatus.current(version: "2.0").endsAWaitForTheAgent)
        let others: [AgentStatus] = [
            .waiting, .connected(version: "2.0"), .outdated(installed: "1.0", bundled: "2.0"),
            .reinstallNeeded(installed: "1.0", bundled: "2.0", reason: .launchRefused),
            .updating(installed: "1.0", bundled: "2.0"), .unresponsive(version: "2.0"),
            .expectedMissing(expected: "2.0"), .connecting(expected: "2.0"), .disconnected(last: "2.0"),
        ]
        for status in others {
            #expect(!status.endsAWaitForTheAgent, "\(status)")
        }
    }
}
