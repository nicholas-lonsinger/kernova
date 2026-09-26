import Foundation
import KernovaTestSupport

@testable import Kernova

/// A mock removable media device service whose `attach` method suspends until explicitly resumed.
///
/// Used to test the rapid-double-click mount mutex in `VMLibraryViewModel`.
///
/// - Important: Only **one** operation can be suspended at a time. The mock stores a
///   single `suspendedContinuation` slot; calling `suspendIfNeeded()` while another
///   operation is already suspended will trigger a precondition failure.
@MainActor
final class SuspendingMockRemovableMediaDeviceService: RemovableMediaAttaching {
    var attachCallCount = 0
    var detachCallCount = 0
    var lastAttachedPath: String?
    var lastAttachedReadOnly: Bool?

    /// Thrown by `attach` after it resumes, so a test can fail an operation
    /// that was overtaken while suspended.
    var attachError: (any Error)?

    // MARK: - Completion Signal

    /// Fired as each operation returns, so a test can await a resumed
    /// operation's completion rather than poll for its effects.
    let operationCompleted = AsyncGate()

    /// How many attaches and detaches have returned to their caller.
    private(set) var completedOperationCount = 0

    private func noteCompletion() {
        completedOperationCount += 1
        operationCompleted.notify()
    }

    // MARK: - Suspension Mechanism

    /// Continuation that, when resumed, unblocks the suspended operation.
    private var suspendedContinuation: CheckedContinuation<Void, Never>?

    /// Fired as an operation parks in `suspendIfNeeded()`.
    private let suspended = AsyncGate()

    /// Waits until an operation is parked inside the mock, throwing at the
    /// backstop when none arrives.
    func waitUntilSuspended() async throws {
        try await suspended.wait { suspendedContinuation != nil }
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
            suspended.notify()
        }
    }

    // MARK: - RemovableMediaAttaching

    func attach(
        diskImagePath: String,
        readOnly: Bool,
        desiredUUID: UUID?,
        to instance: VMInstance
    ) async throws -> RemovableMediaDeviceInfo {
        attachCallCount += 1
        lastAttachedPath = diskImagePath
        lastAttachedReadOnly = readOnly
        await suspendIfNeeded()
        if let attachError {
            noteCompletion()
            throw attachError
        }
        let id = desiredUUID ?? UUID()
        noteCompletion()
        return RemovableMediaDeviceInfo(id: id, path: diskImagePath, readOnly: readOnly)
    }

    func detach(
        deviceInfo: RemovableMediaDeviceInfo,
        from instance: VMInstance
    ) async throws {
        detachCallCount += 1
        noteCompletion()
    }
}
