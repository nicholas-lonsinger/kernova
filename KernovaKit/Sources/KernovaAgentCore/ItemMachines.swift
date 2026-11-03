#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaWire

/// What a side serves of item transfer and the features that offer items over it.
public struct ItemFeatureAvailability: Sendable, Equatable {
    /// ITEM_TRANSFER: whether this side pulls and serves offered items; available only where item adapters
    /// serve them.
    public var itemTransfer: Availability<NoParams>
    /// CLIPBOARD.
    public var clipboard: Availability<NoParams>
    /// DROP.
    public var drop: Availability<NoParams>
    /// DRAG.
    public var drag: Availability<NoParams>

    /// Every item feature absent `NOT_IMPLEMENTED`.
    public static let notImplemented = ItemFeatureAvailability(
        itemTransfer: .absent(.notImplemented, debugDetail: ""), clipboard: .absent(.notImplemented, debugDetail: ""),
        drop: .absent(.notImplemented, debugDetail: ""), drag: .absent(.notImplemented, debugDetail: ""))

    /// Creates an availability.
    public init(
        itemTransfer: Availability<NoParams>, clipboard: Availability<NoParams>, drop: Availability<NoParams>,
        drag: Availability<NoParams>
    ) {
        self.itemTransfer = itemTransfer
        self.clipboard = clipboard
        self.drop = drop
        self.drag = drag
    }

    /// The features that offer items over ITEM_TRANSFER, each one of this availability's entries.
    public static let offering: Set<FeatureID> = [.clipboard, .drop, .drag]

    /// The entry of `feature`, one of `offering`; nil for any other feature, and setting one changes nothing.
    public subscript(offering feature: FeatureID) -> Availability<NoParams>? {
        get {
            switch feature {
            case .clipboard: clipboard
            case .drop: drop
            case .drag: drag
            default: nil
            }
        }
        set {
            guard let newValue else { return }
            switch feature {
            case .clipboard: clipboard = newValue
            case .drop: drop = newValue
            case .drag: drag = newValue
            default: break
            }
        }
    }

    /// What `role` advertises of this: a system peer serves no feature that offers items, which needs a GUI
    /// session (TN2083: a daemon cannot use the window server), so it advertises CLIPBOARD, DROP and DRAG
    /// absent `NOT_SERVED_BY_ROLE`; and a feature that offers items is absent wherever ITEM_TRANSFER, which
    /// moves their bytes, is.
    func advertised(by role: PeerRole) -> ItemFeatureAvailability {
        var advertised = self
        let offering: Availability<NoParams>?
        switch (role, itemTransfer) {
        case (.systemPeer, _): offering = .absent(.notServedByRole, debugDetail: "")
        case (_, .absent(let reason, let detail)): offering = .absent(reason, debugDetail: detail)
        case (_, .available): offering = nil
        }
        if let offering {
            advertised.clipboard = offering
            advertised.drop = offering
            advertised.drag = offering
        }
        return advertised
    }
}

/// One endpoint's item machines: ITEM_TRANSFER, which moves offered items' bytes, and CLIPBOARD, DROP and
/// DRAG, which offer items over it.
struct ItemMachines: Sendable {
    private(set) var transfer: ItemTransfer
    private var clipboard: ClipboardOffers
    private var drop: DropOffers
    private var drag: DragOffers

    /// The machines of one connection for a side of `role` serving `availability`.
    init(_ availability: ItemFeatureAvailability, role: PeerRole, generation: ConnectionGeneration) {
        let advertised = availability.advertised(by: role)
        transfer = ItemTransfer(availability: advertised.itemTransfer, generation: generation)
        clipboard = ClipboardOffers(availability: advertised.clipboard)
        drop = DropOffers(availability: advertised.drop)
        drag = DragOffers(availability: advertised.drag, generation: generation)
    }

    /// Each machine's advert, by feature.
    var adverts: [(FeatureID, LocalAdvert)] {
        [
            (.itemTransfer, transfer.localAdvert), (.clipboard, clipboard.localAdvert), (.drop, drop.localAdvert),
            (.drag, drag.localAdvert),
        ]
    }

    /// The soonest deadline any machine sets.
    func nextDeadline(on clock: JudgedClock) -> CoreInstant? {
        [
            transfer.nextDeadline(on: clock), clipboard.nextDeadline(on: clock), drop.nextDeadline(on: clock),
            drag.nextDeadline(on: clock),
        ].compactMap { $0 }.min()
    }

    /// Tells every machine of a connection-wide event.
    mutating func notify(_ event: FeatureEvent, connection: inout Connection, now: CoreInstant) {
        transfer.handle(event, connection: &connection, now: now)
        clipboard.handle(event, connection: &connection, now: now)
        drop.handle(event, connection: &connection, now: now)
        drag.handle(event, connection: &connection, now: now)
    }

    /// Hands a stream event to the machine owning its kind.
    mutating func deliver(_ event: FeatureEvent, to owner: KindOwner, connection: inout Connection, now: CoreInstant) {
        switch owner {
        case .itemTransfer:
            transfer.handle(event, connection: &connection, now: now)
        case .itemOffer:
            transfer.handleOffer(event, connection: &connection)
            drag.offersChanged(transfer, connection: &connection)
        case .dragTake:
            if case .opened(let stream, let body) = event {
                drag.opened(stream, body: body, items: transfer, connection: &connection)
            } else {
                drag.handle(event, connection: &connection, now: now)
                drag.offersChanged(transfer, connection: &connection)
            }
        case .power, .update, .logs, .testBulk:
            break
        }
    }

    /// Offers `offer` on `feature`'s offer kind for this side's role; nil when opened, or why not:
    /// `UNSUPPORTED_KIND` for a feature that offers no items, or one this role does not offer.
    mutating func offer(_ offer: ItemOffer, feature: FeatureID, connection: inout Connection) -> WireError? {
        switch feature {
        case .clipboard: clipboard.offer(offer, items: &transfer, connection: &connection)
        case .drop: drop.offer(offer, items: &transfer, connection: &connection)
        case .drag: drag.offer(offer, items: &transfer, connection: &connection)
        default: WireError(.unsupportedKind, debugDetail: "\(feature) offers no items")
        }
    }

    /// Withdraws this side's offer of `token`.
    mutating func withdraw(_ token: Data, connection: inout Connection) {
        transfer.withdraw(token, connection: &connection)
    }

    /// Releases the far side's offer of `token`.
    mutating func release(_ token: Data, connection: inout Connection) {
        transfer.release(token, connection: &connection)
    }

    /// Host: takes the peer's open drag offer of `token`.
    mutating func takeDrag(_ token: Data, connection: inout Connection) -> Result<DragTakeID, WireError> {
        drag.take(token, items: transfer, connection: &connection)
    }

    /// Host: tells the peer `control` on a take this side opened.
    mutating func control(_ id: DragTakeID, _ control: DragTakeControl, connection: inout Connection) {
        drag.control(id, control, connection: &connection)
    }

    /// Host: calls off a take this side opened.
    mutating func cancelTake(_ id: DragTakeID, connection: inout Connection) {
        drag.cancel(id, connection: &connection)
    }

    /// Peer: answers a take of its drag.
    mutating func answer(_ id: DragTakeID, _ answer: DragTakeAnswer, connection: inout Connection) {
        drag.answer(id, answer, connection: &connection)
    }

    /// Pulls one representation of the far side's open offer, as `order` says.
    mutating func pull(_ order: ItemPullOrder, connection: inout Connection) -> Result<ItemPullID, WireError> {
        transfer.pull(order, connection: &connection)
    }

    /// Whether a committed pull's publish report is still owed.
    var hasLandingsInFlight: Bool { transfer.hasLandingsInFlight }

    /// Cancels a pull this side opened.
    mutating func cancel(_ id: ItemPullID, connection: inout Connection) {
        transfer.cancel(id, connection: &connection)
    }

    /// Handles the item source's answer or the item sink's report.
    mutating func handle(_ input: ItemTransferInput, connection: inout Connection, now: CoreInstant) {
        transfer.handle(input: input, connection: &connection, now: now)
    }

    /// Everything the machines emitted since the last call, each in its emission order.
    mutating func takeOutputs() -> (items: [ItemTransferOutput], drag: [DragTakeEvent], diagnostics: [Diagnostic]) {
        let items = transfer.takeOutputs()
        let drag = drag.takeOutputs()
        return (items.outputs, drag.events, items.diagnostics + drag.diagnostics)
    }
}
