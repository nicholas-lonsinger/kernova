import Foundation
import KernovaAgentCore
import KernovaClipboardItems
import KernovaFileTree
import KernovaItemTransfer
import KernovaSynchronization
import KernovaTestSupport
import KernovaWire

/// The calls a connection is asked to make, each completed at once: offers open, and each item read is
/// `items`' entry. A pull is ordered through `sink` and opened, or with no sink refused `WRITE_FAILED`.
final class RecordingLink: ClipboardItemLink {
    private struct Calls {
        var offers: [ItemOffer] = []
        var withdrawals: [Data] = []
        var releases: [Data] = []
        var refusals: [(token: Data, code: ErrorCode)] = []
        var ceilings: [UInt64] = []
        var orders: [ItemPullOrder] = []
        var opened: [ItemPullID] = []
        var pulls: [(order: ItemPullOrder, id: ItemPullID)] = []
    }

    private let calls = Locked(Calls())
    private let items: [OfferedItem]
    private let sink: ItemSinkAdapter<POSIXTreeFileSystem>?
    let changed = AsyncGate()

    init(items: [OfferedItem] = [], sink: ItemSinkAdapter<POSIXTreeFileSystem>? = nil) {
        self.items = items
        self.sink = sink
    }

    var offers: [ItemOffer] { calls.withLock(\.offers) }
    var withdrawals: [Data] { calls.withLock(\.withdrawals) }
    var releases: [Data] { calls.withLock(\.releases) }
    var refusals: [(token: Data, code: ErrorCode)] { calls.withLock(\.refusals) }
    /// The `byte_ceiling` of each pull ordered, in order.
    var ceilings: [UInt64] { calls.withLock(\.ceilings) }
    /// Each pull ordered, in order.
    var orders: [ItemPullOrder] { calls.withLock(\.orders) }
    /// The id of each pull opened, in order.
    var opened: [ItemPullID] { calls.withLock(\.opened) }
    /// Each pull opened, with its order.
    var pulls: [(order: ItemPullOrder, id: ItemPullID)] { calls.withLock(\.pulls) }

    func offerItems(_ offer: ItemOffer, _ completion: @escaping @Sendable (WireError?) -> Void) {
        calls.withLock { $0.offers.append(offer) }
        changed.notify()
        completion(nil)
    }

    func withdrawOffer(_ token: Data, code: ErrorCode) {
        calls.withLock { $0.withdrawals.append(token) }
        changed.notify()
    }

    func releaseOffer(_ token: Data) {
        calls.withLock { $0.releases.append(token) }
        changed.notify()
    }

    func refuseOffer(_ token: Data, _ error: WireError) {
        calls.withLock { $0.refusals.append((token, error.code)) }
        changed.notify()
    }

    func readItem(_ token: Data, item: UInt32, _ completion: @escaping @Sendable (OfferedItem?) -> Void) {
        completion(items.indices.contains(Int(item)) ? items[Int(item)] : nil)
    }

    func pullItem(
        _ order: ItemPullOrder, _ completion: @escaping @Sendable (Result<ItemPullID, WireError>) -> Void
    ) {
        let id = calls.withLock { calls in
            let id = ItemPullID(
                generation: ConnectionGeneration(rawValue: 1),
                stream: StreamID(rawValue: UInt32(3 + 2 * calls.opened.count)))
            calls.opened.append(id)
            calls.pulls.append((order, id))
            return id
        }
        completion(.success(id))
        changed.notify()
    }

    func cancelPull(_ id: ItemPullID) {}

    func order(
        token: Data, item: UInt32, representation: UInt32, byteCeiling: UInt64, landing: ItemLanding,
        budget: ByteBudget?
    ) throws(WireError) -> ItemPullOrder {
        calls.withLock { $0.ceilings.append(byteCeiling) }
        guard let sink else { throw WireError(.writeFailed) }
        let order = try sink.order(
            token: token, item: item, representation: representation, byteCeiling: byteCeiling, landing: landing,
            budget: budget)
        calls.withLock { $0.orders.append(order) }
        return order
    }
}
