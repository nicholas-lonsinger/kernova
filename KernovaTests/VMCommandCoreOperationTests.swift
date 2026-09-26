import Foundation
import KernovaKit
import KernovaTestSupport
import Testing

@testable import Kernova

/// What the one-operation-per-VM structure closes, driven through the command
/// core: a session action never releases the operation holding the VM, only
/// that operation's ending moves it back to rest, and a request landing
/// anywhere in between is decided against the operation that holds it.
@Suite("VMCommandCore Operation Tests", .serialized, .admissionGated)
@MainActor
struct VMCommandCoreOperationTests {
    private let preferences = makeTestPreferences()

    private struct Harness {
        let core: VMCommandCore
        let library: VMLibrary
        let lifecycle: VMLifecycleCoordinator
        let storage: MockVMStorageService
        let snapshots: MockVMBundleMachineFiles
    }

    private func makeHarness(
        virtualization: any VirtualizationProviding,
        usbAccessories: MockUSBAccessoryService? = nil,
        clock: any EngineClock = makePlatformEngineClock()
    ) -> Harness {
        let storage = MockVMStorageService()
        let snapshots = MockVMBundleMachineFiles(files: storage.files)
        let fileSystem = MockFileSystem()
        let lifecycle = makeTestLifecycle(
            virtualization: virtualization, usbAccessoryService: usbAccessories,
            fileSystem: fileSystem)
        let library = makeWiredLibrary(
            storage: storage, machineFiles: snapshots, lifecycle: lifecycle,
            fileSystem: fileSystem, preferences: preferences)
        let core = VMCommandCore(
            library: library, lifecycle: lifecycle, storageService: storage,
            diskImageService: MockDiskImageService(), fileSystem: fileSystem,
            preferences: preferences, clock: clock)
        return Harness(
            core: core, library: library, lifecycle: lifecycle, storage: storage,
            snapshots: snapshots)
    }

    @discardableResult
    private func makeInstance(
        in harness: Harness, name: String = "Core VM", phase: VMLifecyclePhase = .stopped,
        guestOS: VMGuestOS = .linux, snapshots: [VMSnapshot] = [],
        mutate: (inout VMConfiguration) -> Void = { _ in }
    ) -> VMInstance {
        let instance = RegisteredVMInstanceFixture.register(
            name: name, phase: phase, guestOS: guestOS, snapshots: snapshots,
            library: harness.library, storage: harness.storage, preferences: preferences,
            mutate: mutate)
        for snapshot in snapshots {
            harness.snapshots.setCapturedConfiguration(instance.configuration, for: snapshot.id)
        }
        return instance
    }

    private func commandError(_ body: () async throws -> Void) async -> CommandError? {
        do {
            try await body()
            return nil
        } catch let error as CommandError {
            return error
        } catch {
            Issue.record("Expected a command error, got \(error)")
            return nil
        }
    }

    private func commandError(_ body: () throws -> Void) -> CommandError? {
        do {
            try body()
            return nil
        } catch let error as CommandError {
            return error
        } catch {
            Issue.record("Expected a command error, got \(error)")
            return nil
        }
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
        instance.beginSessionContext()
        defer { VMInstanceFixture.removeBundle(of: instance) }
        accessories.accessories.append(MockUSBAccessoryService.accessory(registryID: 42, serial: "A1"))
        accessories.suspendNextAttach = true

        let attach = Task { @MainActor in
            try await harness.core.attachUSBAccessory(.id(instance.id), accessory: 42)
        }
        await accessories.attachStarted()
        let held = instance.phase
        #expect(held.operation?.kind == .attachingUSB(registryID: 42))

        try await harness.core.stop(.id(instance.id), disposition: .graceful, confirmed: false)
        #expect(virtualization.stopCallCount == 1)

        let refused = try #require(await commandError { try await harness.core.suspend(.id(instance.id)) })
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
        defer { VMInstanceFixture.removeBundle(of: instance) }

        let pause = Task { @MainActor in try await harness.core.pause(.id(instance.id)) }
        await virtualization.waitUntilSuspended()
        let held = instance.phase
        #expect(held.operation?.kind == .pausing)

        try await harness.core.stop(.id(instance.id), disposition: .graceful, confirmed: false)
        #expect(virtualization.requestStopCallCount == 1)

        let refused = try #require(await commandError { try await harness.core.suspend(.id(instance.id)) })
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
        defer { VMInstanceFixture.removeBundle(of: instance) }

        let revert = Task { @MainActor in
            try await harness.core.revertToSnapshot(
                .id(instance.id), snapshot: snapshot.id, takingCheckpoint: false, confirmed: true)
        }
        // Parked before the revert ends the session it holds: the stop window.
        await virtualization.waitUntilSuspended()
        #expect(instance.isHeldByRevert)
        #expect(instance.liveSessionID == session)

        let refused = try #require(
            await commandError {
                try await harness.core.stop(.id(instance.id), disposition: .force, confirmed: true)
            })
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
        #expect(harness.snapshots.events == [.stageRestore])
        let start = try #require(
            await commandError { try await harness.core.start(.id(instance.id), recovery: false) })
        #expect(start.isBusy)
        #expect(virtualization.startCallCount == 0)

        virtualization.resumeSuspended()
        try await revert.value
        #expect(harness.snapshots.events == [.stageRestore, .installRestore])
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
        defer { VMInstanceFixture.removeBundle(of: instance) }
        let sharing = instance.configuration.clipboardSharingEnabled

        let revert = Task { @MainActor in
            try await harness.core.revertToSnapshot(
                .id(instance.id), snapshot: snapshot.id, takingCheckpoint: false, confirmed: true)
        }
        await virtualization.waitUntilSuspended()
        #expect(instance.isHeldByRevert)

        #expect(!harness.library.capabilities.accepts(.rename, on: instance))
        #expect(!harness.library.capabilities.accepts(.editLiveConfiguration, on: instance))
        let rename = try #require(commandError { try harness.core.rename(.id(instance.id), to: "Renamed") })
        #expect(rename.isBusy)
        let edit = try #require(
            commandError {
                try harness.core.setConfiguration(
                    .id(instance.id),
                    assignments: [ConfigurationEntry(key: "clipboard.sharing", value: String(!sharing))],
                    confirmed: true)
            })
        #expect(edit.isBusy)
        #expect(instance.name == "Reverting")
        #expect(instance.configuration.clipboardSharingEnabled == sharing)

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
            .id(instance.id), permanently: false, alsoRemoving: [], confirmed: true)
        #expect(instance.phase == .removed)

        let capabilities = harness.library.capabilities
        for capability in VMCapability.allCases {
            #expect(!capabilities.accepts(capability, on: instance), "\(capability)")
            #expect(!capabilities.isApplicable(capability, to: instance), "\(capability)")
        }

        // The verbs a surface holding the instance itself reaches, past the
        // library lookup a selector would already fail.
        let notFound = CommandError.notFound(.id(instance.id))
        #expect(await commandError { try await harness.core.start(instance) } == notFound)
        #expect(
            await commandError {
                try await harness.core.stop(instance, disposition: .graceful, confirmed: true)
            } == notFound)
        #expect(
            await commandError {
                try await harness.core.stop(instance, disposition: .force, confirmed: true)
            } == notFound)
        #expect(await commandError { try await harness.core.suspend(instance) } == notFound)
        // No capture mode is left to name a request for, so this one refuses
        // with the state rather than the removal — refused all the same.
        #expect(
            await commandError { _ = try await harness.core.takeSnapshot(instance, name: "Late", notes: "") }
                != nil)
        #expect(commandError { _ = try harness.core.startRevert(instance, to: snapshot) } == notFound)
        await #expect(throws: VMAdmissionRefusal(refusal: .removed)) {
            try await harness.lifecycle.pause(instance)
        }

        // And every selector verb, which no longer finds it.
        let selector = VMSelector.id(instance.id)
        #expect(await commandError { try await harness.core.resume(selector) } == notFound)
        #expect(await commandError { try await harness.core.restart(selector, timeout: nil) } == notFound)
        #expect(commandError { try harness.core.rename(selector, to: "Late") } == notFound)
        #expect(
            await commandError {
                try await harness.core.delete(selector, permanently: false, alsoRemoving: [], confirmed: true)
            } == notFound)
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
        let reported = FailureRecorder()
        harness.core.onFailure = { failure, _ in reported.failures.append(failure) }

        // The delete is admitted in the very step the power-off rests the VM —
        // entered synchronously from the hook, so no other request, the
        // restart's own boot included, can be decided in between.
        let core = harness.core
        let poweredOff = instance.activity.onPoweredOff
        instance.activity.onPoweredOff = {
            poweredOff?()
            reported.deletion = Task.immediate { @MainActor in
                try await core.delete(
                    .id(instance.id), permanently: false, alsoRemoving: [], confirmed: true)
            }
        }

        let restart = Task { @MainActor in
            try await harness.core.restart(.id(instance.id), timeout: 60)
        }
        // The parked sleep is the power-off deadline: the restart is waiting.
        try await clock.sleepRequested.wait { !clock.parked.isEmpty }
        #expect(virtualization.stopCallCount == 1)

        instance.activity.deliverSessionEvent(.guestDidStop, from: session)
        #expect(instance.activity.decide(.start(recovery: false), posture: .commit) != .admit)
        try await reported.deletion?.value
        #expect(instance.phase == .removed)

        let error = await commandError { try await restart.value }
        #expect(error == .notFound(.id(instance.id)))
        #expect(virtualization.startCallCount == 0)
        #expect(reported.failures.isEmpty)
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
            defer { VMInstanceFixture.removeBundle(of: instance) }
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
            #expect(harness.snapshots.events.isEmpty)
            #expect(await commandError { try await harness.core.start(instance) }?.isBusy == true)
            let resumed = await commandError { try await harness.core.resume(.id(instance.id)) }
            #expect(resumed?.isBusy == (resting == .suspended), "\(resting)")
            #expect(resumed != nil, "\(resting)")
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
            try await harness.core.start(.id(original.id), recovery: false)
        }
        await virtualization.waitUntilSuspended()
        // A second boot wrongly admitted runs through rather than parking
        // beside the first.
        virtualization.shouldSuspendOnStart = false
        // Nothing live yet: the identity is held by the bring-up itself.
        #expect(!original.hasLiveVirtualMachine)
        #expect(original.status == .starting)

        let refused = try #require(
            await commandError { try await harness.core.start(.id(clone.id), recovery: false) })
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

/// What a command core reported with nobody waiting, and the delete a hook
/// started.
@MainActor
private final class FailureRecorder {
    var failures: [CommandError] = []
    var deletion: Task<Void, any Error>?
}
