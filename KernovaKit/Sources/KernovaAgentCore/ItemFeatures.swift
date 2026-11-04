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

/// The peer's answer to a take of its drag.
public enum DragTakeAnswer: Sendable, Equatable {
    /// The drag goes to the host; the offer stays open until the host releases it.
    case taken
    /// The drag stays the guest's: `DRAG_PRESS_OVER`, `DRAG_NOT_CURRENT`, …
    case refused(WireError)
}

/// How a take the host opened ended.
public enum DragTakeResult: Sendable, Equatable {
    /// The peer let the drag go; its offer stays open until this side releases it.
    case taken
    /// The peer kept the drag, and why.
    case refused(WireError)
    /// The stream closed without the peer's answer.
    case closed(StreamClosure)
}

/// What the drag machine tells its owner.
public enum DragTakeEvent: Sendable, Equatable {
    /// Peer: the host takes this side's open drag offer of `token`; answer with `.dragTake`. A take of an
    /// offer that ends first is refused `DRAG_NOT_CURRENT` without one.
    case requested(DragTakeID, token: Data)
    /// Host: a take `takeDrag` opened ended. Once per take.
    case ended(DragTakeID, DragTakeResult)
}

// MARK: - The features

/// CLIPBOARD on one connection: this side's pasteboard offers, on the clipboard offer kind its role opens.
/// This side keeps at most one open: a new offer withdraws the previous one first, `ITEM_OFFER_REPLACED`, so
/// the far side knows a newer one follows and a pull of the old one ends `ITEM_OFFER_STALE`. A copy
/// (``ItemOffer/copy``) is not one of them: it withdraws nothing, and nothing but its own end withdraws it.
public struct ClipboardOffers: FeatureMachine {
    /// CLIPBOARD.
    public static let feature = FeatureID.clipboard

    private let availability: Availability<NoParams>

    /// A machine advertising `availability`.
    public init(availability: Availability<NoParams>) {
        self.availability = availability
    }

    /// The `ClipboardCapability` advert, or the absence.
    public var localAdvert: LocalAdvert {
        LocalAdvert(version: 1, availability: Availability(availability) { _ in Data() })
    }

    /// The machine sets no deadlines.
    public func nextDeadline(on clock: JudgedClock) -> CoreInstant? { nil }

    /// Resets every clipboard offer once CLIPBOARD is not usable.
    public mutating func handle(_ event: FeatureEvent, connection: inout Connection, now: CoreInstant) {
        switch event {
        case .usabilityChanged, .policyChanged: connection.resetStreams(ofUnusable: Self.feature)
        default: break
        }
    }

    /// Withdraws this side's previous clipboard offer, then offers `offer`; nil when opened, or why not. A copy
    /// withdraws nothing.
    public func offer(_ offer: ItemOffer, items: inout ItemTransfer, connection: inout Connection)
        -> WireError?
    {
        for token in offer.copy ? [] : items.offers.localTokens(of: Self.feature) {
            items.withdraw(token, code: .itemOfferReplaced, connection: &connection)
        }
        let kind: StreamKind = connection.role == .host ? .clipboardOfferByHost : .clipboardOfferByPeer
        return items.offer(offer, kind: kind, connection: &connection)
    }
}

/// DROP on one connection: the host's offers of what was dropped onto the VM, any number at once. Only the
/// host opens a drop offer; a peer's open is refused `UNSUPPORTED_KIND`.
public struct DropOffers: FeatureMachine {
    /// DROP.
    public static let feature = FeatureID.drop

    private let availability: Availability<NoParams>

    /// A machine advertising `availability`.
    public init(availability: Availability<NoParams>) {
        self.availability = availability
    }

    /// The `DropCapability` advert, or the absence.
    public var localAdvert: LocalAdvert {
        LocalAdvert(version: 1, availability: Availability(availability) { _ in Data() })
    }

    /// The machine sets no deadlines.
    public func nextDeadline(on clock: JudgedClock) -> CoreInstant? { nil }

    /// Resets every drop offer once DROP is not usable.
    public mutating func handle(_ event: FeatureEvent, connection: inout Connection, now: CoreInstant) {
        switch event {
        case .usabilityChanged, .policyChanged: connection.resetStreams(ofUnusable: Self.feature)
        default: break
        }
    }

    /// Offers `offer` on DROP_OFFER; nil when opened, or why not.
    public func offer(_ offer: ItemOffer, items: inout ItemTransfer, connection: inout Connection) -> WireError? {
        items.offer(offer, kind: .dropOffer, connection: &connection)
    }
}

/// What a peer's END of a DROP offer says landed: the index of each of the offer's items it landed, ascending.
public struct DropLanded: Sendable, Equatable {
    /// The landed items' indexes.
    public var items: [Int]

    /// Says `items` landed.
    public init(items: [Int]) {
        self.items = items
    }

    /// What `endBody`, a peer's END body on DROP_OFFER, says landed; nil when it does not decode.
    public init?(endBody: Data) {
        guard let landed = try? Kernova_V2_DropLanded(serializedBytes: endBody) else { return nil }
        items = landed.items.map(Int.init)
    }

    /// The END body saying so.
    public var endBody: Data {
        var landed = Kernova_V2_DropLanded()
        landed.items = items.map { UInt32(clamping: $0) }
        return landed.encoded
    }
}

/// DRAG on one connection: the peer's offers of drags in progress in the guest, and the host's takes of them.
/// Only a peer opens DRAG_OFFER and only the host DRAG_TAKE. A take is valid only while the drag offer it
/// names is open, and each offer is taken at most once: the peer refuses any other take `DRAG_NOT_CURRENT`
/// itself, asks its owner about the rest, and refuses an asked take whose offer ends first.
public struct DragOffers: FeatureMachine {
    /// DRAG.
    public static let feature = FeatureID.drag

    private struct Take: Sendable {
        var id: DragTakeID
        var token: Data
    }

    private let availability: Availability<NoParams>
    private let generation: ConnectionGeneration
    /// Peer: takes its owner was asked about and has not answered.
    private var asked: [Take] = []
    /// Peer: the tokens of this side's drag offers a take claimed, while they stay open.
    private var taken: [Data] = []
    /// Host: the takes this side opened, until their streams close.
    private var opened: [Take] = []
    private var events: [DragTakeEvent] = []
    private var diagnostics: [Diagnostic] = []

    /// A machine for one connection, advertising `availability`.
    public init(availability: Availability<NoParams>, generation: ConnectionGeneration) {
        self.availability = availability
        self.generation = generation
    }

    /// The `DragCapability` advert, or the absence.
    public var localAdvert: LocalAdvert {
        LocalAdvert(version: 1, availability: Availability(availability) { _ in Data() })
    }

    /// The machine sets no deadlines.
    public func nextDeadline(on clock: JudgedClock) -> CoreInstant? { nil }

    mutating func takeOutputs() -> (events: [DragTakeEvent], diagnostics: [Diagnostic]) {
        defer {
            events.removeAll()
            diagnostics.removeAll()
        }
        return (events, diagnostics)
    }

    /// Offers `offer` on DRAG_OFFER; nil when opened, or why not.
    public func offer(_ offer: ItemOffer, items: inout ItemTransfer, connection: inout Connection) -> WireError? {
        items.offer(offer, kind: .dragOffer, connection: &connection)
    }

    /// Host: takes the far side's open drag offer of `token`; the take's one `.ended` follows.
    public mutating func take(_ token: Data, items: ItemTransfer, connection: inout Connection) -> Result<
        DragTakeID, WireError
    > {
        guard items.offers.remoteFeature(token) == .drag else {
            return .failure(WireError(.itemOfferStale, debugDetail: "no drag offer of this token is open"))
        }
        if let refusal = connection.openRefusal(.dragTake) { return .failure(refusal) }
        var body = Kernova_V2_DragTake()
        body.token = token
        let stream = connection.open(.dragTake, body: body.encoded)
        guard stream != .session, connection.canQueue(on: stream) else {
            return .failure(WireError(.internal, debugDetail: "the open failed"))
        }
        connection.end(stream, body: Data())
        let id = DragTakeID(generation: generation, stream: stream)
        opened.append(Take(id: id, token: token))
        return .success(id)
    }

    /// Peer: answers an asked take. An answer to a take already ended is dropped.
    public mutating func answer(_ id: DragTakeID, _ answer: DragTakeAnswer, connection: inout Connection) {
        guard id.generation == generation, let index = asked.firstIndex(where: { $0.id == id }) else { return }
        let take = asked.remove(at: index)
        switch answer {
        case .taken:
            taken.append(take.token)
            end(take.id.stream, nil, &connection)
        case .refused(let error):
            end(take.id.stream, error, &connection)
        }
    }

    /// Handles a DRAG_TAKE stream's event, and resets every drag stream once DRAG is not usable.
    public mutating func handle(_ event: FeatureEvent, connection: inout Connection, now: CoreInstant) {
        switch event {
        case .usabilityChanged, .policyChanged:
            connection.resetStreams(ofUnusable: Self.feature)
        case .streamClosed(let stream, let closure):
            asked.removeAll { $0.id.stream == stream }
            guard let index = opened.firstIndex(where: { $0.id.stream == stream }) else { return }
            events.append(.ended(opened.remove(at: index).id, Self.result(closure)))
        case .sessionEstablished, .opened, .message, .data, .remoteEnded, .writable, .slotFreed, .deadline:
            break
        }
    }

    /// Peer: the host opened a take of `body`'s token.
    mutating func opened(_ stream: StreamID, body: Data, items: ItemTransfer, connection: inout Connection) {
        let token = (try? Kernova_V2_DragTake(serializedBytes: body))?.token ?? Data()
        let id = DragTakeID(generation: generation, stream: stream)
        guard items.offers.localFeature(token) == .drag, !taken.contains(token),
            !asked.contains(where: { $0.token == token })
        else {
            return end(stream, WireError(.dragNotCurrent), &connection)
        }
        asked.append(Take(id: id, token: token))
        events.append(.requested(id, token: token))
    }

    /// The offer registry changed: a take of a drag offer no longer open is refused `DRAG_NOT_CURRENT`.
    mutating func offersChanged(_ items: ItemTransfer, connection: inout Connection) {
        let open = items.offers.localTokens
        taken.removeAll { !open.contains($0) }
        for take in asked where !open.contains(take.token) {
            end(take.id.stream, WireError(.dragNotCurrent), &connection)
        }
        asked.removeAll { !open.contains($0.token) }
    }

    /// ENDs a take with its outcome: TAKEN, or REFUSED with `error`.
    private func end(_ stream: StreamID, _ error: WireError?, _ connection: inout Connection) {
        guard connection.canQueue(on: stream) else { return }
        var outcome = Kernova_V2_DragTakeOutcome()
        outcome.kind = error == nil ? .taken : .refused
        if let error { outcome.error = error.proto }
        connection.end(stream, body: outcome.encoded)
    }

    /// The peer's `DragTakeOutcome` when it ENDed; otherwise how the stream closed.
    private static func result(_ closure: StreamClosure) -> DragTakeResult {
        guard case .completed(let body) = closure else { return .closed(closure) }
        guard let outcome = try? Kernova_V2_DragTakeOutcome(serializedBytes: body) else {
            return .refused(WireError(.malformedMessage, debugDetail: "a DragTakeOutcome that does not decode"))
        }
        switch outcome.kind {
        case .taken: return .taken
        case .refused, .unspecified, .UNRECOGNIZED:
            return .refused(outcome.hasError ? WireError(received: outcome.error) : WireError(.unspecified))
        }
    }
}
