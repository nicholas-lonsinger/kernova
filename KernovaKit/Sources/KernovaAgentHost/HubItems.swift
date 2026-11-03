#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaAgentCore
import KernovaWire

/// An item event of one peer's connection, as the hub hands it on under console authority: a peer's offer
/// only from its feature's console peer, and every other event only about what the owner holds open there.
/// When the hub ends an item itself, its event closes `.resetLocally(CANCELLED)`.
public enum HubItemEvent: Sendable, Equatable {
    /// An offer or pull on `PeerHandle`'s connection changed.
    case items(PeerHandle, ItemTransferEvent)
    /// A take of `PeerHandle`'s drag ended.
    case dragTake(PeerHandle, DragTakeEvent)
}

/// What the owner of the hub's item events holds open on one connection, each in the order it opened: the host's
/// offers, the peer's offers the hub forwarded, and the pulls and takes the owner opened. The hub hands on an
/// event ending one of these only while it is held, so each ends toward the owner exactly once.
struct HubOpenItems: Sendable {
    struct Offer: Sendable, Equatable {
        var token: Data
        var feature: FeatureID
    }

    var hostOffers: [Offer] = []
    var forwardedOffers: [Offer] = []
    var pulls: [(id: ItemPullID, feature: FeatureID)] = []
    var takes: [DragTakeID] = []
}

/// The item commands the hub awaits answers to, each with the peer asked and what its answer is for.
/// Touched only on the hub's queue.
struct HubItemRequests: Sendable {
    struct Pending: Sendable {
        var peer: PeerHandle
        var command: ItemCommand
        /// A pull's: the feature of the offer it names, which the hub forwarded.
        var feature: FeatureID?
        /// Receives the answer, or nil when the connection ended without one.
        var answer: @Sendable (ItemReply?) -> Void
    }

    private var pending: [ItemRequestID: Pending] = [:]
    private var nextRequest: UInt64 = 0

    /// Records `command`, the one `build` makes around a fresh id, to `peer`, whose answer `answer` receives;
    /// `feature` is a pull's, as `Pending.feature` says.
    mutating func add(
        _ peer: PeerHandle, _ build: (ItemRequestID) -> ItemCommand, feature: FeatureID?,
        _ answer: @escaping @Sendable (ItemReply?) -> Void
    ) -> ItemCommand {
        nextRequest += 1
        let id = ItemRequestID(rawValue: nextRequest)
        let command = build(id)
        pending[id] = Pending(peer: peer, command: command, feature: feature, answer: answer)
        return command
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

/// Console authority over items. A feature's offers, the host's and the peer's, live only on that feature's
/// console peer, as `consolePeer(for:)` reads it now: a peer's offer from any other connection is released
/// unforwarded, and once a feature's console peer changes, the host's offers of it on the peer that lost it
/// are withdrawn and the offers the hub forwarded from that peer released. A connection that leaves the peer
/// set hands on nothing more, so everything the owner held on it ends there. Each such end reaches the owner as
/// the event it stands for, closed `.resetLocally(CANCELLED)`.
extension AgentHubState {
    /// What console authority does with item event `event` of `handle`'s connection: whether the owner hears
    /// it, and the command the connection is sent instead.
    mutating func admit(
        _ event: ItemTransferEvent, from handle: PeerHandle
    ) -> (forward: Bool, command: ItemCommand?) {
        guard var entry = connections[handle] else { return (false, nil) }
        defer { connections[handle] = entry }
        switch event {
        case .offerReceived(let header):
            guard consolePeer(for: header.feature) == handle else {
                return (false, .release(token: header.token))
            }
            entry.items.forwardedOffers.append(HubOpenItems.Offer(token: header.token, feature: header.feature))
            return (true, nil)
        case .offerEnded(_, .local, let token, _):
            return (entry.items.hostOffers.removeFirst(where: { $0.token == token }), nil)
        case .offerEnded(_, .remote, let token, _):
            return (entry.items.forwardedOffers.removeFirst(where: { $0.token == token }), nil)
        case .pullEnded(_, let id, _):
            return (entry.items.pulls.removeFirst(where: { $0.id == id }), nil)
        case .serveEnded:
            return (entry.peer != nil, nil)
        }
    }

    /// Whether the owner hears `event` of `handle`'s connection's drag takes.
    mutating func admit(_ event: DragTakeEvent, from handle: PeerHandle) -> Bool {
        switch event {
        case .requested:
            // A peer's event: its host never emits one.
            return false
        case .ended(let id, _):
            return connections[handle]?.items.takes.removeFirst(where: { $0 == id }) ?? false
        }
    }

    /// Whether `handle`'s connection is a peer.
    func isPeer(_ handle: PeerHandle) -> Bool {
        connections[handle]?.peer != nil
    }

    /// The feature of the offer of `token` the hub forwarded from `handle`'s connection and still holds.
    func forwardedFeature(_ token: Data, on handle: PeerHandle) -> FeatureID? {
        connections[handle]?.items.forwardedOffers.first { $0.token == token }?.feature
    }

    /// Records what `reply`, the answer of `handle`'s connection to `pending`, opened there.
    mutating func opened(_ pending: HubItemRequests.Pending, _ reply: ItemReply, on handle: PeerHandle) {
        switch (pending.command, reply) {
        case (.offer(_, let offer, let feature), .offered(nil)):
            connections[handle]?.items.hostOffers.append(HubOpenItems.Offer(token: offer.token, feature: feature))
        case (.pull, .pulled(.success(let id))):
            guard let feature = pending.feature else { break }
            connections[handle]?.items.pulls.append((id, feature))
        case (_, .took(.success(let id))):
            connections[handle]?.items.takes.append(id)
        default:
            break
        }
    }

    /// Ends everything the owner holds where console authority no longer allows it: each offer on a connection
    /// that is not its feature's console peer, and, on a connection that is no peer, its pulls and takes too.
    /// Returns, in order, each command to send and each event to hand on.
    mutating func settleItems() -> [(handle: PeerHandle, command: ItemCommand?, event: HubItemEvent)] {
        let console = Dictionary(
            uniqueKeysWithValues: ItemFeatureAvailability.offering.map { ($0, consolePeer(for: $0)) })
        var ended: [(handle: PeerHandle, command: ItemCommand?, event: HubItemEvent)] = []
        for handle in connections.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            guard var items = connections[handle]?.items else { continue }
            let isPeer = connections[handle]?.peer != nil
            func held(_ offer: HubOpenItems.Offer) -> Bool { console[offer.feature] == handle }
            for offer in items.hostOffers where !held(offer) {
                let end = ItemTransferEvent.offerEnded(offer.feature, .local, token: offer.token, Self.endedByHub)
                ended.append((handle, .withdraw(token: offer.token), .items(handle, end)))
            }
            for offer in items.forwardedOffers where !held(offer) {
                let end = ItemTransferEvent.offerEnded(offer.feature, .remote, token: offer.token, Self.endedByHub)
                ended.append((handle, .release(token: offer.token), .items(handle, end)))
            }
            items.hostOffers.removeAll { !held($0) }
            items.forwardedOffers.removeAll { !held($0) }
            if !isPeer {
                for pull in items.pulls {
                    let end = ItemTransferEvent.pullEnded(pull.feature, pull.id, .closed(Self.endedByHub))
                    ended.append((handle, .cancel(pull.id), .items(handle, end)))
                }
                for id in items.takes {
                    ended.append((handle, nil, .dragTake(handle, .ended(id, .closed(Self.endedByHub)))))
                }
                items.pulls = []
                items.takes = []
            }
            connections[handle]?.items = items
        }
        return ended
    }

    /// How an item the hub ended for console authority closed.
    static let endedByHub = StreamClosure.resetLocally(
        WireError(.cancelled, debugDetail: "not on the feature's console peer"))
}

extension Array {
    /// Removes the first element `predicate` accepts; whether there was one.
    fileprivate mutating func removeFirst(where predicate: (Element) -> Bool) -> Bool {
        guard let index = firstIndex(where: predicate) else { return false }
        remove(at: index)
        return true
    }
}
