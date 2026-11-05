import Foundation
import KernovaAgentCore
import KernovaSynchronization
import KernovaWire

/// The CLIPBOARD item calls of the one connection an end's clipboard runs over: the host's to the feature's
/// console peer, a guest agent's to its host. Each completion runs once, on any queue; an answer comes before
/// any event the call caused.
public protocol ClipboardItemLink: Sendable {
    /// Offers `offer` on CLIPBOARD, withdrawing this side's previous clipboard offer unless it is a copy; nil
    /// once it opened, or why it did not.
    func offerItems(_ offer: ItemOffer, _ completion: @escaping @Sendable (WireError?) -> Void)
    /// Withdraws this side's offer of `token`, RESET with `code`.
    func withdrawOffer(_ token: Data, code: ErrorCode)
    /// Releases the far side's offer of `token`: this side pulls nothing more of it.
    func releaseOffer(_ token: Data)
    /// Refuses the far side's offer of `token` with `error`, so its opener hears why this side pulls nothing
    /// more of it.
    func refuseOffer(_ token: Data, _ error: WireError)
    /// Item `item` of the far side's open offer of `token`, decoded; nil when no such item is held.
    func readItem(_ token: Data, item: UInt32, _ completion: @escaping @Sendable (OfferedItem?) -> Void)
    /// Pulls as `order` says; the pull's id, whose one `.pullEnded` follows, or why it was not opened.
    func pullItem(_ order: ItemPullOrder, _ completion: @escaping @Sendable (Result<ItemPullID, WireError>) -> Void)
    /// Cancels a pull this side opened; its `.pullEnded` follows.
    func cancelPull(_ id: ItemPullID)
    /// The pull of representation `representation` of item `item` of the far side's offer `token`, landing as
    /// `landing` says and charging what lands to `budget`, as this end's item sink builds it.
    func order(
        token: Data, item: UInt32, representation: UInt32, byteCeiling: UInt64, landing: ItemLanding,
        budget: ByteBudget?
    ) throws(WireError) -> ItemPullOrder
}
