import Foundation
@testable import Kernova

/// A mock virtualization service whose `start` and `pause` methods suspend until
/// explicitly resumed.
///
/// Used to test operation serialization in `VMLifecycleCoordinator`.
///
/// - Important: Only **one** operation can be suspended at a time. The mock stores a
///   single `suspendedContinuation` slot; calling `suspendIfNeeded()` while another
///   operation is already suspended will trigger a precondition failure.
@MainActor
final class SuspendingMockVirtualizationService: VirtualizationProviding {
    /// When `true`, `start` will suspend.
    ///
    /// Set to `false` to allow subsequent calls through immediately.
    var shouldSuspendOnStart = true

    /// When `true`, `pause` will suspend.
    ///
    /// Set to `false` to allow subsequent calls through immediately.
    var shouldSuspendOnPause = true

    /// When `true`, `resume` will suspend while the VM stands in the phase a
    /// real resume of its kind stands in — `.restoringSavedState` for a cold
    /// one building its configuration, the live-paused phase it was called in
    /// for a hot one.
    ///
    /// Defaults to `false` so existing callers keep the immediate behavior.
    var shouldSuspendOnResume = false

    /// When `true`, `revertToSnapshot` will suspend before tearing the session
    /// down, standing in for the window a real revert spends copying files.
    ///
    /// Defaults to `false` so existing callers keep the immediate behavior.
    var shouldSuspendOnRevert = false

    /// Error `start` throws once it is let through, resting the VM the way the
    /// real service rests a failed start.
    var startError: (any Error)?

    /// Number of `start` calls, so a test can prove a second start joined the
    /// first rather than issuing its own.
    private(set) var startCallCount = 0
    /// The account the last `start` was handed.
    private(set) var lastStartProvisioning: GuestProvisioningCredentials?

    // MARK: - Suspension Mechanism

    /// Continuation that, when resumed, unblocks the suspended operation.
    private var suspendedContinuation: CheckedContinuation<Void, Never>?

    /// Continuation that signals the test that the mock has entered its suspended state.
    private var suspendedNotification: CheckedContinuation<Void, Never>?

    /// Waits until the mock is suspended inside an operation.
    ///
    /// This relies on `@MainActor` cooperative scheduling: the `Task { @MainActor in … }`
    /// that drives the coordinator will suspend at `withCheckedContinuation` inside
    /// `suspendIfNeeded()`, yielding back to the main actor run loop. That yield allows
    /// this method's own `withCheckedContinuation` to execute and observe the stored
    /// `suspendedContinuation`, confirming the mock has entered its suspended state.
    func waitUntilSuspended() async {
        // If already suspended, return immediately
        if suspendedContinuation != nil { return }

        await withCheckedContinuation { continuation in
            suspendedNotification = continuation
        }
    }

    /// Called by the test to let the suspended operation complete.
    func resumeSuspended() {
        suspendedContinuation?.resume()
        suspendedContinuation = nil
    }

    private func suspendIfNeeded() async {
        precondition(suspendedContinuation == nil, "Only one operation can be suspended at a time")
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            suspendedContinuation = continuation

            // Signal the test that we're now suspended
            suspendedNotification?.resume()
            suspendedNotification = nil
        }
    }

    // MARK: - VirtualizationProviding

    func start(
        _ instance: VMInstance, bootIntoRecovery: Bool = false,
        provisioning: GuestProvisioningCredentials? = nil
    ) async throws -> GuestStartRoute {
        startCallCount += 1
        lastStartProvisioning = provisioning
        // Read before the suspension, as the real service decides it before its
        // first await.
        let route = GuestStartRoute(startOf: instance, bootIntoRecovery: bootIntoRecovery)
        // Before the suspension, as the real service enters it before its first
        // await: a start in flight is what every other caller reads off the VM.
        instance.enter(.starting(sessionID: nil))
        if shouldSuspendOnStart {
            await suspendIfNeeded()
        }
        if let error = startError {
            instance.tearDownSession(
                restingAt: VirtualizationService.restingPhaseAfterLifecycleFailure(
                    error, on: instance, transientRestingPhase: .stopped))
            throw error
        }
        instance.enter(.running(sessionID: MockVirtualizationPhases.sessionIdentity(for: instance)))
        return route
    }

    func stop(_ instance: VMInstance) async throws {
        instance.restAfterPowerOff()
    }

    func forceStop(_ instance: VMInstance) async throws {
        instance.restAfterPowerOff()
    }

    func pause(_ instance: VMInstance) async throws {
        if shouldSuspendOnPause {
            await suspendIfNeeded()
        }
        instance.enter(.livePaused(sessionID: MockVirtualizationPhases.sessionIdentity(for: instance)))
    }

    func resume(_ instance: VMInstance) async throws {
        // A cold resume rebuilds the VM from the save file and stands in
        // `.restoringSavedState` for the whole of that build; a hot one resumes
        // the session it already holds and touches no phase until it settles.
        if instance.holdsSuspendedSession { instance.enter(.restoringSavedState(sessionID: nil)) }
        if shouldSuspendOnResume {
            await suspendIfNeeded()
        }
        instance.removeSaveFile()
        instance.enter(.running(sessionID: MockVirtualizationPhases.sessionIdentity(for: instance)))
    }

    func save(_ instance: VMInstance) async throws {
        // The slot is what makes the VM resumable, so a real one is written:
        // every predicate a suspended VM is judged by reads the file.
        try VMInstanceFixture.writeSaveFile(for: instance)
        instance.tearDownSession(restingAt: .suspended)
    }

    func takeSnapshot(
        _ instance: VMInstance, snapshot: VMSnapshotRecord, store: any VMSnapshotStoring
    ) async throws -> VMSnapshot {
        let phases = try MockVirtualizationPhases.capturePhases(for: instance, kind: snapshot.kind)
        instance.enter(phases.capturing)
        instance.enter(phases.resting)
        return VMSnapshot(snapshot, macAddress: instance.configuration.macAddress)
    }

    func revertToSnapshot(
        _ instance: VMInstance, snapshot: VMSnapshot, store: any VMSnapshotStoring,
        adopt: @MainActor (VMSnapshotRestorePlan) -> Void
    ) async throws {
        let plan = try store.planRestore(
            bundleURL: instance.bundleURL, snapshotID: snapshot.id, kind: snapshot.kind)
        if shouldSuspendOnRevert {
            await suspendIfNeeded()
        }
        var restore = plan
        restore.configuration = instance.configuration.adoptingSnapshotState(plan.configuration)
        try store.restore(bundleURL: instance.bundleURL, snapshotID: snapshot.id, plan: restore)
        adopt(restore)
        // A warm snapshot's own saved state is what the VM comes back on, and
        // the store mock copies no files, so the slot is written here.
        try VMInstanceFixture.writeSaveFile(for: instance)
        instance.tearDownSession(restingAt: .suspended)
    }
}
