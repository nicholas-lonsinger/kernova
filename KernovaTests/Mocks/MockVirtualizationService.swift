import Foundation
import KernovaKit
@testable import Kernova

/// Mock for `VirtualizationProviding` that moves a VM's lifecycle phase without
/// real VZ operations.
///
/// A live phase needs a session identity a CI host cannot mint a real
/// `VZVirtualMachine` for, so each bring-up synthesizes one and every later
/// phase reuses whatever the instance is already holding.
@MainActor
final class MockVirtualizationService: VirtualizationProviding {
    // MARK: - Call Tracking

    var startCallCount = 0
    var stopCallCount = 0
    var forceStopCallCount = 0
    var pauseCallCount = 0
    var resumeCallCount = 0
    var saveCallCount = 0

    /// The `bootIntoRecovery` argument from the most recent `start` call.
    var lastStartBootIntoRecovery = false
    /// The account the last `start` was handed, so a test can read what the
    /// boot would have carried into VZ.
    private(set) var lastStartProvisioning: GuestProvisioningCredentials?

    /// The route `start` answers with, in place of the one the VM's own state
    /// implies — for a test that wants a route without arranging the state that
    /// produces it (a save file on disk, above all).
    var startRoute: GuestStartRoute?

    /// What the last `start` answered, derived or overridden.
    private(set) var lastStartRoute: GuestStartRoute?

    /// The configuration as it stood when `start` was called, so a caller that
    /// must persist a change *before* the VZ configuration is built can be
    /// asserted on ordering, not just on the final value.
    var configurationAtStart: VMConfiguration?

    /// The status the VM was in when `start` was called.
    ///
    /// The real service refuses a start from a phase that fails
    /// ``VMLifecyclePhase/canStart``; recording it is what lets a caller that
    /// hands a VM off to a boot be asserted on the state it hands over.
    var statusAtStart: VMStatus?

    /// Whether the guest ignores the ACPI shutdown `stop` sends, as a macOS
    /// guest resting at its login screen does: the request is delivered and the
    /// VM keeps running.
    var guestIgnoresShutdownRequest = false

    // MARK: - Error Injection & Recovery

    var startError: (any Error)?
    var stopError: (any Error)?
    var forceStopError: (any Error)?
    var pauseError: (any Error)?
    var resumeError: (any Error)?
    var saveError: (any Error)?
    var takeSnapshotError: (any Error)?

    /// Runs once the capture has entered its capturing phase, so a test can
    /// reproduce what the real capture does to the instance while it runs.
    var onTakeSnapshot: (@MainActor () -> Void)?
    var revertToSnapshotError: (any Error)?

    // MARK: - Snapshot call tracking

    /// Snapshots passed to `takeSnapshot`, in call order.
    private(set) var takenSnapshots: [VMSnapshot] = []
    /// Snapshots passed to `revertToSnapshot`, in call order.
    private(set) var revertedSnapshots: [VMSnapshot] = []

    // MARK: - VirtualizationProviding

    func start(
        _ instance: VMInstance, bootIntoRecovery: Bool = false,
        provisioning: GuestProvisioningCredentials? = nil
    ) async throws -> GuestStartRoute {
        startCallCount += 1
        lastStartBootIntoRecovery = bootIntoRecovery
        lastStartProvisioning = provisioning
        configurationAtStart = instance.configuration
        statusAtStart = instance.status
        let route =
            startRoute ?? GuestStartRoute(startOf: instance, bootIntoRecovery: bootIntoRecovery)
        lastStartRoute = route
        if let error = startError {
            instance.tearDownSession(
                restingAt: VirtualizationService.restingPhaseAfterLifecycleFailure(
                    error, on: instance, transientRestingPhase: .stopped))
            throw error
        }
        // A restore consumes the slot it loaded, as the real one does.
        if route == .restoredSavedState { instance.removeSaveFile() }
        instance.enter(.running(sessionID: MockVirtualizationPhases.sessionIdentity(for: instance)))
        return route
    }

    func stop(_ instance: VMInstance) async throws {
        stopCallCount += 1
        if let error = stopError { throw error }
        // No guest to ask: the stop discards the saved state instead.
        if instance.holdsSuspendedSession {
            instance.discardSavedState()
            return
        }
        guard !guestIgnoresShutdownRequest else { return }
        instance.restAfterPowerOff()
    }

    func forceStop(_ instance: VMInstance) async throws {
        forceStopCallCount += 1
        if let error = forceStopError { throw error }
        if instance.holdsSuspendedSession {
            instance.discardSavedState()
            return
        }
        // The real service's gate, mirrored: VZ takes a termination only from
        // the phases `canForceStop` admits, so a test driving a VM through this
        // from any other one must not read as a success.
        guard instance.canForceStop else {
            throw VirtualizationError.invalidStateTransition(
                from: instance.status, action: "force stop")
        }
        instance.restAfterPowerOff()
    }

    func pause(_ instance: VMInstance) async throws {
        pauseCallCount += 1
        // A failed pause leaves the phase alone, as the real service does: the
        // pause did not take, so the VM is where it was and still holds its
        // session.
        if let error = pauseError { throw error }
        instance.enter(.livePaused(sessionID: MockVirtualizationPhases.sessionIdentity(for: instance)))
    }

    func resume(_ instance: VMInstance) async throws {
        resumeCallCount += 1
        if let error = resumeError {
            instance.tearDownSession(
                restingAt: VirtualizationService.restingPhaseAfterLifecycleFailure(
                    error, on: instance, transientRestingPhase: nil))
            throw error
        }
        // A cold resume consumes the slot it restored; a hot one drops the file
        // its pause left behind. Either way the guest is live again.
        instance.removeSaveFile()
        instance.enter(.running(sessionID: MockVirtualizationPhases.sessionIdentity(for: instance)))
    }

    func save(_ instance: VMInstance) async throws {
        saveCallCount += 1
        // The real service marks the VM `.saving` before tearing the session
        // down, so the teardown hook fires from a phase that reads as
        // transitioning.
        instance.enter(.saving(sessionID: MockVirtualizationPhases.sessionIdentity(for: instance)))
        if let error = saveError {
            // A write that threw left a truncated slot, which the real service
            // drops before it rests the VM.
            instance.dropTruncatedSaveFile()
            instance.tearDownSession(restingAt: .failed(message: error.localizedDescription))
            throw error
        }
        // The suspend slot is what makes the VM resumable, so the mock writes a
        // real one: every predicate a suspended VM is judged by reads the file.
        try VMInstanceFixture.writeSaveFile(for: instance)
        instance.tearDownSession(restingAt: .suspended)
    }

    /// Mirrors the real service's state machine without VZ: the VM passes
    /// through `.snapshotting` and comes back where it started — live back
    /// where it was found, suspended and stopped resting session-less where
    /// they started.
    func takeSnapshot(
        _ instance: VMInstance, snapshot: VMSnapshot, store: any VMSnapshotStoring
    ) async throws -> VMSnapshot {
        let phases = try MockVirtualizationPhases.capturePhases(for: instance, kind: snapshot.kind)
        instance.enter(phases.capturing)
        // Stands in for what a real warm capture does to the VM mid-flight —
        // notably taking every passthrough accessory off before it writes the
        // guest's state.
        onTakeSnapshot?()
        if let error = takeSnapshotError {
            instance.enter(phases.resting)
            throw error
        }
        // The store is exercised for real so a test can assert on the files the
        // capture writes; the VZ saved state has no stand-in, so only the disk
        // copies land.
        let configuration = instance.configuration
        if let prepared = try? store.prepareSnapshot(
            bundleURL: instance.bundleURL, snapshotID: snapshot.id,
            configuration: configuration)
        {
            try? store.captureDisks(
                bundleURL: instance.bundleURL, snapshotID: snapshot.id,
                relativePaths: prepared.relativePaths)
        }
        takenSnapshots.append(snapshot)
        instance.enter(phases.resting)
        return snapshot.captured(under: configuration)
    }

    /// Mirrors the real service: the pre-flight runs before anything is torn
    /// down, the live session is then discarded, and the VM lands in the state
    /// the snapshot captured — cold-paused on a warm snapshot's saved state and
    /// settings, stopped on a cold snapshot's disks.
    func revertToSnapshot(
        _ instance: VMInstance, snapshot: VMSnapshot, store: any VMSnapshotStoring,
        adopt: @MainActor (VMSnapshotRestorePlan) -> Void
    ) async throws {
        let plan = try store.planRestore(
            bundleURL: instance.bundleURL, snapshotID: snapshot.id, kind: snapshot.kind)
        var restore = plan
        restore.configuration = instance.configuration.adoptingSnapshotState(plan.configuration)

        instance.tearDownSession(restingAt: .revertingToSnapshot)
        if let error = revertToSnapshotError {
            instance.enter(instance.restingPhase(withoutSlot: .stopped))
            throw error
        }
        try store.restore(
            bundleURL: instance.bundleURL, snapshotID: snapshot.id, plan: restore)
        adopt(restore)
        revertedSnapshots.append(snapshot)
        // A warm snapshot's own saved state is what the VM comes back on, and a
        // cold one leaves the bundle without a slot. The store mock copies no
        // files, so the slot every predicate reads is written here.
        if plan.kind == .warm {
            try VMInstanceFixture.writeSaveFile(for: instance)
        } else {
            instance.removeSaveFile()
        }
        instance.enter(plan.kind == .warm ? .suspended : .stopped)
    }
}
