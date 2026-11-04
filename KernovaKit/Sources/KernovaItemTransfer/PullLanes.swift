#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import Dispatch
import KernovaAgentCore
import KernovaAgentRuntime
import KernovaSynchronization

/// One pull, across every connection an adapter serves: its id is unique only on its connection.
struct PullKey: Hashable, Sendable {
    let connection: ItemConnection
    let id: ItemPullID
}

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
    private let lanes = Locked<[PullKey: Lane]>([:])

    init(label: String) {
        self.label = label
    }

    /// Opens `key`'s lane and runs `body` on it, which makes the pull's state.
    func open(_ key: PullKey, _ body: @escaping @Sendable () -> State?) {
        let lane = Lane("\(label).\(key.id.generation.rawValue).\(key.id.stream.rawValue)")
        lanes.withLock { $0[key] = lane }
        lane.queue.async { lane.state = body() }
    }

    /// Runs `body` on `key`'s lane with its state, after everything queued before it; nothing when the lane is
    /// closed or holds no state.
    func run(_ key: PullKey, _ body: @escaping @Sendable (inout State) -> Void) {
        guard let lane = lanes.withLock({ $0[key] }) else { return }
        lane.queue.async {
            guard var state = lane.state else { return }
            lane.state = nil
            body(&state)
            lane.state = state
        }
    }

    /// Closes every lane now, dropping each one's state on its queue once what was queued before has run, and
    /// returns once every state is dropped.
    func closeAll() {
        let closed = lanes.withLock { lanes in
            defer { lanes.removeAll() }
            return Array(lanes.values)
        }
        for lane in closed { lane.queue.sync { lane.state = nil } }
    }

    /// Closes `key`'s lane: `body` runs last on it with its state, which is then dropped.
    func close(_ key: PullKey, _ body: @escaping @Sendable (inout State?) -> Void = { _ in }) {
        guard let lane = lanes.withLock({ $0.removeValue(forKey: key) }) else { return }
        lane.queue.async {
            body(&lane.state)
            lane.state = nil
        }
    }
}
