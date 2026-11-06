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

/// A drag in progress in the guest, which its take lists the items of.
package struct GuestDragOffer: Equatable, Sendable {
    /// The peer that offered it.
    package var peer: PeerHandle
    /// The offer's token.
    package var token: Data
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
}

extension AgentHub: DragOutHub {}

/// DRAG's owner on the host: the drag the console peer offers now, and the
/// takes of it and their pulls.
///
/// It lives on the main actor. The hub's events and the answers to its calls
/// reach it in the order the hub emitted them, each hopping from the hub's
/// queue to the main queue, so a call's answer still comes before any event it
/// caused. A take's delivery is the exception: it settles on the hub's queue,
/// because a Mac destination asking a promised item's name waits for it
/// holding the main thread.
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

    /// Every take still running, each with its offer's token: held by the
    /// take, since a guest may offer a token again while a take of it runs.
    @ObservationIgnored private var takes: [(token: Data, take: GuestDragTake)] = []
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
                content: { _, _, _ in
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
    /// The take runs while `holds` stays true. Any earlier take's guest drag
    /// ended with this press: one before its Mac session ends, and one a Mac
    /// session carried keeps its promises until this take's session begins,
    /// which writes the drag pasteboard over them.
    package func takeGuestDrag(
        display: any GuestDragDisplay, while holds: @escaping @MainActor () -> Bool
    ) -> GuestDragTake? {
        guard let offer, let hub else { return nil }
        self.offer = nil
        for earlier in liveTakes { earlier.newerTakeBegan() }
        let transport = Transport(owner: self, hub: hub, peer: offer.peer, token: offer.token)
        let take = GuestDragTake(
            transport: transport, display: display, reporter: reporter,
            peerName: peerName(), holds: holds,
            onFinished: { [weak self] finished in self?.takes.removeAll { $0.take === finished } },
            onHostSessionBegan: { [weak self] began in self?.hostSessionBegan(began) })
        takes.append((offer.token, take))
        take.begin()
        return take
    }

    /// The app is terminating: every take still running retires now, its
    /// promises withdrawn.
    package func endForTermination() {
        for take in liveTakes { take.endForTermination() }
    }

    /// `began`'s Mac session wrote the drag pasteboard: every other take's
    /// promises are gone from it.
    private func hostSessionBegan(_ began: GuestDragTake) {
        for take in liveTakes where take !== began { take.promisesReplaced() }
    }

    private var liveTakes: [GuestDragTake] { takes.map(\.take) }

    // MARK: - The hub's events

    /// DRAG's console peer is now `peer`, or none: an offer of any other
    /// peer's is not the display's to take.
    func consolePeerChanged(_ peer: PeerHandle?) {
        if let offer, offer.peer != peer { self.offer = nil }
    }

    private func handle(_ event: ItemTransferEvent, from peer: PeerHandle) {
        switch event {
        case .offerReceived(let header):
            offerReceived(header.token, from: peer)
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
        for live in takes where live.token == token { live.take.offerEnded() }
    }

    /// Pull `id` ended as `result`.
    func pullEnded(_ id: ItemPullID, _ result: ItemPullResult) {
        pulls.removeValue(forKey: id)?(result)
    }

    /// Take `id` ended as `result`.
    func takeEnded(_ id: DragTakeID, _ result: DragTakeResult) {
        takeEvents.removeValue(forKey: id)?.events(.ended(result))
    }

    /// `peer`'s drag offer of `token` arrived: it is the drag the display may
    /// take now, whose take lists its items.
    func offerReceived(_ token: Data, from peer: PeerHandle) {
        offer = GuestDragOffer(peer: peer, token: token)
    }

    // MARK: - A take's calls

    /// The hub-side of one take: its offer's peer and token, and its id once
    /// the hub opened it.
    private final class Transport: GuestDragTransport {
        private weak var owner: HubDragOut?
        private let hub: any DragOutHub
        private let peer: PeerHandle
        private let token: Data
        private var id: DragTakeID?
        /// What the take said before the hub named it, in order.
        private var held: [DragTakeControl] = []
        private var cancelHeld = false

        init(owner: HubDragOut, hub: any DragOutHub, peer: PeerHandle, token: Data) {
            self.owner = owner
            self.hub = hub
            self.peer = peer
            self.token = token
        }

        func take(delivery: GuestDragDelivery, _ events: @escaping @MainActor (GuestDragTakeEvent) -> Void) {
            guard let owner else {
                delivery.settle(.undelivered)
                return events(.ended(.refused(WireError(.featureUnavailable, debugDetail: "no owner"))))
            }
            let deliveries = owner.deliveries
            let token = token
            hub.takeDrag(token, of: peer) { [weak self, weak owner] result in
                // Recorded on the hub's queue, before any of the take's
                // events can reach it.
                if case .success(let id) = result {
                    deliveries.add(id, delivery: delivery)
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

        /// Lands the pull at exactly `destination`, a file promise's URL: a
        /// sandboxed app may write that path and nothing beside it
        /// (`NSFilePromiseProvider.h`: "Always use the supplied URL").
        func pull(
            _ item: DraggedOutItem, at index: Int, to destination: URL,
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
                    landing: .exactPath(destination.path))
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

        func release() {
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

    /// Every open take's delivery by its id, named and settled on the hub's
    /// queue as the take reports.
    private final class Deliveries: Sendable {
        private struct Entry: Sendable {
            /// The drag's items, once the take's first `TARGETED` listed them.
            var items: [DraggedOutItem] = []
            var delivery: GuestDragDelivery
        }

        private let entries = Mutex([DragTakeID: Entry]())

        func add(_ id: DragTakeID, delivery: GuestDragDelivery) {
            entries.withLock { $0[id] = Entry(delivery: delivery) }
        }

        /// Hears a take event on the hub's queue: the guest answering the ask
        /// for a delivering drop, its drop naming the promises, or the take
        /// ending, which settles its delivery.
        func hear(_ event: DragTakeEvent) {
            switch event {
            case .report(let id, .targeted(let items)):
                entries.withLock { entries in
                    if entries[id]?.items.isEmpty == true { entries[id]?.items = DraggedOutItem.carried(items) }
                }
            case .report(let id, .delivering), .report(let id, .deliverRefused):
                entries.withLock { $0[id] }?.delivery.peerAnswered()
            case .report(let id, .named(let names)):
                guard let entry = entries.withLock({ $0[id] }) else { return }
                let promised = entry.items.indices.filter { entry.items[$0].isPromised }
                let delivery = DragDelivery(
                    names: Dictionary(uniqueKeysWithValues: zip(promised, names)), sizes: [:])
                entry.delivery.named(Self.items(entry.items, delivery))
            case .ended(let id, let result):
                guard let entry = entries.withLock({ $0.removeValue(forKey: id) }) else { return }
                guard case .caught(let delivery?) = result else { return entry.delivery.settle(.undelivered) }
                entry.delivery.settle(.delivered(Self.items(entry.items, delivery)))
            case .report, .requested, .control, .cancelled:
                break
            }
        }

        /// `items` under the names `delivery` gives its promises and the sizes
        /// it gives its folders.
        private static func items(_ items: [DraggedOutItem], _ delivery: DragDelivery) -> [DraggedOutItem] {
            items.indices.map { index in
                var item = items[index]
                if let name = delivery.names[index] { item.name = name }
                if let size = delivery.sizes[index] { item.sizeEstimate = size }
                return item
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
