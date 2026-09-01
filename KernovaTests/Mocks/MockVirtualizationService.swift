import Foundation
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

    // MARK: - Error Injection & Recovery

    var startError: (any Error)?
    var stopError: (any Error)?
    var forceStopError: (any Error)?
    var pauseError: (any Error)?
    var resumeError: (any Error)?
    var saveError: (any Error)?
    var takeSnapshotError: (any Error)?
    var revertToSnapshotError: (any Error)?

    // MARK: - Snapshot call tracking

    /// Snapshots passed to `takeSnapshot`, in call order.
    private(set) var takenSnapshots: [VMSnapshot] = []
    /// Snapshots passed to `revertToSnapshot`, in call order.
    private(set) var revertedSnapshots: [VMSnapshot] = []

    // MARK: - VirtualizationProviding

    func start(_ instance: VMInstance, bootIntoRecovery: Bool = false) async throws {
        startCallCount += 1
        lastStartBootIntoRecovery = bootIntoRecovery
        configurationAtStart = instance.configuration
        statusAtStart = instance.status
        if let error = startError {
            instance.tearDownSession(
                restingAt: VirtualizationService.restingPhaseAfterLifecycleFailure(
                    error, on: instance, transientRestingPhase: .stopped))
            throw error
        }
        instance.enter(.running(sessionID: MockVirtualizationPhases.sessionIdentity(for: instance)))
    }

    func stop(_ instance: VMInstance) async throws {
        stopCallCount += 1
        if let error = stopError { throw error }
        instance.resetToStopped()
    }

    func forceStop(_ instance: VMInstance) async throws {
        forceStopCallCount += 1
        if let error = forceStopError { throw error }
        instance.resetToStopped()
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
        instance.enter(.running(sessionID: MockVirtualizationPhases.sessionIdentity(for: instance)))
    }

    func save(_ instance: VMInstance) async throws {
        saveCallCount += 1
        // The real service marks the VM `.saving` before tearing the session
        // down, so the teardown hook fires from a phase that reads as
        // transitioning.
        instance.enter(.saving(sessionID: MockVirtualizationPhases.sessionIdentity(for: instance)))
        if let error = saveError {
            instance.tearDownSession(restingAt: .failed(message: error.localizedDescription))
            throw error
        }
        instance.tearDownSession(restingAt: .suspended)
    }

    /// Mirrors the real service's state machine without VZ: the VM passes
    /// through `.snapshotting` and comes back where it started — live back
    /// where it was found, suspended and stopped resting session-less where
    /// they started.
    func takeSnapshot(
        _ instance: VMInstance, snapshot: VMSnapshot, store: any VMSnapshotStoring
    ) async throws {
        let phases = try MockVirtualizationPhases.capturePhases(for: instance, kind: snapshot.kind)
        instance.enter(phases.capturing)
        if let error = takeSnapshotError {
            instance.enter(phases.resting)
            throw error
        }
        // The store is exercised for real so a test can assert on the files the
        // capture writes; the VZ saved state has no stand-in, so only the disk
        // copies land.
        if let prepared = try? store.prepareSnapshot(
            bundleURL: instance.bundleURL, snapshotID: snapshot.id,
            configuration: instance.configuration)
        {
            try? store.captureDisks(
                bundleURL: instance.bundleURL, snapshotID: snapshot.id,
                relativePaths: prepared.relativePaths)
        }
        takenSnapshots.append(snapshot)
        instance.enter(phases.resting)
    }

    /// Mirrors the real service: the pre-flight runs before anything is torn
    /// down, the live session is then discarded, and the VM lands in the state
    /// the snapshot captured — cold-paused on a warm snapshot's saved state and
    /// settings, stopped on a cold snapshot's disks.
    func revertToSnapshot(
        _ instance: VMInstance, snapshot: VMSnapshot, store: any VMSnapshotStoring
    ) async throws {
        let plan = try store.planRestore(
            bundleURL: instance.bundleURL, snapshotID: snapshot.id, kind: snapshot.kind)
        var restore = plan
        restore.configuration = instance.configuration.adoptingSnapshotState(plan.configuration)

        instance.tearDownSession(restingAt: .revertingToSnapshot)
        if let error = revertToSnapshotError {
            instance.enter(VirtualizationService.restingPhaseAfterRestoreFailure(on: instance))
            throw error
        }
        try store.restore(
            bundleURL: instance.bundleURL, snapshotID: snapshot.id, plan: restore)
        instance.configuration = restore.configuration
        revertedSnapshots.append(snapshot)
        instance.enter(plan.kind == .warm ? .suspended : .stopped)
    }
}
