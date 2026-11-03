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

/// What an endpoint's owner asks of its item machines from another queue than the driver's. Each command
/// that carries an `ItemRequestID` is answered by exactly one `ItemReply` event of that id, emitted before
/// any event the command caused; one sent after the connection ended is never answered.
public enum ItemCommand: Sendable, Equatable {
    /// Offer on `feature`'s offer kind, as `offerItems` does; answered `.offered`.
    case offer(ItemRequestID, ItemOffer, feature: FeatureID)
    /// Withdraw this side's offer of `token`.
    case withdraw(token: Data)
    /// Release the far side's offer of `token`.
    case release(token: Data)
    /// Pull one representation of the far side's open offer; answered `.pulled`.
    case pull(ItemRequestID, PullRequest)
    /// Cancel a pull this side opened.
    case cancel(ItemPullID)
    /// Host: take the peer's open drag offer of `token`; answered `.took`.
    case takeDrag(ItemRequestID, token: Data)
    /// Decode every item of the far side's open offer of `token`; answered `.read`.
    case read(ItemRequestID, token: Data)
}

/// An endpoint's answer to an `ItemCommand`.
public enum ItemReply: Sendable, Equatable {
    /// The offer opened (nil), or why not.
    case offered(WireError?)
    /// The pull's id, whose one `.pullEnded` follows, or why it was not opened.
    case pulled(Result<ItemPullID, WireError>)
    /// The take's id, whose one `.dragTake(.ended)` follows, or why it was not opened.
    case took(Result<DragTakeID, WireError>)
    /// The offer's items in order; nil when no offer of the token is held whole.
    case read([OfferedItem]?)
}

extension ItemMachines {
    /// Carries out `command`: the answer it owes and the id it answers, or nil for a command answered by none.
    mutating func perform(_ command: ItemCommand, connection: inout Connection) -> (ItemRequestID, ItemReply)? {
        switch command {
        case .offer(let id, let offer, let feature):
            return (id, .offered(self.offer(offer, feature: feature, connection: &connection)))
        case .withdraw(let token):
            withdraw(token, connection: &connection)
        case .release(let token):
            release(token, connection: &connection)
        case .pull(let id, let request):
            return (id, .pulled(pull(request, connection: &connection)))
        case .cancel(let pull):
            cancel(pull, connection: &connection)
        case .takeDrag(let id, let token):
            return (id, .took(takeDrag(token, connection: &connection)))
        case .read(let id, let token):
            return (id, .read(transfer.offers.remoteItems(token)))
        }
        return nil
    }
}
