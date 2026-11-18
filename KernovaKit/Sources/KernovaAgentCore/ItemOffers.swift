#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaWire

/// Every open offer on one connection, this side's and the far side's, of whichever feature's offer kind, and
/// the item-set message stream that carries each: an `ItemSetHeader` OPEN, one `Item` MESSAGE per item, then
/// the opener's END. An offer is in the registry exactly while its stream is open; the opener's RESET withdraws
/// it, and the receiver's END or RESET releases it. This side's tokens and the far side's are separate
/// namespaces: a pull of this side's offer is looked up among this side's, and one this side opens among the far
/// side's.
///
/// The host's requests that the peer offer its clipboard ride the same stream grammar, of no items, on
/// CLIPBOARD_OFFER_REQUEST, and are held apart from the offers: no pull or read finds one, and a request's
/// events are its own (``ItemTransferEvent/offerRequested(token:)``,
/// ``ItemTransferEvent/requestEnded(_:token:_:)``). A token names at most one offer or request of a side.
///
/// The far side's items are held as their encoded bytes, each an exact-size copy, and decoded one at a time
/// when a pull or the owner names it, so what they hold is what is charged: an offer's OPEN reserves
/// `remoteItemOverhead` per item its header counts, and each item its bytes as it arrives. An offer the
/// budget cannot hold is reset `TOO_LARGE`.
package struct ItemOfferRegistry: Sendable {
    /// The most the far side's open offers may hold at once: their reserved overhead and their items' bytes.
    package static let remoteItemByteLimit = 16 << 20
    /// What one held item costs beyond its bytes, at most: its array slot, its `Data` storage object, and
    /// allocation rounding.
    package static let remoteItemOverhead = 128

    struct Local: Sendable {
        var stream: StreamID
        var feature: FeatureID
        var offer: ItemOffer
        var encoded: [Data]
        var sent = 0
        var ended = false
    }

    struct Remote: Sendable {
        var stream: StreamID
        var header: ItemSetHeaderValue
        /// Each item's encoded bytes, as received.
        var items: [Data] = []
        /// What this offer holds against `remoteItemByteLimit`.
        var charged: Int
        var complete = false
    }

    /// The host's request that the peer offer its clipboard, held past its stream's close while the peer's offer
    /// answering it arrives, until it ends as ``ItemCommand/requestClipboardOffer(_:token:)`` says.
    struct LocalRequest: Sendable {
        var stream: StreamID
        var token: Data
        /// How its stream closed, once it did.
        var closed: StreamClosure?
        /// The peer's clipboard offer naming it in `ItemSetHeader.request`, once that offer's OPEN arrived.
        var answer: Answer?
    }

    /// The peer's offer answering a request of the host's.
    enum Answer: Sendable {
        /// Its OPEN arrived on this stream, and it has not arrived whole.
        case arriving(StreamID)
        case whole
        /// Its stream closed before it arrived whole.
        case ended(StreamClosure)
    }

    /// The host's request to this side.
    struct RemoteRequest: Sendable {
        var stream: StreamID
        var token: Data
        /// Its opener's END arrived.
        var complete = false
    }

    private var local: [Local] = []
    private var remote: [Remote] = []
    private var localRequests: [LocalRequest] = []
    private var remoteRequests: [RemoteRequest] = []
    private var remoteCharged = 0

    package init() {}

    /// Whether `body` is an item-set offer's OPEN body: an `ItemSetHeader` with a 16-byte token.
    package static let isValidHeader: @Sendable (Data) -> Bool = { body in
        (try? Kernova_V2_ItemSetHeader(serializedBytes: body))?.token.count == 16
    }

    /// The tokens of this side's open offers.
    package var localTokens: [Data] { local.map(\.offer.token) }

    /// The tokens of this side's open offers of `feature`.
    package func localTokens(of feature: FeatureID) -> [Data] {
        local.filter { $0.feature == feature }.map(\.offer.token)
    }

    /// The feature of this side's open offer of `token`; nil when none is open.
    package func localFeature(_ token: Data) -> FeatureID? {
        local.first { $0.offer.token == token }?.feature
    }

    /// The far side's open offer of `token`, held whole: its feature and its items, decoded now; nil while none
    /// is open or it has not arrived whole.
    func remoteOffer(_ token: Data) -> (feature: FeatureID, items: [OfferedItem])? {
        guard let entry = remote.first(where: { $0.header.token == token }), entry.complete else { return nil }
        let items = entry.items.compactMap { try? OfferedItem(serializedBytes: $0) }
        guard items.count == entry.items.count else { return nil }
        return (entry.header.feature, items)
    }

    /// The tokens of the far side's open offers.
    package var remoteTokens: [Data] { remote.map(\.header.token) }

    /// The tokens of the far side's open offers of `feature`, whole or still arriving.
    func remoteTokens(of feature: FeatureID) -> [Data] {
        remote.filter { $0.header.feature == feature }.map(\.header.token)
    }

    #if DEBUG
    /// What the far side's open offers hold against `remoteItemByteLimit`, and the bytes their items hold.
    package var remoteHoldingForTesting: (charged: Int, itemBytes: Int, items: Int) {
        (
            remoteCharged, remote.reduce(0) { $0 + $1.items.reduce(0) { $0 + $1.count } },
            remote.reduce(0) { $0 + $1.header.count }
        )
    }
    #endif

    /// Item `index` of the far side's open offer of `token`, decoded now; nil when none is held.
    func remoteItem(_ token: Data, _ index: Int) -> OfferedItem? {
        guard let entry = remote.first(where: { $0.header.token == token }), index < entry.items.count else {
            return nil
        }
        return try? OfferedItem(serializedBytes: entry.items[index])
    }

    /// The representation a pull of this side's offer names, and the offer's feature, or the code refusing it.
    func localRepresentation(_ request: PullRequest) -> Result<(FeatureID, Representation), WireError> {
        guard let entry = local.first(where: { $0.offer.token == request.token }) else {
            return .failure(WireError(.itemOfferStale))
        }
        return Self.representation(request, in: entry.offer.items).map { (entry.feature, $0) }
    }

    /// The representation a pull of the far side's offer names, among the items received so far, and the
    /// offer's feature.
    func remoteRepresentation(_ request: PullRequest) -> Result<(FeatureID, Representation), WireError> {
        guard let entry = remote.first(where: { $0.header.token == request.token }) else {
            return .failure(WireError(.itemOfferStale))
        }
        guard let item = remoteItem(request.token, Int(request.item)) else {
            return .failure(WireError(.itemRepresentationUnavailable))
        }
        return Self.representation(request, of: item).map { (entry.header.feature, $0) }
    }

    private static func representation(_ request: PullRequest, in items: [OfferedItem]) -> Result<
        Representation, WireError
    > {
        guard request.item < items.count else { return .failure(WireError(.itemRepresentationUnavailable)) }
        return representation(request, of: items[Int(request.item)])
    }

    private static func representation(_ request: PullRequest, of item: OfferedItem) -> Result<
        Representation, WireError
    > {
        guard request.representation < item.representations.count else {
            return .failure(WireError(.itemRepresentationUnavailable))
        }
        let representation = item.representations[Int(request.representation)]
        switch representation.storage {
        case .inline, .file, .folder: return .success(representation)
        case .unspecified, .UNRECOGNIZED: return .failure(WireError(.itemRepresentationUnavailable))
        }
    }

    // MARK: A drag's items

    /// Gives this side's whole, empty DRAG offer of `token` its drag's `items`, as its take lists them; false
    /// when no such offer is open.
    mutating func carryLocal(_ token: Data, items: [OfferedItem]) -> Bool {
        guard let index = local.firstIndex(where: { $0.offer.token == token }), local[index].feature == .drag,
            local[index].ended, local[index].offer.items.isEmpty
        else { return false }
        local[index].offer.items = items
        return true
    }

    /// Gives the far side's whole, empty DRAG offer of `token` its drag's `items`, as its take listed them,
    /// charging them as received items; the code refusing it when no such offer is open or the budget cannot
    /// hold them.
    mutating func carryRemote(_ token: Data, items: [OfferedItem]) -> WireError? {
        guard let index = remote.firstIndex(where: { $0.header.token == token }), remote[index].header.feature == .drag,
            remote[index].complete, remote[index].items.isEmpty
        else { return WireError(.itemOfferStale, debugDetail: "no whole, empty drag offer of this token is open") }
        let encoded = items.map(\.encoded)
        let cost = encoded.reduce(items.count * Self.remoteItemOverhead) { $0 + $1.count }
        guard cost <= Self.remoteItemByteLimit - remoteCharged else {
            return WireError(.tooLarge, limit: UInt64(Self.remoteItemByteLimit))
        }
        remote[index].items = encoded
        remote[index].header.count = items.count
        remote[index].charged += cost
        remoteCharged += cost
        return nil
    }

    // MARK: This side's offers

    /// Opens a stream of `kind`, an item-set offer kind, offering `offer`, and sends its items as credit
    /// allows; nil when opened.
    mutating func offer(_ offer: ItemOffer, kind: StreamKind, connection: inout Connection) -> WireError? {
        guard let descriptor = connection.descriptor(for: kind), descriptor.owner == .itemOffer,
            let feature = descriptor.feature
        else { return WireError(.unsupportedKind, debugDetail: "\(kind) is no item-set offer kind") }
        if let refusal = connection.openRefusal(kind) { return refusal }
        guard isFreshLocalToken(offer.token) else {
            return WireError(.internal, debugDetail: "an offer token is 16 bytes no open offer or request holds")
        }
        guard offer.items.allSatisfy(Self.isNamedByContract) else {
            return WireError(.internal, debugDetail: "a representation's name breaks Representation.name's contract")
        }
        let encoded = offer.items.map(\.encoded)
        var header = Kernova_V2_ItemSetHeader()
        header.concealed = offer.concealed
        header.count = UInt32(clamping: offer.items.count)
        header.token = offer.token
        header.request = offer.request
        let body = header.encoded
        if let oversize = (encoded + [body]).first(where: { $0.count > WireConstants.maxControlPayload }) {
            return WireError(
                .tooLarge, limit: UInt64(WireConstants.maxControlPayload), debugDetail: "\(oversize.count) bytes")
        }
        let stream = connection.open(kind, body: body)
        guard stream != .session else { return WireError(.internal) }
        local.append(Local(stream: stream, feature: feature, offer: offer, encoded: encoded))
        pump(stream, &connection)
        return nil
    }

    /// Host: opens a CLIPBOARD_OFFER_REQUEST of `token`, asking the peer to offer its clipboard, and ENDs it at
    /// once; nil when opened.
    mutating func request(_ token: Data, connection: inout Connection) -> WireError? {
        if let refusal = connection.openRefusal(.clipboardOfferRequest) { return refusal }
        guard isFreshLocalToken(token) else {
            return WireError(.internal, debugDetail: "a request token is 16 bytes no open offer or request holds")
        }
        var header = Kernova_V2_ItemSetHeader()
        header.token = token
        let stream = connection.open(.clipboardOfferRequest, body: header.encoded)
        guard stream != .session else { return WireError(.internal) }
        localRequests.append(LocalRequest(stream: stream, token: token))
        if connection.canQueue(on: stream) { connection.end(stream, body: Data()) }
        return nil
    }

    /// Whether `token` is 16 bytes no open offer or request of this side holds.
    private func isFreshLocalToken(_ token: Data) -> Bool {
        token.count == 16 && !local.contains { $0.offer.token == token }
            && !localRequests.contains { $0.token == token }
    }

    /// The stream of this side's offer or request of `token`.
    private func localStream(_ token: Data) -> StreamID? {
        local.first { $0.offer.token == token }?.stream ?? localRequests.first { $0.token == token }?.stream
    }

    /// The stream of the far side's offer or request of `token`, and whether its opener's END arrived.
    private func remoteStream(_ token: Data) -> (stream: StreamID, complete: Bool)? {
        if let entry = remote.first(where: { $0.header.token == token }) { return (entry.stream, entry.complete) }
        return remoteRequests.first { $0.token == token }.map { ($0.stream, $0.complete) }
    }

    /// Resets this side's offer or request of `token` with `code`.
    mutating func withdraw(_ token: Data, code: ErrorCode, connection: inout Connection) {
        guard let stream = localStream(token), connection.canReset(stream) else { return }
        connection.reset(stream, WireError(code))
    }

    /// Ends the far side's offer or request of `token` from this side: END with `endBody` once it is whole,
    /// RESET CANCELLED before.
    mutating func release(_ token: Data, endBody: Data, connection: inout Connection) {
        guard let entry = remoteStream(token) else { return }
        if entry.complete, connection.canQueue(on: entry.stream) {
            connection.end(entry.stream, body: endBody)
        } else if connection.canReset(entry.stream) {
            connection.reset(entry.stream, WireError(.cancelled))
        }
    }

    /// Resets the far side's offer or request of `token` with `error`.
    mutating func refuse(_ token: Data, _ error: WireError, connection: inout Connection) {
        guard let stream = remoteStream(token)?.stream, connection.canReset(stream) else { return }
        connection.reset(stream, error)
    }

    private mutating func pump(_ stream: StreamID, _ connection: inout Connection) {
        guard let index = local.firstIndex(where: { $0.stream == stream }), !local[index].ended else { return }
        while local[index].sent < local[index].encoded.count {
            let message = local[index].encoded[local[index].sent]
            guard connection.canSendMessage(message.count, on: stream) else { return }
            connection.send(message: message, on: stream)
            local[index].sent += 1
        }
        guard connection.canQueue(on: stream) else { return }
        local[index].ended = true
        connection.end(stream, body: Data())
    }

    // MARK: Stream events

    /// Handles an event on an offer stream, appending what the owner hears.
    mutating func handle(_ event: FeatureEvent, connection: inout Connection, events: inout [ItemTransferOutput]) {
        switch event {
        case .opened(let stream, let body):
            received(stream, body, &connection)
        case .message(let stream, let message):
            item(stream, message, &connection)
        case .remoteEnded(let stream, _):
            if let index = remoteRequests.firstIndex(where: { $0.stream == stream }) {
                remoteRequests[index].complete = true
                events.append(.event(.offerRequested(token: remoteRequests[index].token)))
            } else if let index = remote.firstIndex(where: { $0.stream == stream }) {
                guard remote[index].items.count == remote[index].header.count else {
                    return refuse(
                        stream, .streamProtocolError, "END after \(remote[index].items.count) items", &connection)
                }
                remote[index].complete = true
                events.append(.event(.offerReceived(remote[index].header)))
                answerSettled(on: stream, .whole, events: &events)
            } else if let entry = local.first(where: { $0.stream == stream }), !entry.ended,
                connection.canReset(stream)
            {
                // The receiver released the offer before it was whole.
                connection.reset(stream, WireError(.cancelled))
            }
        case .writable(let stream):
            pump(stream, &connection)
        case .streamClosed(let stream, let closure):
            if let index = localRequests.firstIndex(where: { $0.stream == stream }) {
                localRequests[index].closed = closure
                end(localRequestAt: index, events: &events)
            } else if let index = remoteRequests.firstIndex(where: { $0.stream == stream }) {
                let request = remoteRequests.remove(at: index)
                events.append(.event(.requestEnded(.remote, token: request.token, closure)))
            } else if let index = local.firstIndex(where: { $0.stream == stream }) {
                let entry = local.remove(at: index)
                events.append(.event(.offerEnded(entry.feature, .local, token: entry.offer.token, closure)))
            } else if let index = remote.firstIndex(where: { $0.stream == stream }) {
                let header = remote[index].header
                events.append(.event(.offerEnded(header.feature, .remote, token: header.token, closure)))
                remoteCharged -= remote[index].charged
                remote.remove(at: index)
            }
            answerSettled(on: stream, .ended(closure), events: &events)
        case .data, .sessionEstablished, .usabilityChanged, .policyChanged, .slotFreed, .deadline:
            break
        }
    }

    /// Ends the host's request at `index` once its stream closed, unless the peer released it while the offer
    /// answering it is still arriving: as its stream closed, or as that offer's did when it ended before whole.
    private mutating func end(localRequestAt index: Int, events: inout [ItemTransferOutput]) {
        let request = localRequests[index]
        guard let closure = request.closed else { return }
        let ending: StreamClosure
        switch (closure, request.answer) {
        case (.completed, .arriving?): return
        case (.completed, .ended(let answerClosure)?): ending = answerClosure
        default: ending = closure
        }
        localRequests.remove(at: index)
        events.append(.event(.requestEnded(.local, token: request.token, ending)))
    }

    /// The offer arriving on `stream`, if it answers a request of the host's, arrived whole or ended before it was.
    private mutating func answerSettled(on stream: StreamID, _ answer: Answer, events: inout [ItemTransferOutput]) {
        guard
            let index = localRequests.firstIndex(where: {
                if case .arriving(stream)? = $0.answer { true } else { false }
            })
        else { return }
        localRequests[index].answer = answer
        end(localRequestAt: index, events: &events)
    }

    private mutating func received(_ stream: StreamID, _ body: Data, _ connection: inout Connection) {
        // The connection admits only a kind the table lists, and routes only an item-set offer kind here.
        guard let descriptor = connection.descriptor(of: stream), let feature = descriptor.feature else { return }
        let wire = (try? Kernova_V2_ItemSetHeader(serializedBytes: body)) ?? Kernova_V2_ItemSetHeader()
        // The first clipboard offer naming a request of the host's answers it, whether or not it is refused here.
        if feature == .clipboard,
            let index = localRequests.firstIndex(where: { $0.token == wire.request && $0.answer == nil })
        {
            localRequests[index].answer = .arriving(stream)
        }
        guard remoteStream(wire.token) == nil else {
            return refuse(stream, .streamProtocolError, "a token the far side already offers", &connection)
        }
        guard descriptor.kind != .clipboardOfferRequest else {
            guard wire.count == 0 else {
                return refuse(stream, .malformedMessage, "a CLIPBOARD_OFFER_REQUEST that lists items", &connection)
            }
            return remoteRequests.append(RemoteRequest(stream: stream, token: wire.token))
        }
        let header = ItemSetHeaderValue(wire, feature: feature)
        // A drag's items come with its take (`carry`), never on its offer.
        guard feature != .drag || header.count == 0 else {
            return refuse(stream, .malformedMessage, "a DRAG_OFFER that lists items", &connection)
        }
        // The header's claim is reserved whole, so no count can outrun the budget.
        guard header.count <= (Self.remoteItemByteLimit - remoteCharged) / Self.remoteItemOverhead else {
            return connection.reset(stream, WireError(.tooLarge, limit: UInt64(Self.remoteItemByteLimit)))
        }
        let reserved = header.count * Self.remoteItemOverhead
        remoteCharged += reserved
        remote.append(Remote(stream: stream, header: header, charged: reserved))
    }

    private mutating func item(_ stream: StreamID, _ message: Data, _ connection: inout Connection) {
        guard let index = remote.firstIndex(where: { $0.stream == stream }) else { return }
        guard remote[index].items.count < remote[index].header.count else {
            return refuse(stream, .streamProtocolError, "more items than the header's count", &connection)
        }
        guard remoteCharged + message.count <= Self.remoteItemByteLimit else {
            return connection.reset(stream, WireError(.tooLarge, limit: UInt64(Self.remoteItemByteLimit)))
        }
        guard let item = try? OfferedItem(serializedBytes: message) else {
            return refuse(stream, .malformedMessage, "an Item that does not decode", &connection)
        }
        guard Self.isNamedByContract(item) else {
            return refuse(stream, .malformedMessage, "an Item whose names break their contract", &connection)
        }
        // A copy, so the item holds exactly its bytes rather than the received buffer it was cut from.
        let held = message.withUnsafeBytes { Data($0) }
        remote[index].items.append(held)
        remote[index].charged += held.count
        remoteCharged += held.count
    }

    /// Whether every representation of `item` is named as `Representation.name` requires: a FILE or FOLDER by
    /// one path component, an INLINE not at all. The registry holds no other item, this side's or the far
    /// side's.
    static func isNamedByContract(_ item: OfferedItem) -> Bool {
        item.representations.allSatisfy { representation in
            switch representation.storage {
            case .file, .folder: PathComponent.isValid(representation.name)
            case .inline: representation.name.isEmpty
            case .unspecified, .UNRECOGNIZED: true
            }
        }
    }

    private func refuse(_ stream: StreamID, _ code: ErrorCode, _ detail: String, _ connection: inout Connection) {
        guard connection.canReset(stream) else { return }
        connection.diagnose(.remoteViolation(detail))
        connection.reset(stream, WireError(code, debugDetail: detail))
    }
}
