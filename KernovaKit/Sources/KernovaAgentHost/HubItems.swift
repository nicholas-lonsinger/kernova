#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaAgentCore
import KernovaWire

/// An item event of one peer's connection, as the hub hands it on.
public enum HubItemEvent: Sendable, Equatable {
    /// An offer or pull on `PeerHandle`'s connection changed.
    case items(PeerHandle, ItemTransferEvent)
    /// A take of `PeerHandle`'s drag ended.
    case dragTake(PeerHandle, DragTakeEvent)
}

/// The item commands the hub awaits answers to, each with the peer asked and what its answer is for.
/// Touched only on the hub's queue.
struct HubItemRequests: Sendable {
    struct Pending: Sendable {
        var peer: PeerHandle
        /// Receives the answer, or nil when the connection ended without one.
        var answer: @Sendable (ItemReply?) -> Void
    }

    private var pending: [ItemRequestID: Pending] = [:]
    private var nextRequest: UInt64 = 0

    /// Records a command to `peer` whose answer `answer` receives, and returns the id it carries.
    mutating func add(_ peer: PeerHandle, _ answer: @escaping @Sendable (ItemReply?) -> Void) -> ItemRequestID {
        nextRequest += 1
        let id = ItemRequestID(rawValue: nextRequest)
        pending[id] = Pending(peer: peer, answer: answer)
        return id
    }

    /// The request `peer`'s connection answered with `id`, which it removes.
    mutating func take(_ id: ItemRequestID, from peer: PeerHandle) -> Pending? {
        guard pending[id]?.peer == peer else { return nil }
        return pending.removeValue(forKey: id)
    }

    /// Every request asked of `peer`, which it removes: its connection ended, so none is answered.
    mutating func takeAll(of peer: PeerHandle) -> [Pending] {
        let ended = pending.filter { $0.value.peer == peer }
        for id in ended.keys { pending[id] = nil }
        return ended.sorted { $0.key.rawValue < $1.key.rawValue }.map(\.value)
    }
}
