import Foundation
import KernovaTestSupport

/// A step a test holds in flight — an arrival's bundle write, an operation's
/// body: it parks until ``release(throwing:)``, the way an uninterruptible
/// copy runs to its end whether or not anything was cancelled meanwhile.
@MainActor
final class GatedStep {
    /// Fires as the step begins parking.
    let entered = AsyncGate()
    private(set) var hasEntered = false
    private var outcome: Result<Void, any Error>?
    private var parked: [CheckedContinuation<Void, any Error>] = []

    /// Lets the step finish — or throw `error`.
    func release(throwing error: (any Error)? = nil) {
        let result: Result<Void, any Error> = error.map { .failure($0) } ?? .success(())
        outcome = result
        let waiting = parked
        parked.removeAll()
        for continuation in waiting { continuation.resume(with: result) }
    }

    /// Parks until released, answering what the release carried.
    func pass() async throws {
        hasEntered = true
        entered.notify()
        if let outcome { return try outcome.get() }
        try await withCheckedThrowingContinuation { parked.append($0) }
    }

    /// Waits until the step has begun parking.
    func waitUntilEntered() async throws {
        try await entered.wait { hasEntered }
    }
}
