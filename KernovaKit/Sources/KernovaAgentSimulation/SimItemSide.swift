#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaAgentCore
import KernovaWire

/// One side of one link's item transfer: its source and sink, answering asynchronously as the runtime's
/// adapters do, and what its owner heard.
package final class SimItemSide {
    package var source = ContainerItemSource()
    package var sink = DecodingItemSink()
    /// The consumer-stall fault holding the sink's consumption, while one does.
    var stall: Int?
    /// How long the sink takes to publish a committed pull.
    package var publishDelay: SimTime = .us(20)
    private var heldConsumption: [ItemSinkInput] = []
    /// Every pull asked for, and what `pullItem` returned.
    package private(set) var pulls: [(time: SimTime, request: PullRequest, result: Result<ItemPullID, WireError>)] = []
    /// Every refused offer.
    package private(set) var offerRefusals: [WireError] = []
    package private(set) var pullsEnded: [(time: SimTime, feature: FeatureID, id: ItemPullID, result: ItemPullResult)] =
        []
    package private(set) var servesEnded:
        [(time: SimTime, feature: FeatureID, id: ItemPullID, result: ItemServeResult)] = []
    package private(set) var offersReceived: [(time: SimTime, header: ItemSetHeaderValue)] = []
    package private(set) var offersEnded:
        [(time: SimTime, feature: FeatureID, origin: ItemOfferOrigin, token: Data, closure: StreamClosure)] = []
    /// Peer: how its owner ends each take, after 20 µs; nil leaves takes unanswered.
    package var takeAnswer: DragTakeAnswer? = .caught(sizes: nil)
    /// Peer: the items its owner's first `TARGETED` lists, just before it ends a take `CAUGHT`; nil sends none.
    package var takeItems: [OfferedItem]?
    /// Every take `takeDrag` asked for, and what it returned.
    package private(set) var takes: [(time: SimTime, token: Data, result: Result<DragTakeID, WireError>)] = []
    /// Peer: every take its owner was asked about.
    package private(set) var takesRequested: [(time: SimTime, id: DragTakeID, token: Data)] = []
    /// Host: every take that ended.
    package private(set) var takesEnded: [(time: SimTime, id: DragTakeID, result: DragTakeResult)] = []
    /// Host: every step a take reported.
    package private(set) var takeReports: [(time: SimTime, id: DragTakeID, report: DragTakeReport)] = []
    /// Peer: every control the host sent on a take.
    package private(set) var takeControls: [(time: SimTime, id: DragTakeID, control: DragTakeControl)] = []
    /// Peer: every take that closed before its owner ended it.
    package private(set) var takesCancelled: [(time: SimTime, id: DragTakeID)] = []
    /// Every item `.read` answered, by the token and item it named.
    package private(set) var reads: [(time: SimTime, token: Data, item: UInt32, result: OfferedItem?)] = []

    /// What an item command's answer is recorded as.
    fileprivate enum Awaited {
        case offer(token: Data)
        case pull(PullRequest)
        case take(token: Data)
        case read(token: Data, item: UInt32)
    }

    /// The item commands sent and not yet answered.
    private var awaiting: [ItemRequestID: Awaited] = [:]
    private var nextRequest: UInt64 = 0
    /// Property 13: what this side's answers opened and no event has ended yet.
    private var answeredOffers: Set<Data> = []
    private var answeredPulls: Set<ItemPullID> = []
    private var answeredTakes: Set<DragTakeID> = []

    init() {}

    /// The ids of the commands sent and never answered.
    var unanswered: [ItemRequestID] { Array(awaiting.keys) }

    /// The command `build` makes around a fresh request id, recording what its answer is for.
    fileprivate func command(_ awaited: Awaited, _ build: (ItemRequestID) -> ItemCommand) -> ItemCommand {
        nextRequest += 1
        let id = ItemRequestID(rawValue: nextRequest)
        awaiting[id] = awaited
        return build(id)
    }

    /// Records the answer to the command of `id`.
    func reply(_ id: ItemRequestID, _ reply: ItemReply, link: SimLink, side: SimSide, world: SimWorld) {
        guard let awaited = awaiting.removeValue(forKey: id) else {
            return world.checker.fail("property 13: link \(link.id) \(side) answer \(id.rawValue) to no command")
        }
        switch (awaited, reply) {
        case (.offer(let token), .offered(let refusal)):
            if let refusal { offerRefusals.append(refusal) } else { answeredOffers.insert(token) }
        case (.pull(let request), .pulled(let result)):
            pulls.append((world.now, request, result))
            if case .success(let id) = result { answeredPulls.insert(id) }
        case (.take(let token), .took(let result)):
            takes.append((world.now, token, result))
            if case .success(let id) = result { answeredTakes.insert(id) }
        case (.read(let token, let item), .read(let result)):
            reads.append((world.now, token, item, result))
        default:
            world.checker.fail("property 13: link \(link.id) \(side) answered \(awaited) with \(reply)")
        }
    }

    /// Property 13: the event that ends what an answer opened comes after that answer.
    private func answered<ID: Hashable>(
        _ id: ID, in answered: inout Set<ID>, _ what: String, link: SimLink, side: SimSide, world: SimWorld
    ) {
        guard answered.remove(id) == nil else { return }
        world.checker.fail("property 13: link \(link.id) \(side) \(what) ended before its answer")
    }

    /// Hands one output to the source, the sink or the record; answers go back after a delay.
    func handle(_ output: ItemTransferOutput, link: SimLink, side: SimSide, world: SimWorld) {
        switch output {
        case .source(let effect):
            guard let input = source.handle(effect) else { return }
            world.itemInput(.source(input), link: link, side: side, after: world.options.payloadSourceDelay)
        case .sink(let effect):
            guard let input = sink.handle(effect) else { return }
            if case .consumed = input, let stall {
                heldConsumption.append(input)
                world.faultTookEffect(stall)
                return
            }
            switch input {
            case .published, .publishFailed:
                world.itemInput(.sink(input), link: link, side: side, after: publishDelay)
            default:
                world.itemInput(.sink(input), link: link, side: side, after: .us(20))
            }
        case .event(let event):
            switch event {
            case .offerReceived(let header):
                offersReceived.append((world.now, header))
                // The owner reads each item as the offer arrives.
                let index = world.links.firstIndex { $0 === link } ?? 0
                world.at(world.now) { world in
                    world.itemCommand(side, link: index) { items in
                        (0..<UInt32(clamping: header.count)).map { item in
                            items.command(.read(token: header.token, item: item)) {
                                .read($0, token: header.token, item: item)
                            }
                        }
                    }
                }
            case .offerEnded(let feature, let origin, let token, let closure):
                offersEnded.append((world.now, feature, origin, token, closure))
                if origin == .local {
                    answered(token, in: &answeredOffers, "offer", link: link, side: side, world: world)
                }
            case .pullEnded(let feature, let id, let result):
                pullsEnded.append((world.now, feature, id, result))
                answered(id, in: &answeredPulls, "pull \(id.stream.rawValue)", link: link, side: side, world: world)
            case .serveEnded(let feature, let id, let result): servesEnded.append((world.now, feature, id, result))
            }
        case .reply:
            // The endpoint hands a reply out as its `.itemReply` event, which `reply` records.
            break
        }
    }

    /// Records a drag take's event; a peer's owner answers a requested take with `takeAnswer`.
    func dragTake(_ event: DragTakeEvent, link: SimLink, side: SimSide, world: SimWorld) {
        switch event {
        case .requested(let id, let token):
            takesRequested.append((world.now, id, token))
            guard let answer = takeAnswer else { return }
            if let takeItems, case .caught = answer {
                world.peerInput(.dragTake(id, .report(.targeted(takeItems))), link: link, after: .us(10))
            }
            world.peerInput(.dragTake(id, answer), link: link, after: .us(20))
        case .control(let id, let control):
            takeControls.append((world.now, id, control))
        case .cancelled(let id):
            takesCancelled.append((world.now, id))
        case .report(let id, let report):
            takeReports.append((world.now, id, report))
        case .ended(let id, let result):
            takesEnded.append((world.now, id, result))
            answered(id, in: &answeredTakes, "take \(id.stream.rawValue)", link: link, side: side, world: world)
        }
    }

    /// Host: the takes `takeDrag` opened that have not ended.
    var openTakes: [DragTakeID] {
        let ended = Set(takesEnded.map(\.id))
        return takes.compactMap { take in
            guard case .success(let id) = take.result, !ended.contains(id) else { return nil }
            return id
        }
    }

    /// Releases a consumer stall: what the sink held is consumed now.
    func releaseStall(link: SimLink, side: SimSide, world: SimWorld) {
        stall = nil
        for input in heldConsumption { world.itemInput(.sink(input), link: link, side: side, after: 0) }
        heldConsumption = []
    }
}

extension SimWorld {
    /// Feeds `input` to the link's peer endpoint after `delay`, if the link still runs there.
    package func peerInput(_ input: PeerInput, link: SimLink, after delay: SimTime) {
        let process = process(of: link, .peer)
        at(now + delay) { world in
            world.perform(process) { world in
                guard !link.shutDown.contains(.peer) else { return }
                link.peer?.handle(input, now: world.localNow(process))
                world.drain(link, .peer)
            }
        }
    }

    /// Feeds an item source's or sink's answer to `side`'s endpoint after `delay`, if the link still runs
    /// there or has a landing in flight, as a driver feeds a finished endpoint until its committed pulls end.
    package func itemInput(_ input: ItemTransferInput, link: SimLink, side: SimSide, after delay: SimTime) {
        let process = process(of: link, side)
        at(now + delay) { world in
            world.perform(process) { world in
                guard !link.shutDown.contains(side) || link.hasLandingsInFlight(side) else { return }
                let local = world.localNow(process)
                if case .sink(let report) = input { world.checker.sinkReport(report, link: link, side: side) }
                switch side {
                case .host: link.host?.handle(input, now: local)
                case .peer: link.peer?.handle(.items(input), now: local)
                }
                world.drain(link, side)
            }
        }
    }

    /// Sends `side`'s endpoint of link `index` the commands `build` makes, as that side's process, then
    /// drains it; each answer reaches the link's item side as the endpoint emits it.
    fileprivate func itemCommand(
        _ side: SimSide, link index: Int, _ build: @escaping (SimItemSide) -> [ItemCommand]
    ) {
        guard index < links.count else { return checker.fail("no link \(index)") }
        let link = links[index]
        let process = process(of: link, side)
        perform(process) { world in
            guard !link.shutDown.contains(side) else { return }
            for command in build(link.items(side)) {
                let now = world.localNow(process)
                switch side {
                case .host: link.host?.handle(.items(command), now: now)
                case .peer: link.peer?.handle(.itemCommand(command), now: now)
                }
            }
            world.drain(link, side)
        }
    }

    /// `side` offers `offer` on link `index`, as `feature`'s offer.
    package func offerItems(
        _ offer: ItemOffer, feature: FeatureID = .clipboard, from side: SimSide, link index: Int = 0
    ) {
        itemCommand(side, link: index) { items in
            [items.command(.offer(token: offer.token)) { .offer($0, offer, feature: feature) }]
        }
    }

    /// `side` withdraws its offer of `token` on link `index`.
    package func withdrawOffer(_ token: Data, from side: SimSide, link index: Int = 0) {
        itemCommand(side, link: index) { _ in [.withdraw(token: token)] }
    }

    /// `side` releases the far side's offer of `token` on link `index`.
    package func releaseOffer(_ token: Data, by side: SimSide, link index: Int = 0) {
        itemCommand(side, link: index) { _ in [.release(token: token)] }
    }

    /// The host takes the peer's drag offer of `token` on link `index`.
    package func takeDrag(_ token: Data, link index: Int = 0) {
        itemCommand(.host, link: index) { items in
            [items.command(.take(token: token)) { .takeDrag($0, token: token) }]
        }
    }

    /// The host tells the peer `control` on every take it opened on link `index` that has not ended.
    package func controlTakes(_ control: DragTakeControl, link index: Int = 0) {
        itemCommand(.host, link: index) { items in items.openTakes.map { .controlTake($0, control) } }
    }

    /// The host calls off every take it opened on link `index` that has not ended.
    package func cancelTakes(link index: Int = 0) {
        itemCommand(.host, link: index) { items in items.openTakes.map { .cancelTake($0) } }
    }

    /// `side` pulls `request` on link `index`, landing it as `DecodingItemSink.landing`.
    package func pullItem(_ request: PullRequest, by side: SimSide, link index: Int = 0) {
        itemCommand(side, link: index) { items in
            let order = ItemPullOrder(request, landing: DecodingItemSink.landing)
            return [items.command(.pull(request)) { .pull($0, order) }]
        }
    }

    /// `side` cancels every pull it opened on link `index` that has not ended.
    package func cancelPulls(by side: SimSide, link index: Int = 0) {
        itemCommand(side, link: index) { items in
            let ended = Set(items.pullsEnded.map(\.id))
            return items.pulls.compactMap { pull in
                guard case .success(let id) = pull.result, !ended.contains(id) else { return nil }
                return .cancel(id)
            }
        }
    }
}
