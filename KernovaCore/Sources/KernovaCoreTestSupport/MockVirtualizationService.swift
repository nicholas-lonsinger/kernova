import Foundation
import KernovaCommandModel

#if SWIFT_PACKAGE
import KernovaTestSupport
#endif

@testable import KernovaCore

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
    /// Fires as each shutdown request arrives, after ``stopCallCount`` rises
    /// — the moment a stop or restart starts waiting on the power-off, which
    /// changes no state a test can observe.
    let stopRequested = AsyncGate()
    var forceStopCallCount = 0
    var pauseCallCount = 0
    var resumeCallCount = 0
    var saveCallCount = 0

    /// Whether the most recent `start` ran a Recovery boot.
    var lastStartBootIntoRecovery = false

    /// What the last `start` answered.
    private(set) var lastStartRoute: GuestStartRoute?

    /// The configuration as it stood when `start` was called, so a caller that
    /// must persist a change *before* the VZ configuration is built can be
    /// asserted on ordering, not just on the final value.
    var configurationAtStart: VMConfiguration?

    /// The host state as it stood when the guest last began executing — what
    /// a bring-up commits before the guest can write anything.
    private(set) var hostStateAtStart: VMHostState?

    /// Whether the guest ignores the ACPI shutdown `requestStop` sends, as a
    /// macOS guest resting at its login screen does: the request is delivered
    /// and the VM keeps running.
    var guestIgnoresShutdownRequest = false

    // MARK: - Error Injection & Recovery

    var startError: (any Error)?
    /// Thrown by a `start` that restores a saved state, ahead of
    /// ``startError`` — so one VM's restore can fail while another boots.
    var restoreError: (any Error)?
    /// Whether a sent stop completes; off, it stays in flight — as when the
    /// VM process doesn't answer — until a test delivers its end.
    var forceStopCompletes = true
    /// Parks a start once its session is bound and before the guest is up, so
    /// a test can act while the bring-up still holds the VM.
    var startGate: GatedStep?
    var saveError: (any Error)?
    var takeSnapshotError: (any Error)?
    var revertToSnapshotError: (any Error)?

    // MARK: - Snapshot call tracking

    /// Snapshots passed to `takeSnapshot`, in call order.
    private(set) var takenSnapshots: [VMSnapshotRecord] = []
    /// The session a live clone's copy drives: the real capture body runs
    /// over it. `nil` drives a fresh one, found as the clone found the guest,
    /// that writes a stand-in saved state.
    var liveCopySession: MockSnapshotSession?

    /// Snapshots passed to `revertToSnapshot`, in call order.
    private(set) var revertedSnapshots: [VMSnapshot] = []
    /// How many reverts reached the mock, failed ones included.
    private(set) var revertCallCount = 0

    // MARK: - VirtualizationProviding

    func start(
        _ instance: VMInstance, _ context: borrowing VMGuestStartContext,
        provisioning: GuestProvisioningCredentials?
    ) async throws -> VMOperationEnding<GuestStartRoute> {
        startCallCount += 1
        let route = GuestStartRoute(context.kind)
        lastStartBootIntoRecovery = route == .recoveryBoot
        configurationAtStart = instance.configuration
        lastStartRoute = route
        // A restore reads the slot before anything is marked, as the real one
        // does, so a restore that fails leaves the marker as it found it.
        if route == .restoredSavedState, let error = restoreError { throw error }
        // The boot's start, or the restored session's resume: the call VZ
        // fails, or the one the guest first executes in.
        try await context.bringUp.operation.executingGuest { _ in
            if let error = startError { throw error }
            hostStateAtStart = instance.hostState
            context.bringUp.bindSessionForTesting(UUID())
            try await startGate?.pass()
        }
        return .rest(.live(.running), route)
    }

    /// Delivers the ACPI request; a guest that honors it powers off, which
    /// reaches the VM as the session event the real guest raises.
    func requestStop(_ instance: VMInstance) async throws {
        stopCallCount += 1
        stopRequested.notify()
        guard !guestIgnoresShutdownRequest, let sessionID = instance.liveSessionID else { return }
        instance.activity.deliverSessionEvent(.guestDidStop, from: sessionID)
    }

    /// Sends the stop; unless ``forceStopCompletes`` is off, it completes at
    /// once, as the session event the real stop's completion raises.
    func forceStop(_ instance: VMInstance) throws {
        forceStopCallCount += 1
        guard forceStopCompletes, let sessionID = instance.liveSessionID else { return }
        instance.activity.deliverSessionEvent(.stopDidComplete, from: sessionID)
    }

    func pause(
        _ instance: VMInstance, _ context: borrowing VMOperationContext
    ) async throws -> VMOperationEnding<Void> {
        pauseCallCount += 1
        return .rest(.live(.paused), ())
    }

    func resume(
        _ instance: VMInstance, _ context: borrowing VMOperationContext
    ) async throws -> VMOperationEnding<Void> {
        resumeCallCount += 1
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
        guard context.sessionEnd == nil else {
            // As the real one does: the slot is however far the write got.
            context.bundle.removeSaveFile()
            return .rest(.afterSessionEnd, ())
        }
        context.parkedSession()
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
        return .rest(.asStarted, VMSnapshot(snapshot, capturedUnder: configuration))
    }

    /// Runs the real live-capture body over ``liveCopySession``.
    func copyLive(
        _ instance: VMInstance, _ context: borrowing VMCaptureContext,
        savingStateTo saveFileURL: URL,
        prepare: () async throws -> Void,
        copy: () async throws -> Void
    ) async throws -> VMOperationEnding<Void> {
        guard let sessionID = context.operation.sessionID else {
            throw VirtualizationError.noVirtualMachine
        }
        let foundPaused = instance.phase.operation?.startedFrom == .livePaused(sessionID: sessionID)
        let session =
            liveCopySession
            ?? MockSnapshotSession(guestState: foundPaused ? .paused : .running, writesStateFile: true)
        return await VMLiveStateCapture.captureWarm(
            instance, context, session: session, prepare: prepare,
            savingStateTo: { saveFileURL }, copy: copy)
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
        revertCallCount += 1
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
        // The restore of that saved state, inside the same operation, over
        // files that have landed — as the real one records them.
        context.bringUp.operation.filesLanded()
        do {
            try await context.bringUp.operation.executingGuest { _ in
                hostStateAtStart = instance.hostState
                context.bringUp.bindSessionForTesting(UUID())
            }
        } catch {
            return .failed(
                .atRest(.stopped), VirtualizationError.revertResumeFailed(underlying: error))
        }
        return .rest(.live(.running), ())
    }
}
