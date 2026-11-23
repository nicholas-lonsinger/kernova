#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaAgentCore
@testable import KernovaAgentHost
import KernovaAgentRuntime
import KernovaAgentSimulation
import KernovaPortableTestSupport
import KernovaWire
import Testing

/// The hub's item calls and events against real peers, over in-memory streams, on the platform clock.
@Suite("Agent hub items")
struct AgentHubItemTests {
    static let offConsole = PeerClaim.session(.user, instance: 2)
    static let offState = PeerSessionState(console: .off, sessionID: "2", userName: "other")
    static let allEnabled = SimItems.policy(PolicySnapshot())
    static let offer = SimItems.offer(1, [[SimItems.representation(.inline, size: 64)]])
    static let token = SimItems.token(1)
    static let order = ItemPullOrder(SimItems.request(1), landing: DecodingItemSink.landing)

    private func harness(policy: PolicySnapshot = Self.allEnabled) async throws -> HubHarness {
        let harness = HubHarness(policy: policy, items: MemoryItems().adapters())
        try await harness.attached()
        return harness
    }

    /// A started runtime serving every item feature, its events recorded into `events`.
    private func runtime(
        _ harness: HubHarness, claim: PeerClaim = Fixture.peerClaim, state: PeerSessionState = Fixture.peerState,
        events: Recorder<PeerEvent> = Recorder()
    ) -> PeerAgentRuntime {
        let runtime = harness.runtime(
            claim: claim, state: state, registry: PeerFeatureRegistry(items: MemoryItems().adapters()), events: events)
        runtime.start()
        return runtime
    }

    private func close(_ runtimes: [PeerAgentRuntime], _ harness: HubHarness) async throws {
        for runtime in runtimes {
            try await Backstop("runtime.close").park { resume in runtime.close { resume(()) } }
        }
        harness.hub.close()
    }

    private func offer(
        _ harness: HubHarness, _ feature: FeatureID, _ offer: ItemOffer = Self.offer
    ) async throws -> Result<PeerHandle, WireError> {
        try await Backstop("harness.hub.offerItems").park { resume in
            harness.hub.offerItems(offer, feature: feature) { resume($0) }
        }
    }

    private static func isOfferReceived(_ event: PeerEvent) -> Bool {
        if case .items(.offerReceived) = event { true } else { false }
    }

    @Test("With no console peer an offer is refused FEATURE_UNAVAILABLE with the absence, and sent nowhere")
    func noConsolePeerRefuses() async throws {
        let harness = try await harness()
        #expect(try await offer(harness, .clipboard) == .failure(WireError(.featureUnavailable, absence: .noAgent)))

        let events = Recorder<PeerEvent>()
        let off = runtime(harness, claim: Self.offConsole, state: Self.offState, events: events)
        let snapshot = try await harness.snapshot { $0.peers.count == 1 && $0.features[.clipboard].isAvailable }
        #expect(snapshot.consolePeers.isEmpty)
        #expect(
            try await offer(harness, .clipboard) == .failure(WireError(.featureUnavailable, absence: .notOnConsole)))
        try await harness.settled()
        #expect(!events.elements.contains(where: Self.isOfferReceived))
        try await close([off], harness)
    }

    @Test("A peer's offer is read and pulled through the hub, each answer before the events it causes")
    func pullThroughHub() async throws {
        let harness = try await harness()
        let peer = HubPeer(harness, claim: Fixture.peerClaim, items: MemoryItems())
        let handle = try await harness.snapshot { $0.consolePeers.count == 3 }.peers[0].handle
        peer.send(.offer(ItemRequestID(rawValue: 1), Self.offer, feature: .clipboard))
        var log = harness.itemLog.waiter()
        let received = try await log.next { if case .event(.items(_, .offerReceived)) = $0 { true } else { false } }
        guard case .event(.items(handle, .offerReceived(let header))) = received else {
            Issue.record("received \(received)"); return
        }
        #expect(header.token == Self.token)

        let item = try await Backstop("harness.hub.readItem").park { resume in
            harness.hub.readItem(Self.token, item: 0, of: handle) { resume($0) }
        }
        #expect(item == Self.offer.items[0])
        let pulled = try await Backstop("harness.hub.pullItem").park { resume in
            harness.hub.pullItem(Self.order, from: handle) { result in
                harness.itemLog.record(.note("pulled"))
                resume(result)
            }
        }
        guard case .success(let id) = pulled else { Issue.record("pulled \(pulled)"); return }
        let ended = try await log.next { if case .event(.items(_, .pullEnded)) = $0 { true } else { false } }
        guard case .event(.items(handle, .pullEnded(.clipboard, id, let result))) = ended, case .landed = result else {
            Issue.record("ended \(ended)"); return
        }
        let entries = harness.itemLog.elements
        #expect(entries.firstIndex(of: .note("pulled"))! < entries.firstIndex(of: ended)!)

        harness.hub.releaseOffer(Self.token, of: handle)
        var events = peer.events.waiter()
        _ = try await events.next {
            if case .items(.offerEnded(.clipboard, .local, Self.token, _)) = $0 { true } else { false }
        }
        harness.hub.close()
    }

    /// The peer's clipboard offer of `count` inline items, once the hub has forwarded it.
    private func offered(_ harness: HubHarness, count: Int, items: MemoryItems) async throws -> (HubPeer, PeerHandle) {
        let peer = HubPeer(harness, claim: Fixture.peerClaim, items: items)
        let handle = try await harness.snapshot { $0.consolePeers.count == 3 }.peers[0].handle
        let offer = SimItems.offer(1, Array(repeating: [SimItems.representation(.inline, size: 64)], count: count))
        peer.send(.offer(ItemRequestID(rawValue: 1), offer, feature: .clipboard))
        var log = harness.itemLog.waiter()
        _ = try await log.next { if case .event(.items(_, .offerReceived)) = $0 { true } else { false } }
        return (peer, handle)
    }

    private static func order(item: Int) -> ItemPullOrder {
        ItemPullOrder(SimItems.request(1, item: UInt32(item)), landing: DecodingItemSink.landing)
    }

    @Test("Three times the 64-stream limit of pulls, asked at once, each opens as a slot frees and every one lands")
    func pullsPastTheStreamLimitAllLand() async throws {
        let harness = try await harness()
        let count = 192
        let (_, handle) = try await offered(harness, count: count, items: MemoryItems())
        let opened = Recorder<Result<ItemPullID, WireError>>()
        for item in 0..<count {
            harness.hub.pullItem(Self.order(item: item), from: handle) { opened.record($0) }
        }
        var answers = opened.waiter()
        var ids: Set<ItemPullID> = []
        for _ in 0..<count {
            switch try await answers.next(where: { _ in true }) {
            case .success(let id): ids.insert(id)
            case .failure(let error): Issue.record("a pull was refused: \(error)")
            }
        }
        var log = harness.itemLog.waiter()
        var landed = 0
        while landed < ids.count {
            let ended = try await log.next { if case .event(.items(_, .pullEnded)) = $0 { true } else { false } }
            guard case .event(.items(handle, .pullEnded(.clipboard, let id, let result))) = ended, ids.contains(id)
            else { Issue.record("ended \(ended)"); return }
            guard case .landed = result else { Issue.record("pull \(id.stream.rawValue) ended \(result)"); return }
            landed += 1
        }
        harness.hub.close()
    }

    @Test("A pull waiting for a stream slot is refused ITEM_OFFER_STALE once its offer ends, and never opens")
    func waitingPullRefusedAtOfferEnd() async throws {
        let harness = try await harness()
        // Reads are held, so every opened pull keeps its slot.
        let (_, handle) = try await offered(harness, count: 65, items: MemoryItems(holdsReads: true))
        let opened = Recorder<Result<ItemPullID, WireError>>()
        for item in 0..<64 {
            harness.hub.pullItem(Self.order(item: item), from: handle) { opened.record($0) }
        }
        var answers = opened.waiter()
        for _ in 0..<64 {
            guard case .success = try await answers.next(where: { _ in true }) else {
                Issue.record("a pull under the limit did not open"); return
            }
        }
        let waiting = Recorder<Result<ItemPullID, WireError>>()
        harness.hub.pullItem(Self.order(item: 64), from: handle) { waiting.record($0) }
        try await harness.settled()
        #expect(waiting.elements.isEmpty, "the 65th pull was answered while every slot was held")

        harness.hub.releaseOffer(SimItems.token(1), of: handle)
        var answer = waiting.waiter()
        guard case .failure(let error) = try await answer.next(where: { _ in true }) else {
            Issue.record("the waiting pull opened after its offer ended"); return
        }
        #expect(error.code == .itemOfferStale)
        harness.hub.close()
    }

    @Test("A call to a peer the hub does not hold is answered at once, as a connection that ended")
    func gonePeer() async throws {
        let harness = try await harness()
        let gone = PeerHandle(rawValue: 99)
        let pulled = try await Backstop("harness.hub.pullItem").park { resume in
            harness.hub.pullItem(Self.order, from: gone) { resume($0) }
        }
        guard case .failure(let error) = pulled else { Issue.record("pulled \(pulled)"); return }
        #expect(error.code == .shuttingDown)
        let item = try await Backstop("harness.hub.readItem").park { resume in
            harness.hub.readItem(Self.token, item: 0, of: gone) { resume($0) }
        }
        #expect(item == nil)
        harness.hub.close()
    }
}
