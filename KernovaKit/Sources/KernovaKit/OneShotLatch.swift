import Foundation
import KernovaSynchronization

/// A gate that opens once and stays open, waking everything waiting on it.
///
/// Nothing in it times out: a wait ends only when whoever holds the condition
/// it stands for opens it.
final class OneShotLatch: Sendable {
    private struct State: Sendable {
        var isOpen = false
        var wakeups: [@Sendable () -> Void] = []
    }

    private let state = Locked(State())

    /// Whether the latch has opened.
    var isOpen: Bool { state.withLock { $0.isOpen } }

    /// Opens the latch, running every wakeup registered so far on the calling
    /// thread. Idempotent.
    func open() {
        let wakeups = state.withLock { state -> [@Sendable () -> Void] in
            guard !state.isOpen else { return [] }
            state.isOpen = true
            defer { state.wakeups = [] }
            return state.wakeups
        }
        for wake in wakeups { wake() }
    }

    /// Runs `body` once the latch is open — at once, on the calling thread,
    /// when it already is; otherwise on the thread that opens it.
    func whenOpen(_ body: @escaping @Sendable () -> Void) {
        let isOpen = state.withLock { state -> Bool in
            guard !state.isOpen else { return true }
            state.wakeups.append(body)
            return false
        }
        if isOpen { body() }
    }

    /// Holds the calling thread until the latch opens, which another thread
    /// must do.
    func wait() {
        let semaphore = DispatchSemaphore(value: 0)
        whenOpen { semaphore.signal() }
        semaphore.wait()
    }

    /// Suspends until the latch opens.
    func opened() async {
        await withCheckedContinuation { continuation in
            whenOpen { continuation.resume() }
        }
    }
}
