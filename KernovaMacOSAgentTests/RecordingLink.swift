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
        var ceilings: [UInt64] = []
        var pullsOpened = 0
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
    /// The `byte_ceiling` of each pull ordered, in order.
    var ceilings: [UInt64] { calls.withLock(\.ceilings) }

    func offerItems(_ offer: ItemOffer, _ completion: @escaping @Sendable (WireError?) -> Void) {
        calls.withLock { $0.offers.append(offer) }
        changed.notify()
        completion(nil)
    }

    func withdrawOffer(_ token: Data, code: ErrorCode) {
        changed.notify()
    }

    func releaseOffer(_ token: Data) {
        changed.notify()
    }

    func refuseOffer(_ token: Data, _ error: WireError) {
        changed.notify()
    }

    func readItem(_ token: Data, item: UInt32, _ completion: @escaping @Sendable (OfferedItem?) -> Void) {
        completion(items.indices.contains(Int(item)) ? items[Int(item)] : nil)
    }

    func pullItem(
        _ order: ItemPullOrder, _ completion: @escaping @Sendable (Result<ItemPullID, WireError>) -> Void
    ) {
        let id = calls.withLock { calls in
            defer { calls.pullsOpened += 1 }
            return ItemPullID(
                generation: ConnectionGeneration(rawValue: 1),
                stream: StreamID(rawValue: UInt32(3 + 2 * calls.pullsOpened)))
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
        return try sink.order(
            token: token, item: item, representation: representation, byteCeiling: byteCeiling, landing: landing,
            budget: budget)
    }
}
