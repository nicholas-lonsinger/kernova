#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaAgentCore
import KernovaWire

/// What an offered representation's container is made from, as its owner produces it when a pull names it.
public enum ItemContent: Sendable, Equatable {
    /// A FILE or FOLDER: the entry at the absolute path `path`, read through that path itself.
    case tree(path: String)
    /// An INLINE representation's bytes.
    case inline(Data)
}

/// The owner of one feature that offers items, on one end, whose connections `Peer` names.
public struct ItemFeatureOwner<Peer: Sendable>: Sendable {
    /// Hears where the feature can be used now: the peer whose connection serves it, or nil once none does.
    /// Once per change, in order with the item events. On the host it is the feature's console peer; on a
    /// guest agent, `()` while its connection to the host can use the feature.
    public var usable: @Sendable (Peer?) -> Void
    /// Hears each item event of the feature, from the connection of the peer it names, in the order the end
    /// delivers them and on its queue.
    public var events: @Sendable (Peer, ItemTransferEvent) -> Void
    /// Produces the content of a representation of this end's offer of the feature that pull `ItemPullID`
    /// names, or why it cannot: called on the pull's own queue, so it may wait, as a promise called in does,
    /// until that pull's `.serveEnded` reaches ``events``.
    public var content: @Sendable (ItemPullID, PullRequest, Representation) -> Result<ItemContent, WireError>
    /// Hears the host's policy each time a guest agent's connection receives it, in order with the item events;
    /// never on the host, whose policy it is.
    public var policy: @Sendable (PolicySnapshot) -> Void

    /// Creates an owner.
    public init(
        usable: @escaping @Sendable (Peer?) -> Void,
        events: @escaping @Sendable (Peer, ItemTransferEvent) -> Void,
        content: @escaping @Sendable (ItemPullID, PullRequest, Representation) -> Result<ItemContent, WireError>,
        policy: @escaping @Sendable (PolicySnapshot) -> Void = { _ in }
    ) {
        self.usable = usable
        self.events = events
        self.content = content
        self.policy = policy
    }
}

/// DRAG's owner: an item feature's owner that also hears the takes of drags.
public struct DragFeatureOwner<Peer: Sendable>: Sendable {
    /// DRAG's item events and content.
    public var items: ItemFeatureOwner<Peer>
    /// Hears each `DragTakeEvent`, as `ItemFeatureOwner.events` hears item events.
    public var takes: @Sendable (Peer, DragTakeEvent) -> Void

    /// Creates DRAG's owner.
    public init(items: ItemFeatureOwner<Peer>, takes: @escaping @Sendable (Peer, DragTakeEvent) -> Void) {
        self.items = items
        self.takes = takes
    }
}

/// One end's item features and their owners, fixed for its life: each item event and drag take reaches the
/// owner of its feature, and each pull's content request the owner of the pulled offer's feature. Its
/// `features` are the ones `ItemAdapters` serve, so a feature with no owner is advertised absent, and the core
/// delivers nothing of it.
///
/// Delivery is a synchronous call on the caller's thread: the order and queue an end delivers on are the
/// owners'.
public struct ItemFeatureRouter<Peer: Sendable>: Sendable {
    private let clipboard: ItemFeatureOwner<Peer>?
    private let drop: ItemFeatureOwner<Peer>?
    private let drag: DragFeatureOwner<Peer>?

    /// A router serving the features given an owner.
    public init(
        clipboard: ItemFeatureOwner<Peer>? = nil, drop: ItemFeatureOwner<Peer>? = nil,
        drag: DragFeatureOwner<Peer>? = nil
    ) {
        self.clipboard = clipboard
        self.drop = drop
        self.drag = drag
    }

    /// The features with an owner: the set `ItemAdapters.features` takes.
    public var features: Set<FeatureID> {
        Set(ItemFeatureAvailability.offering.filter { owner(of: $0) != nil })
    }

    /// Hands `event` of `peer`'s connection to its feature's owner.
    public func deliver(_ event: ItemTransferEvent, from peer: Peer) {
        guard let owner = owner(of: event.feature) else {
            return assertionFailure("an item event of \(event.feature), which has no owner to be advertised")
        }
        owner.events(peer, event)
    }

    /// Tells `feature`'s owner where it can be used now: on `peer`'s connection, or nowhere.
    public func deliver(_ feature: FeatureID, usableOn peer: Peer?) {
        guard let owner = owner(of: feature) else {
            return assertionFailure("\(feature) became usable or not, though it has no owner to be advertised")
        }
        owner.usable(peer)
    }

    /// Hands `event` of `peer`'s connection to DRAG's owner.
    public func deliver(_ event: DragTakeEvent, from peer: Peer) {
        guard let drag else { return assertionFailure("a drag take, though DRAG has no owner to be advertised") }
        drag.takes(peer, event)
    }

    /// The content of `representation` of this end's offer of `feature` that pull `id`'s `request` pulls, from
    /// its owner: the `ItemSourceAdapter.Content` this end's source serves.
    public func content(
        _ feature: FeatureID, _ id: ItemPullID, _ request: PullRequest, _ representation: Representation
    ) -> Result<ItemContent, WireError> {
        guard let owner = owner(of: feature) else {
            return .failure(WireError(.itemRepresentationUnavailable, debugDetail: "\(feature) has no owner"))
        }
        return owner.content(id, request, representation)
    }

    private func owner(of feature: FeatureID) -> ItemFeatureOwner<Peer>? {
        switch feature {
        case .clipboard: clipboard
        case .drop: drop
        case .drag: drag?.items
        default: nil
        }
    }
}

extension ItemFeatureRouter where Peer == Void {
    /// Hands each item event, drag take and usability change of a peer's connection to its owner, and the
    /// host's policy to every owner; every other event is none of these.
    public func deliver(_ event: PeerEvent) {
        switch event {
        case .items(let event): deliver(event, from: ())
        case .dragTake(let event): deliver(event, from: ())
        case .itemFeatureUsable(let feature, let usable): deliver(feature, usableOn: usable ? () : nil)
        case .policyReceived(let policy):
            for owner in [clipboard, drop, drag?.items].compactMap({ $0 }) { owner.policy(policy) }
        case .established, .hostLiveness, .updateAvailable, .itemReply, .diagnostic, .closed:
            break
        }
    }
}
