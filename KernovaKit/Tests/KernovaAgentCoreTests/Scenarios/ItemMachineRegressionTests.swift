#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaAgentCore
import KernovaAgentSimulation
import KernovaWire
import Testing

/// What the item-transfer machines hold against a far side shaped to break them.
enum Regression {
    /// A host that read the far peer's Hello, recording no trace when `trace` is false.
    static func host(trace: Bool = true) -> HostileRun {
        let run = HostileRun(local: .host, seed: 1, items: true) { connection in
            if !trace { connection.recordsTrace = false }
        }
        run.feed([HostileItems.peerHello], preamble: true)
        return run
    }

    /// `count` copies of `frame`, fed a batch at a time.
    static func feedRepeated(_ run: HostileRun, _ frame: Frame, count: Int) {
        let one = WireFrames.bytes([frame], preamble: false)
        let batch = min(4096, count)
        var chunk = Data()
        for _ in 0..<batch { chunk.append(one) }
        var left = count
        while left > 0 {
            let take = min(batch, left)
            run.host?.receive(take == batch ? chunk : Data(chunk.prefix(one.count * take)), now: run.now)
            run.drain()
            left -= take
        }
    }

    static func received(_ run: HostileRun) -> [ItemSetHeaderValue] {
        run.itemOutputs.compactMap { if case .event(.offerReceived(let header)) = $0 { header } else { nil } }
    }

    static func resets(_ run: HostileRun, on stream: UInt32) -> [ErrorCode] {
        run.streamResets.filter { $0.stream == stream }.map(\.code)
    }

    static func localFaults(_ run: HostileRun) -> [Diagnostic] {
        run.hostEvents.compactMap {
            if case .diagnostic(let diagnostic) = $0, case .localFault = diagnostic { diagnostic } else { nil }
        }
    }

    static func token(_ tag: UInt8) -> Data { SimItems.token(tag) }
}

@Suite("Item machine regressions", .serialized)
struct ItemMachineRegressionTests {
    static let overhead = ItemOfferRegistry.remoteItemOverhead
    static let limit = ItemOfferRegistry.remoteItemByteLimit

    @Test("An offer's count is reserved at its OPEN: a claim past the budget is refused TOO_LARGE before any item")
    func countReservedAtOpen() {
        let run = Regression.host()
        run.feed([
            WireFrames.open(1, .clipboardOfferByPeer, body: HostileItems.header(count: .max)),
            WireFrames.open(
                3, .clipboardOfferByPeer, body: HostileItems.header(token: Regression.token(3), count: 1_000_000)),
        ])
        #expect(Regression.resets(run, on: 1) == [.tooLarge])
        #expect(Regression.resets(run, on: 3) == [.tooLarge])
        #expect(run.closure == nil)
    }

    @Test("Empty Items cost their overhead: a full budget of them refuses the next offer until it is released")
    func emptyItemsCharged() {
        let run = Regression.host(trace: false)
        let fits = Self.limit / Self.overhead
        run.feed([WireFrames.open(1, .clipboardOfferByPeer, body: HostileItems.header(count: UInt32(fits)))])
        Regression.feedRepeated(run, Unit.rawMessage(1, Data()), count: fits)
        run.feed([Unit.end(1)])
        #expect(Regression.received(run).map(\.count) == [fits])
        run.feed([
            WireFrames.open(3, .clipboardOfferByPeer, body: HostileItems.header(token: Regression.token(3), count: 1))
        ])
        #expect(Regression.resets(run, on: 3) == [.tooLarge])
        // The far side withdraws the full offer; its whole charge returns.
        run.feed([WireFrames.reset(1, code: ErrorCode.cancelled.rawValue)])
        run.feed([
            WireFrames.open(5, .clipboardOfferByPeer, body: HostileItems.header(token: Regression.token(5), count: 1)),
            WireFrames.message(5, HostileItems.offer.items[0]), Unit.end(5),
        ])
        #expect(Regression.resets(run, on: 5).isEmpty)
        #expect(Regression.received(run).count == 2)
    }

    @Test("Items that decode to far more than their bytes are held encoded; the one a pull names decodes alone")
    func amplifyingItemsHeldEncoded() throws {
        let run = Regression.host(trace: false)
        // Each 64 KiB Item holds 32,768 empty representations.
        let payload = Data((0..<65_536).map { $0 % 2 == 0 ? 0x0A : 0x00 })
        let messages = 200
        run.feed([WireFrames.open(1, .clipboardOfferByPeer, body: HostileItems.header(count: UInt32(messages)))])
        Regression.feedRepeated(run, Unit.rawMessage(1, payload), count: messages)
        run.feed([Unit.end(1)])
        #expect(Regression.received(run).map(\.count) == [messages])
        // What the registry holds is the items' bytes, each charged with its overhead.
        let holding = try #require(run.host?.itemOffers.remoteHolding)
        #expect(holding.itemBytes == messages * payload.count)
        #expect(holding.charged == holding.itemBytes + holding.items * Self.overhead)
        #expect(holding.charged <= Self.limit)
        let item = try #require(run.host?.remoteOfferItem(token: HostileItems.header(count: 0).token, index: 0))
        #expect(item.representations.count == 32_768)
    }

    @Test("Concurrent pulls' reads reserve the shared raw budget: every honest answer fits")
    func concurrentReadsFit() {
        let run = Regression.host()
        #expect(run.offerItems(SimItems.offer(9, [[SimItems.representation(.file, size: 1 << 20)]])) == nil)
        let opens = (0..<9).map { WireFrames.open(UInt32(2 * $0 + 1), .itemPullByPeer, body: SimItems.request(9)) }
        run.host?.receive(WireFrames.bytes(opens, preamble: false), now: run.now)
        run.drain()
        let reads = run.itemOutputs.compactMap { if case .source(.read(_, let max)) = $0 { max } else { nil } }
        #expect(!reads.isEmpty)
        #expect(!run.streamResets.contains { $0.code == .readFailed }, "\(run.streamResets)")
        #expect(Regression.localFaults(run).isEmpty, "\(Regression.localFaults(run))")
        #expect(run.closure == nil)
    }

    @Test("This side releasing the far side's offer ends its pull of it ITEM_OFFER_STALE, uncommitted")
    func releaseEndsPull() throws {
        let (run, pulled) = HostileItems.pulling(seed: 4)
        let id = try #require(pulled)
        run.host?.releaseOffer(SimItems.token(7), now: run.now)
        run.drain()
        run.feed([Unit.raw(HostileItems.pullStream, HostileItems.container), Unit.end(HostileItems.pullStream)])
        #expect(run.itemEnds == [.pullEnded(id, .closed(.resetLocally(WireError(.itemOfferStale))))])
        #expect(!run.itemOutputs.contains(.sink(.commit(id))))
        #expect(HostileItems.endedOnce(run, id).isEmpty, "\(HostileItems.endedOnce(run, id))")
    }

    @Test("The far side withdrawing its offer ends this side's pull of it ITEM_OFFER_STALE, uncommitted")
    func withdrawEndsPull() throws {
        let (run, pulled) = HostileItems.pulling(seed: 5)
        let id = try #require(pulled)
        run.feed([WireFrames.reset(1, code: ErrorCode.cancelled.rawValue)])
        run.feed([Unit.raw(HostileItems.pullStream, HostileItems.container), Unit.end(HostileItems.pullStream)])
        #expect(run.itemEnds == [.pullEnded(id, .closed(.resetLocally(WireError(.itemOfferStale))))])
        #expect(!run.itemOutputs.contains(.sink(.commit(id))))
        #expect(HostileItems.endedOnce(run, id).isEmpty, "\(HostileItems.endedOnce(run, id))")
    }

    @Test("A puller's END before this side's END left is reset STREAM_PROTOCOL_ERROR, not taken as landed")
    func outcomeBeforeOurEnd() throws {
        let run = Regression.host()
        #expect(run.offerItems(SimItems.offer(9, [[SimItems.representation(.inline, size: 100)]])) == nil)
        run.writerStalled = true
        run.feed([WireFrames.open(1, .itemPullByPeer, body: SimItems.request(9))])
        var landed = Kernova_V2_PullOutcome()
        landed.kind = .landed
        run.feed([Unit.end(1, Unit.encode(landed))])
        run.writerStalled = false
        run.drain()
        #expect(HostileItems.servesResetLocally(run) == [.streamProtocolError] && run.itemEnds.count == 1)
        #expect(Regression.resets(run, on: 1) == [.streamProtocolError])
    }

    @Test("A peer's UPDATE_PULL END before the host's END left is reset STREAM_PROTOCOL_ERROR")
    func updateOutcomeBeforeHostEnd() {
        let run = HostileRun(local: .host, seed: 1)
        run.writerStalled = true
        run.feed([HostileItems.peerHello], preamble: true)
        var pull = Kernova_V2_UpdatePull()
        pull.payloadHash = SimHub.bundle(size: 100_000, tag: 1).manifest.payloadHash
        run.feed([WireFrames.open(1, .updatePull, body: pull)])
        var source = FixturePayloadSource()
        var answered = 0
        while answered < run.hostEffects.count {
            if case .read(let id, let manifest, let offset, let maxBytes) = run.hostEffects[answered] {
                run.payload(source.answer(id, manifest, offset: offset, maxBytes: maxBytes))
            }
            answered += 1
        }
        var staged = Kernova_V2_UpdateResult()
        staged.kind = .staged
        run.feed([Unit.end(1, Unit.encode(staged))])
        run.writerStalled = false
        run.drain()
        #expect(Regression.resets(run, on: 1) == [.streamProtocolError])
        #expect(!run.hostEvents.contains { if case .update(.result) = $0 { true } else { false } })
    }

    @Test("Offer tokens are per side: the far side may reuse this side's token, and each end names its origin")
    func tokensPerSide() {
        let run = Regression.host()
        let token = Regression.token(9)
        #expect(run.offerItems(SimItems.offer(9, [[SimItems.representation(.inline, size: 10)]])) == nil)
        run.feed([
            WireFrames.open(1, .clipboardOfferByPeer, body: HostileItems.header(token: token, count: 0)), Unit.end(1),
        ])
        #expect(Regression.resets(run, on: 1).isEmpty)
        #expect(Regression.received(run).map(\.token) == [token])
        run.feed([WireFrames.reset(1, code: ErrorCode.cancelled.rawValue)])
        let ends = run.itemOutputs.compactMap {
            if case .event(.offerEnded(_, let origin, let ended, _)) = $0 { (origin, ended) } else { nil }
        }
        #expect(ends.map(\.0) == [.remote] && ends.map(\.1) == [token])
        // This side's offer of the same token is still open and served.
        run.feed([WireFrames.open(3, .itemPullByPeer, body: SimItems.request(9))])
        #expect(run.itemOutputs.contains { if case .source(.serve) = $0 { true } else { false } })
        #expect(Regression.resets(run, on: 3).isEmpty)
    }
}
