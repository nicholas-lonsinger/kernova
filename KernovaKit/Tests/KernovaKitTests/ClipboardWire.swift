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
/// queue, after the call's answer — and reaches the far side only when the test delivers it, one message at a time,
/// in order. A side's clipboard offer, once it opens, releases every offer of the far side's it holds and
/// withdraws its own previous one `ITEM_OFFER_REPLACED`; only the host opens a request, which is no offer, and
/// which ends as ``ItemCommand/requestClipboardOffer(_:token:)`` says; a call naming a token its side does not
/// hold changes nothing. Once ``cut()``, it carries nothing more.
///
/// An offer's open is answered at once, or — on a wire that holds opens — only when the test answers it
/// (``answerOldestOpen(of:)``): the far side may hear the offer first, as on a real connection, where the answer
/// hops through the opener's queues.
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

    /// A request of the host's as its item registry holds it, until the guest released it and the offer answering
    /// it, if one opened, arrived whole or ended.
    private struct HostRequest: Sendable {
        var released = false
        var answer: Answer?
    }

    private enum Answer: Sendable {
        /// The guest opened it, and the host does not hold it whole.
        case arriving(Data)
        case whole
        case ended(StreamClosure)
    }

    private struct State: Sendable {
        var local: [Side: [Data: Open]] = [.host: [:], .guest: [:]]
        var remote: [Side: [Data: [OfferedItem]]] = [.host: [:], .guest: [:]]
        /// The host's requests, on its side and as the guest holds them.
        var localRequests: [Data: HostRequest] = [:]
        var remoteRequests: Set<Data> = []
        /// The messages toward each side, oldest first.
        var queues: [Side: [Message]] = [.host: [], .guest: []]
        /// Every offer each side opened, in order.
        var opened: [Side: [ItemOffer]] = [.host: [], .guest: []]
        /// Every request the host opened, in order.
        var requests: [Data] = []
        /// Each side's opens still to be answered, oldest first: the offer's token, the answer, and the events
        /// the open caused.
        var unanswered: [Side: [(token: Data, answer: @Sendable () -> Void, events: [ItemTransferEvent])]] = [
            .host: [], .guest: [],
        ]
        var nextStream: UInt32 = 1
        var cut = false
    }

    private let state = Locked(State())
    private let holdsOpens: Bool
    private let work: ClipboardWireWork
    /// Hands an event to a side's end.
    private let deliver: @MainActor @Sendable (Side, ItemTransferEvent, ClipboardWire) -> Void
    /// Pull `id`'s content from a side's end, asked off the main thread.
    private let content: @Sendable (Side, ItemPullID, PullRequest) -> Result<ItemContent, WireError>
    /// Hands a pull's end to the side that opened it, on any queue.
    private let pullEnded: @Sendable (Side, ItemPullID, ItemPullResult) -> Void

    init(
        work: ClipboardWireWork, holdsOpens: Bool = false,
        deliver: @escaping @MainActor @Sendable (Side, ItemTransferEvent, ClipboardWire) -> Void,
        content: @escaping @Sendable (Side, ItemPullID, PullRequest) -> Result<ItemContent, WireError> = { _, _, _ in
            .failure(WireError(.itemRepresentationUnavailable))
        },
        pullEnded: @escaping @Sendable (Side, ItemPullID, ItemPullResult) -> Void = { _, _, _ in }
    ) {
        self.work = work
        self.holdsOpens = holdsOpens
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

    /// The host's requests its side holds, not yet ended.
    var openRequests: Set<Data> { state.withLock { Set($0.localRequests.keys) } }

    /// Every offer `side` opened, in order.
    func opened(_ side: Side) -> [ItemOffer] { state.withLock { $0.opened[side] ?? [] } }

    /// Every request the host opened, in order.
    var requests: [Data] { state.withLock(\.requests) }

    /// The tokens of `side`'s offers whose opens are still to be answered, oldest first.
    func unansweredOpens(_ side: Side) -> [Data] { state.withLock { $0.unanswered[side]?.map(\.token) ?? [] } }

    /// Answers `side`'s oldest open still to be answered, then hands it the events the open caused.
    func answerOldestOpen(of side: Side) {
        let open = state.withLock { state in
            state.unanswered[side]?.isEmpty == false ? state.unanswered[side]?.removeFirst() : nil
        }
        guard let open else { return }
        open.answer()
        work.mark()
        hand(open.events, to: side)
    }

    /// The oldest message toward `side`, an offer, never reaches its end: `side`'s item registry resets it
    /// `TOO_LARGE`, as it does an offer over the budget its far side's open offers share.
    func refuseOverBudget(toward side: Side) {
        let events = state.withLock { state -> [ItemTransferEvent] in
            guard case .opened(let header, _)? = state.queues[side]?.first else { return [] }
            state.queues[side]?.removeFirst()
            let error = WireError(.tooLarge)
            state.queues[side.far]?.append(.refused(token: header.token, error: error))
            return side == .host ? Self.answer(header.token, .ended(.resetLocally(error)), &state) : []
        }
        hand(events, to: side)
    }

    /// Ends the connection: nothing queued arrives, and nothing more is carried.
    func cut() {
        state.withLock { state in
            state.cut = true
            state.queues = [.host: [], .guest: []]
            state.local = [.host: [:], .guest: [:]]
            state.remote = [.host: [:], .guest: [:]]
            state.localRequests = [:]
            state.remoteRequests = []
        }
    }

    /// Delivers the oldest message toward `side`, returning it; nil when none is queued. One ending an offer of
    /// `side`'s whose open is still to be answered answers it first, and arrives after the answer: the far side's
    /// end of an offer reaches its opener after the open's answer, which the connection gave before the far side
    /// could hear of the offer.
    @MainActor
    @discardableResult
    func deliverNext(toward side: Side) -> Message? {
        let answering: Data? = state.withLock { state in
            switch state.queues[side]?.first {
            case .released(let token)?, .refused(let token, _)?:
                state.unanswered[side]?.contains { $0.token == token } == true ? token : nil
            default:
                nil
            }
        }
        if let answering {
            while let oldest = unansweredOpens(side).first {
                answerOldestOpen(of: side)
                if oldest == answering { break }
            }
        }
        let (message, events) = state.withLock { state -> (Message?, [ItemTransferEvent]) in
            guard let message = state.queues[side]?.first else { return (nil, []) }
            state.queues[side]?.removeFirst()
            switch message {
            case .opened(let header, let items):
                state.remote[side]?[header.token] = items
                let answered = side == .host ? Self.answer(header.token, .whole, &state) : []
                return (message, [.offerReceived(header)] + answered)
            case .requested(let token):
                state.remoteRequests.insert(token)
                return (message, [.offerRequested(token: token)])
            case .withdrawn(let token, let code):
                let closure = StreamClosure.resetByPeer(WireError(code))
                if state.remote[side]?.removeValue(forKey: token) != nil {
                    return (message, [.offerEnded(.clipboard, .remote, token: token, closure)])
                }
                guard side == .guest, state.remoteRequests.remove(token) != nil else { return (message, []) }
                return (message, [.requestEnded(.remote, token: token, closure)])
            case .released(let token):
                if state.local[side]?.removeValue(forKey: token) != nil {
                    return (message, [.offerEnded(.clipboard, .local, token: token, .completed(remoteEndBody: Data()))])
                }
                guard side == .host, state.localRequests[token] != nil else { return (message, []) }
                state.localRequests[token]?.released = true
                return (message, Self.endRequest(token, &state))
            case .refused(let token, let error):
                if state.local[side]?.removeValue(forKey: token) != nil {
                    return (message, [.offerEnded(.clipboard, .local, token: token, .resetByPeer(error))])
                }
                guard side == .host, state.localRequests.removeValue(forKey: token) != nil else { return (message, []) }
                return (message, [.requestEnded(.local, token: token, .resetByPeer(error))])
            }
        }
        if answering == nil {
            for event in events { deliver(side, event, self) }
        } else {
            hand(events, to: side)
        }
        return message
    }

    /// The guest's offer of `token`, if it answers a request of the host's still arriving, arrived whole or ended
    /// as `answer` says: the request's end, once it has one.
    private static func answer(_ token: Data, _ answer: Answer, _ state: inout State) -> [ItemTransferEvent] {
        guard
            let request = state.localRequests.first(where: {
                if case .arriving(token)? = $0.value.answer { true } else { false }
            })?.key
        else { return [] }
        state.localRequests[request]?.answer = answer
        return endRequest(request, &state)
    }

    /// The host's request `token` ends once the guest released it and its answer, if one opened, arrived whole
    /// or ended: `.completed` unless that answer ended first.
    private static func endRequest(_ token: Data, _ state: inout State) -> [ItemTransferEvent] {
        guard let request = state.localRequests[token], request.released else { return [] }
        let closure: StreamClosure
        switch request.answer {
        case .arriving?: return []
        case .ended(let ended)?: closure = ended
        case .whole?, nil: closure = .completed(remoteEndBody: Data())
        }
        state.localRequests[token] = nil
        return [.requestEnded(.local, token: token, closure)]
    }

    // MARK: The calls

    fileprivate func offer(_ offer: ItemOffer, from side: Side, _ completion: @escaping @Sendable (WireError?) -> Void)
    {
        let answered = state.withLock { state -> Bool in
            guard !state.cut else { return false }
            var events: [ItemTransferEvent] = []
            for token in (state.remote[side] ?? [:]).keys {
                events += Self.endRemote(
                    token, .released(token: token), .completed(remoteEndBody: Data()), from: side, &state)
            }
            for token in (state.local[side] ?? [:]).keys {
                events += Self.withdraw(token, .itemOfferReplaced, from: side, &state)
            }
            let header = ItemSetHeaderValue(
                feature: .clipboard, token: offer.token, concealed: offer.concealed, count: offer.items.count,
                request: offer.request)
            state.local[side]?[offer.token] = Open(header: header, items: offer.items)
            if side == .guest, state.localRequests[offer.request]?.answer == nil {
                state.localRequests[offer.request]?.answer = .arriving(offer.token)
            }
            state.queues[side.far]?.append(.opened(header, offer.items))
            state.opened[side]?.append(offer)
            state.unanswered[side]?.append((token: offer.token, answer: { completion(nil) }, events: events))
            return true
        }
        guard answered else {
            completion(WireError(.cancelled, debugDetail: "the connection ended"))
            return work.mark()
        }
        if !holdsOpens { answerOldestOpen(of: side) }
    }

    fileprivate func requestOffer(_ token: Data, _ completion: @escaping @Sendable (WireError?) -> Void) {
        let refusal = state.withLock { state -> WireError? in
            guard !state.cut else { return WireError(.cancelled, debugDetail: "the connection ended") }
            state.localRequests[token] = HostRequest()
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
        // A request the guest released is closed: withdrawing it changes nothing.
        guard side == .host, state.localRequests[token]?.released == false else { return [] }
        state.localRequests[token] = nil
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
