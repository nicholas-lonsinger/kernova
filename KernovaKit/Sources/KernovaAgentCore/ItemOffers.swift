#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaWire

/// Every open offer on one connection, this side's and the far side's, by token, and the item-set message
/// stream that carries each: an `ItemSetHeader` OPEN, one `Item` MESSAGE per item, then the opener's END. An
/// offer is in the registry exactly while its stream is open; the opener's RESET withdraws it, and the
/// receiver's END or RESET releases it.
package struct ItemOfferRegistry: Sendable {
    /// The most `Item` bytes the far side's open offers hold at once; an offer that would pass it is reset
    /// `TOO_LARGE`.
    package static let remoteItemByteLimit = 16 << 20

    struct Local: Sendable {
        var stream: StreamID
        var offer: ItemOffer
        var encoded: [Data]
        var sent = 0
        var ended = false
    }

    struct Remote: Sendable {
        var stream: StreamID
        var offer: ItemOffer
        var count: Int
        var bytes = 0
        var complete = false
    }

    private var local: [Local] = []
    private var remote: [Remote] = []
    private var remoteBytes = 0

    package init() {}

    /// Whether `body` is an item-set offer's OPEN body: an `ItemSetHeader` with a 16-byte token.
    package static let isValidHeader: @Sendable (Data) -> Bool = { body in
        (try? Kernova_V2_ItemSetHeader(serializedBytes: body))?.token.count == 16
    }

    /// The tokens of this side's open offers.
    package var localTokens: [Data] { local.map(\.offer.token) }

    /// The representation a pull of this side's offer names, or the code refusing it.
    func localRepresentation(_ request: PullRequest) -> Result<Representation, WireError> {
        guard let offer = local.first(where: { $0.offer.token == request.token })?.offer else {
            return .failure(WireError(.itemOfferStale))
        }
        return Self.representation(request, in: offer.items)
    }

    /// The representation a pull of the far side's offer names, among the items received so far.
    func remoteRepresentation(_ request: PullRequest) -> Result<Representation, WireError> {
        guard let offer = remote.first(where: { $0.offer.token == request.token })?.offer else {
            return .failure(WireError(.itemOfferStale))
        }
        return Self.representation(request, in: offer.items)
    }

    private static func representation(_ request: PullRequest, in items: [OfferedItem]) -> Result<
        Representation, WireError
    > {
        guard request.item < items.count, request.representation < items[Int(request.item)].representations.count
        else { return .failure(WireError(.itemRepresentationUnavailable)) }
        let representation = items[Int(request.item)].representations[Int(request.representation)]
        switch representation.storage {
        case .inline, .file, .folder: return .success(representation)
        case .unspecified, .UNRECOGNIZED: return .failure(WireError(.itemRepresentationUnavailable))
        }
    }

    // MARK: This side's offers

    /// Opens a stream of `kind` offering `offer`, and sends its items as credit allows; nil when opened.
    mutating func offer(_ offer: ItemOffer, kind: StreamKind, connection: inout Connection) -> WireError? {
        guard offer.token.count == 16, !local.contains(where: { $0.offer.token == offer.token }) else {
            return WireError(.internal, debugDetail: "an offer token is 16 bytes no open offer holds")
        }
        let encoded = offer.items.map(\.encoded)
        var header = Kernova_V2_ItemSetHeader()
        header.concealed = offer.concealed
        header.transient = offer.transient
        header.count = UInt32(clamping: offer.items.count)
        header.token = offer.token
        let body = header.encoded
        if let oversize = (encoded + [body]).first(where: { $0.count > WireConstants.maxControlPayload }) {
            return WireError(
                .tooLarge, limit: UInt64(WireConstants.maxControlPayload), debugDetail: "\(oversize.count) bytes")
        }
        if let refusal = connection.openRefusal(kind) { return refusal }
        let stream = connection.open(kind, body: body)
        guard stream != .session else { return WireError(.internal) }
        local.append(Local(stream: stream, offer: offer, encoded: encoded))
        pump(stream, &connection)
        return nil
    }

    /// Resets this side's offer of `token` CANCELLED.
    mutating func withdraw(_ token: Data, connection: inout Connection) {
        guard let entry = local.first(where: { $0.offer.token == token }), connection.canReset(entry.stream) else {
            return
        }
        connection.reset(entry.stream, WireError(.cancelled))
    }

    /// Ends the far side's offer of `token` from this side: END once the set is whole, RESET CANCELLED before.
    mutating func release(_ token: Data, connection: inout Connection) {
        guard let entry = remote.first(where: { $0.offer.token == token }) else { return }
        if entry.complete, connection.canQueue(on: entry.stream) {
            connection.end(entry.stream, body: Data())
        } else if connection.canReset(entry.stream) {
            connection.reset(entry.stream, WireError(.cancelled))
        }
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
                guard remote[index].offer.items.count == remote[index].count else {
                    return refuse(
                        stream, .streamProtocolError, "END after \(remote[index].offer.items.count) items", &connection)
                }
                remote[index].complete = true
                events.append(.event(.offerReceived(remote[index].offer)))
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
                events.append(.event(.offerEnded(token: local[index].offer.token, closure)))
                local.remove(at: index)
            } else if let index = remote.firstIndex(where: { $0.stream == stream }) {
                events.append(.event(.offerEnded(token: remote[index].offer.token, closure)))
                remoteBytes -= remote[index].bytes
                remote.remove(at: index)
            }
        case .data, .sessionEstablished, .usabilityChanged, .policyChanged, .slotFreed, .deadline:
            break
        }
    }

    private mutating func received(_ stream: StreamID, _ body: Data, _ connection: inout Connection) {
        let header = (try? Kernova_V2_ItemSetHeader(serializedBytes: body)) ?? Kernova_V2_ItemSetHeader()
        guard !remote.contains(where: { $0.offer.token == header.token }) else {
            return connection.reset(stream, WireError(.streamProtocolError, debugDetail: "a token already open"))
        }
        let offer = ItemOffer(token: header.token, concealed: header.concealed, transient: header.transient, items: [])
        remote.append(Remote(stream: stream, offer: offer, count: Int(header.count)))
    }

    private mutating func item(_ stream: StreamID, _ message: Data, _ connection: inout Connection) {
        guard let index = remote.firstIndex(where: { $0.stream == stream }) else { return }
        guard remote[index].offer.items.count < remote[index].count else {
            return refuse(stream, .streamProtocolError, "more items than the header's count", &connection)
        }
        guard remoteBytes + message.count <= Self.remoteItemByteLimit else {
            return connection.reset(stream, WireError(.tooLarge, limit: UInt64(Self.remoteItemByteLimit)))
        }
        guard let item = try? OfferedItem(serializedBytes: message) else {
            return refuse(stream, .malformedMessage, "an Item that does not decode", &connection)
        }
        remote[index].offer.items.append(item)
        remote[index].bytes += message.count
        remoteBytes += message.count
    }

    private func refuse(_ stream: StreamID, _ code: ErrorCode, _ detail: String, _ connection: inout Connection) {
        guard connection.canReset(stream) else { return }
        connection.diagnose(.remoteViolation(detail))
        connection.reset(stream, WireError(code, debugDetail: detail))
    }
}
