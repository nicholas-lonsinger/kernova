import Foundation
import KernovaAgentCore
import KernovaAgentRuntime
import KernovaClipboardItems
import KernovaSynchronization
import KernovaTestSupport
import KernovaWire

/// The main-queue work a set of ``ClipboardWire``s has handed the ends and not yet seen run: each event it
/// delivers on the main queue, and a mark queued behind each completion it calls, so every hop the end's own
/// code queued from inside that completion runs before the mark does.
final class ClipboardWireWork: Sendable {
    private let pending = Locked(0)
    /// Fires each time a piece of that work ran; await it instead of polling.
    let changed = AsyncGate()

    /// Whether nothing handed over is still queued.
    var isIdle: Bool { pending.withLock { $0 == 0 } }

    /// Runs `body` on the main queue, counted until it has.
    func onMain(_ body: @escaping @MainActor @Sendable () -> Void) {
        pending.withLock { $0 += 1 }
        DispatchQueue.main.async {
            MainActor.assumeIsolated { body() }
            self.pending.withLock { $0 -= 1 }
            self.changed.notify()
        }
    }

    /// Queues a mark behind whatever the caller just queued on the main queue.
    func mark() {
        onMain {}
    }
}

/// One CLIPBOARD connection between a host's end and a guest's, in memory, with the item registry's rules a
/// clipboard end relies on: a side's call takes effect on its own side at once — its events reach it on the main
/// queue — and reaches the far side only when the test delivers it, one message at a time, in order. A side's
/// clipboard offer withdraws its previous one `ITEM_OFFER_REPLACED`; only the host opens a request, which is no
/// offer; a call naming a token its side does not hold changes nothing. Once ``cut()``, it carries nothing more.
final class ClipboardWire: Sendable {
    enum Side: Sendable, Hashable, CaseIterable {
        case host, guest

        var far: Side { self == .host ? .guest : .host }
    }

    /// What crosses toward one side.
    enum Message: Sendable, Equatable {
        /// The far side opened this offer.
        case opened(ItemSetHeaderValue, [OfferedItem])
        /// The host asks this side to offer its clipboard.
        case requested(token: Data)
        /// The far side withdrew its offer or request.
        case withdrawn(token: Data, code: ErrorCode)
        /// The far side let this side's offer or request go.
        case released(token: Data)
        /// The far side refused this side's offer or request.
        case refused(token: Data, error: WireError)
    }

    /// One side's open offer.
    struct Open: Sendable {
        let header: ItemSetHeaderValue
        let items: [OfferedItem]
    }

    private struct State: Sendable {
        var local: [Side: [Data: Open]] = [.host: [:], .guest: [:]]
        var remote: [Side: [Data: [OfferedItem]]] = [.host: [:], .guest: [:]]
        /// The host's requests still open, on its side and as the guest holds them.
        var localRequests: Set<Data> = []
        var remoteRequests: Set<Data> = []
        /// The messages toward each side, oldest first.
        var queues: [Side: [Message]] = [.host: [], .guest: []]
        /// Every offer each side opened, in order.
        var opened: [Side: [ItemOffer]] = [.host: [], .guest: []]
        /// Every request the host opened, in order.
        var requests: [Data] = []
        /// How many items of the far side's offers each side read.
        var itemReads: [Side: Int] = [.host: 0, .guest: 0]
        /// How many pulls each side opened.
        var pulls: [Side: Int] = [.host: 0, .guest: 0]
        var nextStream: UInt32 = 1
        var cut = false
    }

    private let state = Locked(State())
    private let work: ClipboardWireWork
    /// Hands an event to a side's end.
    private let deliver: @MainActor @Sendable (Side, ItemTransferEvent, ClipboardWire) -> Void
    /// Pull `id`'s content from a side's end, asked off the main thread.
    private let content: @Sendable (Side, ItemPullID, PullRequest) -> Result<ItemContent, WireError>
    /// Hands a pull's end to the side that opened it, on any queue.
    private let pullEnded: @Sendable (Side, ItemPullID, ItemPullResult) -> Void

    init(
        work: ClipboardWireWork,
        deliver: @escaping @MainActor @Sendable (Side, ItemTransferEvent, ClipboardWire) -> Void,
        content: @escaping @Sendable (Side, ItemPullID, PullRequest) -> Result<ItemContent, WireError> = { _, _, _ in
            .failure(WireError(.itemRepresentationUnavailable))
        },
        pullEnded: @escaping @Sendable (Side, ItemPullID, ItemPullResult) -> Void = { _, _, _ in }
    ) {
        self.work = work
        self.deliver = deliver
        self.content = content
        self.pullEnded = pullEnded
    }

    /// `side`'s item calls.
    func link(_ side: Side) -> Link { Link(wire: self, side: side) }

    /// The host's link, which can also ask the guest for its clipboard.
    var hostLink: HostLink { HostLink(items: link(.host)) }

    // MARK: What the test sees

    /// The messages toward `side` not yet delivered, oldest first.
    func queue(toward side: Side) -> [Message] { state.withLock { $0.queues[side] ?? [] } }

    /// `side`'s open offers, by token.
    func open(_ side: Side) -> [Data: Open] { state.withLock { $0.local[side] ?? [:] } }

    /// The host's requests still open on its side.
    var openRequests: Set<Data> { state.withLock(\.localRequests) }

    /// Every offer `side` opened, in order.
    func opened(_ side: Side) -> [ItemOffer] { state.withLock { $0.opened[side] ?? [] } }

    /// Every request the host opened, in order.
    var requests: [Data] { state.withLock(\.requests) }

    /// How many items of the far side's offers `side` read.
    func itemReads(_ side: Side) -> Int { state.withLock { $0.itemReads[side] ?? 0 } }

    /// How many pulls `side` opened.
    func pulls(_ side: Side) -> Int { state.withLock { $0.pulls[side] ?? 0 } }

    /// Ends the connection: nothing queued arrives, and nothing more is carried.
    func cut() {
        state.withLock { state in
            state.cut = true
            state.queues = [.host: [], .guest: []]
            state.local = [.host: [:], .guest: [:]]
            state.remote = [.host: [:], .guest: [:]]
            state.localRequests = []
            state.remoteRequests = []
        }
    }

    /// Delivers the oldest message toward `side`, returning it; nil when none is queued.
    @MainActor
    @discardableResult
    func deliverNext(toward side: Side) -> Message? {
        let (message, event) = state.withLock { state -> (Message?, ItemTransferEvent?) in
            guard let message = state.queues[side]?.first else { return (nil, nil) }
            state.queues[side]?.removeFirst()
            switch message {
            case .opened(let header, let items):
                state.remote[side]?[header.token] = items
                return (message, .offerReceived(header))
            case .requested(let token):
                state.remoteRequests.insert(token)
                return (message, .offerRequested(token: token))
            case .withdrawn(let token, let code):
                let closure = StreamClosure.resetByPeer(WireError(code))
                if state.remote[side]?.removeValue(forKey: token) != nil {
                    return (message, .offerEnded(.clipboard, .remote, token: token, closure))
                }
                guard side == .guest, state.remoteRequests.remove(token) != nil else { return (message, nil) }
                return (message, .requestEnded(.remote, token: token, closure))
            case .released(let token):
                return (message, Self.endLocal(token, .completed(remoteEndBody: Data()), on: side, &state))
            case .refused(let token, let error):
                return (message, Self.endLocal(token, .resetByPeer(error), on: side, &state))
            }
        }
        if let event { deliver(side, event, self) }
        return message
    }

    /// Ends `side`'s offer or request of `token` as `closure` says; nil when it holds none.
    private static func endLocal(_ token: Data, _ closure: StreamClosure, on side: Side, _ state: inout State)
        -> ItemTransferEvent?
    {
        if state.local[side]?.removeValue(forKey: token) != nil {
            return .offerEnded(.clipboard, .local, token: token, closure)
        }
        guard side == .host, state.localRequests.remove(token) != nil else { return nil }
        return .requestEnded(.local, token: token, closure)
    }

    // MARK: The calls

    fileprivate func offer(_ offer: ItemOffer, from side: Side, _ completion: @escaping @Sendable (WireError?) -> Void)
    {
        let (refusal, events) = state.withLock { state -> (WireError?, [ItemTransferEvent]) in
            guard !state.cut else { return (WireError(.cancelled, debugDetail: "the connection ended"), []) }
            var events: [ItemTransferEvent] = []
            for token in (state.local[side] ?? [:]).keys {
                events += Self.withdraw(token, .itemOfferReplaced, from: side, &state)
            }
            let header = ItemSetHeaderValue(
                feature: .clipboard, token: offer.token, concealed: offer.concealed, count: offer.items.count,
                after: offer.after, request: offer.request)
            state.local[side]?[offer.token] = Open(header: header, items: offer.items)
            state.queues[side.far]?.append(.opened(header, offer.items))
            state.opened[side]?.append(offer)
            return (nil, events)
        }
        hand(events, to: side)
        completion(refusal)
        work.mark()
    }

    fileprivate func requestOffer(_ token: Data, _ completion: @escaping @Sendable (WireError?) -> Void) {
        let refusal = state.withLock { state -> WireError? in
            guard !state.cut else { return WireError(.cancelled, debugDetail: "the connection ended") }
            state.localRequests.insert(token)
            state.queues[.guest]?.append(.requested(token: token))
            state.requests.append(token)
            return nil
        }
        completion(refusal)
        work.mark()
    }

    fileprivate func withdraw(_ token: Data, code: ErrorCode, from side: Side) {
        let events = state.withLock { state in Self.withdraw(token, code, from: side, &state) }
        hand(events, to: side)
    }

    private static func withdraw(_ token: Data, _ code: ErrorCode, from side: Side, _ state: inout State)
        -> [ItemTransferEvent]
    {
        let closure = StreamClosure.resetLocally(WireError(code))
        if state.local[side]?.removeValue(forKey: token) != nil {
            state.queues[side.far]?.append(.withdrawn(token: token, code: code))
            return [.offerEnded(.clipboard, .local, token: token, closure)]
        }
        guard side == .host, state.localRequests.remove(token) != nil else { return [] }
        state.queues[.guest]?.append(.withdrawn(token: token, code: code))
        return [.requestEnded(.local, token: token, closure)]
    }

    fileprivate func release(_ token: Data, from side: Side) {
        let events = state.withLock { state in
            Self.endRemote(token, .released(token: token), .completed(remoteEndBody: Data()), from: side, &state)
        }
        hand(events, to: side)
    }

    fileprivate func refuse(_ token: Data, _ error: WireError, from side: Side) {
        let events = state.withLock { state in
            Self.endRemote(token, .refused(token: token, error: error), .resetLocally(error), from: side, &state)
        }
        hand(events, to: side)
    }

    /// Ends the far side's offer or request of `token` from `side`, telling the far side `message`.
    private static func endRemote(
        _ token: Data, _ message: Message, _ closure: StreamClosure, from side: Side, _ state: inout State
    ) -> [ItemTransferEvent] {
        if state.remote[side]?.removeValue(forKey: token) != nil {
            state.queues[side.far]?.append(message)
            return [.offerEnded(.clipboard, .remote, token: token, closure)]
        }
        guard side == .guest, state.remoteRequests.remove(token) != nil else { return [] }
        state.queues[.host]?.append(message)
        return [.requestEnded(.remote, token: token, closure)]
    }

    fileprivate func readItem(_ token: Data, item: UInt32, from side: Side) -> OfferedItem? {
        state.withLock { state in
            state.itemReads[side, default: 0] += 1
            guard let items = state.remote[side]?[token], items.indices.contains(Int(item)) else { return nil }
            return items[Int(item)]
        }
    }

    /// Opens a pull and serves it at once from the far side's end, landing it as its order says.
    fileprivate func pull(
        _ order: ItemPullOrder, from side: Side,
        _ completion: @escaping @Sendable (Result<ItemPullID, WireError>) -> Void
    ) {
        let id = state.withLock { state -> ItemPullID? in
            guard !state.cut, state.remote[side]?[order.request.token] != nil else { return nil }
            state.pulls[side, default: 0] += 1
            defer { state.nextStream += 2 }
            return ItemPullID(
                generation: ConnectionGeneration(rawValue: 1), stream: StreamID(rawValue: state.nextStream))
        }
        guard let id else {
            completion(.failure(WireError(.itemOfferStale)))
            return work.mark()
        }
        completion(.success(id))
        work.mark()
        let content = content
        let pullEnded = pullEnded
        DispatchQueue.global().async {
            let result = Self.land(content(side.far, id, order.request), as: order.landing)
            pullEnded(side, id, result)
        }
    }

    private static func land(_ content: Result<ItemContent, WireError>, as landing: ItemLanding) -> ItemPullResult {
        switch (content, landing) {
        case (.failure(let error), _):
            return .failed(error)
        case (.success(.inline(let data)), .memory):
            return .landed(.inline(data))
        case (.success(.inline(let data)), .staged(let directory, let name)):
            let named: Data
            switch name {
            case .exactly(let exact), .keepingBoth(let exact): named = exact
            }
            let url = URL(fileURLWithPath: directory).appendingPathComponent(String(decoding: named, as: UTF8.self))
            guard (try? data.write(to: url)) != nil else { return .failed(WireError(.writeFailed)) }
            return .landed(.named(named))
        case (.success, _):
            return .failed(WireError(.writeFailed, debugDetail: "this wire lands only INLINE representations"))
        }
    }

    /// Hands `events` to `side`'s end on the main queue.
    private func hand(_ events: [ItemTransferEvent], to side: Side) {
        for event in events {
            work.onMain { [self] in deliver(side, event, self) }
        }
    }

    /// One side's item calls into the wire.
    struct Link: ClipboardItemLink {
        let wire: ClipboardWire
        let side: Side

        func offerItems(_ offer: ItemOffer, _ completion: @escaping @Sendable (WireError?) -> Void) {
            wire.offer(offer, from: side, completion)
        }

        func withdrawOffer(_ token: Data, code: ErrorCode) { wire.withdraw(token, code: code, from: side) }
        func releaseOffer(_ token: Data) { wire.release(token, from: side) }
        func refuseOffer(_ token: Data, _ error: WireError) { wire.refuse(token, error, from: side) }

        func readItem(_ token: Data, item: UInt32, _ completion: @escaping @Sendable (OfferedItem?) -> Void) {
            completion(wire.readItem(token, item: item, from: side))
            wire.work.mark()
        }

        func pullItem(
            _ order: ItemPullOrder, _ completion: @escaping @Sendable (Result<ItemPullID, WireError>) -> Void
        ) {
            wire.pull(order, from: side, completion)
        }

        func cancelPull(_ id: ItemPullID) {}

        func order(
            token: Data, item: UInt32, representation: UInt32, byteCeiling: UInt64, landing: ItemLanding,
            budget: ByteBudget?
        ) throws(WireError) -> ItemPullOrder {
            var request = PullRequest()
            request.token = token
            request.item = item
            request.representation = representation
            request.byteCeiling = byteCeiling
            return ItemPullOrder(request, landing: landing, budget: budget)
        }
    }

    /// The host's calls into the wire: its item calls, and its requests that the guest offer its clipboard.
    struct HostLink: ClipboardHostItemLink {
        let items: Link

        func requestOffer(_ token: Data, _ completion: @escaping @Sendable (WireError?) -> Void) {
            items.wire.requestOffer(token, completion)
        }

        func offerItems(_ offer: ItemOffer, _ completion: @escaping @Sendable (WireError?) -> Void) {
            items.offerItems(offer, completion)
        }

        func withdrawOffer(_ token: Data, code: ErrorCode) { items.withdrawOffer(token, code: code) }
        func releaseOffer(_ token: Data) { items.releaseOffer(token) }
        func refuseOffer(_ token: Data, _ error: WireError) { items.refuseOffer(token, error) }

        func readItem(_ token: Data, item: UInt32, _ completion: @escaping @Sendable (OfferedItem?) -> Void) {
            items.readItem(token, item: item, completion)
        }

        func pullItem(
            _ order: ItemPullOrder, _ completion: @escaping @Sendable (Result<ItemPullID, WireError>) -> Void
        ) {
            items.pullItem(order, completion)
        }

        func cancelPull(_ id: ItemPullID) { items.cancelPull(id) }

        func order(
            token: Data, item: UInt32, representation: UInt32, byteCeiling: UInt64, landing: ItemLanding,
            budget: ByteBudget?
        ) throws(WireError) -> ItemPullOrder {
            try items.order(
                token: token, item: item, representation: representation, byteCeiling: byteCeiling, landing: landing,
                budget: budget)
        }
    }
}
