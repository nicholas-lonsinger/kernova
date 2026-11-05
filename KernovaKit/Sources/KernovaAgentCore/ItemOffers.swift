#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaWire

/// Every open offer on one connection, this side's and the far side's, of whichever feature's offer kind, and
/// the item-set message stream that carries each: an `ItemSetHeader` OPEN, one `Item` MESSAGE per item, then
/// the opener's END. An offer is in
/// the registry exactly while its stream is open; the opener's RESET withdraws it, and the receiver's END or
/// RESET releases it. This side's tokens and the far side's are separate namespaces: a pull of this side's
/// offer is looked up among this side's, and one this side opens among the far side's.
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

    private var local: [Local] = []
    private var remote: [Remote] = []
    private var remoteCharged = 0

    package init() {}

    /// Whether `body` is an item-set offer's OPEN body: an `ItemSetHeader` with a 16-byte token.
    package static let isValidHeader: @Sendable (Data) -> Bool = { body in
        (try? Kernova_V2_ItemSetHeader(serializedBytes: body))?.token.count == 16
    }

    /// The tokens of this side's open offers.
    package var localTokens: [Data] { local.map(\.offer.token) }

    /// The tokens of this side's open offers of `feature`, its copies (``ItemOffer/copy``) left out.
    package func localTokens(of feature: FeatureID) -> [Data] {
        local.filter { $0.feature == feature && $0.offer.copy == .notACopy }.map(\.offer.token)
    }

    /// The feature of this side's open offer of `token`; nil when none is open.
    package func localFeature(_ token: Data) -> FeatureID? {
        local.first { $0.offer.token == token }?.feature
    }

    /// The feature of the far side's open offer of `token`; nil when none is open.
    package func remoteFeature(_ token: Data) -> FeatureID? {
        remote.first { $0.header.token == token }?.header.feature
    }

    /// The tokens of the far side's open offers.
    package var remoteTokens: [Data] { remote.map(\.header.token) }

    /// What the far side's open offers hold against `remoteItemByteLimit`, and the bytes their items hold.
    package var remoteHolding: (charged: Int, itemBytes: Int, items: Int) {
        (
            remoteCharged, remote.reduce(0) { $0 + $1.items.reduce(0) { $0 + $1.count } },
            remote.reduce(0) { $0 + $1.header.count }
        )
    }

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

    // MARK: This side's offers

    /// Opens a stream of `kind`, an item-set offer kind, offering `offer`, and sends its items as credit
    /// allows; nil when opened.
    mutating func offer(_ offer: ItemOffer, kind: StreamKind, connection: inout Connection) -> WireError? {
        guard let descriptor = connection.descriptor(for: kind), descriptor.owner == .itemOffer,
            let feature = descriptor.feature
        else { return WireError(.unsupportedKind, debugDetail: "\(kind) is no item-set offer kind") }
        if let refusal = connection.openRefusal(kind) { return refusal }
        guard offer.token.count == 16, !local.contains(where: { $0.offer.token == offer.token }) else {
            return WireError(.internal, debugDetail: "an offer token is 16 bytes no open offer holds")
        }
        guard offer.items.allSatisfy(Self.isNamedByContract) else {
            return WireError(.internal, debugDetail: "a representation's name breaks Representation.name's contract")
        }
        let encoded = offer.items.map(\.encoded)
        var header = Kernova_V2_ItemSetHeader()
        header.concealed = offer.concealed
        header.count = UInt32(clamping: offer.items.count)
        header.token = offer.token
        header.after = offer.after
        header.copy = offer.copy.wire
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

    /// Resets this side's offer of `token` with `code`.
    mutating func withdraw(_ token: Data, code: ErrorCode, connection: inout Connection) {
        guard let entry = local.first(where: { $0.offer.token == token }), connection.canReset(entry.stream) else {
            return
        }
        connection.reset(entry.stream, WireError(code))
    }

    /// Ends the far side's offer of `token` from this side: END with `endBody` once the set is whole, RESET
    /// CANCELLED before.
    mutating func release(_ token: Data, endBody: Data, connection: inout Connection) {
        guard let entry = remote.first(where: { $0.header.token == token }) else { return }
        if entry.complete, connection.canQueue(on: entry.stream) {
            connection.end(entry.stream, body: endBody)
        } else if connection.canReset(entry.stream) {
            connection.reset(entry.stream, WireError(.cancelled))
        }
    }

    /// Resets the far side's offer of `token` with `error`.
    mutating func refuse(_ token: Data, _ error: WireError, connection: inout Connection) {
        guard let entry = remote.first(where: { $0.header.token == token }), connection.canReset(entry.stream) else {
            return
        }
        connection.reset(entry.stream, error)
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
            if let index = remote.firstIndex(where: { $0.stream == stream }) {
                guard remote[index].items.count == remote[index].header.count else {
                    return refuse(
                        stream, .streamProtocolError, "END after \(remote[index].items.count) items", &connection)
                }
                remote[index].complete = true
                events.append(.event(.offerReceived(remote[index].header)))
            } else if let entry = local.first(where: { $0.stream == stream }), !entry.ended,
                connection.canReset(stream)
            {
                // The receiver released the offer before it was whole.
                connection.reset(stream, WireError(.cancelled))
            }
        case .writable(let stream):
            pump(stream, &connection)
        case .streamClosed(let stream, let closure):
            if let index = local.firstIndex(where: { $0.stream == stream }) {
                let entry = local.remove(at: index)
                events.append(.event(.offerEnded(entry.feature, .local, token: entry.offer.token, closure)))
            } else if let index = remote.firstIndex(where: { $0.stream == stream }) {
                let header = remote[index].header
                events.append(.event(.offerEnded(header.feature, .remote, token: header.token, closure)))
                remoteCharged -= remote[index].charged
                remote.remove(at: index)
            }
        case .data, .sessionEstablished, .usabilityChanged, .policyChanged, .slotFreed, .deadline:
            break
        }
    }

    private mutating func received(_ stream: StreamID, _ body: Data, _ connection: inout Connection) {
        // The connection admits only a kind the table lists, and routes only an item-set offer kind here.
        guard let feature = connection.descriptor(of: stream)?.feature else { return }
        let header = ItemSetHeaderValue(
            (try? Kernova_V2_ItemSetHeader(serializedBytes: body)) ?? Kernova_V2_ItemSetHeader(), feature: feature)
        guard !remote.contains(where: { $0.header.token == header.token }) else {
            return refuse(stream, .streamProtocolError, "a token the far side already offers", &connection)
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
    private static func isNamedByContract(_ item: OfferedItem) -> Bool {
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
