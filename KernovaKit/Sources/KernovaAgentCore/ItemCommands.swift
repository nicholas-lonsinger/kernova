#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaWire

/// An endpoint owner's number for one item command it awaits an answer to; the owner draws it.
public struct ItemRequestID: Hashable, Sendable {
    /// The owner's number.
    public var rawValue: UInt64

    /// Creates an id.
    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }
}

/// What an endpoint's owner asks of its item machines, the one way in. Each command that carries an
/// `ItemRequestID` is answered by exactly one `ItemReply` event of that id, emitted before any event the
/// command caused. A command the driver receives after the connection finished is never answered; one
/// answered while the connection is closing follows `.closed`.
public enum ItemCommand: Sendable, Equatable {
    /// Offer on `feature`'s offer kind: CLIPBOARD, withdrawing this side's previous clipboard offer, DROP from
    /// the host, or DRAG from a peer; answered `.offered`, refused `UNSUPPORTED_KIND` for a kind this side
    /// does not open.
    case offer(ItemRequestID, ItemOffer, feature: FeatureID)
    /// Withdraw this side's offer of `token`; its `.offerEnded` follows.
    case withdraw(token: Data)
    /// Release the far side's offer of `token`: this side pulls nothing more of it. Once the offer is whole
    /// the release is END with `endBody`, its kind's acceptor END body. Releasing a taken drag offer completes
    /// the drag.
    case release(token: Data, endBody: Data = Data())
    /// Refuse the far side's offer of `token`: RESET with `error`, so its opener hears why this side pulls
    /// nothing of it.
    case refuse(token: Data, WireError)
    /// Pull one representation of the far side's open offer, landing it as the order says; answered `.pulled`.
    case pull(ItemRequestID, ItemPullOrder)
    /// Cancel a pull this side opened; its `.pullEnded` follows.
    case cancel(ItemPullID)
    /// Host: take the peer's open drag offer of `token`; answered `.took`, refused `ITEM_OFFER_STALE` when no
    /// drag offer of `token` is open.
    case takeDrag(ItemRequestID, token: Data)
    /// Host: tell the peer `DragTakeControl` on a take this side opened; dropped once the take has ended.
    case controlTake(DragTakeID, DragTakeControl)
    /// Host: call off a take this side opened, before any release onto its catcher; its `.dragTake(.ended)`
    /// follows.
    case cancelTake(DragTakeID)
    /// Decode item `item` of the far side's open offer of `token`; answered `.read`.
    case read(ItemRequestID, token: Data, item: UInt32)
}

/// An endpoint's answer to an `ItemCommand`.
public enum ItemReply: Sendable, Equatable {
    /// The offer opened (nil), or why not.
    case offered(WireError?)
    /// The pull's id, whose one `.pullEnded` follows, or why it was not opened.
    case pulled(Result<ItemPullID, WireError>)
    /// The take's id, whose reports and one `.dragTake(.ended)` follow, or why it was not opened.
    case took(Result<DragTakeID, WireError>)
    /// The item, decoded now; nil when no such item is held. Each FILE and FOLDER representation's name passes
    /// `PathComponent.isValid`, and each INLINE one's is empty.
    case read(OfferedItem?)
}

extension ItemMachines {
    /// Carries out `command`: the answer it owes and the id it answers, or nil for a command answered by none.
    mutating func perform(_ command: ItemCommand, connection: inout Connection) -> (ItemRequestID, ItemReply)? {
        switch command {
        case .offer(let id, let offer, let feature):
            return (id, .offered(self.offer(offer, feature: feature, connection: &connection)))
        case .withdraw(let token):
            withdraw(token, connection: &connection)
        case .release(let token, let endBody):
            release(token, endBody: endBody, connection: &connection)
        case .refuse(let token, let error):
            refuse(token, error, connection: &connection)
        case .pull(let id, let order):
            return (id, .pulled(pull(order, connection: &connection)))
        case .cancel(let pull):
            cancel(pull, connection: &connection)
        case .takeDrag(let id, let token):
            return (id, .took(takeDrag(token, connection: &connection)))
        case .controlTake(let take, let control):
            self.control(take, control, connection: &connection)
        case .cancelTake(let take):
            cancelTake(take, connection: &connection)
        case .read(let id, let token, let item):
            return (id, .read(transfer.offers.remoteItem(token, Int(item))))
        }
        return nil
    }
}
