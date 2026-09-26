import Foundation
@testable import Kernova

/// A mock virtualization service whose `start` and `pause` bodies — and, on
/// request, a hot resume and points inside a revert — suspend until explicitly
/// resumed, while the operation that runs them holds the VM.
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

    /// When `true`, a hot `resume` will suspend.
    ///
    /// Defaults to `false` so existing callers keep the immediate behavior.
    var shouldSuspendOnResume = false

    /// When `true`, `revertToSnapshot` will suspend before ending the session,
    /// standing in for the window a real revert spends copying files.
    ///
    /// Defaults to `false` so existing callers keep the immediate behavior.
    var shouldSuspendOnRevert = false

    /// When `true`, `revertToSnapshot` suspends before it reads the snapshot's
    /// plan — the first thing its body does.
    var shouldSuspendBeforePlanning = false

    /// When `true`, `revertToSnapshot` suspends once the session is ended and
    /// the files are staged, before `installRestore` copies them in.
    var shouldSuspendBeforeInstall = false

    /// Whether the guest ignores the ACPI shutdown `requestStop` sends, as a
    /// macOS guest resting at its login screen does: the request is delivered
    /// and the VM keeps running.
    var guestIgnoresShutdownRequest = false

    /// Number of `requestStop` and `forceStop` calls that reached the mock.
    private(set) var requestStopCallCount = 0
    private(set) var forceStopCallCount = 0

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
        _ instance: VMInstance, _ context: borrowing VMBringUpContext,
        provisioning: GuestProvisioningCredentials?
    ) async throws -> VMOperationEnding<GuestStartRoute> {
        startCallCount += 1
        lastStartProvisioning = provisioning
        guard case .bringUp(let kind) = context.operation.kind, let route = GuestStartRoute(kind)
        else {
            throw VirtualizationError.invalidStateTransition(from: instance.status, action: "start")
        }
        if shouldSuspendOnStart {
            await suspendIfNeeded()
        }
        if let error = startError { throw error }
        if route == .restoredSavedState { context.operation.bundle.removeSaveFile() }
        context.bindSessionForTesting(UUID())
        return .rest(.live(.running), route)
    }

    /// A guest that honors the request powers off, which reaches the VM as the
    /// session event the real guest raises.
    func requestStop(_ instance: VMInstance) async throws {
        requestStopCallCount += 1
        guard !guestIgnoresShutdownRequest, let sessionID = instance.liveSessionID else { return }
        instance.activity.deliverSessionEvent(.guestDidStop, from: sessionID)
    }

    func forceStop(_ instance: VMInstance) async throws {
        forceStopCallCount += 1
    }

    func pause(
        _ instance: VMInstance, _ context: borrowing VMOperationContext
    ) async throws -> VMOperationEnding<Void> {
        if shouldSuspendOnPause {
            await suspendIfNeeded()
        }
        return .rest(.live(.paused), ())
    }

    func resume(
        _ instance: VMInstance, _ context: borrowing VMOperationContext
    ) async throws -> VMOperationEnding<Void> {
        if shouldSuspendOnResume {
            await suspendIfNeeded()
        }
        context.bundle.removeSaveFile()
        return .rest(.live(.running), ())
    }

    func save(
        _ instance: VMInstance, _ context: borrowing VMOperationContext
    ) async throws -> VMOperationEnding<Void> {
        // The slot is what makes the VM resumable, so a real one is written:
        // every predicate a suspended VM is judged by reads the file.
        try VMInstanceFixture.writeSaveFile(for: instance)
        context.endSession()
        return .rest(.atRest(.stopped), ())
    }

    func takeSnapshot(
        _ instance: VMInstance, _ context: borrowing VMOperationContext,
        snapshot request: VMSnapshotCaptureRequest
    ) async throws -> VMOperationEnding<VMSnapshot> {
        guard case .capturingSnapshot(let mode) = context.kind else {
            throw VirtualizationError.invalidStateTransition(
                from: instance.status, action: "take a snapshot of")
        }
        return .rest(
            .asStarted,
            VMSnapshot(request.record(capturedIn: mode), macAddress: instance.configuration.macAddress))
    }

    func revertToSnapshot(
        _ instance: VMInstance, _ context: borrowing VMBringUpContext, snapshot: VMSnapshot,
        commitConfiguration: @MainActor (VMSnapshotRestorePlan) throws -> Void
    ) async throws -> VMOperationEnding<Void> {
        if shouldSuspendBeforePlanning {
            await suspendIfNeeded()
        }
        let plan = try await context.operation.bundle.planRestore(fromSnapshot: snapshot.id, kind: snapshot.kind)
        if shouldSuspendOnRevert {
            await suspendIfNeeded()
        }
        context.operation.endSession()
        try await context.operation.bundle.stageRestore(fromSnapshot: snapshot.id, plan: plan)
        try commitConfiguration(plan)
        if shouldSuspendBeforeInstall {
            await suspendIfNeeded()
        }
        try await context.operation.bundle.installRestore(plan)
        // A warm snapshot's own saved state is what the VM comes back on, and
        // the machine-files mock copies no files, so the slot is written here.
        try VMInstanceFixture.writeSaveFile(for: instance)
        return .rest(.atRest(.stopped), ())
    }
}
