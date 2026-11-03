#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import Dispatch
import KernovaAgentCore
import KernovaSynchronization

/// Each pull's state on a serial queue of its own, so one pull's disk work never waits on another's and every
/// effect of a pull runs in the order the core emitted it.
final class PullLanes<State>: Sendable {
    /// One pull's queue and the state only that queue touches.
    private final class Lane: @unchecked Sendable {
        let queue: DispatchQueue
        /// Read and written only on `queue`.
        var state: State?

        init(_ label: String) {
            queue = DispatchQueue(label: label)
        }
    }

    private let label: String
    private let lanes = Locked<[ItemPullID: Lane]>([:])

    init(label: String) {
        self.label = label
    }

    /// Opens `id`'s lane and runs `body` on it, which makes the pull's state.
    func open(_ id: ItemPullID, _ body: @escaping @Sendable () -> State?) {
        let lane = Lane("\(label).\(id.generation.rawValue).\(id.stream.rawValue)")
        lanes.withLock { $0[id] = lane }
        lane.queue.async { lane.state = body() }
    }

    /// Runs `body` on `id`'s lane with its state, after everything queued before it; nothing when the lane is
    /// closed or holds no state.
    func run(_ id: ItemPullID, _ body: @escaping @Sendable (inout State) -> Void) {
        guard let lane = lanes.withLock({ $0[id] }) else { return }
        lane.queue.async {
            guard var state = lane.state else { return }
            lane.state = nil
            body(&state)
            lane.state = state
        }
    }

    /// Closes `id`'s lane: `body` runs last on it with its state, which is then dropped.
    func close(_ id: ItemPullID, _ body: @escaping @Sendable (inout State?) -> Void = { _ in }) {
        guard let lane = lanes.withLock({ $0.removeValue(forKey: id) }) else { return }
        lane.queue.async {
            body(&lane.state)
            lane.state = nil
        }
    }
}
