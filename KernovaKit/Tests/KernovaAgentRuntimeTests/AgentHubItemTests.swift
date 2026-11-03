#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaAgentCore
@testable import KernovaAgentHost
import KernovaAgentRuntime
import KernovaAgentSimulation
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
    static let order = ItemPullOrder(SimItems.request(1), landing: .inline)

    private func harness(policy: PolicySnapshot = Self.allEnabled) async -> HubHarness {
        let harness = HubHarness(policy: policy, items: MemoryItems().adapters())
        await harness.attached()
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

    private func close(_ runtimes: [PeerAgentRuntime], _ harness: HubHarness) async {
        for runtime in runtimes {
            await withCheckedContinuation { continuation in runtime.close { continuation.resume() } }
        }
        harness.hub.close()
    }

    private func offer(
        _ harness: HubHarness, _ feature: FeatureID, _ offer: ItemOffer = Self.offer
    ) async -> Result<PeerHandle, WireError> {
        await withCheckedContinuation { continuation in
            harness.hub.offerItems(offer, feature: feature) { continuation.resume(returning: $0) }
        }
    }

    private static func isOfferReceived(_ event: PeerEvent) -> Bool {
        if case .items(.offerReceived) = event { true } else { false }
    }

    @Test("An offer goes to the console session's peer only, and its events carry that peer")
    func offerReachesConsolePeer() async {
        let harness = await harness()
        let (onEvents, offEvents) = (Recorder<PeerEvent>(), Recorder<PeerEvent>())
        let on = runtime(harness, events: onEvents)
        let off = runtime(harness, claim: Self.offConsole, state: Self.offState, events: offEvents)
        let ready = await harness.snapshot { $0.peers.count == 2 && $0.consolePeers.count == 3 }
        guard let console = ready.peers.first(where: { $0.sessionID == "1" })?.handle else {
            Issue.record("no peer of session 1"); return
        }
        #expect(ready.consolePeers == [.clipboard: console, .drop: console, .drag: console])

        #expect(await offer(harness, .clipboard) == .success(console))
        var received = onEvents.waiter()
        guard case .items(.offerReceived(let header)) = await received.next(where: Self.isOfferReceived) else {
            Issue.record("no offer received"); return
        }
        #expect(header.feature == .clipboard && header.token == Self.token && header.count == 1)
        #expect(!offEvents.elements.contains(where: Self.isOfferReceived))
        // Only a peer offers a drag: the console peer's connection refuses the host's.
        guard case .failure(let refusal) = await offer(harness, .drag, SimItems.offer(2, [])) else {
            Issue.record("a drag opened"); return
        }
        #expect(refusal.code == .unsupportedKind)

        harness.hub.withdrawOffer(Self.token, from: console)
        var log = harness.itemLog.waiter()
        let ended = await log.next { if case .event(.items(_, .offerEnded)) = $0 { true } else { false } }
        guard case .event(.items(let peer, .offerEnded(.clipboard, .local, Self.token, _))) = ended else {
            Issue.record("ended \(ended)"); return
        }
        #expect(peer == console)
        await close([on, off], harness)
    }

    @Test("With no console peer an offer is refused FEATURE_UNAVAILABLE with the absence, and sent nowhere")
    func noConsolePeerRefuses() async {
        let harness = await harness()
        #expect(await offer(harness, .clipboard) == .failure(WireError(.featureUnavailable, absence: .noAgent)))

        let events = Recorder<PeerEvent>()
        let off = runtime(harness, claim: Self.offConsole, state: Self.offState, events: events)
        let snapshot = await harness.snapshot { $0.peers.count == 1 && $0.features[.clipboard].isAvailable }
        #expect(snapshot.consolePeers.isEmpty)
        #expect(await offer(harness, .clipboard) == .failure(WireError(.featureUnavailable, absence: .notOnConsole)))
        await harness.settled()
        #expect(!events.elements.contains(where: Self.isOfferReceived))
        await close([off], harness)
    }

    @Test("The snapshot's console peer for each feature follows the console from one session to another")
    func consolePeerFollowsConsole() async {
        let harness = await harness()
        let first = runtime(harness)
        let second = runtime(harness, claim: Self.offConsole, state: Self.offState)
        let ready = await harness.snapshot { $0.peers.count == 2 && $0.consolePeers.count == 3 }
        guard let one = ready.peers.first(where: { $0.sessionID == "1" })?.handle,
            let two = ready.peers.first(where: { $0.sessionID == "2" })?.handle
        else { Issue.record("not both sessions"); return }
        #expect(ready.consolePeers[.clipboard] == one)

        first.setPeerState(PeerSessionState(console: .off, sessionID: "1", userName: "user"))
        second.setPeerState(PeerSessionState(console: .on, sessionID: "2", userName: "other"))
        let moved = await harness.snapshot { $0.consolePeers[.clipboard] == two }
        #expect(moved.consolePeers == [.clipboard: two, .drop: two, .drag: two])
        #expect(await offer(harness, .drop) == .success(two))

        second.setPeerState(PeerSessionState(console: .off, sessionID: "2", userName: "other"))
        _ = await harness.snapshot { $0.peers.count == 2 && $0.consolePeers.isEmpty }
        await close([first, second], harness)
    }

    @Test(
        "A console move withdraws the host's offer from the old peer, the owner hears its end once with why no peer holds it, and a re-offer reaches the new console peer"
    )
    func consoleMoveWithdrawsOffer() async {
        let harness = await harness()
        let (oneEvents, twoEvents) = (Recorder<PeerEvent>(), Recorder<PeerEvent>())
        let first = runtime(harness, events: oneEvents)
        let second = runtime(harness, claim: Self.offConsole, state: Self.offState, events: twoEvents)
        let ready = await harness.snapshot { $0.peers.count == 2 && $0.consolePeers.count == 3 }
        guard let one = ready.peers.first(where: { $0.sessionID == "1" })?.handle,
            let two = ready.peers.first(where: { $0.sessionID == "2" })?.handle
        else { Issue.record("not both sessions"); return }
        #expect(await offer(harness, .clipboard) == .success(one))
        var oneWaiter = oneEvents.waiter()
        _ = await oneWaiter.next(where: Self.isOfferReceived)

        var log = harness.itemLog.waiter()
        first.setPeerState(PeerSessionState(console: .off, sessionID: "1", userName: "user"))
        let ended = await log.next { if case .event(.items(_, .offerEnded)) = $0 { true } else { false } }
        // No session is on the console until the second says it is.
        let unheld = StreamClosure.resetLocally(WireError(.featureUnavailable, absence: .notOnConsole))
        #expect(ended == .event(.items(one, .offerEnded(.clipboard, .local, token: Self.token, unheld))))
        _ = await oneWaiter.next {
            if case .items(.offerEnded(.clipboard, .remote, Self.token, _)) = $0 { true } else { false }
        }
        second.setPeerState(PeerSessionState(console: .on, sessionID: "2", userName: "other"))

        _ = await harness.snapshot { $0.consolePeers[.clipboard] == two }
        #expect(await offer(harness, .clipboard) == .success(two))
        var twoWaiter = twoEvents.waiter()
        _ = await twoWaiter.next(where: Self.isOfferReceived)
        await harness.settled()
        let ends = harness.itemLog.elements.filter {
            if case .event(.items(_, .offerEnded)) = $0 { true } else { false }
        }
        #expect(ends.count == 1, "\(ends)")
        await close([first, second], harness)
    }

    @Test("A peer's offer from a peer that is not the feature's console peer is released, never forwarded")
    func offConsoleOfferReleased() async {
        let harness = await harness()
        let on = HubPeer(harness, claim: Fixture.peerClaim, items: MemoryItems())
        let off = HubPeer(harness, claim: Self.offConsole, state: Self.offState, items: MemoryItems())
        let ready = await harness.snapshot { $0.peers.count == 2 && $0.consolePeers.count == 3 }
        guard let console = ready.peers.first(where: { $0.sessionID == "1" })?.handle else {
            Issue.record("no peer of session 1"); return
        }
        off.send(.offer(ItemRequestID(rawValue: 1), Self.offer, feature: .clipboard))
        off.send(.offer(ItemRequestID(rawValue: 2), SimItems.offer(2, []), feature: .drag))
        var released = off.events.waiter()
        for token in [Self.token, SimItems.token(2)] {
            _ = await released.next {
                if case .items(.offerEnded(_, .local, token, _)) = $0 { true } else { false }
            }
        }
        on.send(.offer(ItemRequestID(rawValue: 1), Self.offer, feature: .clipboard))
        var log = harness.itemLog.waiter()
        let received = await log.next { if case .event(.items(_, .offerReceived)) = $0 { true } else { false } }
        guard case .event(.items(console, .offerReceived(let header))) = received else {
            Issue.record("received \(received)"); return
        }
        #expect(header.token == Self.token)
        await harness.settled()
        let forwarded = harness.itemLog.elements.filter {
            if case .event(.items(_, .offerReceived)) = $0 { true } else { false }
        }
        #expect(forwarded == [received])
        harness.hub.close()
    }

    @Test(
        "Each of CLIPBOARD, DROP and DRAG is served only with its own policy entry",
        arguments: [FeatureID.clipboard, .drop, .drag])
    func policyEntryPerFeature(_ enabled: FeatureID) async {
        let harness = await harness(policy: PolicySnapshot([FeaturePolicyValue(feature: enabled, enabled: true)]))
        let peer = runtime(harness)
        let snapshot = await harness.snapshot { $0.peers.count == 1 && $0.features[enabled].isAvailable }
        #expect(snapshot.consolePeers == [enabled: snapshot.peers[0].handle])
        for feature in [FeatureID.clipboard, .drop, .drag] where feature != enabled {
            guard case .absent(.disabledByPolicy, _) = snapshot.features[feature] else {
                Issue.record("\(feature) is \(snapshot.features[feature])")
                continue
            }
        }
        let offered: FeatureID = enabled == .clipboard ? .drop : .clipboard
        #expect(await offer(harness, offered) == .failure(WireError(.featureUnavailable, absence: .disabledByPolicy)))
        await close([peer], harness)
    }

    @Test("A peer's offer is read and pulled through the hub, each answer before the events it causes")
    func pullThroughHub() async {
        let harness = await harness()
        let peer = HubPeer(harness, claim: Fixture.peerClaim, items: MemoryItems())
        let handle = await harness.snapshot { $0.consolePeers.count == 3 }.peers[0].handle
        peer.send(.offer(ItemRequestID(rawValue: 1), Self.offer, feature: .clipboard))
        var log = harness.itemLog.waiter()
        let received = await log.next { if case .event(.items(_, .offerReceived)) = $0 { true } else { false } }
        guard case .event(.items(handle, .offerReceived(let header))) = received else {
            Issue.record("received \(received)"); return
        }
        #expect(header.token == Self.token)

        let item = await withCheckedContinuation { continuation in
            harness.hub.readItem(Self.token, item: 0, of: handle) { continuation.resume(returning: $0) }
        }
        #expect(item == Self.offer.items[0])
        let pulled = await withCheckedContinuation { continuation in
            harness.hub.pullItem(Self.order, from: handle) { result in
                harness.itemLog.record(.note("pulled"))
                continuation.resume(returning: result)
            }
        }
        guard case .success(let id) = pulled else { Issue.record("pulled \(pulled)"); return }
        let ended = await log.next { if case .event(.items(_, .pullEnded)) = $0 { true } else { false } }
        guard case .event(.items(handle, .pullEnded(.clipboard, id, let result))) = ended, case .landed = result else {
            Issue.record("ended \(ended)"); return
        }
        let entries = harness.itemLog.elements
        #expect(entries.firstIndex(of: .note("pulled"))! < entries.firstIndex(of: ended)!)

        harness.hub.releaseOffer(Self.token, of: handle)
        var events = peer.events.waiter()
        _ = await events.next {
            if case .items(.offerEnded(.clipboard, .local, Self.token, _)) = $0 { true } else { false }
        }
        harness.hub.close()
    }

    @Test("A cancelled pull ends without landing, the end carrying its peer")
    func cancelledPull() async {
        let harness = await harness()
        let peer = HubPeer(harness, claim: Fixture.peerClaim, items: MemoryItems(holdsReads: true))
        let handle = await harness.snapshot { $0.consolePeers.count == 3 }.peers[0].handle
        peer.send(.offer(ItemRequestID(rawValue: 1), Self.offer, feature: .clipboard))
        var log = harness.itemLog.waiter()
        _ = await log.next { if case .event(.items(_, .offerReceived)) = $0 { true } else { false } }

        let pulled = await withCheckedContinuation { continuation in
            harness.hub.pullItem(Self.order, from: handle) { continuation.resume(returning: $0) }
        }
        guard case .success(let id) = pulled else { Issue.record("pulled \(pulled)"); return }
        harness.hub.cancelPull(id, on: handle)
        let ended = await log.next { if case .event(.items(_, .pullEnded)) = $0 { true } else { false } }
        guard case .event(.items(handle, .pullEnded(.clipboard, id, let result))) = ended else {
            Issue.record("ended \(ended)"); return
        }
        if case .landed = result { Issue.record("a cancelled pull landed") }
        harness.hub.close()
    }

    @Test("The host takes a peer's drag through the hub, and the take's end carries the peer")
    func takeDrag() async {
        let harness = await harness()
        let peer = HubPeer(harness, claim: Fixture.peerClaim, items: MemoryItems())
        let handle = await harness.snapshot { $0.consolePeers.count == 3 }.peers[0].handle
        peer.send(.offer(ItemRequestID(rawValue: 1), Self.offer, feature: .drag))
        var log = harness.itemLog.waiter()
        _ = await log.next { if case .event(.items(_, .offerReceived)) = $0 { true } else { false } }

        let took = await withCheckedContinuation { continuation in
            harness.hub.takeDrag(Self.token, of: handle) { continuation.resume(returning: $0) }
        }
        guard case .success(let take) = took else { Issue.record("took \(took)"); return }
        var events = peer.events.waiter()
        guard
            case .dragTake(.requested(let asked, Self.token)) = await events.next(where: {
                if case .dragTake(.requested) = $0 { true } else { false }
            })
        else { Issue.record("no take asked"); return }
        peer.driver.handle(.dragTake(asked, .taken))
        _ = await log.next { $0 == .event(.dragTake(handle, .ended(take, .taken))) }
        harness.hub.close()
    }

    @Test("A call to a peer the hub does not hold is answered at once, as a connection that ended")
    func gonePeer() async {
        let harness = await harness()
        let gone = PeerHandle(rawValue: 99)
        let pulled = await withCheckedContinuation { continuation in
            harness.hub.pullItem(Self.order, from: gone) { continuation.resume(returning: $0) }
        }
        guard case .failure(let error) = pulled else { Issue.record("pulled \(pulled)"); return }
        #expect(error.code == .shuttingDown)
        let item = await withCheckedContinuation { continuation in
            harness.hub.readItem(Self.token, item: 0, of: gone) { continuation.resume(returning: $0) }
        }
        #expect(item == nil)
        harness.hub.close()
    }
}
