import Foundation
import KernovaTestSupport

@testable import KernovaCore

/// A mock virtualization service whose `start` and `pause` bodies — and, on
/// request, points inside a revert — suspend until explicitly
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

    /// When `true`, `revertToSnapshot` will suspend before ending the session,
    /// standing in for the window a real revert spends copying files.
    var shouldSuspendOnRevert = false

    /// Number of `start` calls, so a test can prove a second start joined the
    /// first rather than issuing its own.
    private(set) var startCallCount = 0

    // MARK: - Suspension Mechanism

    /// Continuation that, when resumed, unblocks the suspended operation.
    private var suspendedContinuation: CheckedContinuation<Void, Never>?

    /// Resumes the test parked in ``waitUntilSuspended(fileID:line:)`` once an
    /// operation suspends.
    private var suspendedNotification: (@Sendable (()) -> Void)?

    /// Waits until the mock is suspended inside an operation.
    ///
    /// This and `suspendIfNeeded()` both run on the main actor, so an operation
    /// either suspended before this checks — and it returns at once — or
    /// suspends later and resumes the park this arms.
    func waitUntilSuspended(fileID: String = #fileID, line: Int = #line) async throws {
        // If already suspended, return immediately
        if suspendedContinuation != nil { return }

        try await Backstop("waitUntilSuspended()", fileID: fileID, line: line).park { resume in
            suspendedNotification = resume
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
            suspendedNotification?(())
            suspendedNotification = nil
        }
    }

    // MARK: - VirtualizationProviding

    func start(
        _ instance: VMInstance, _ context: borrowing VMGuestStartContext,
        provisioning: GuestProvisioningCredentials?
    ) async throws -> VMOperationEnding<GuestStartRoute> {
        startCallCount += 1
        let route = GuestStartRoute(context.kind)
        if shouldSuspendOnStart {
            await suspendIfNeeded()
        }
        try await context.bringUp.operation.executingGuest { _ in
            context.bringUp.bindSessionForTesting(UUID())
        }
        return .rest(.live(.running), route)
    }

    /// The guest honors the request and powers off, which reaches the VM as
    /// the session event the real guest raises.
    func requestStop(_ instance: VMInstance) async throws {
        guard let sessionID = instance.liveSessionID else { return }
        instance.activity.deliverSessionEvent(.guestDidStop, from: sessionID)
    }

    /// Sends the stop, which completes at once as the session event the real
    /// stop's completion raises.
    func forceStop(_ instance: VMInstance) throws {
        guard let sessionID = instance.liveSessionID else { return }
        instance.activity.deliverSessionEvent(.stopDidComplete, from: sessionID)
    }

    func pause(
        _ instance: VMInstance, _ context: borrowing VMOperationContext
    ) async throws -> VMOperationEnding<Void> {
        await suspendIfNeeded()
        return .rest(.live(.paused), ())
    }

    func resume(
        _ instance: VMInstance, _ context: borrowing VMOperationContext
    ) async throws -> VMOperationEnding<Void> {
        .rest(.live(.running), ())
    }

    func save(
        _ instance: VMInstance, _ context: borrowing VMOperationContext
    ) async throws -> VMOperationEnding<Void> {
        // The slot is what makes the VM resumable, so a real one is written:
        // every predicate a suspended VM is judged by reads the file.
        try VMInstanceFixture.writeSaveFile(for: instance)
        context.parkedSession()
        context.endSession()
        return .rest(.atRest(.stopped), ())
    }

    func takeSnapshot(
        _ instance: VMInstance, _ context: borrowing VMCaptureContext,
        snapshot request: VMSnapshotCaptureRequest
    ) async throws -> VMOperationEnding<VMSnapshot> {
        .rest(
            .asStarted,
            VMSnapshot(request.record(capturedIn: context.mode), capturedUnder: instance.configuration))
    }

    func copyLive(
        _ instance: VMInstance, _ context: borrowing VMCaptureContext,
        savingStateTo saveFileURL: URL,
        prepare: () async throws -> Void,
        copy: () async throws -> Void
    ) async throws -> VMOperationEnding<Void> {
        try await prepare()
        try await copy()
        return .rest(.asStarted, ())
    }

    func revertToSnapshot(
        _ instance: VMInstance, _ context: borrowing VMRevertContext,
        commitConfiguration: @MainActor (borrowing VMEditPermit, VMSnapshotRestorePlan) throws -> Void
    ) async throws -> VMOperationEnding<Void> {
        let snapshot = context.snapshot
        let plan = try await context.bringUp.operation.bundle.planRestore(
            fromSnapshot: snapshot.id, kind: snapshot.kind)
        if shouldSuspendOnRevert {
            await suspendIfNeeded()
        }
        context.bringUp.operation.endSession()
        try await context.bringUp.operation.bundle.stageRestore(fromSnapshot: snapshot.id, plan: plan)
        try commitConfiguration(context.bringUp.operation.permit, plan)
        try await context.bringUp.operation.bundle.installRestore(plan)
        // A warm snapshot's own saved state is what the VM comes back on, and
        // the machine-files mock copies no files, so the slot is written here.
        try VMInstanceFixture.writeSaveFile(for: instance)
        return .rest(.atRest(.stopped), ())
    }
}
