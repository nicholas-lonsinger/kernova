import Foundation
@testable import Kernova

/// A mock USB device service whose `attach` method suspends until explicitly resumed.
/// Used to test the rapid-double-click mount mutex in `VMLibraryViewModel`.
///
/// - Important: Only **one** operation can be suspended at a time. The mock stores a
///   single `suspendedContinuation` slot; calling `suspendIfNeeded()` while another
///   operation is already suspended will overwrite the first continuation, leaking it.
@MainActor
final class SuspendingMockUSBDeviceService: USBDeviceProviding {

    /// When `true`, `attach` will suspend. Set to `false` to allow subsequent calls through immediately.
    var shouldSuspendOnAttach = true

    var attachCallCount = 0
    var detachCallCount = 0
    var lastAttachedPath: String?
    var lastAttachedReadOnly: Bool?

    // MARK: - Suspension Mechanism

    /// Continuation that, when resumed, unblocks the suspended operation.
    private var suspendedContinuation: CheckedContinuation<Void, Never>?

    /// Continuation that signals the test that the mock has entered its suspended state.
    private var suspendedNotification: CheckedContinuation<Void, Never>?

    /// Waits until the mock is suspended inside an operation.
    ///
    /// This relies on `@MainActor` cooperative scheduling: the `Task { @MainActor in … }`
    /// that drives the view model will suspend at `withCheckedContinuation` inside
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

    // MARK: - USBDeviceProviding

    func attach(
        diskImagePath: String,
        readOnly: Bool,
        to instance: VMInstance
    ) async throws -> USBDeviceInfo {
        attachCallCount += 1
        lastAttachedPath = diskImagePath
        lastAttachedReadOnly = readOnly
        if shouldSuspendOnAttach { await suspendIfNeeded() }
        return USBDeviceInfo(path: diskImagePath, readOnly: readOnly)
    }

    func detach(
        deviceInfo: USBDeviceInfo,
        from instance: VMInstance
    ) async throws {
        detachCallCount += 1
    }
}
