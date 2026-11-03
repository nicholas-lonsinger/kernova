import Foundation
import KernovaAgentCore
import KernovaAgentHost
import KernovaAgentRuntime
import KernovaFileTree
import KernovaItemTransfer
import KernovaKit
import KernovaLogging
import KernovaWire
import Synchronization

/// A drag the guest offers, its items read.
package struct GuestDragOffer: Equatable, Sendable {
    /// The peer that offered it.
    package var peer: PeerHandle
    /// The offer's token.
    package var token: Data
    /// What it carries, in the offer's order.
    package var items: [DraggedOutItem]
}

/// The calls DRAG's host owner makes of the agent hub; the hub's own, and a
/// test's fake.
package protocol DragOutHub: AnyObject, Sendable {
    func takeDrag(
        _ token: Data, of peer: PeerHandle, _ completion: @escaping @Sendable (Result<DragTakeID, WireError>) -> Void)
    func pullItem(
        _ order: ItemPullOrder, from peer: PeerHandle,
        _ completion: @escaping @Sendable (Result<ItemPullID, WireError>) -> Void)
    func cancelPull(_ id: ItemPullID, on peer: PeerHandle)
    func controlTake(_ id: DragTakeID, _ control: DragTakeControl, on peer: PeerHandle)
    func cancelTake(_ id: DragTakeID, on peer: PeerHandle)
    func releaseOffer(_ token: Data, of peer: PeerHandle)
    func readItem(
        _ token: Data, item: UInt32, of peer: PeerHandle, _ completion: @escaping @Sendable (OfferedItem?) -> Void)
}

extension AgentHub: DragOutHub {}

/// DRAG's owner on the host: the drag the console peer offers now, read whole,
/// and the takes of it and their pulls.
///
/// It lives on the main actor. The hub's events and the answers to its calls
/// reach it in the order the hub emitted them, each hopping from the hub's
/// queue to the main queue, so a call's answer still comes before any event it
/// caused. A take's delivery is the exception: it settles on the hub's queue,
/// reading the offer a delivering catch names there, because a Mac destination
/// asking a promised item's name waits for it holding the main thread.
@MainActor
@Observable
package final class HubDragOut {
    /// The drag the console peer offers that nothing has taken yet, or nil.
    ///
    /// Cleared when the guest ends it, when it is taken, and when a new press
    /// begins on the display. The new-press clearing is a cheap filter only:
    /// the guest refuses a take of a drag its current press does not hold.
    package private(set) var offer: GuestDragOffer?

    /// The hub the owner calls, set once the hub exists: it is built from the
    /// router this owner is part of.
    @ObservationIgnored package var hub: (any DragOutHub)?

    @ObservationIgnored private let sink: ItemSinkAdapter<POSIXTreeFileSystem>
    @ObservationIgnored private let reporter: ClipboardTransferReporter
    @ObservationIgnored private let peerName: @MainActor () -> String

    /// The offer whose items are being read, by its token.
    @ObservationIgnored private var reading: (peer: PeerHandle, token: Data)?
    /// Every take still running, by each of its offers' tokens: the one taken,
    /// and the one a delivering catch names.
    @ObservationIgnored private var takes: [Data: GuestDragTake] = [:]
    /// Each take's id once the hub opened it, with the token it took and what
    /// hears its events.
    @ObservationIgnored private var takeEvents:
        [DragTakeID: (token: Data, events: @MainActor (GuestDragTakeEvent) -> Void)] = [:]
    /// What the hub's queue settles each take's delivery from, by its id.
    nonisolated private let deliveries = Deliveries()
    /// Each pull, until its one `.pullEnded`.
    @ObservationIgnored private var pulls: [ItemPullID: @MainActor (ItemPullResult) -> Void] = [:]

    private static let logger = KernovaLogger(subsystem: "app.kernova", category: "HubDragOut")

    /// An owner landing its pulls through `sink`, reporting them to `reporter`
    /// under the name `peerName` gives.
    package init(
        sink: ItemSinkAdapter<POSIXTreeFileSystem>, reporter: ClipboardTransferReporter,
        peerName: @escaping @MainActor () -> String
    ) {
        self.sink = sink
        self.reporter = reporter
        self.peerName = peerName
    }

    /// DRAG's owner, as the hub's item router hands it events: each hops to
    /// the main queue. The host offers no drag, so it serves no content.
    nonisolated package var owner: DragFeatureOwner<PeerHandle> {
        DragFeatureOwner(
            items: ItemFeatureOwner(
                usable: { [weak self] peer in Self.onMain { self?.consolePeerChanged(peer) } },
                events: { [weak self] peer, event in Self.onMain { self?.handle(event, from: peer) } },
                content: { _, _ in
                    .failure(WireError(.itemRepresentationUnavailable, debugDetail: "the host offers no drag"))
                }),
            takes: { [weak self, deliveries] peer, event in
                deliveries.hear(event)
                Self.onMain { self?.handle(event, from: peer) }
            })
    }

    nonisolated private static func onMain(_ body: @escaping @MainActor @Sendable () -> Void) {
        DispatchQueue.main.async { MainActor.assumeIsolated(body) }
    }

    // MARK: - The display

    /// A press began on the display: no drag offered before it is the press's.
    package func displayPressBegan() {
        offer = nil
    }

    /// Takes over ``offer`` for `display`, or returns nil when there is none.
    ///
    /// The take runs while `holds` stays true. Any earlier take is superseded:
    /// one before its Mac session ends, and one a Mac session carries keeps
    /// writing what its destination asks for.
    package func takeGuestDrag(
        display: any GuestDragDisplay, while holds: @escaping @MainActor () -> Bool
    ) -> GuestDragTake? {
        guard let offer, let hub else { return nil }
        self.offer = nil
        var superseded = Set<ObjectIdentifier>()
        for earlier in takes.values where superseded.insert(ObjectIdentifier(earlier)).inserted {
            earlier.supersede()
        }
        let transport = Transport(
            owner: self, hub: hub, peer: offer.peer, token: offer.token, count: offer.items.count)
        let take = GuestDragTake(
            items: offer.items, token: offer.token, transport: transport, display: display, reporter: reporter,
            peerName: peerName(), holds: holds,
            onFinished: { [weak self] finished in self?.takes = self?.takes.filter { $0.value !== finished } ?? [:] })
        takes[offer.token] = take
        take.begin()
        return take
    }

    // MARK: - The hub's events

    /// DRAG's console peer is now `peer`, or none: an offer of any other
    /// peer's is not the display's to take.
    func consolePeerChanged(_ peer: PeerHandle?) {
        if let offer, offer.peer != peer { self.offer = nil }
        if let reading, reading.peer != peer { self.reading = nil }
    }

    private func handle(_ event: ItemTransferEvent, from peer: PeerHandle) {
        switch event {
        case .offerReceived(let header):
            offerReceived(header.token, count: header.count, from: peer)
        case .offerEnded(_, .remote, let token, _):
            offerEnded(token)
        case .pullEnded(_, let id, let result):
            pullEnded(id, result)
        case .offerEnded(_, .local, _, _), .serveEnded:
            // The host offers no drag.
            break
        }
    }

    private func handle(_ event: DragTakeEvent, from peer: PeerHandle) {
        switch event {
        case .report(let id, let report): takeEvents[id]?.events(.report(report))
        case .ended(let id, let result): takeEnded(id, result)
        case .requested, .control, .cancelled: break
        }
    }

    /// The guest's offer of `token` ended.
    func offerEnded(_ token: Data) {
        if offer?.token == token { offer = nil }
        if reading?.token == token { reading = nil }
        takes[token]?.offerEnded(token)
    }

    /// Pull `id` ended as `result`.
    func pullEnded(_ id: ItemPullID, _ result: ItemPullResult) {
        pulls.removeValue(forKey: id)?(result)
    }

    /// Take `id` ended as `result`. An offer a delivering catch names carries
    /// the take's drag on, so it is the take's, never a drag to take.
    func takeEnded(_ id: DragTakeID, _ result: DragTakeResult) {
        guard let (token, events) = takeEvents.removeValue(forKey: id) else { return }
        if case .caught(let reoffer?) = result {
            if offer?.token == reoffer { offer = nil }
            if reading?.token == reoffer { reading = nil }
            takes[reoffer] = takes[token]
        }
        events(.ended(result))
    }

    /// Reads every item of `peer`'s offer of `token`, `count` of them; the
    /// last read makes it the current offer, unless it ended or another
    /// replaced it first. An offer of anything but files and folders cannot be
    /// carried, so it is released.
    func offerReceived(_ token: Data, count: Int, from peer: PeerHandle) {
        guard let hub else { return }
        reading = (peer, token)
        guard count > 0 else { return read([], of: token, from: peer) }
        let items = ReadItems()
        for index in 0..<UInt32(count) {
            hub.readItem(token, item: index, of: peer) { [weak self] item in
                let all = items.read.withLock { read -> [OfferedItem?]? in
                    read[index] = item
                    guard read.count == count else { return nil }
                    return (0..<UInt32(count)).map { read[$0] ?? nil }
                }
                guard let all else { return }
                Self.onMain { self?.read(all, of: token, from: peer) }
            }
        }
    }

    private func read(_ items: [OfferedItem?], of token: Data, from peer: PeerHandle) {
        guard let reading, reading.token == token, reading.peer == peer else { return }
        self.reading = nil
        let dragged = items.compactMap { $0.flatMap(DraggedOutItem.init) }
        guard !dragged.isEmpty, dragged.count == items.count else {
            Self.logger.log(.error, "The guest offered a drag of something other than files; releasing it")
            hub?.releaseOffer(token, of: peer)
            return
        }
        offer = GuestDragOffer(peer: peer, token: token, items: dragged)
    }

    // MARK: - A take's calls

    /// The hub-side of one take: its offer's peer and token, and its id once
    /// the hub opened it.
    private final class Transport: GuestDragTransport {
        private weak var owner: HubDragOut?
        private let hub: any DragOutHub
        private let peer: PeerHandle
        private let token: Data
        /// How many items the offer holds, which a delivering catch's offer
        /// holds too.
        private let count: Int
        private var id: DragTakeID?
        /// What the take said before the hub named it, in order.
        private var held: [DragTakeControl] = []
        private var cancelHeld = false

        init(owner: HubDragOut, hub: any DragOutHub, peer: PeerHandle, token: Data, count: Int) {
            self.owner = owner
            self.hub = hub
            self.peer = peer
            self.token = token
            self.count = count
        }

        func take(delivery: GuestDragDelivery, _ events: @escaping @MainActor (GuestDragTakeEvent) -> Void) {
            guard let owner else {
                delivery.settle(.undelivered)
                return events(.ended(.refused(WireError(.featureUnavailable, debugDetail: "no owner"))))
            }
            let deliveries = owner.deliveries
            let token = token
            let count = count
            hub.takeDrag(token, of: peer) { [weak self, weak owner, hub, peer] result in
                // Recorded on the hub's queue, before any of the take's
                // events can reach it.
                if case .success(let id) = result {
                    deliveries.add(id, count: count, delivery: delivery, peer: peer, hub: hub)
                } else {
                    delivery.settle(.undelivered)
                }
                HubDragOut.onMain {
                    switch result {
                    case .success(let id):
                        owner?.takeEvents[id] = (token, events)
                        self?.opened(id)
                    case .failure(let error):
                        events(.ended(.refused(error)))
                    }
                }
            }
        }

        /// The hub opened the take as `id`: what the take said before goes now.
        private func opened(_ id: DragTakeID) {
            self.id = id
            for control in held { hub.controlTake(id, control, on: peer) }
            held.removeAll()
            if cancelHeld { hub.cancelTake(id, on: peer) }
        }

        func control(_ control: DragTakeControl) {
            guard let id else { return held.append(control) }
            hub.controlTake(id, control, on: peer)
        }

        func cancel() {
            guard let id else {
                cancelHeld = true
                return
            }
            hub.cancelTake(id, on: peer)
        }

        func pull(
            _ item: DraggedOutItem, at index: Int, of token: Data, into directory: URL, named name: String,
            ended: @escaping @MainActor (Result<Void, WireError>) -> Void
        ) -> @MainActor () -> Void {
            guard let owner else {
                ended(.failure(WireError(.featureUnavailable, debugDetail: "no owner")))
                return {}
            }
            let order: ItemPullOrder
            do throws(WireError) {
                order = try owner.sink.order(
                    token: token, item: UInt32(index), representation: item.representation, byteCeiling: .max,
                    landing: .tree(directory: directory.path, name: .exactly(Data(name.utf8))))
            } catch {
                ended(.failure(error))
                return {}
            }
            let peer = peer
            let state = PullState()
            hub.pullItem(order, from: peer) { [weak owner, hub] result in
                HubDragOut.onMain {
                    switch result {
                    case .success(let id):
                        state.id = id
                        owner?.pulls[id] = { result in ended(Self.outcome(result)) }
                        if state.cancelled { hub.cancelPull(id, on: peer) }
                    case .failure(let error):
                        ended(.failure(error))
                    }
                }
            }
            return { [hub] in
                state.cancelled = true
                if let id = state.id { hub.cancelPull(id, on: peer) }
            }
        }

        func release(_ token: Data) {
            hub.releaseOffer(token, of: peer)
        }

        private static func outcome(_ result: ItemPullResult) -> Result<Void, WireError> {
            switch result {
            case .landed: .success(())
            case .failed(let error): .failure(error)
            case .closed(let closure): .failure(closure.error)
            }
        }
    }

    /// The items of one offer read so far, by index.
    private final class ReadItems: Sendable {
        let read = Mutex([UInt32: OfferedItem?]())
    }

    /// Every open take's delivery by its id, settled on the hub's queue as the
    /// take ends.
    private final class Deliveries: Sendable {
        private struct Entry: Sendable {
            var count: Int
            var delivery: GuestDragDelivery
            var peer: PeerHandle
            var hub: any DragOutHub
        }

        private let entries = Mutex([DragTakeID: Entry]())

        func add(_ id: DragTakeID, count: Int, delivery: GuestDragDelivery, peer: PeerHandle, hub: any DragOutHub) {
            entries.withLock { $0[id] = Entry(count: count, delivery: delivery, peer: peer, hub: hub) }
        }

        /// Hears a take event on the hub's queue: the guest answering the ask
        /// for a delivering drop, or the take ending, which settles its
        /// delivery once the offer it names is read. The hub reports a take
        /// that names an offer ended only once that offer arrived whole, so
        /// every item is there to read.
        func hear(_ event: DragTakeEvent) {
            switch event {
            case .report(let id, .delivering), .report(let id, .deliverRefused):
                entries.withLock { $0[id] }?.delivery.peerAnswered()
            case .ended(let id, let result):
                guard let entry = entries.withLock({ $0.removeValue(forKey: id) }) else { return }
                guard case .caught(let reoffer?) = result, entry.count > 0 else {
                    return entry.delivery.settle(.undelivered)
                }
                Self.read(reoffer, entry)
            case .report, .requested, .control, .cancelled:
                break
            }
        }

        /// Reads every item of the offer of `token`, as many as the taken offer
        /// held, and settles `entry`'s delivery with them.
        private static func read(_ token: Data, _ entry: Entry) {
            let count = entry.count
            let items = ReadItems()
            for index in 0..<UInt32(count) {
                entry.hub.readItem(token, item: index, of: entry.peer) { item in
                    let all = items.read.withLock { read -> [OfferedItem?]? in
                        read[index] = item
                        guard read.count == count else { return nil }
                        return (0..<UInt32(count)).map { read[$0] ?? nil }
                    }
                    guard let all else { return }
                    let delivered = all.compactMap { $0.flatMap(DraggedOutItem.init) }
                    entry.delivery.settle(
                        delivered.count == count ? .delivered(token: token, items: delivered) : .undelivered)
                }
            }
        }
    }

    /// A pull a take started, until the hub names it.
    @MainActor
    private final class PullState {
        var id: ItemPullID?
        var cancelled = false
    }
}

extension StreamClosure {
    /// What a pull that closed this way reports.
    fileprivate var error: WireError {
        switch self {
        case .resetByPeer(let error), .resetLocally(let error), .connectionClosedLocally(let error),
            .connectionClosedByPeer(let error):
            error
        case .completed, .connectionLost: WireError(.cancelled, debugDetail: "the pull's stream closed: \(self)")
        }
    }
}
