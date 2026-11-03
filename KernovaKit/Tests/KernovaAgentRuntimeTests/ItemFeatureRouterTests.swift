#if canImport(Darwin) || os(Linux)
#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaAgentCore
import KernovaAgentHost
import KernovaAgentRuntime
import KernovaAgentSimulation
import KernovaFileTree
import KernovaItemTransfer
import KernovaSynchronization
import KernovaWire
import Testing

/// What one router's owners heard, each entry naming the owner that heard it.
private enum Heard: Sendable, Equatable {
    case items(FeatureID, ItemTransferEvent)
    case take(DragTakeEvent)
    case content(FeatureID, token: Data)
}

/// A router whose owners — of `features` — record into `heard`, each serving `content` when pulled.
private func router<Peer: Sendable>(
    _ features: Set<FeatureID> = ItemFeatureAvailability.offering, heard: Recorder<Heard>,
    content: ItemContent = .inline(Data("routed".utf8)), takes: @escaping @Sendable (DragTakeEvent) -> Void = { _ in }
) -> ItemFeatureRouter<Peer> {
    func owner(_ feature: FeatureID) -> ItemFeatureOwner<Peer>? {
        guard features.contains(feature) else { return nil }
        return ItemFeatureOwner(
            events: { _, event in heard.record(.items(feature, event)) },
            content: { request, _ in
                heard.record(.content(feature, token: request.token))
                return .success(content)
            })
    }
    return ItemFeatureRouter(
        clipboard: owner(.clipboard), drop: owner(.drop),
        drag: owner(.drag).map { items in
            DragFeatureOwner(items: items) { _, event in
                heard.record(.take(event))
                takes(event)
            }
        })
}

@Suite("Item feature router")
struct ItemFeatureRouterTests {
    static let pull = ItemPullID(generation: ConnectionGeneration(rawValue: 1), stream: StreamID(rawValue: 4))
    static let take = DragTakeID(generation: ConnectionGeneration(rawValue: 1), stream: StreamID(rawValue: 8))
    static let closed = StreamClosure.resetLocally(WireError(.cancelled))

    @Test("Each item event reaches its feature's owner alone, in the order delivered")
    func eventsRouteByFeature() {
        let heard = Recorder<Heard>()
        let router: ItemFeatureRouter<PeerHandle> = router(heard: heard)
        let events: [ItemTransferEvent] = [
            .offerEnded(.drop, .local, token: SimItems.token(1), Self.closed),
            .pullEnded(.clipboard, Self.pull, .closed(Self.closed)),
            .serveEnded(.drag, Self.pull, .landed),
            .offerEnded(.clipboard, .remote, token: SimItems.token(2), Self.closed),
            .serveEnded(.drop, Self.pull, .closed(Self.closed)),
        ]
        for event in events { router.deliver(event, from: PeerHandle(rawValue: 1)) }
        #expect(heard.elements == events.map { .items($0.feature, $0) })
    }

    @Test("A drag take reaches DRAG's owner, interleaved in order with item events")
    func dragTakeReachesDrag() {
        let heard = Recorder<Heard>()
        let router: ItemFeatureRouter<Void> = router(heard: heard)
        let offerEnded = ItemTransferEvent.offerEnded(.drag, .local, token: SimItems.token(1), Self.closed)
        router.deliver(.dragTake(.requested(Self.take, token: SimItems.token(1))))
        router.deliver(.items(offerEnded))
        router.deliver(.policyReceived)
        #expect(heard.elements == [.take(.requested(Self.take, token: SimItems.token(1))), .items(.drag, offerEnded)])
    }

    @Test("Content comes from the owner of the pulled offer's feature", arguments: [FeatureID.clipboard, .drop, .drag])
    func contentReachesOwner(_ feature: FeatureID) {
        let heard = Recorder<Heard>()
        let router: ItemFeatureRouter<PeerHandle> = router(heard: heard)
        let result = router.content(feature, SimItems.request(3), SimItems.representation(.inline, size: 6))
        #expect(result == .success(.inline(Data("routed".utf8))))
        #expect(heard.elements == [.content(feature, token: SimItems.token(3))])
    }

    @Test("Only the features given an owner are the router's, and content of another is unavailable")
    func featuresAreOwners() {
        let heard = Recorder<Heard>()
        let router: ItemFeatureRouter<PeerHandle> = router([.clipboard, .drag], heard: heard)
        #expect(router.features == [.clipboard, .drag])
        #expect(ItemFeatureRouter<PeerHandle>().features.isEmpty)
        let content = router.content(.drop, SimItems.request(1), SimItems.representation(.inline, size: 1))
        guard case .failure(let error) = content else { Issue.record("content of an unowned feature"); return }
        #expect(error.code == .itemRepresentationUnavailable)
        #expect(heard.elements.isEmpty)
    }

    @Test(
        "A peer advertises available exactly the features its router has owners for, and item transfer only with one",
        arguments: [Set<FeatureID>(), [.clipboard], [.clipboard, .drag]])
    func advertFollowsOwners(_ owned: Set<FeatureID>) async {
        let router: ItemFeatureRouter<Void> = router(owned, heard: Recorder())
        let harness = PeerRuntimeHarness(
            items: ItemAdapters(
                source: RegisteredItemAdapters(), sink: RegisteredItemAdapters(), features: router.features))
        harness.runtime.start()
        let link = await harness.connect(1)
        switch link.far.peerAdvert(.itemTransfer) {
        case .available? where !owned.isEmpty, .absent(.notImplemented, _)? where owned.isEmpty: break
        case let advert: Issue.record("item transfer advertised \(String(describing: advert))")
        }
        for feature in ItemFeatureAvailability.offering {
            switch link.far.peerAdvert(feature) {
            case .available? where owned.contains(feature), .absent(.notImplemented, _)? where !owned.contains(feature):
                continue
            case let advert:
                Issue.record("\(feature) advertised \(String(describing: advert))")
            }
        }
    }

    @Test("Through a hub and a peer runtime, each end's owners hear their features' events in order, and serve")
    func routesThroughHubAndPeer() async {
        let (hostHeard, peerHeard) = (Recorder<Heard>(), Recorder<Heard>())
        let hostRouter: ItemFeatureRouter<PeerHandle> = router(heard: hostHeard)
        let harness = HubHarness(
            policy: SimItems.policy(PolicySnapshot()),
            items: ItemAdapters(source: MemoryItems(), sink: MemoryItems(), features: hostRouter.features),
            itemEvents: { hostRouter.deliver($0) })
        await harness.attached()
        let runtime = Locked<PeerAgentRuntime?>(nil)
        let peerRouter: ItemFeatureRouter<Void> = router([.clipboard, .drag], heard: peerHeard) { event in
            if case .requested(let id, _) = event { runtime.withLock { $0 }?.answerDragTake(id, .taken) }
        }
        let peer = PeerAgentRuntime(
            claim: Fixture.peerClaim, state: Fixture.peerState,
            registry: PeerFeatureRegistry(
                items: ItemAdapters(
                    source: ItemSourceAdapter(fileSystem: POSIXTreeFileSystem()) { peerRouter.content($0, $1, $2) },
                    sink: MemoryItems(), features: peerRouter.features)),
            dialer: HubDialer(harness: harness), scheduler: SystemScheduler(), logger: Fixture.logger,
            handlers: PeerAgentRuntime.Handlers(event: { peerRouter.deliver($0) }, stop: { _ in }))
        runtime.withLock { $0 = peer }
        peer.start()
        let ready = await harness.snapshot { $0.consolePeers[.clipboard] != nil && $0.consolePeers[.drag] != nil }
        let handle = ready.peers[0].handle
        guard case .absent(.notImplemented, _) = ready.features[.drop] else {
            Issue.record("DROP, which the peer has no owner for, is \(ready.features[.drop])"); return
        }

        let representation = SimItems.representation(.inline, size: 6)
        #expect(await offer(SimItems.offer(1, [[representation]]), .clipboard, on: peer) == nil)
        var host = hostHeard.waiter()
        _ = await host.next { if case .items(.clipboard, .offerReceived) = $0 { true } else { false } }
        let pulled = await withCheckedContinuation { continuation in
            harness.hub.pullItem(ItemPullOrder(SimItems.request(1), landing: .inline), from: handle) {
                continuation.resume(returning: $0)
            }
        }
        guard case .success(let id) = pulled else { Issue.record("pulled \(pulled)"); return }
        _ = await host.next { $0 == .items(.clipboard, .pullEnded(.clipboard, id, .landed(.inline(Data())))) }
        var served = peerHeard.waiter()
        _ = await served.next { $0 == .content(.clipboard, token: SimItems.token(1)) }
        _ = await served.next {
            if case .items(.clipboard, .serveEnded(.clipboard, _, .landed)) = $0 { true } else { false }
        }

        #expect(await offer(SimItems.offer(2, [[representation]]), .drag, on: peer) == nil)
        _ = await host.next { if case .items(.drag, .offerReceived) = $0 { true } else { false } }
        let took = await withCheckedContinuation { continuation in
            harness.hub.takeDrag(SimItems.token(2), of: handle) { continuation.resume(returning: $0) }
        }
        guard case .success(let take) = took else { Issue.record("took \(took)"); return }
        _ = await host.next { $0 == .take(.ended(take, .taken)) }
        let asked = peerHeard.elements.contains { heard in
            if case .take(.requested(_, SimItems.token(2))) = heard { true } else { false }
        }
        #expect(asked)

        await harness.settled()
        let delivered = harness.itemLog.elements.compactMap { entry -> Heard? in
            switch entry {
            case .event(.items(_, let event)): .items(event.feature, event)
            case .event(.dragTake(_, let event)): .take(event)
            case .note: nil
            }
        }
        #expect(hostHeard.elements == delivered)
        await withCheckedContinuation { continuation in peer.close { continuation.resume() } }
        harness.hub.close()
    }

    private func offer(_ offer: ItemOffer, _ feature: FeatureID, on peer: PeerAgentRuntime) async -> WireError? {
        await withCheckedContinuation { continuation in
            peer.offerItems(offer, feature: feature) { continuation.resume(returning: $0) }
        }
    }
}
#endif
