import Foundation
import KernovaKit

@testable import Kernova

/// A wait a verb parks in until the task running it is cancelled.
///
/// Lock-guarded and isolation-free rather than `@MainActor`: a cancellation
/// handler is isolated to nothing, and a cancel that lands *before* the park
/// still has to release it.
final class CancellationPark: @unchecked Sendable {
    /// Fires when a park is released, so a test awaits the cancellation rather
    /// than polling for it.
    let released = AsyncGate()

    private let lock = NSLock()
    private var parked: CheckedContinuation<Void, Never>?
    private var cancelled = false

    /// Whether the task that parked here has been cancelled.
    var wasCancelled: Bool { lock.withLock { cancelled } }

    /// Suspends until the calling task is cancelled.
    func park() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let alreadyCancelled = lock.withLock { () -> Bool in
                    guard !cancelled else { return true }
                    parked = continuation
                    return false
                }
                if alreadyCancelled { continuation.resume() }
            }
        } onCancel: {
            release()
        }
    }

    private func release() {
        let waiting = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            cancelled = true
            defer { parked = nil }
            return parked
        }
        waiting?.resume()
        released.notify()
    }
}
