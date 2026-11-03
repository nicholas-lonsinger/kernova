import Foundation
import KernovaAgentCore
import KernovaWire

/// The CLIPBOARD item calls of the one connection an end's clipboard runs over: the host's to the feature's
/// console peer, a guest agent's to its host. Each completion runs once, on any queue; an answer comes before
/// any event the call caused.
public protocol ClipboardItemLink: Sendable {
    /// Offers `offer` on CLIPBOARD, withdrawing this side's previous clipboard offer; nil once it opened, or why
    /// it did not.
    func offerItems(_ offer: ItemOffer, _ completion: @escaping @Sendable (WireError?) -> Void)
    /// Withdraws this side's offer of `token`.
    func withdrawOffer(_ token: Data)
    /// Releases the far side's offer of `token`: this side pulls nothing more of it.
    func releaseOffer(_ token: Data)
    /// Item `item` of the far side's open offer of `token`, decoded; nil when no such item is held.
    func readItem(_ token: Data, item: UInt32, _ completion: @escaping @Sendable (OfferedItem?) -> Void)
    /// Pulls as `order` says; the pull's id, whose one `.pullEnded` follows, or why it was not opened.
    func pullItem(_ order: ItemPullOrder, _ completion: @escaping @Sendable (Result<ItemPullID, WireError>) -> Void)
    /// Cancels a pull this side opened; its `.pullEnded` follows.
    func cancelPull(_ id: ItemPullID)
    /// The pull of representation `representation` of item `item` of the far side's offer `token`, landing as
    /// `landing` says, as this end's item sink builds it.
    func order(
        token: Data, item: UInt32, representation: UInt32, byteCeiling: UInt64, landing: ItemLanding
    ) throws(WireError) -> ItemPullOrder
}
