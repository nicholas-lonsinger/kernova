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
    /// The feature is usable on this peer's connection now, described; nil for nowhere.
    case usable(FeatureID, on: String?)
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
            usable: { peer in heard.record(.usable(feature, on: peer.map { "\($0)" })) },
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
            if case .requested(let id, _) = event { runtime.withLock { $0 }?.answerDragTake(id, .caught(folderSizes: nil)) }
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

        #expect(await offer(SimItems.offer(2, []), .drag, on: peer) == nil)
        _ = await host.next { if case .items(.drag, .offerReceived) = $0 { true } else { false } }
        let took = await withCheckedContinuation { continuation in
            harness.hub.takeDrag(SimItems.token(2), of: handle) { continuation.resume(returning: $0) }
        }
        guard case .success(let take) = took else { Issue.record("took \(took)"); return }
        _ = await host.next { $0 == .take(.ended(take, .caught(nil))) }
        let asked = peerHeard.elements.contains { heard in
            if case .take(.requested(_, SimItems.token(2))) = heard { true } else { false }
        }
        #expect(asked)

        await harness.settled()
        let delivered = harness.itemLog.elements.compactMap { entry -> Heard? in
            switch entry {
            case .event(.items(_, let event)): .items(event.feature, event)
            case .event(.dragTake(_, let event)): .take(event)
            case .event(.consolePeer(let feature, let peer)): .usable(feature, on: peer.map { "\($0)" })
            case .note: nil
            }
        }
        #expect(hostHeard.elements == delivered)
        let on = "\(handle)"
        // DROP, which the peer does not serve, never had a console peer, so its owner hears nothing.
        #expect(Array(hostHeard.elements.prefix(2)) == [.usable(.clipboard, on: on), .usable(.drag, on: on)])
        #expect(Array(peerHeard.elements.prefix(2)) == [.usable(.clipboard, on: "()"), .usable(.drag, on: "()")])

        await withCheckedContinuation { continuation in peer.close { continuation.resume() } }
        _ = await host.next { $0 == .usable(.drag, on: nil) }
        await harness.settled()
        let hostTail = hostHeard.elements.suffix(2)
        #expect(Array(hostTail) == [.usable(.clipboard, on: nil), .usable(.drag, on: nil)])
        let peerTail = peerHeard.elements.filter { if case .usable = $0 { true } else { false } }.suffix(2)
        #expect(Array(peerTail) == [.usable(.clipboard, on: nil), .usable(.drag, on: nil)])
        harness.hub.close()
    }

    // MARK: Usability

    /// A hub whose router owns every item feature, recording into `heard`, its policy `policy`.
    private static func hub(
        _ heard: Recorder<Heard>, policy: PolicySnapshot = SimItems.policy(PolicySnapshot())
    ) async -> HubHarness {
        let router: ItemFeatureRouter<PeerHandle> = router(heard: heard)
        let harness = HubHarness(
            policy: policy, items: MemoryItems().adapters(), itemEvents: { router.deliver($0) })
        await harness.attached()
        return harness
    }

    /// A started peer runtime on `harness` whose router owns CLIPBOARD and DRAG, recording into `heard`.
    private static func peer(
        _ harness: HubHarness, _ heard: Recorder<Heard> = Recorder(), claim: PeerClaim = Fixture.peerClaim,
        state: PeerSessionState = Fixture.peerState
    ) -> PeerAgentRuntime {
        let router: ItemFeatureRouter<Void> = router([.clipboard, .drag], heard: heard)
        let runtime = PeerAgentRuntime(
            claim: claim, state: state,
            registry: PeerFeatureRegistry(items: MemoryItems().adapters(router.features)),
            dialer: HubDialer(harness: harness), scheduler: SystemScheduler(), logger: Fixture.logger,
            handlers: PeerAgentRuntime.Handlers(event: { router.deliver($0) }, stop: { _ in }))
        runtime.start()
        return runtime
    }

    private static func usable(_ heard: Recorder<Heard>) -> [Heard] {
        heard.elements.filter { if case .usable = $0 { true } else { false } }
    }

    private static func close(_ runtime: PeerAgentRuntime) async {
        await withCheckedContinuation { continuation in runtime.close { continuation.resume() } }
    }

    @Test(
        "Host: a feature's first console peer, its move away and back, and its connection's end each reach the owner once"
    )
    func hostConsoleMoves() async {
        let heard = Recorder<Heard>()
        let harness = await Self.hub(heard)
        let first = Self.peer(harness)
        var waiter = heard.waiter()
        _ = await waiter.next { $0 == .usable(.drag, on: "\(PeerHandle(rawValue: 1))") }
        let a = "\(PeerHandle(rawValue: 1))"
        #expect(Self.usable(heard) == [.usable(.clipboard, on: a), .usable(.drag, on: a)])

        // The host's offer on the console peer ends before the owner hears the console moved off it.
        let offered = await withCheckedContinuation { continuation in
            harness.hub.offerItems(SimItems.offer(1, []), feature: .clipboard) { continuation.resume(returning: $0) }
        }
        #expect(offered == .success(PeerHandle(rawValue: 1)))
        first.setPeerState(PeerSessionState(console: .off, sessionID: "1", userName: "user"))
        _ = await waiter.next { $0 == .usable(.drag, on: nil) }
        let afterOffer = heard.elements.drop { $0 != .usable(.drag, on: a) }.dropFirst()
        guard case .items(.clipboard, .offerEnded(.clipboard, .local, _, _))? = afterOffer.first else {
            Issue.record("after the move: \(Array(afterOffer))"); return
        }
        #expect(Array(afterOffer.dropFirst()) == [.usable(.clipboard, on: nil), .usable(.drag, on: nil)])

        let second = Self.peer(
            harness, claim: AgentHubItemTests.offConsole,
            state: PeerSessionState(console: .on, sessionID: "2", userName: "other"))
        _ = await waiter.next { if case .usable(.drag, on: .some) = $0 { true } else { false } }
        let b = "\(PeerHandle(rawValue: 2))"
        await Self.close(second)
        _ = await waiter.next { $0 == .usable(.drag, on: nil) }
        await harness.settled()
        #expect(
            Self.usable(heard) == [
                .usable(.clipboard, on: a), .usable(.drag, on: a), .usable(.clipboard, on: nil),
                .usable(.drag, on: nil), .usable(.clipboard, on: b), .usable(.drag, on: b),
                .usable(.clipboard, on: nil), .usable(.drag, on: nil),
            ])
        await Self.close(first)
        harness.hub.close()
    }

    @Test("Host: a policy turning a feature off takes its console peer, and no other feature's")
    func hostPolicyOff() async {
        let heard = Recorder<Heard>()
        let harness = await Self.hub(heard)
        let peer = Self.peer(harness)
        var waiter = heard.waiter()
        _ = await waiter.next { if case .usable(.drag, on: .some) = $0 { true } else { false } }
        let a = "\(PeerHandle(rawValue: 1))"
        harness.hub.setPolicy(PolicySnapshot([FeaturePolicyValue(feature: .drag, enabled: true)]))
        _ = await waiter.next { $0 == .usable(.clipboard, on: nil) }
        await harness.settled()
        #expect(
            Self.usable(heard) == [.usable(.clipboard, on: a), .usable(.drag, on: a), .usable(.clipboard, on: nil)])
        await Self.close(peer)
        harness.hub.close()
    }

    @Test(
        "Agent: first usability, policy off and the connection's end each reach the owner once; a console move is its own"
    )
    func agentUsability() async {
        let heard = Recorder<Heard>()
        let harness = await Self.hub(Recorder())
        let peer = Self.peer(harness, heard)
        var waiter = heard.waiter()
        _ = await waiter.next { $0 == .usable(.drag, on: "()") }
        #expect(Self.usable(heard) == [.usable(.clipboard, on: "()"), .usable(.drag, on: "()")])

        peer.setPeerState(PeerSessionState(console: .off, sessionID: "1", userName: "user"))
        harness.hub.setPolicy(PolicySnapshot([FeaturePolicyValue(feature: .drag, enabled: true)]))
        _ = await waiter.next { $0 == .usable(.clipboard, on: nil) }
        await Self.close(peer)
        _ = await waiter.next { $0 == .usable(.drag, on: nil) }
        await flush(peer.queue)
        #expect(
            Self.usable(heard) == [
                .usable(.clipboard, on: "()"), .usable(.drag, on: "()"), .usable(.clipboard, on: nil),
                .usable(.drag, on: nil),
            ])
        harness.hub.close()
    }

    private func offer(_ offer: ItemOffer, _ feature: FeatureID, on peer: PeerAgentRuntime) async -> WireError? {
        await withCheckedContinuation { continuation in
            peer.offerItems(offer, feature: feature) { continuation.resume(returning: $0) }
        }
    }
}
#endif
