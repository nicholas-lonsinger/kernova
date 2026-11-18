#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaWire

/// One DRAG_TAKE: the connection it runs on and its stream, on either side.
public struct DragTakeID: Hashable, Sendable {
    /// The connection the take belongs to.
    public var generation: ConnectionGeneration
    /// The take's stream.
    public var stream: StreamID

    /// Creates a take id.
    public init(generation: ConnectionGeneration, stream: StreamID) {
        self.generation = generation
        self.stream = stream
    }
}

/// What the host tells the peer on a take: the drag's catcher shown or stood down, or the next drop on it
/// delivering the drag.
public enum DragTakeControl: Sendable, Equatable {
    /// The Mac drag session left the VM's display (`shown`), so the catcher shows again, or came back over it, so
    /// the catcher stands down and the drag is the guest's.
    case catcher(shown: Bool)
    /// A Mac destination takes the drag: the next drop on the catcher calls its promises in and sizes its items.
    case deliver
}

/// One step of the peer's hand-off on a take.
public enum DragTakeReport: Sendable, Equatable {
    /// The catcher is up under the pointer: once for the take and once for each `.catcher(shown: true)`.
    case armed
    /// The drag's items, read off the drag as the catcher sees it, once per take and before its first
    /// `.targeted`: they become the taken offer's items. The wire carries each in a MESSAGE of its own, and an
    /// item whose report does not fit one refuses the take `TOO_LARGE` instead. The host reports them once the
    /// last arrived, each having passed an offer's item's rules and ``DragItems/carried(_:)``'s, and resets the
    /// take otherwise.
    case listed([OfferedItem])
    /// The guest's drag manager entered the catcher with the taken drag: a release now drops on it.
    case targeted
    /// Answers `.deliver`: the next drop on the catcher delivers the drag.
    case delivering
    /// Answers `.deliver`: the drag is not on the catcher, and no drop delivers.
    case deliverRefused
    /// Answers each `.catcher(shown: false)`, in order: the catcher is down, so a release drops where the pointer
    /// is.
    case stoodDown
    /// The delivering drop called the drag's promises in: the name each took, one per promised item of the
    /// taken offer, in its order, which serves each promise from then on; each one path component. The host
    /// reports only names that pass ``DragItems/checkedNames(_:of:)``, and resets the take
    /// `MALFORMED_MESSAGE` for any others.
    case named([Data])
}

/// What the peer's owner says on a take: a step, which the take goes on after, or how it ended.
public enum DragTakeAnswer: Sendable, Equatable {
    /// A step of the hand-off.
    case report(DragTakeReport)
    /// The drag ended on the catcher. After `.report(.named)`, the drop delivered it, and `sizes` sizes each
    /// item of the taken offer, promised ones included, in its order, 0 where unknown; nil when the drop
    /// delivered nothing, and only then before `.report(.named)`. The taken offer stays open until the host
    /// releases it.
    case caught(sizes: [UInt64]?)
    /// The drag ended in the guest, its catcher stood down.
    case returned
    /// The drag stays the guest's: `DRAG_PRESS_OVER`, `DRAG_NOT_CURRENT`, …
    case refused(WireError)

    /// Whether the answer ends the take.
    var ends: Bool {
        if case .report = self { false } else { true }
    }
}

/// What a delivering drop delivered of a drag, by the index of each item in the taken offer.
public struct DragDelivery: Sendable, Equatable {
    /// The name each promised item took once called in.
    public var names: [Int: Data]
    /// The size estimate of each item, 0 where unknown.
    public var sizes: [Int: UInt64]

    /// Creates a delivery.
    public init(names: [Int: Data], sizes: [Int: UInt64]) {
        self.names = names
        self.sizes = sizes
    }
}

/// How a take the host opened ended.
public enum DragTakeResult: Sendable, Equatable {
    /// The drag ended on the catcher; `delivery` is what a delivering drop delivered, which passed
    /// ``DragItems/checkedNames(_:of:)`` and sized every item within ``DragItems/maxTotalEstimate``, or nil
    /// when it delivered nothing or sized another count of items. The taken offer stays open until this side
    /// releases it.
    case caught(DragDelivery?)
    /// The drag ended in the guest, its catcher stood down.
    case returned
    /// The peer kept the drag, and why.
    case refused(WireError)
    /// The stream closed without the peer's END.
    case closed(StreamClosure)
}

/// What the drag machine tells its owner.
public enum DragTakeEvent: Sendable, Equatable {
    /// Peer: the host takes this side's open drag offer of `token`; answer with `.dragTake`. A take of an
    /// offer that ends before this side ends the take is refused `DRAG_NOT_CURRENT` for it.
    case requested(DragTakeID, token: Data)
    /// Peer: the host's word on a take this side has not ended.
    case control(DragTakeID, DragTakeControl)
    /// Peer: a take this side had not ended is over: the host called it off, its offer ended and it was refused,
    /// its listing held an item whose report does not fit one MESSAGE and it was refused `TOO_LARGE`, or the
    /// connection ended. Once per asked take this side did not end.
    case cancelled(DragTakeID)
    /// Host: a step of the peer's hand-off on a take `takeDrag` opened.
    case report(DragTakeID, DragTakeReport)
    /// Host: a take `takeDrag` opened ended. Once per take.
    case ended(DragTakeID, DragTakeResult)
}

/// The one rule for which offers a take carries, and what a delivering drop may say of them.
public enum DragItems {
    /// The most a drag's size estimates may sum to: a byte count of one volume's files.
    public static let maxTotalEstimate = UInt64(Int64.max)

    /// The representation each of `items` is carried by, its first FILE or FOLDER one, with its index in the
    /// item, by item; nil unless every item has one and their estimates sum to at most ``maxTotalEstimate``.
    public static func carried(_ items: [OfferedItem]) -> [(index: UInt32, representation: Representation)]? {
        var carried: [(index: UInt32, representation: Representation)] = []
        var total: UInt64 = 0
        for item in items {
            guard let next = carriedRepresentation(of: item),
                let sum = adding(next.representation.sizeEstimate, to: total)
            else { return nil }
            carried.append(next)
            total = sum
        }
        return carried
    }

    /// The representation `item` is carried by, its first FILE or FOLDER one, with its index in the item; nil
    /// when it has none.
    static func carriedRepresentation(of item: OfferedItem) -> (index: UInt32, representation: Representation)? {
        guard let index = item.representations.firstIndex(where: { $0.storage == .file || $0.storage == .folder })
        else { return nil }
        return (UInt32(index), item.representations[index])
    }

    /// The key two names collide under: a destination's file system ignores case, and Swift's `String`
    /// equality already ignores Unicode normalization.
    public static func nameKey(_ name: Data) -> String {
        String(decoding: name, as: UTF8.self).lowercased()
    }

    /// `names`, one per promised item of `items` in order, by item index; nil unless the count matches, each is
    /// one path component, and none collides with another or with any unpromised item's name.
    public static func checkedNames(_ names: [Data], of items: [Representation]) -> [Int: Data]? {
        let promised = items.indices.filter { items[$0].promised }
        guard names.count == promised.count, names.allSatisfy(PathComponent.isValid) else { return nil }
        var keys = Set(items.indices.filter { !items[$0].promised }.map { nameKey(items[$0].name) })
        for name in names {
            guard keys.insert(nameKey(name)).inserted else { return nil }
        }
        return Dictionary(uniqueKeysWithValues: zip(promised, names))
    }

    /// `total` plus `estimate`, or nil past ``maxTotalEstimate``.
    static func adding(_ estimate: UInt64, to total: UInt64) -> UInt64? {
        let (sum, overflow) = total.addingReportingOverflow(estimate)
        guard !overflow, sum <= maxTotalEstimate else { return nil }
        return sum
    }
}

// MARK: - The features

/// CLIPBOARD on one connection: this side's pasteboard offers, on the clipboard offer kind its role opens.
/// This side keeps at most one open, and a new one supersedes every clipboard offer of either side's: once it
/// opens, it withdraws this side's previous one `ITEM_OFFER_REPLACED`, so a pull of it ends `ITEM_OFFER_STALE`,
/// and releases every one of the far side's this side holds. So a far-side offer that arrives while this side's is
/// still open was made before the far side saw this side's: the two crossed. The host's request that the peer
/// offer its clipboard is no offer, and withdraws none.
struct ClipboardOffers: Sendable {
    /// CLIPBOARD.
    static let feature = FeatureID.clipboard

    private let availability: Availability<NoParams>

    /// A machine advertising `availability`.
    init(availability: Availability<NoParams>) {
        self.availability = availability
    }

    /// The `ClipboardCapability` advert, or the absence.
    var localAdvert: LocalAdvert {
        LocalAdvert(version: 1, availability: Availability(availability) { _ in Data() })
    }

    /// Resets every clipboard offer once CLIPBOARD is not usable.
    mutating func handle(_ event: FeatureEvent, connection: inout Connection) {
        switch event {
        case .usabilityChanged, .policyChanged: connection.resetStreams(ofUnusable: Self.feature)
        default: break
        }
    }

    /// Offers `offer` and, once it opened, releases every clipboard offer of the far side's and withdraws this
    /// side's previous one; nil when opened, or why not, every offer standing as it did.
    func offer(_ offer: ItemOffer, items: inout ItemTransfer, connection: inout Connection)
        -> WireError?
    {
        let farSide = items.offers.remoteTokens(of: Self.feature)
        let previous = items.offers.localTokens(of: Self.feature)
        let kind: StreamKind = connection.role == .host ? .clipboardOfferByHost : .clipboardOfferByPeer
        if let refusal = items.offer(offer, kind: kind, connection: &connection) { return refusal }
        for token in farSide {
            items.release(token, connection: &connection)
        }
        for token in previous {
            items.withdraw(token, code: .itemOfferReplaced, connection: &connection)
        }
        return nil
    }

    /// Host: asks the peer to offer its clipboard, on CLIPBOARD_OFFER_REQUEST of `token`; nil when opened, or why
    /// not: `UNSUPPORTED_KIND` from a peer.
    func requestOffer(_ token: Data, items: inout ItemTransfer, connection: inout Connection) -> WireError? {
        items.requestClipboardOffer(token, connection: &connection)
    }
}

/// DROP on one connection: the host's offers of what was dropped onto the VM, any number at once. Only the
/// host opens a drop offer; a peer's open is refused `UNSUPPORTED_KIND`.
struct DropOffers: Sendable {
    /// DROP.
    static let feature = FeatureID.drop

    private let availability: Availability<NoParams>

    /// A machine advertising `availability`.
    init(availability: Availability<NoParams>) {
        self.availability = availability
    }

    /// The `DropCapability` advert, or the absence.
    var localAdvert: LocalAdvert {
        LocalAdvert(version: 1, availability: Availability(availability) { _ in Data() })
    }

    /// Resets every drop offer once DROP is not usable.
    mutating func handle(_ event: FeatureEvent, connection: inout Connection) {
        switch event {
        case .usabilityChanged, .policyChanged: connection.resetStreams(ofUnusable: Self.feature)
        default: break
        }
    }

    /// Offers `offer` on DROP_OFFER; nil when opened, or why not.
    func offer(_ offer: ItemOffer, items: inout ItemTransfer, connection: inout Connection) -> WireError? {
        items.offer(offer, kind: .dropOffer, connection: &connection)
    }
}

/// What a peer's END of a DROP offer says landed: how many of the offer's items it landed, skipping the rest.
public struct DropLanded: Sendable, Equatable {
    /// How many items landed.
    public var landed: Int

    /// Says `landed` items landed.
    public init(landed: Int) {
        self.landed = landed
    }

    /// What `endBody`, a peer's END body on DROP_OFFER, says landed; nil when it does not decode.
    public init?(endBody: Data) {
        guard let landed = try? Kernova_V2_DropLanded(serializedBytes: endBody) else { return nil }
        self.landed = Int(landed.landed)
    }

    /// The END body saying so.
    public var endBody: Data {
        var body = Kernova_V2_DropLanded()
        body.landed = UInt32(landed)
        return body.encoded
    }
}

/// DRAG on one connection: the peer's offers of drags in progress in the guest, and the host's takes of them.
/// Only a peer opens DRAG_OFFER and only the host DRAG_TAKE. A take runs both ways: the host sends
/// `DragTakeControl`s, the peer `DragTakeReport`s and then its END, which the host's END answers; the host's RESET
/// calls it off. A take is valid only while the drag offer it names is open, and each offer is taken at most once:
/// the peer refuses any other take `DRAG_NOT_CURRENT` itself, asks its owner about the rest, and refuses a take
/// whose offer ends before the owner ended it.
///
/// The peer's reports carry the drag's listing, its promises' names and its items' sizes one fact per MESSAGE, in
/// the order `DragTakeReport`'s schema gives. The host holds each report to where its take stands, and the
/// listing to the taken offer's budget, resetting the take on the first that breaks either.
struct DragOffers: Sendable {
    /// DRAG.
    static let feature = FeatureID.drag

    private struct Take: Sendable {
        /// How far the peer listed the drag's items.
        enum Listing: Sendable {
            case unlisted
            /// Host: `received` of the `expected` items arrived, their size estimates summing to `estimate`.
            case listing(expected: Int, received: Int, estimate: UInt64)
            /// All `count` items are listed.
            case listed(count: Int)
        }

        var id: DragTakeID
        var token: Data
        var listing = Listing.unlisted
        /// Host: the index of each promised item listed.
        var promised: [Int] = []
        /// Host: the promises' names that arrived, in order.
        var names: [Data] = []
        /// `STEP_NAMED` went out (peer) or passed its checks (host).
        var named = false
        /// Host: the items' sizes that arrived, in order, and their sum.
        var sizes: [UInt64] = []
        var sizeTotal: UInt64 = 0
    }

    /// A take's messages its stream has not taken yet, from `next` on, and the END that waits behind them: a
    /// stream holds one unsent message at a time.
    private struct Outbox: Sendable {
        var messages: [Data] = []
        var next = 0
        var end: Data?
    }

    private let availability: Availability<NoParams>
    private let generation: ConnectionGeneration
    /// Peer: takes its owner was asked about and has not ended.
    private var asked: [Take] = []
    /// Peer: the tokens of this side's drag offers a take claimed, while they stay open.
    private var taken: [Data] = []
    /// Host: the takes this side opened, until their streams close.
    private var opened: [Take] = []
    private var outbox: [StreamID: Outbox] = [:]
    private var events: [DragTakeEvent] = []
    private var diagnostics: [Diagnostic] = []

    /// A machine for one connection, advertising `availability`.
    init(availability: Availability<NoParams>, generation: ConnectionGeneration) {
        self.availability = availability
        self.generation = generation
    }

    /// The `DragCapability` advert, or the absence.
    var localAdvert: LocalAdvert {
        LocalAdvert(version: 1, availability: Availability(availability) { _ in Data() })
    }

    mutating func takeOutputs() -> (events: [DragTakeEvent], diagnostics: [Diagnostic]) {
        defer {
            events.removeAll()
            diagnostics.removeAll()
        }
        return (events, diagnostics)
    }

    /// Offers `offer`, a drag in progress, on DRAG_OFFER; nil when opened, or why not. It lists no items: its
    /// take does.
    func offer(_ offer: ItemOffer, items: inout ItemTransfer, connection: inout Connection) -> WireError? {
        if let refusal = connection.openRefusal(.dragOffer) { return refusal }
        guard offer.items.isEmpty else {
            return WireError(.internal, debugDetail: "a drag offer lists no items; its take does")
        }
        return items.offer(offer, kind: .dragOffer, connection: &connection)
    }

    /// Host: takes the far side's open drag offer of `token`, held whole; the take's reports and its one
    /// `.ended` follow.
    mutating func take(_ token: Data, items: ItemTransfer, connection: inout Connection) -> Result<
        DragTakeID, WireError
    > {
        guard items.offers.remoteOffer(token)?.feature == Self.feature else {
            return .failure(WireError(.itemOfferStale, debugDetail: "no drag offer of this token is open whole"))
        }
        if let refusal = connection.openRefusal(.dragTake) { return .failure(refusal) }
        var body = Kernova_V2_DragTake()
        body.token = token
        let stream = connection.open(.dragTake, body: body.encoded)
        guard stream != .session else { return .failure(WireError(.internal, debugDetail: "the open failed")) }
        let id = DragTakeID(generation: generation, stream: stream)
        opened.append(Take(id: id, token: token))
        return .success(id)
    }

    /// Host: tells the peer `control` on take `id`. Dropped once the take has ended.
    mutating func control(_ id: DragTakeID, _ control: DragTakeControl, connection: inout Connection) {
        guard id.generation == generation, opened.contains(where: { $0.id == id }) else { return }
        var message = Kernova_V2_DragTakeControl()
        switch control {
        case .catcher(let shown):
            var catcher = Kernova_V2_DragCatcher()
            catcher.shown = shown
            message.catcher = catcher
        case .deliver:
            message.deliver = Kernova_V2_DragDeliver()
        }
        send([message.encoded], on: id.stream, &connection)
    }

    /// Host: calls take `id` off, which the peer hears before any release. Dropped once the take has ended.
    mutating func cancel(_ id: DragTakeID, connection: inout Connection) {
        guard id.generation == generation, opened.contains(where: { $0.id == id }), connection.canReset(id.stream)
        else { return }
        connection.reset(id.stream, WireError(.cancelled, debugDetail: "the host called the take off"))
    }

    /// Peer: answers an asked take, as ``DragTakeAnswer`` and ``DragTakeReport`` say it must be answered. An
    /// answer to a take already ended is dropped.
    mutating func answer(
        _ id: DragTakeID, _ answer: DragTakeAnswer, items: inout ItemTransfer, connection: inout Connection
    ) {
        guard id.generation == generation, let index = asked.firstIndex(where: { $0.id == id }) else { return }
        let stream = id.stream
        switch answer {
        case .report(.listed(let offered)):
            list(offered, at: index, items: &items, connection: &connection)
        case .report(.targeted):
            guard case .listed = asked[index].listing else {
                return connection.misuse("a TARGETED before the drag's items are listed")
            }
            send([Self.report(.step(.targeted))], on: stream, &connection)
        case .report(.named(let names)):
            guard case .listed = asked[index].listing, !asked[index].named, names.allSatisfy(PathComponent.isValid)
            else { return connection.misuse("a STEP_NAMED before the listing, after another, or of a non-file name") }
            asked[index].named = true
            send(names.map { Self.report(.promiseName($0)) } + [Self.report(.step(.named))], on: stream, &connection)
        case .report(.armed):
            send([Self.report(.step(.armed))], on: stream, &connection)
        case .report(.delivering):
            send([Self.report(.step(.delivering))], on: stream, &connection)
        case .report(.deliverRefused):
            send([Self.report(.step(.deliverRefused))], on: stream, &connection)
        case .report(.stoodDown):
            send([Self.report(.step(.stoodDown))], on: stream, &connection)
        case .caught(let sizes):
            if let sizes {
                guard asked[index].named, case .listed(let count) = asked[index].listing, sizes.count == count else {
                    return connection.misuse("sizes for a take not named, or other than one per item")
                }
                send(sizes.map { Self.report(.size($0)) }, on: stream, &connection)
            }
            taken.append(asked.remove(at: index).token)
            end(stream, Self.outcome(.caught), &connection)
        case .returned:
            taken.append(asked.remove(at: index).token)
            end(stream, Self.outcome(.returned), &connection)
        case .refused(let error):
            asked.remove(at: index)
            refuse(stream, error, &connection)
        }
    }

    /// Peer: lists `offered`, the drag's items, on the asked take at `index`, giving them to its offer; a take
    /// with an item whose report does not fit one MESSAGE is refused `TOO_LARGE` instead.
    private mutating func list(
        _ offered: [OfferedItem], at index: Int, items: inout ItemTransfer, connection: inout Connection
    ) {
        guard case .unlisted = asked[index].listing, !offered.isEmpty else {
            return connection.misuse("a listing of no items, or a second listing")
        }
        let reports = offered.map { Self.report(.item($0)) }
        if let oversize = reports.firstIndex(where: { $0.count > WireConstants.maxControlPayload }) {
            let take = asked.remove(at: index)
            events.append(.cancelled(take.id))
            let detail = "the drag's item \(oversize) lists \(reports[oversize].count) bytes"
            let error = WireError(.tooLarge, limit: UInt64(WireConstants.maxControlPayload), debugDetail: detail)
            return refuse(take.id.stream, error, &connection)
        }
        guard items.carryLocal(asked[index].token, items: offered) else {
            return connection.misuse("a listing whose offer is no whole, empty drag offer")
        }
        asked[index].listing = .listed(count: offered.count)
        send([Self.report(.itemCount(UInt32(offered.count)))] + reports, on: asked[index].id.stream, &connection)
    }

    /// Resets every drag stream once DRAG is not usable.
    mutating func handle(_ event: FeatureEvent, connection: inout Connection) {
        switch event {
        case .usabilityChanged, .policyChanged:
            connection.resetStreams(ofUnusable: Self.feature)
        default:
            break
        }
    }

    /// Handles a DRAG_TAKE stream's event; a host's take listing the drag gives the taken offer its items in
    /// `items`.
    mutating func handleTake(_ event: FeatureEvent, items: inout ItemTransfer, connection: inout Connection) {
        switch event {
        case .message(let stream, let payload):
            message(payload, on: stream, items: &items, connection: &connection)
        case .writable(let stream):
            flush(stream, &connection)
        case .remoteEnded(let stream, _):
            // The host's END answers the peer's; what it had left to say no
            // longer reaches a take.
            guard opened.contains(where: { $0.id.stream == stream }), connection.canQueue(on: stream) else { return }
            outbox[stream] = nil
            connection.end(stream, body: Data())
        case .streamClosed(let stream, let closure):
            outbox[stream] = nil
            if let index = asked.firstIndex(where: { $0.id.stream == stream }) {
                events.append(.cancelled(asked.remove(at: index).id))
            }
            guard let index = opened.firstIndex(where: { $0.id.stream == stream }) else { return }
            let take = opened.remove(at: index)
            events.append(.ended(take.id, result(of: take, closure)))
        case .usabilityChanged, .policyChanged, .sessionEstablished, .opened, .data, .slotFreed, .deadline:
            break
        }
    }

    /// A message on a take: the host's control on one this side was asked about, or the peer's report on one this
    /// side opened. One that does not decode resets the take.
    private mutating func message(
        _ payload: Data, on stream: StreamID, items: inout ItemTransfer, connection: inout Connection
    ) {
        if let take = asked.first(where: { $0.id.stream == stream }) {
            guard let message = try? Kernova_V2_DragTakeControl(serializedBytes: payload) else {
                return resetTake(
                    stream, WireError(.malformedMessage, debugDetail: "a DragTakeControl that does not decode"),
                    &connection)
            }
            switch message.control {
            case .catcher(let catcher): events.append(.control(take.id, .catcher(shown: catcher.shown)))
            case .deliver: events.append(.control(take.id, .deliver))
            case nil: diagnostics.append(.remoteViolation("a DragTakeControl that sets no control"))
            }
        } else if let index = opened.firstIndex(where: { $0.id.stream == stream }) {
            guard let message = try? Kernova_V2_DragTakeReport(serializedBytes: payload) else {
                return resetTake(
                    stream, WireError(.malformedMessage, debugDetail: "a DragTakeReport that does not decode"),
                    &connection)
            }
            switch message.report {
            case .itemCount(let count): listing(Int(count), at: index, items: &items, connection: &connection)
            case .item(let item): listed(item, at: index, items: &items, connection: &connection)
            case .promiseName(let name): named(name, at: index, &connection)
            case .size(let size): sized(size, at: index, &connection)
            case .step(let step): stepped(step, at: index, items: items, connection: &connection)
            case nil: diagnostics.append(.remoteViolation("a DragTakeReport that reports nothing"))
            }
        }
    }

    /// Host: the peer begins listing the drag's `count` items on the take at `index`, which reserves them in its
    /// taken offer.
    private mutating func listing(
        _ count: Int, at index: Int, items: inout ItemTransfer, connection: inout Connection
    ) {
        let take = opened[index]
        guard case .unlisted = take.listing else {
            return resetTake(take.id.stream, Self.disorder("a second item_count"), &connection)
        }
        guard count >= 1 else {
            return resetTake(
                take.id.stream, WireError(.malformedMessage, debugDetail: "an item_count of 0"), &connection)
        }
        if let refusal = items.reserveCarried(take.token, count: count) {
            return resetTake(take.id.stream, refusal, &connection)
        }
        opened[index].listing = .listing(expected: count, received: 0, estimate: 0)
    }

    // This handler and the next two read the take in place rather than binding a copy of it: a copy alive
    // across an append to one of its arrays makes the append copy the whole array, once per report.

    /// Host: the drag's next item arrived on the take at `index`, and its taken offer holds it; the last reports
    /// them all.
    private mutating func listed(
        _ item: OfferedItem, at index: Int, items: inout ItemTransfer, connection: inout Connection
    ) {
        let (id, token) = (opened[index].id, opened[index].token)
        guard case .listing(let expected, let received, let estimate) = opened[index].listing else {
            return resetTake(id.stream, Self.disorder("an item outside the drag's listing"), &connection)
        }
        var carried: Representation?
        var total = estimate
        let refusal = items.appendCarried(token, item.encoded) { decoded in
            guard let representation = DragItems.carriedRepresentation(of: decoded)?.representation,
                let sum = DragItems.adding(representation.sizeEstimate, to: total)
            else { return nil }
            carried = representation
            total = sum
            return representation.promised ? ItemOfferRegistry.carriedNameReservation : 0
        }
        if let refusal { return resetTake(id.stream, refusal, &connection) }
        if carried?.promised == true { opened[index].promised.append(received) }
        guard received + 1 == expected else {
            opened[index].listing = .listing(expected: expected, received: received + 1, estimate: total)
            return
        }
        opened[index].listing = .listed(count: expected)
        guard let offer = items.offers.remoteOffer(token) else {
            return connection.misuse("a drag offer whose last listed item left it short of whole")
        }
        events.append(.report(id, .listed(offer.items)))
    }

    /// Host: a promise's name arrived on the take at `index`.
    private mutating func named(_ name: Data, at index: Int, _ connection: inout Connection) {
        let stream = opened[index].id.stream
        guard case .listed = opened[index].listing, !opened[index].named,
            opened[index].names.count < opened[index].promised.count
        else { return resetTake(stream, Self.disorder("a promise_name outside the drag's naming"), &connection) }
        guard PathComponent.isValid(name) else {
            return resetTake(
                stream, WireError(.malformedMessage, debugDetail: "a promise_name that is no path component"),
                &connection)
        }
        opened[index].names.append(name)
    }

    /// Host: an item's size arrived on the take at `index`.
    private mutating func sized(_ size: UInt64, at index: Int, _ connection: inout Connection) {
        let stream = opened[index].id.stream
        guard opened[index].named, case .listed(let count) = opened[index].listing, opened[index].sizes.count < count
        else { return resetTake(stream, Self.disorder("a size outside the drag's sizing"), &connection) }
        guard let total = DragItems.adding(size, to: opened[index].sizeTotal) else {
            return resetTake(
                stream, WireError(.malformedMessage, debugDetail: "sizes summing past 2^63-1"), &connection)
        }
        opened[index].sizes.append(size)
        opened[index].sizeTotal = total
    }

    /// Host: a step of the peer's hand-off arrived on the take at `index`.
    private mutating func stepped(
        _ step: Kernova_V2_DragTakeReport.Step, at index: Int, items: ItemTransfer, connection: inout Connection
    ) {
        let take = opened[index]
        switch step {
        case .targeted:
            guard case .listed = take.listing else {
                return resetTake(
                    take.id.stream, Self.disorder("a TARGETED before the drag's items are listed"), &connection)
            }
            events.append(.report(take.id, .targeted))
        case .named:
            guard case .listed = take.listing, !take.named else {
                return resetTake(
                    take.id.stream, Self.disorder("a STEP_NAMED before the drag's listing, or after another"),
                    &connection)
            }
            guard let carried = items.offers.remoteOffer(take.token).flatMap({ DragItems.carried($0.items) }),
                DragItems.checkedNames(take.names, of: carried.map(\.representation)) != nil
            else {
                return resetTake(
                    take.id.stream,
                    WireError(.malformedMessage, debugDetail: "a STEP_NAMED its taken offer cannot take"),
                    &connection)
            }
            opened[index].named = true
            events.append(.report(take.id, .named(take.names)))
        case .armed: events.append(.report(take.id, .armed))
        case .delivering: events.append(.report(take.id, .delivering))
        case .deliverRefused: events.append(.report(take.id, .deliverRefused))
        case .stoodDown: events.append(.report(take.id, .stoodDown))
        case .unspecified, .UNRECOGNIZED: break
        }
    }

    /// A report out of the take's order.
    private static func disorder(_ what: String) -> WireError {
        WireError(.streamProtocolError, debugDetail: what)
    }

    /// Resets the take on `stream` with `error`, for a message the take cannot take, diagnosed unless the taken
    /// offer refused it for its budget or its absence.
    private mutating func resetTake(_ stream: StreamID, _ error: WireError, _ connection: inout Connection) {
        if error.code != .tooLarge, error.code != .itemOfferStale {
            diagnostics.append(.remoteViolation(error.debugDetail))
        }
        if connection.canReset(stream) { connection.reset(stream, error) }
    }

    /// Queues `payloads` on `stream`, behind any message the stream has not taken yet. One over a MESSAGE is a
    /// misuse, so the outbox never holds a message the stream cannot take.
    private mutating func send(_ payloads: [Data], on stream: StreamID, _ connection: inout Connection) {
        guard payloads.allSatisfy({ $0.count <= WireConstants.maxControlPayload }) else {
            return connection.misuse("a DRAG_TAKE message over one MESSAGE")
        }
        outbox[stream, default: Outbox()].messages += payloads
        flush(stream, &connection)
    }

    /// ENDs `stream` with `body` once every message before it is queued.
    private mutating func end(_ stream: StreamID, _ body: Data, _ connection: inout Connection) {
        guard outbox[stream] != nil else {
            if connection.canQueue(on: stream) { connection.end(stream, body: body) }
            return
        }
        outbox[stream]?.end = body
    }

    /// Hands `stream` what its outbox holds, as far as it takes it.
    private mutating func flush(_ stream: StreamID, _ connection: inout Connection) {
        guard var waiting = outbox.removeValue(forKey: stream) else { return }
        while waiting.next < waiting.messages.count,
            connection.canSendMessage(waiting.messages[waiting.next].count, on: stream)
        {
            connection.send(message: waiting.messages[waiting.next], on: stream)
            waiting.next += 1
        }
        guard waiting.next == waiting.messages.count else {
            outbox[stream] = waiting
            return
        }
        if let body = waiting.end, connection.canQueue(on: stream) { connection.end(stream, body: body) }
    }

    /// Peer: the host opened a take of `body`'s token.
    mutating func opened(_ stream: StreamID, body: Data, items: ItemTransfer, connection: inout Connection) {
        let token = (try? Kernova_V2_DragTake(serializedBytes: body))?.token ?? Data()
        let id = DragTakeID(generation: generation, stream: stream)
        guard items.offers.localFeature(token) == .drag, !taken.contains(token),
            !asked.contains(where: { $0.token == token })
        else {
            return refuse(stream, WireError(.dragNotCurrent), &connection)
        }
        asked.append(Take(id: id, token: token))
        events.append(.requested(id, token: token))
    }

    /// The offer registry changed: a take of a drag offer no longer open is refused `DRAG_NOT_CURRENT`.
    mutating func offersChanged(_ items: ItemTransfer, connection: inout Connection) {
        let open = items.offers.localTokens
        taken.removeAll { !open.contains($0) }
        for take in asked where !open.contains(take.token) {
            refuse(take.id.stream, WireError(.dragNotCurrent), &connection)
            events.append(.cancelled(take.id))
        }
        asked.removeAll { !open.contains($0.token) }
    }

    /// ENDs a take REFUSED with `error`.
    private mutating func refuse(_ stream: StreamID, _ error: WireError, _ connection: inout Connection) {
        var outcome = Kernova_V2_DragTakeOutcome()
        outcome.kind = .refused
        outcome.error = error.proto
        end(stream, outcome.encoded, &connection)
    }

    /// One report, encoded.
    private static func report(_ report: Kernova_V2_DragTakeReport.OneOf_Report) -> Data {
        var message = Kernova_V2_DragTakeReport()
        message.report = report
        return message.encoded
    }

    /// An outcome of `kind`, encoded.
    private static func outcome(_ kind: Kernova_V2_DragTakeOutcome.Kind) -> Data {
        var outcome = Kernova_V2_DragTakeOutcome()
        outcome.kind = kind
        return outcome.encoded
    }

    /// Take `take`'s end: the peer's `DragTakeOutcome` when it ENDed, a CAUGHT delivered only after
    /// `STEP_NAMED` and one size per item of its taken offer; otherwise how the stream closed.
    private mutating func result(of take: Take, _ closure: StreamClosure) -> DragTakeResult {
        guard case .completed(let body) = closure else { return .closed(closure) }
        guard let outcome = try? Kernova_V2_DragTakeOutcome(serializedBytes: body) else {
            return .refused(WireError(.malformedMessage, debugDetail: "a DragTakeOutcome that does not decode"))
        }
        switch outcome.kind {
        case .caught:
            guard take.named else { return .caught(nil) }
            guard case .listed(let count) = take.listing, take.sizes.count == count else {
                diagnostics.append(.remoteViolation("a CAUGHT after sizing \(take.sizes.count) of the items"))
                return .caught(nil)
            }
            return .caught(
                DragDelivery(
                    names: Dictionary(uniqueKeysWithValues: zip(take.promised, take.names)),
                    sizes: Dictionary(uniqueKeysWithValues: zip(take.sizes.indices, take.sizes))))
        case .returned: return .returned
        case .refused, .unspecified, .UNRECOGNIZED:
            return .refused(outcome.hasError ? WireError(received: outcome.error) : WireError(.unspecified))
        }
    }
}
