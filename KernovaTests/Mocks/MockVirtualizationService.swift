import Foundation
import KernovaKit
@testable import Kernova

/// Mock for `VirtualizationProviding` whose bodies end the way the real
/// service's do, without real VZ operations.
///
/// A live phase needs a session identity a CI host cannot mint a real
/// `VZVirtualMachine` for, so each bring-up that comes up live binds a fresh
/// one through ``VMBringUpContext/bindSessionForTesting(_:)``.
@MainActor
final class MockVirtualizationService: VirtualizationProviding {
    // MARK: - Call Tracking

    var startCallCount = 0
    var stopCallCount = 0
    var forceStopCallCount = 0
    var pauseCallCount = 0
    var resumeCallCount = 0
    var saveCallCount = 0

    /// Whether the most recent `start` ran a Recovery boot.
    var lastStartBootIntoRecovery = false
    /// The account the last `start` was handed, so a test can read what the
    /// boot would have carried into VZ.
    private(set) var lastStartProvisioning: GuestProvisioningCredentials?

    /// The route `start` answers with, in place of the one its bring-up
    /// implies — for a test that wants a route without arranging the state that
    /// produces it (a save file on disk, above all).
    var startRoute: GuestStartRoute?

    /// What the last `start` answered, derived or overridden.
    private(set) var lastStartRoute: GuestStartRoute?

    /// The configuration as it stood when `start` was called, so a caller that
    /// must persist a change *before* the VZ configuration is built can be
    /// asserted on ordering, not just on the final value.
    var configurationAtStart: VMConfiguration?

    /// The status the bring-up running `start` was admitted from — what a
    /// caller that hands a VM off to a boot handed over.
    var statusAtStart: VMStatus?

    /// Whether the guest ignores the ACPI shutdown `requestStop` sends, as a
    /// macOS guest resting at its login screen does: the request is delivered
    /// and the VM keeps running.
    var guestIgnoresShutdownRequest = false

    // MARK: - Error Injection & Recovery

    var startError: (any Error)?
    /// Thrown by a `start` that restores a saved state, ahead of
    /// ``startError`` — so one VM's restore can fail while another boots.
    var restoreError: (any Error)?
    var stopError: (any Error)?
    var forceStopError: (any Error)?
    var pauseError: (any Error)?
    /// Thrown by a hot resume, and by the restore a live warm revert ends in.
    var resumeError: (any Error)?
    var saveError: (any Error)?
    var takeSnapshotError: (any Error)?

    /// Runs once the capture operation holds the VM, so a test can reproduce
    /// what the real capture does to the instance while it runs.
    var onTakeSnapshot: (@MainActor () -> Void)?
    var revertToSnapshotError: (any Error)?

    // MARK: - Snapshot call tracking

    /// Snapshots passed to `takeSnapshot`, in call order.
    private(set) var takenSnapshots: [VMSnapshotRecord] = []
    /// Snapshots passed to `revertToSnapshot`, in call order.
    private(set) var revertedSnapshots: [VMSnapshot] = []

    // MARK: - VirtualizationProviding

    func start(
        _ instance: VMInstance, _ context: borrowing VMGuestStartContext,
        provisioning: GuestProvisioningCredentials?
    ) async throws -> VMOperationEnding<GuestStartRoute> {
        startCallCount += 1
        let derived = GuestStartRoute(context.kind)
        lastStartBootIntoRecovery = derived == .recoveryBoot
        lastStartProvisioning = provisioning
        configurationAtStart = instance.configuration
        statusAtStart = instance.phase.operation?.startedFrom.status
        let route = startRoute ?? derived
        lastStartRoute = route
        if derived == .restoredSavedState, let error = restoreError { throw error }
        if let error = startError { throw error }
        // A restore consumes the slot it loaded, as the real one does.
        if route == .restoredSavedState { context.bringUp.operation.bundle.removeSaveFile() }
        context.bringUp.bindSessionForTesting(UUID())
        return .rest(.live(.running), route)
    }

    /// Delivers the ACPI request; a guest that honors it powers off, which
    /// reaches the VM as the session event the real guest raises.
    func requestStop(_ instance: VMInstance) async throws {
        stopCallCount += 1
        if let error = stopError { throw error }
        guard !guestIgnoresShutdownRequest, let sessionID = instance.liveSessionID else { return }
        instance.activity.deliverSessionEvent(.guestDidStop, from: sessionID)
    }

    func forceStop(_ instance: VMInstance) async throws {
        forceStopCallCount += 1
        if let error = forceStopError { throw error }
    }

    func pause(
        _ instance: VMInstance, _ context: borrowing VMOperationContext
    ) async throws -> VMOperationEnding<Void> {
        pauseCallCount += 1
        if let error = pauseError { throw error }
        instance.cancelAgentPostStartWatchdog()
        return .rest(.live(.paused), ())
    }

    func resume(
        _ instance: VMInstance, _ context: borrowing VMOperationContext
    ) async throws -> VMOperationEnding<Void> {
        resumeCallCount += 1
        if let error = resumeError { throw error }
        context.bundle.removeSaveFile()
        return .rest(.live(.running), ())
    }

    func save(
        _ instance: VMInstance, _ context: borrowing VMOperationContext
    ) async throws -> VMOperationEnding<Void> {
        saveCallCount += 1
        if let error = saveError {
            // A write that threw left a truncated slot, which the real service
            // drops before it rests the VM.
            context.bundle.removeSaveFile()
            let rest: VMOperationRest =
                context.sessionEnd == nil
                ? .atRest(.failed(message: error.localizedDescription)) : .afterSessionEnd
            return .failed(rest, error)
        }
        // The suspend slot is what makes the VM resumable, so the mock writes a
        // real one: every predicate a suspended VM is judged by reads the file.
        try VMInstanceFixture.writeSaveFile(for: instance)
        context.endSession()
        return .rest(.atRest(.stopped), ())
    }

    /// Captures in the mode the capture operation was admitted in, and leaves
    /// the VM where it was found.
    func takeSnapshot(
        _ instance: VMInstance, _ context: borrowing VMCaptureContext,
        snapshot request: VMSnapshotCaptureRequest
    ) async throws -> VMOperationEnding<VMSnapshot> {
        let mode = context.mode
        let snapshot = request.record(capturedIn: mode)
        // Stands in for what a real warm capture does to the VM mid-flight —
        // notably taking every passthrough accessory off before it writes the
        // guest's state.
        onTakeSnapshot?()
        if let error = takeSnapshotError {
            guard mode == .live else { throw error }
            return .failed(.asStarted, error)
        }
        // The bundle is exercised for real so a test can assert on the files
        // the capture writes; the VZ saved state has no stand-in, so only the
        // disk copies land.
        let configuration = instance.configuration
        if let prepared = try? await context.operation.bundle.prepareSnapshot(
            snapshot.id, configuration: configuration)
        {
            try? await context.operation.bundle.captureDisks(
                intoSnapshot: snapshot.id, relativePaths: prepared.relativePaths)
        }
        takenSnapshots.append(snapshot)
        return .rest(.asStarted, VMSnapshot(snapshot, macAddress: configuration.macAddress))
    }

    /// Mirrors the real service: the pre-flight runs before anything is torn
    /// down, the live session is then discarded, and the VM lands in the state
    /// the snapshot captured — suspended on a warm snapshot's saved state and
    /// settings, stopped on a cold snapshot's disks, or live again on a warm
    /// one when the revert resumes after.
    func revertToSnapshot(
        _ instance: VMInstance, _ context: borrowing VMRevertContext,
        commitConfiguration: @MainActor (borrowing VMEditPermit, VMSnapshotRestorePlan) throws -> Void
    ) async throws -> VMOperationEnding<Void> {
        let snapshot = context.snapshot
        let plan: VMSnapshotRestorePlan
        do {
            plan = try await context.bringUp.operation.bundle.planRestore(
                fromSnapshot: snapshot.id, kind: snapshot.kind)
        } catch {
            return .failed(.asStarted, error)
        }
        context.bringUp.operation.endSession()
        if let error = revertToSnapshotError { return .failed(.atRest(.stopped), error) }
        // Staged, committed, installed, in the real service's order.
        do {
            try await context.bringUp.operation.bundle.stageRestore(fromSnapshot: snapshot.id, plan: plan)
            do {
                try commitConfiguration(context.bringUp.operation.permit, plan)
            } catch {
                await context.bringUp.operation.bundle.discardRestoreStaging()
                throw error
            }
            try await context.bringUp.operation.bundle.installRestore(plan)
        } catch {
            return .failed(.atRest(.stopped), error)
        }
        revertedSnapshots.append(snapshot)
        // A warm snapshot's own saved state is what the VM comes back on, and a
        // cold one leaves the bundle without a slot. The machine-files mock
        // copies no files, so the slot every predicate reads is written here.
        if plan.kind == .warm {
            try VMInstanceFixture.writeSaveFile(for: instance)
        } else {
            context.bringUp.operation.bundle.removeSaveFile()
        }
        guard context.resumesAfter, plan.kind == .warm else { return .rest(.atRest(.stopped), ()) }
        // The restore of that saved state, inside the same operation.
        if let error = resumeError {
            return .failed(
                .atRest(.stopped), VirtualizationError.revertResumeFailed(underlying: error))
        }
        context.bringUp.operation.bundle.removeSaveFile()
        context.bringUp.bindSessionForTesting(UUID())
        return .rest(.live(.running), ())
    }
}
