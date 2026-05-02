import Foundation
@testable import Kernova

/// A mock virtualization service whose `start` and `pause` methods suspend until
/// explicitly resumed. Used to test operation serialization in `VMLifecycleCoordinator`.
///
/// - Important: Only **one** operation can be suspended at a time. The mock stores a
///   single `suspendedContinuation` slot; calling `suspendIfNeeded()` while another
///   operation is already suspended will trigger a precondition failure.
@MainActor
final class SuspendingMockVirtualizationService: VirtualizationProviding {

    /// When `true`, `start` will suspend. Set to `false` to allow subsequent calls through immediately.
    var shouldSuspendOnStart = true

    /// When `true`, `pause` will suspend. Set to `false` to allow subsequent calls through immediately.
    var shouldSuspendOnPause = true

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

    func start(_ instance: VMInstance) async throws {
        if shouldSuspendOnStart {
            await suspendIfNeeded()
        }
        instance.status = .running
    }

    func stop(_ instance: VMInstance) throws {
        instance.resetToStopped()
    }

    func forceStop(_ instance: VMInstance) async throws {
        instance.resetToStopped()
    }

    func pause(_ instance: VMInstance) async throws {
        if shouldSuspendOnPause {
            await suspendIfNeeded()
        }
        instance.status = .paused
    }

    func resume(_ instance: VMInstance) async throws {
        instance.status = .running
    }

    func save(_ instance: VMInstance) async throws {
        instance.tearDownSession()
        instance.status = .paused
    }

    func restore(_ instance: VMInstance) async throws {
        instance.status = .running
    }
}
