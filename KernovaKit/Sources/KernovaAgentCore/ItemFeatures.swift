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
    /// A Mac destination takes the drag: the next drop on the catcher calls its promises in and sizes its
    /// folders.
    case deliver
}

/// One step of the peer's hand-off on a take.
public enum DragTakeReport: Sendable, Equatable {
    /// The catcher is up under the pointer: once for the take and once for each `.catcher(shown: true)`.
    case armed
    /// The guest's drag manager entered the catcher with the taken drag: a release now drops on it.
    case targeted
    /// Answers `.deliver`: the next drop on the catcher delivers the drag.
    case delivering
    /// Answers `.deliver`: the drag is not on the catcher, and no drop delivers.
    case deliverRefused
    /// Answers each `.catcher(shown: false)`, in order: the catcher is down, so a release drops where the pointer
    /// is.
    case stoodDown
}

/// What the peer's owner says on a take: a step, which the take goes on after, or how it ended.
public enum DragTakeAnswer: Sendable, Equatable {
    /// A step of the hand-off.
    case report(DragTakeReport)
    /// The drag ended on the catcher; `reoffer` is the offer that carries it on when a delivering drop re-offered
    /// it, which this side opened after the take and before this answer. The taken offer stays open until the
    /// host releases it.
    case caught(reoffer: Data?)
    /// The drag ended in the guest, its catcher stood down.
    case returned
    /// The drag stays the guest's: `DRAG_PRESS_OVER`, `DRAG_NOT_CURRENT`, …
    case refused(WireError)

    /// Whether the answer ends the take.
    var ends: Bool {
        if case .report = self { false } else { true }
    }
}

/// How a take the host opened ended.
public enum DragTakeResult: Sendable, Equatable {
    /// The drag ended on the catcher; `reoffer`, when one carries it on, is a DRAG offer the peer opened after the
    /// take, held whole. The taken offer and `reoffer` stay open until this side releases them.
    case caught(reoffer: Data?)
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
    /// or the connection ended. Once per asked take this side did not end.
    case cancelled(DragTakeID)
    /// Host: a step of the peer's hand-off on a take `takeDrag` opened.
    case report(DragTakeID, DragTakeReport)
    /// Host: a take `takeDrag` opened ended. Once per take. A CAUGHT naming a reoffer ends once that offer has
    /// arrived whole, after its `.offerReceived`, whatever order the two streams' frames arrive in; one naming any
    /// other offer ends CAUGHT with no reoffer, as does one called off or whose taken offer ends while its reoffer
    /// has not opened.
    case ended(DragTakeID, DragTakeResult)
}

// MARK: - The features

/// CLIPBOARD on one connection: this side's pasteboard offers, on the clipboard offer kind its role opens.
/// This side keeps at most one open: a new offer withdraws the previous one first, so a pull of the old one
/// ends `ITEM_OFFER_STALE`.
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

    /// Withdraws this side's previous clipboard offer, then offers `offer`; nil when opened, or why not.
    public func offer(_ offer: ItemOffer, items: inout ItemTransfer, connection: inout Connection)
        -> WireError?
    {
        for token in items.offers.localTokens(of: Self.feature) {
            items.withdraw(token, connection: &connection)
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
/// Only a peer opens DRAG_OFFER and only the host DRAG_TAKE. A take runs both ways: the host sends
/// `DragTakeControl`s, the peer `DragTakeReport`s and then its END, which the host's END answers; the host's RESET
/// calls it off. A take is valid only while the drag offer it names is open, and each offer is taken at most once:
/// the peer refuses any other take `DRAG_NOT_CURRENT` itself, asks its owner about the rest, and refuses a take
/// whose offer ends before the owner ended it.
public struct DragOffers: FeatureMachine {
    /// DRAG.
    public static let feature = FeatureID.drag

    private struct Take: Sendable {
        var id: DragTakeID
        var token: Data
        /// Host: the highest stream id the peer had opened when this side opened the take, which any offer the
        /// peer opens after it is above.
        var mark: UInt32 = 0
    }

    /// Host: a take the peer ended CAUGHT naming `reoffer`, until that offer has arrived whole.
    private struct Arrival: Sendable {
        var take: Take
        var reoffer: Data
        /// The reoffer was open, so its absence now means it ended.
        var seen = false
    }

    private let availability: Availability<NoParams>
    private let generation: ConnectionGeneration
    /// Peer: takes its owner was asked about and has not ended.
    private var asked: [Take] = []
    /// Peer: the tokens of this side's drag offers a take claimed, while they stay open.
    private var taken: [Data] = []
    /// Host: the takes this side opened, until their streams close.
    private var opened: [Take] = []
    /// Host: the takes whose CAUGHT names a reoffer not yet whole.
    private var arrivals: [Arrival] = []
    /// Host: the reoffers ended takes carried on in, while they stay open.
    private var adopted: [Data] = []
    /// Each take's messages a stream did not take yet, and the END that waits
    /// behind them: a stream holds one unsent message at a time.
    private var outbox: [StreamID: (messages: [Data], end: Data?)] = [:]
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

    /// Host: takes the far side's open drag offer of `token`; the take's reports and its one `.ended` follow.
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
        guard stream != .session else { return .failure(WireError(.internal, debugDetail: "the open failed")) }
        let id = DragTakeID(generation: generation, stream: stream)
        opened.append(Take(id: id, token: token, mark: connection.highestRemoteOpened))
        return .success(id)
    }

    /// Host: tells the peer `control` on take `id`. Dropped once the take has ended.
    public mutating func control(_ id: DragTakeID, _ control: DragTakeControl, connection: inout Connection) {
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
        send(message.encoded, on: id.stream, &connection)
    }

    /// Host: calls take `id` off, which the peer hears before any release; one the peer already ended CAUGHT
    /// stops waiting for its reoffer and ends CAUGHT with none. Dropped once the take has ended.
    public mutating func cancel(_ id: DragTakeID, connection: inout Connection) {
        guard id.generation == generation else { return }
        if let index = arrivals.firstIndex(where: { $0.take.id == id }) {
            arrivals.remove(at: index)
            return events.append(.ended(id, .caught(reoffer: nil)))
        }
        guard opened.contains(where: { $0.id == id }), connection.canReset(id.stream) else { return }
        connection.reset(id.stream, WireError(.cancelled, debugDetail: "the host called the take off"))
    }

    /// Peer: answers an asked take. An answer to a take already ended is dropped.
    public mutating func answer(_ id: DragTakeID, _ answer: DragTakeAnswer, connection: inout Connection) {
        guard id.generation == generation, let index = asked.firstIndex(where: { $0.id == id }) else { return }
        guard answer.ends else {
            guard case .report(let step) = answer else { return }
            var report = Kernova_V2_DragTakeReport()
            report.step = Self.step(step)
            return send(report.encoded, on: id.stream, &connection)
        }
        let take = asked.remove(at: index)
        var outcome = Kernova_V2_DragTakeOutcome()
        switch answer {
        case .caught(let reoffer):
            taken.append(take.token)
            outcome.kind = .caught
            if let reoffer { outcome.reoffer = reoffer }
        case .returned:
            taken.append(take.token)
            outcome.kind = .returned
        case .refused(let error):
            outcome.kind = .refused
            outcome.error = error.proto
        case .report:
            return
        }
        end(take.id.stream, outcome.encoded, &connection)
    }

    /// Handles a DRAG_TAKE stream's event, and resets every drag stream once DRAG is not usable.
    public mutating func handle(_ event: FeatureEvent, connection: inout Connection, now: CoreInstant) {
        switch event {
        case .usabilityChanged, .policyChanged:
            connection.resetStreams(ofUnusable: Self.feature)
        case .message(let stream, let payload):
            message(payload, on: stream, connection: &connection)
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
            let result = Self.result(closure)
            guard case .caught(let reoffer?) = result else { return events.append(.ended(take.id, result)) }
            guard !adopted.contains(reoffer), !arrivals.contains(where: { $0.reoffer == reoffer }) else {
                return dropReoffer(of: take.id, "names a reoffer another take carries on in")
            }
            // `offersChanged`, which follows every take event, ends it once the reoffer is whole.
            arrivals.append(Arrival(take: take, reoffer: reoffer))
        case .sessionEstablished, .opened, .data, .slotFreed, .deadline:
            break
        }
    }

    /// A message on a take: the host's control on one this side was asked about, or the peer's report on one this
    /// side opened. One that does not decode resets the take.
    private mutating func message(_ payload: Data, on stream: StreamID, connection: inout Connection) {
        if let take = asked.first(where: { $0.id.stream == stream }) {
            guard let message = try? Kernova_V2_DragTakeControl(serializedBytes: payload) else {
                return malformed("a DragTakeControl", on: stream, &connection)
            }
            switch message.control {
            case .catcher(let catcher): events.append(.control(take.id, .catcher(shown: catcher.shown)))
            case .deliver: events.append(.control(take.id, .deliver))
            case nil: diagnostics.append(.remoteViolation("a DragTakeControl that sets no control"))
            }
        } else if let take = opened.first(where: { $0.id.stream == stream }) {
            guard let message = try? Kernova_V2_DragTakeReport(serializedBytes: payload) else {
                return malformed("a DragTakeReport", on: stream, &connection)
            }
            switch message.step {
            case .armed: events.append(.report(take.id, .armed))
            case .targeted: events.append(.report(take.id, .targeted))
            case .delivering: events.append(.report(take.id, .delivering))
            case .deliverRefused: events.append(.report(take.id, .deliverRefused))
            case .stoodDown: events.append(.report(take.id, .stoodDown))
            case .unspecified, .UNRECOGNIZED: break
            }
        }
    }

    private mutating func malformed(_ what: String, on stream: StreamID, _ connection: inout Connection) {
        diagnostics.append(.remoteViolation("\(what) that does not decode"))
        if connection.canReset(stream) { connection.reset(stream, WireError(.malformedMessage)) }
    }

    /// Queues `payload` on `stream`, behind any message the stream has not
    /// taken yet.
    private mutating func send(_ payload: Data, on stream: StreamID, _ connection: inout Connection) {
        outbox[stream, default: ([], nil)].messages.append(payload)
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
        guard var waiting = outbox[stream] else { return }
        while let first = waiting.messages.first, connection.canSendMessage(first.count, on: stream) {
            connection.send(message: first, on: stream)
            waiting.messages.removeFirst()
        }
        guard waiting.messages.isEmpty else {
            outbox[stream] = waiting
            return
        }
        outbox[stream] = nil
        if let body = waiting.end, connection.canQueue(on: stream) { connection.end(stream, body: body) }
    }

    /// Peer: the host opened a take of `body`'s token.
    mutating func opened(_ stream: StreamID, body: Data, items: ItemTransfer, connection: inout Connection) {
        let token = (try? Kernova_V2_DragTake(serializedBytes: body))?.token ?? Data()
        let id = DragTakeID(generation: generation, stream: stream)
        guard items.offers.localFeature(token) == .drag, !taken.contains(token),
            !asked.contains(where: { $0.token == token })
        else {
            return refuse(stream, &connection)
        }
        asked.append(Take(id: id, token: token))
        events.append(.requested(id, token: token))
    }

    /// The offer registry or a take changed. Peer: a take of a drag offer no longer open is refused
    /// `DRAG_NOT_CURRENT`. Host: a CAUGHT take ends once its reoffer is whole, or as soon as the reoffer cannot be
    /// the take's.
    mutating func offersChanged(_ items: ItemTransfer, connection: inout Connection) {
        let open = items.offers.localTokens
        taken.removeAll { !open.contains($0) }
        for take in asked where !open.contains(take.token) {
            refuse(take.id.stream, &connection)
            events.append(.cancelled(take.id))
        }
        asked.removeAll { !open.contains($0.token) }

        adopted.removeAll { items.offers.remoteOffer($0) == nil }
        let waiting = arrivals
        arrivals.removeAll()
        for var arrival in waiting {
            let id = arrival.take.id
            guard let reoffer = items.offers.remoteOffer(arrival.reoffer) else {
                if arrival.seen {
                    dropReoffer(of: id, "names a reoffer that ended before it arrived whole")
                } else if items.offers.remoteOffer(arrival.take.token) == nil {
                    // Nothing is left to carry the drag on from.
                    events.append(.ended(id, .caught(reoffer: nil)))
                } else {
                    arrivals.append(arrival)
                }
                continue
            }
            guard reoffer.feature == Self.feature else {
                dropReoffer(of: id, "names an offer of \(reoffer.feature)")
                continue
            }
            guard reoffer.stream.rawValue > arrival.take.mark else {
                dropReoffer(of: id, "names an offer opened before the take")
                continue
            }
            guard reoffer.complete else {
                arrival.seen = true
                arrivals.append(arrival)
                continue
            }
            adopted.append(arrival.reoffer)
            events.append(.ended(id, .caught(reoffer: arrival.reoffer)))
        }
    }

    /// Host: ends take `id` CAUGHT with no reoffer, the one its END named breaking the reoffer's contract.
    private mutating func dropReoffer(of id: DragTakeID, _ why: String) {
        diagnostics.append(.remoteViolation("a CAUGHT \(why)"))
        events.append(.ended(id, .caught(reoffer: nil)))
    }

    /// ENDs a take REFUSED `DRAG_NOT_CURRENT`.
    private mutating func refuse(_ stream: StreamID, _ connection: inout Connection) {
        var outcome = Kernova_V2_DragTakeOutcome()
        outcome.kind = .refused
        outcome.error = WireError(.dragNotCurrent).proto
        end(stream, outcome.encoded, &connection)
    }

    private static func step(_ report: DragTakeReport) -> Kernova_V2_DragTakeReport.Step {
        switch report {
        case .armed: .armed
        case .targeted: .targeted
        case .delivering: .delivering
        case .deliverRefused: .deliverRefused
        case .stoodDown: .stoodDown
        }
    }

    /// The peer's `DragTakeOutcome` when it ENDed; otherwise how the stream closed.
    private static func result(_ closure: StreamClosure) -> DragTakeResult {
        guard case .completed(let body) = closure else { return .closed(closure) }
        guard let outcome = try? Kernova_V2_DragTakeOutcome(serializedBytes: body) else {
            return .refused(WireError(.malformedMessage, debugDetail: "a DragTakeOutcome that does not decode"))
        }
        switch outcome.kind {
        case .caught: return .caught(reoffer: outcome.reoffer.isEmpty ? nil : outcome.reoffer)
        case .returned: return .returned
        case .refused, .unspecified, .UNRECOGNIZED:
            return .refused(outcome.hasError ? WireError(received: outcome.error) : WireError(.unspecified))
        }
    }
}
