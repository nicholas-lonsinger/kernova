import Foundation
import KernovaKit
import Synchronization

#if SWIFT_PACKAGE
import KernovaTestSupport
#endif

@testable import KernovaCore

/// A wait a verb parks in until the task running it is cancelled.
///
/// Lock-guarded and isolation-free rather than `@MainActor`: a cancellation
/// handler is isolated to nothing, and a cancel that lands *before* the park
/// still has to release it.
final class CancellationPark: Sendable {
    /// Fires when a park is released, so a test awaits the cancellation rather
    /// than polling for it.
    let released = AsyncGate()

    private struct State {
        var parked: CheckedContinuation<Void, Never>?
        var cancelled = false
    }

    private let state = Mutex(State())

    /// Whether the task that parked here has been cancelled.
    var wasCancelled: Bool { state.withLock { $0.cancelled } }

    /// Suspends until the calling task is cancelled.
    func park() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let alreadyCancelled = state.withLock { state -> Bool in
                    guard !state.cancelled else { return true }
                    state.parked = continuation
                    return false
                }
                if alreadyCancelled { continuation.resume() }
            }
        } onCancel: {
            release()
        }
    }

    private func release() {
        let waiting = state.withLock { state -> CheckedContinuation<Void, Never>? in
            state.cancelled = true
            defer { state.parked = nil }
            return state.parked
        }
        waiting?.resume()
        released.notify()
    }
}
