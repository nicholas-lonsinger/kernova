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
    package private(set) var sink = DecodingItemSink()
    /// The consumer-stall fault holding the sink's consumption, while one does.
    var stall: Int?
    private var heldConsumption: [ItemSinkInput] = []
    /// Every pull asked for, and what `pullItem` returned.
    package private(set) var pulls: [(time: SimTime, request: PullRequest, result: Result<ItemPullID, WireError>)] = []
    /// Every refused offer.
    package private(set) var offerRefusals: [WireError] = []
    package private(set) var pullsEnded: [(time: SimTime, id: ItemPullID, result: ItemPullResult)] = []
    package private(set) var servesEnded: [(time: SimTime, id: ItemPullID, result: ItemPullResult)] = []
    package private(set) var offersReceived: [(time: SimTime, header: ItemSetHeaderValue)] = []
    package private(set) var offersEnded:
        [(time: SimTime, feature: FeatureID, origin: ItemOfferOrigin, token: Data, closure: StreamClosure)] = []
    /// Peer: how its owner answers each take, after 20 µs; nil leaves takes unanswered.
    package var takeAnswer: DragTakeAnswer? = .taken
    /// Every take `takeDrag` asked for, and what it returned.
    package private(set) var takes: [(time: SimTime, token: Data, result: Result<DragTakeID, WireError>)] = []
    /// Peer: every take its owner was asked about.
    package private(set) var takesRequested: [(time: SimTime, id: DragTakeID, token: Data)] = []
    /// Host: every take that ended.
    package private(set) var takesEnded: [(time: SimTime, id: DragTakeID, result: DragTakeResult)] = []

    init() {}

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
            world.itemInput(.sink(input), link: link, side: side, after: .us(20))
        case .event(let event):
            switch event {
            case .offerReceived(let header): offersReceived.append((world.now, header))
            case .offerEnded(let feature, let origin, let token, let closure):
                offersEnded.append((world.now, feature, origin, token, closure))
            case .pullEnded(let id, let result): pullsEnded.append((world.now, id, result))
            case .serveEnded(let id, let result): servesEnded.append((world.now, id, result))
            }
        }
    }

    /// Records a drag take's event; a peer's owner answers a requested take with `takeAnswer`.
    func dragTake(_ event: DragTakeEvent, link: SimLink, side: SimSide, world: SimWorld) {
        switch event {
        case .requested(let id, let token):
            takesRequested.append((world.now, id, token))
            guard let answer = takeAnswer else { return }
            world.peerInput(.dragTake(id, answer), link: link, after: .us(20))
        case .ended(let id, let result):
            takesEnded.append((world.now, id, result))
        }
    }

    func recordTake(_ token: Data, _ result: Result<DragTakeID, WireError>, at time: SimTime) {
        takes.append((time, token, result))
    }

    func recordPull(_ request: PullRequest, _ result: Result<ItemPullID, WireError>, at time: SimTime) {
        pulls.append((time, request, result))
    }

    func recordOfferRefusal(_ error: WireError) {
        offerRefusals.append(error)
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

    /// Feeds an item source's or sink's answer to `side`'s endpoint after `delay`, if the link still runs there.
    package func itemInput(_ input: ItemTransferInput, link: SimLink, side: SimSide, after delay: SimTime) {
        let process = process(of: link, side)
        at(now + delay) { world in
            world.perform(process) { world in
                guard !link.shutDown.contains(side) else { return }
                let local = world.localNow(process)
                switch side {
                case .host: link.host?.handle(input, now: local)
                case .peer: link.peer?.handle(.items(input), now: local)
                }
                world.drain(link, side)
            }
        }
    }

    /// Runs `body` on `side`'s endpoint of link `index` as that side's process, then drains it.
    private func onEndpoint(
        _ side: SimSide, link index: Int,
        _ body: @escaping (SimWorld, SimLink, CoreInstant) -> Void
    ) {
        guard index < links.count else { return checker.fail("no link \(index)") }
        let link = links[index]
        let process = process(of: link, side)
        perform(process) { world in
            guard !link.shutDown.contains(side) else { return }
            body(world, link, world.localNow(process))
            world.drain(link, side)
        }
    }

    /// `side` offers `offer` on link `index`, as `feature`'s offer.
    package func offerItems(
        _ offer: ItemOffer, feature: FeatureID = .clipboard, from side: SimSide, link index: Int = 0
    ) {
        onEndpoint(side, link: index) { _, link, now in
            let refusal =
                side == .host
                ? link.host?.offerItems(offer, feature: feature, now: now)
                : link.peer?.offerItems(offer, feature: feature, now: now)
            if let refusal { link.items(side).recordOfferRefusal(refusal) }
        }
    }

    /// `side` withdraws its offer of `token` on link `index`.
    package func withdrawOffer(_ token: Data, from side: SimSide, link index: Int = 0) {
        onEndpoint(side, link: index) { _, link, now in
            switch side {
            case .host: link.host?.withdrawOffer(token, now: now)
            case .peer: link.peer?.withdrawOffer(token, now: now)
            }
        }
    }

    /// `side` releases the far side's offer of `token` on link `index`.
    package func releaseOffer(_ token: Data, by side: SimSide, link index: Int = 0) {
        onEndpoint(side, link: index) { _, link, now in
            switch side {
            case .host: link.host?.releaseOffer(token, now: now)
            case .peer: link.peer?.releaseOffer(token, now: now)
            }
        }
    }

    /// The host takes the peer's drag offer of `token` on link `index`.
    package func takeDrag(_ token: Data, link index: Int = 0) {
        onEndpoint(.host, link: index) { world, link, now in
            guard let result = link.host?.takeDrag(token, now: now) else { return }
            link.items(.host).recordTake(token, result, at: world.now)
        }
    }

    /// `side` pulls `request` on link `index`.
    package func pullItem(_ request: PullRequest, by side: SimSide, link index: Int = 0) {
        onEndpoint(side, link: index) { world, link, now in
            let result =
                side == .host ? link.host?.pullItem(request, now: now) : link.peer?.pullItem(request, now: now)
            if let result { link.items(side).recordPull(request, result, at: world.now) }
        }
    }

    /// `side` cancels every pull it opened on link `index` that has not ended.
    package func cancelPulls(by side: SimSide, link index: Int = 0) {
        onEndpoint(side, link: index) { _, link, now in
            let items = link.items(side)
            let ended = Set(items.pullsEnded.map(\.id))
            for case .success(let id) in items.pulls.map(\.result) where !ended.contains(id) {
                switch side {
                case .host: link.host?.cancelPull(id, now: now)
                case .peer: link.peer?.cancelPull(id, now: now)
                }
            }
        }
    }
}
