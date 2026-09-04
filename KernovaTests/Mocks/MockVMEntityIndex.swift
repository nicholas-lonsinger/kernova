import Foundation
import KernovaTestSupport

@testable import Kernova

/// A ``VMEntityIndexing`` double recording what the gateway wrote, in order.
///
/// `Sendable` by main-actor isolation, which is also where the gateway calls
/// it from — so a test reads `operations` without a hop.
@MainActor
final class MockVMEntityIndex: VMEntityIndexing {
    /// One write the gateway asked for.
    enum Operation: Equatable {
        case index([UUID])
        case remove([UUID])
    }

    /// Every write so far, oldest first.
    private(set) var operations: [Operation] = []

    /// Notified after each recorded write, so a test waits rather than polls.
    let gate = AsyncGate()

    /// What `index` throws, after recording the call.
    var indexError: Error?
    /// The same for `remove`.
    var removeError: Error?

    func index(_ vms: [VMEntity]) async throws {
        record(.index(vms.map(\.id)))
        if let indexError { throw indexError }
    }

    func remove(_ ids: [UUID]) async throws {
        record(.remove(ids))
        if let removeError { throw removeError }
    }

    private func record(_ operation: Operation) {
        operations.append(operation)
        gate.notify()
    }
}
