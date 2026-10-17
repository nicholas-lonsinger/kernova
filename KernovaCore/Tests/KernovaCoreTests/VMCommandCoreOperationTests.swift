import Foundation
import KernovaKit
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport

/// What the one-operation-per-VM structure closes, driven through the command
/// core: a session action never releases the operation holding the VM, only
/// that operation's ending moves it back to rest, and a request landing
/// anywhere in between is decided against the operation that holds it.
@Suite("VMCommandCore Operation Tests", .serialized, .caseScoped)
@MainActor
struct VMCommandCoreOperationTests {
    private let preferences = makeTestPreferences()

    private func makeHarness(
        virtualization: any VirtualizationProviding,
        usbAccessories: MockUSBAccessoryService? = nil,
        clock: any EngineClock = makePlatformEngineClock()
    ) -> WiredCommandCore {
        WiredCommandCore(
            virtualization: virtualization, usbAccessoryService: usbAccessories,
            preferences: preferences, clock: clock)
    }

    @discardableResult
    private func makeInstance(
        in harness: WiredCommandCore, name: String = "Core VM", phase: VMLifecyclePhase = .stopped,
        guestOS: VMGuestOS = .linux, snapshots: [VMSnapshot] = [],
        mutate: (inout VMConfiguration) -> Void = { _ in }
    ) -> VMInstance {
        let instance = RegisteredVMInstanceFixture.register(
            name: name, phase: phase, guestOS: guestOS, snapshots: snapshots,
            library: harness.library, preferences: preferences,
            mutate: mutate)
        for snapshot in snapshots {
            harness.machineFiles.setCapturedConfiguration(instance.configuration, for: snapshot.id)
        }
        return instance
    }

    // MARK: - R2: a stop releases nothing

    @Test("R2: a Stop during a USB attach releases nothing, so Suspend is refused busy until the attach ends")
    func stopDuringAUSBAttachKeepsTheAttachHolding() async throws {
        let virtualization = MockVirtualizationService()
        // The request is delivered and the guest takes its time: what is left
        // is whatever the Stop did to the operation holding the VM.
        virtualization.guestIgnoresShutdownRequest = true
        let accessories = MockUSBAccessoryService()
        let harness = makeHarness(virtualization: virtualization, usbAccessories: accessories)
        let session = UUID()
        let instance = makeInstance(in: harness, phase: .running(sessionID: session))
        instance.beginSessionContextForTesting()
        accessories.accessories.append(MockUSBAccessoryService.accessory(registryID: 42, serial: "A1"))
        accessories.suspendNextAttach = true

        let attach = Task { @MainActor in
            try await harness.core.attachUSBAccessory(.id(instance.id), accessory: 42)
        }
        try await accessories.attachStarted()
        let held = instance.phase
        #expect(held.operation?.kind == .attachingUSB(registryID: 42))

        try await harness.core.stop(.id(instance.id), disposition: .graceful, consent: .none)
        #expect(virtualization.stopCallCount == 1)

        let refused = try await #require(throws: CommandError.self) { try await harness.core.suspend(.id(instance.id)) }
        #expect(refused.isBusy)
        #expect(instance.phase == held)
        #expect(virtualization.saveCallCount == 0)

        accessories.resumeAttach()
        try await attach.value
        #expect(instance.phase == .running(sessionID: session))

        try await harness.core.suspend(.id(instance.id))
        #expect(virtualization.saveCallCount == 1)
        #expect(instance.phase == .suspended)
    }

    @Test("R2: a Stop during a pause releases nothing, so Suspend is refused busy until the pause ends")
    func stopDuringAPauseKeepsThePauseHolding() async throws {
        let virtualization = SuspendingMockVirtualizationService()
        virtualization.guestIgnoresShutdownRequest = true
        let harness = makeHarness(virtualization: virtualization)
        let session = UUID()
        let instance = makeInstance(in: harness, phase: .running(sessionID: session))

        let pause = Task { @MainActor in try await harness.core.pause(.id(instance.id)) }
        await virtualization.waitUntilSuspended()
        let held = instance.phase
        #expect(held.operation?.kind == .pausing)

        try await harness.core.stop(.id(instance.id), disposition: .graceful, consent: .none)
        #expect(virtualization.requestStopCallCount == 1)

        let refused = try await #require(throws: CommandError.self) { try await harness.core.suspend(.id(instance.id)) }
        #expect(refused.isBusy)
        #expect(instance.phase == held)

        virtualization.resumeSuspended()
        try await pause.value
        #expect(instance.phase == .livePaused(sessionID: session))

        try await harness.core.suspend(.id(instance.id))
        #expect(instance.phase == .suspended)
    }

    // MARK: - R3: only the ending commit leaves the operation

    @Test("R3: Force Stop in a revert's stop window is refused busy, and the revert holds until its copy lands")
    func forceStopDuringARevertIsRefusedAndTheRevertHolds() async throws {
        let virtualization = SuspendingMockVirtualizationService()
        virtualization.shouldSuspendOnRevert = true
        virtualization.shouldSuspendBeforeInstall = true
        // A start wrongly admitted mid-revert runs through rather than
        // parking beside it, so it fails an expectation instead of the mock.
        virtualization.shouldSuspendOnStart = false
        let harness = makeHarness(virtualization: virtualization)
        let session = UUID()
        let snapshot = VMSnapshot(name: "Clean install", macAddress: nil)
        let instance = makeInstance(
            in: harness, phase: .running(sessionID: session), snapshots: [snapshot])

        let revert = Task { @MainActor in
            try await harness.core.revertToSnapshot(
                .id(instance.id), snapshot: snapshot.id, consent: .all)
        }
        // Parked before the revert ends the session it holds: the stop window.
        await virtualization.waitUntilSuspended()
        #expect(instance.isHeldByRevert)
        #expect(instance.liveSessionID == session)

        let refused = try await #require(throws: CommandError.self) {
            try await harness.core.stop(.id(instance.id), disposition: .force, consent: .all)
        }
        #expect(refused.isBusy)
        #expect(virtualization.forceStopCallCount == 0)

        // The session going down under the revert — its own stop landing, or
        // the guest's — marks the operation's session ended and nothing more.
        instance.activity.deliverSessionEvent(.guestDidStop, from: session)
        #expect(instance.isHeldByRevert)
        #expect(instance.phase.operation?.sessionEnd == .poweredOff)

        virtualization.resumeSuspended()
        // Parked again with the files staged and not yet installed.
        await virtualization.waitUntilSuspended()
        #expect(instance.isHeldByRevert)
        #expect(harness.machineFiles.events == [.stageRestore])
        let start = try await #require(throws: CommandError.self) {
            try await harness.core.start(.id(instance.id), recovery: false, consent: .none)
        }
        #expect(start.isBusy)
        #expect(virtualization.startCallCount == 0)

        virtualization.resumeSuspended()
        try await revert.value
        #expect(harness.machineFiles.events == [.stageRestore, .installRestore])
        #expect(!instance.isHeldByRevert)
        #expect(instance.phase == .suspended)
    }

    // MARK: - R8: a live revert takes no rename and no live edit

    @Test("R8: a rename and a live-key edit during a live revert are refused, changing nothing")
    func renameAndLiveEditDuringALiveRevertAreRefused() async throws {
        let virtualization = SuspendingMockVirtualizationService()
        virtualization.shouldSuspendOnRevert = true
        let harness = makeHarness(virtualization: virtualization)
        let snapshot = VMSnapshot(name: "Clean install", macAddress: nil)
        let instance = makeInstance(
            in: harness, name: "Reverting", phase: .running(sessionID: UUID()),
            snapshots: [snapshot])
        let relays = instance.configuration.serialSocketRelayEnabled

        let revert = Task { @MainActor in
            try await harness.core.revertToSnapshot(
                .id(instance.id), snapshot: snapshot.id, consent: .all)
        }
        await virtualization.waitUntilSuspended()
        #expect(instance.isHeldByRevert)

        #expect(!harness.library.capabilities.accepts(.rename, on: instance))
        #expect(!harness.library.capabilities.accepts(.editLiveConfiguration, on: instance))
        let rename = try #require(throws: CommandError.self) {
            try harness.core.rename(.id(instance.id), to: "Renamed")
        }
        #expect(rename.isBusy)
        let edit = try #require(throws: CommandError.self) {
            try harness.core.setConfiguration(
                .id(instance.id),
                assignments: [ConfigurationEntry(key: "serial.socket", value: String(!relays))],
                consent: .all)
        }
        #expect(edit.isBusy)
        #expect(instance.name == "Reverting")
        #expect(instance.configuration.serialSocketRelayEnabled == relays)

        virtualization.resumeSuspended()
        try await revert.value
        // The same edits are taken once the revert has ended.
        try harness.core.rename(.id(instance.id), to: "Renamed")
        #expect(instance.name == "Renamed")
    }

    // MARK: - R10: removed refuses everything

    @Test("R10: once deleted, a VM refuses every capability and every verb")
    func deletedVMRefusesEverything() async throws {
        let virtualization = MockVirtualizationService()
        let harness = makeHarness(virtualization: virtualization)
        let snapshot = VMSnapshot(name: "Clean install", macAddress: nil)
        let instance = makeInstance(in: harness, name: "Doomed", snapshots: [snapshot])

        try await harness.core.delete(
            .id(instance.id), permanently: false, alsoRemoving: [], consent: .all)
        #expect(instance.phase == .removed)

        let capabilities = harness.library.capabilities
        for capability in VMCapability.allCases {
            #expect(!capabilities.accepts(capability, on: instance), "\(capability)")
            #expect(!capabilities.isApplicable(capability, to: instance), "\(capability)")
        }

        // The verbs a surface holding the instance itself reaches, past the
        // library lookup a selector would already fail.
        let notFound = CommandError.notFound(.id(instance.id))
        await #expect(throws: notFound) {
            try await harness.core.start(.id(instance.id), recovery: false, consent: .none)
        }
        await #expect(throws: notFound) {
            try await harness.core.stop(instance, disposition: .graceful, consent: .all)
        }
        await #expect(throws: notFound) {
            try await harness.core.stop(instance, disposition: .force, consent: .all)
        }
        await #expect(throws: notFound) { try await harness.core.suspend(instance) }
        // No capture mode is left to name a request for, so this one refuses
        // with the state rather than the removal — refused all the same, and
        // offering nothing.
        let snapshotRefusal = try await #require(throws: CommandError.self) {
            _ = try await harness.core.takeSnapshot(instance, name: "Late", notes: "")
        }
        if case .invalidState(let vm, let current, let allowed, _) = snapshotRefusal {
            #expect(vm.id == instance.id)
            #expect(current == .stopped)
            #expect(allowed.isEmpty)
        } else {
            Issue.record("Expected an invalid-state refusal, got \(snapshotRefusal)")
        }
        #expect(throws: notFound) { _ = try harness.core.startRevert(instance, to: snapshot) }
        await #expect(throws: VMAdmissionRefusal(refusal: .removed)) {
            try await harness.lifecycle.pause(instance)
        }

        // And every selector verb, which no longer finds it.
        let selector = VMSelector.id(instance.id)
        await #expect(throws: notFound) { try await harness.core.resume(selector, consent: .none) }
        await #expect(throws: notFound) { try await harness.core.restart(selector, timeout: nil, consent: .none) }
        #expect(throws: notFound) { try harness.core.rename(selector, to: "Late") }
        await #expect(throws: notFound) {
            try await harness.core.delete(selector, permanently: false, alsoRemoving: [], consent: .all)
        }
        #expect(virtualization.startCallCount == 0)
        #expect(virtualization.saveCallCount == 0)
        #expect(virtualization.revertedSnapshots.isEmpty)
        #expect(virtualization.takenSnapshots.isEmpty)
    }

    @Test("R10: a restart whose power-off wait a delete interrupts ends refused as removed, reporting nothing")
    func restartInterruptedByADeleteEndsRefused() async throws {
        let virtualization = MockVirtualizationService()
        // The guest takes its time, so the restart is parked on the power-off
        // when the guest does go down.
        virtualization.guestIgnoresShutdownRequest = true
        let clock = GatedEngineClock()
        let harness = makeHarness(virtualization: virtualization, clock: clock)
        let session = UUID()
        let instance = makeInstance(in: harness, name: "Doomed", phase: .running(sessionID: session))
        let deletion = StartedDeletion()

        // The delete is admitted in the very step the power-off rests the VM —
        // entered synchronously from the hook, so no other request, the
        // restart's own boot included, can be decided in between.
        let core = harness.core
        let poweredOff = instance.activity.onPoweredOff
        instance.activity.onPoweredOff = {
            let owed = poweredOff?() ?? []
            deletion.task = Task.immediate { @MainActor in
                try await core.delete(
                    .id(instance.id), permanently: false, alsoRemoving: [], consent: .all)
            }
            return owed
        }

        let restart = Task { @MainActor in
            try await harness.core.restart(.id(instance.id), timeout: 60, consent: .none)
        }
        // The parked sleep is the power-off deadline: the restart is waiting.
        try await clock.sleepRequested.wait { !clock.parked.isEmpty }
        #expect(virtualization.stopCallCount == 1)

        instance.activity.deliverSessionEvent(.guestDidStop, from: session)
        #expect(instance.activity.decide(.start(recovery: false), posture: .commit) != .admit)
        try await deletion.task?.value
        #expect(instance.phase == .removed)

        let error = try await #require(throws: CommandError.self) { try await restart.value }
        #expect(error == .notFound(.id(instance.id)))
        #expect(virtualization.startCallCount == 0)
        #expect(harness.failures.isEmpty)
    }

    // MARK: - R11: a revert holds the VM from its admission

    @Test("R11: right after a revert is started, Start and Resume are refused and neither is offered")
    func startAndResumeRefusedRightAfterARevertStarts() async throws {
        // One VM Start is offered to and one Resume is offered to, so each
        // refusal below is a change from what the VM at rest offered.
        for resting in [VMLifecyclePhase.stopped, .suspended] {
            let virtualization = SuspendingMockVirtualizationService()
            virtualization.shouldSuspendBeforePlanning = true
            virtualization.shouldSuspendOnStart = false
            let harness = makeHarness(virtualization: virtualization)
            let snapshot = VMSnapshot(name: "Clean install", macAddress: nil)
            let instance = makeInstance(in: harness, phase: resting, snapshots: [snapshot])
            if resting == .suspended { try VMInstanceFixture.writeSaveFile(for: instance) }
            let capabilities = harness.library.capabilities
            let offered: VMCapability = resting == .suspended ? .resume : .start
            #expect(capabilities.isAvailable(offered, on: instance), "\(resting)")

            let outcome = try harness.core.startRevert(instance, to: snapshot)

            // Not a turn later: the revert's task has not begun planning. Start
            // and Resume both commit a bring-up here, so both are busy for a
            // VM holding a slot; a stopped one has nothing to resume at all.
            let busy = VMAdmission.Decision.refuse(
                .busy(.bringUp(.reverting(snapshotID: snapshot.id, resumesAfter: false))))
            #expect(instance.activity.decide(.start(recovery: false), posture: .commit) == busy, "\(resting)")
            let resume: VMAdmission.Decision = resting == .suspended ? busy : .refuse(.invalidState)
            #expect(instance.activity.decide(.resume, posture: .commit) == resume, "\(resting)")
            #expect(!capabilities.isAvailable(.start, on: instance), "\(resting)")
            #expect(!capabilities.isAvailable(.resume, on: instance), "\(resting)")

            await virtualization.waitUntilSuspended()
            #expect(harness.machineFiles.events.isEmpty)
            #expect(
                try await #require(throws: CommandError.self) {
                    try await harness.core.start(.id(instance.id), recovery: false, consent: .none)
                }.isBusy)
            let resumed = try await #require(throws: CommandError.self) {
                try await harness.core.resume(.id(instance.id), consent: .none)
            }
            #expect(resumed.isBusy == (resting == .suspended), "\(resting)")
            #expect(virtualization.startCallCount == 0)

            virtualization.resumeSuspended()
            try await outcome.value()
            #expect(!instance.isHeldByRevert)
        }
    }

    // MARK: - Identity held by a bring-up

    @Test("Twin clones started back to back: the second is refused by the first's bring-up in flight")
    func twinStartRefusedByTheFirstsBringUp() async throws {
        let virtualization = SuspendingMockVirtualizationService()
        let harness = makeHarness(virtualization: virtualization)
        let machineID = Data([1, 2, 3])
        let original = makeInstance(in: harness, name: "Original", guestOS: .macOS) {
            $0.machineIdentifierData = machineID
        }
        let clone = makeInstance(in: harness, name: "Clone", guestOS: .macOS) {
            $0.machineIdentifierData = machineID
        }

        let boot = Task { @MainActor in
            try await harness.core.start(.id(original.id), recovery: false, consent: .none)
        }
        await virtualization.waitUntilSuspended()
        // A second boot wrongly admitted runs through rather than parking
        // beside the first.
        virtualization.shouldSuspendOnStart = false
        // Nothing live yet: the identity is held by the bring-up itself.
        #expect(!original.hasLiveVirtualMachine)
        #expect(original.status == .starting)

        let refused = try await #require(throws: CommandError.self) {
            try await harness.core.start(.id(clone.id), recovery: false, consent: .none)
        }
        guard case .conflict(let vm, let other, _) = refused else {
            Issue.record("Expected an identity conflict, got \(refused)")
            return
        }
        #expect(vm.id == clone.id)
        #expect(other.id == original.id)
        #expect(virtualization.startCallCount == 1)
        #expect(clone.status == .stopped)

        virtualization.resumeSuspended()
        try await boot.value
        #expect(original.status == .running)
    }
}

/// The delete a hook started.
@MainActor
private final class StartedDeletion {
    var task: Task<Void, any Error>?
}
