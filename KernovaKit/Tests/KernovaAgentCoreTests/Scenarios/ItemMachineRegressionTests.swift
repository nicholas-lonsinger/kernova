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
            if !trace { connection.recordsTraceForTesting = false }
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
        let holding = try #require(run.host?.itemOffersForTesting.remoteHoldingForTesting)
        #expect(holding.itemBytes == messages * payload.count)
        #expect(holding.charged == holding.itemBytes + holding.items * Self.overhead)
        #expect(holding.charged <= Self.limit)
        let item = try #require(run.readItem(HostileItems.header(count: 0).token))
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

    @Test("The far side withdrawing its offer ends this side's pull of it ITEM_OFFER_STALE, uncommitted")
    func withdrawEndsPull() throws {
        let (run, pulled) = HostileItems.pulling(seed: 5)
        let id = try #require(pulled)
        run.feed([WireFrames.reset(1, code: ErrorCode.cancelled.rawValue)])
        run.feed([Unit.raw(HostileItems.pullStream, HostileItems.container), Unit.end(HostileItems.pullStream)])
        #expect(run.itemEnds == [.pullEnded(.clipboard, id, .closed(.resetLocally(WireError(.itemOfferStale))))])
        #expect(!run.itemOutputs.contains(.sink(.commit(id))))
        #expect(HostileItems.endedOnce(run, id).isEmpty, "\(HostileItems.endedOnce(run, id))")
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
}

@Suite("Clipboard offers and the host's requests against a far side")
struct ClipboardOfferRequestTests {
    static let request = Regression.token(5)
    static let answer = Regression.token(7)

    /// A host that asked the far peer for its clipboard, and the stream its request is on.
    static func asking() throws -> (HostileRun, UInt32) {
        let run = Regression.host()
        run.item(.requestClipboardOffer(ItemRequestID(rawValue: 1), token: request))
        let open = try #require(run.written.first { $0.type == .open && $0.streamID != .session })
        return (run, open.streamID.rawValue)
    }

    /// The OPEN of the far peer's answer on stream 1, announcing `count` items.
    static func answerOpen(count: UInt32) -> Frame {
        var header = HostileItems.header(token: answer, count: count)
        header.request = request
        return WireFrames.open(1, .clipboardOfferByPeer, body: header)
    }

    /// How the host heard its request end, each time it did.
    static func ends(_ run: HostileRun) -> [StreamClosure] {
        run.itemOutputs.compactMap {
            if case .event(.requestEnded(.local, request, let closure)) = $0 { closure } else { nil }
        }
    }

    static func received(_ run: HostileRun) -> Bool {
        run.itemOutputs.contains { if case .event(.offerReceived) = $0 { true } else { false } }
    }

    @Test("A request whose answer the host's registry resets over budget at its OPEN ends TOO_LARGE once released")
    func answerOverBudget() throws {
        let (run, stream) = try Self.asking()
        let overBudget = UInt32(ItemOfferRegistry.remoteItemByteLimit / ItemOfferRegistry.remoteItemOverhead + 1)
        run.feed([Self.answerOpen(count: overBudget)])
        #expect(Regression.resets(run, on: 1) == [.tooLarge])
        #expect(Self.ends(run).isEmpty)
        run.feed([Unit.end(stream)])
        guard case .resetLocally(let error)? = Self.ends(run).first, Self.ends(run).count == 1 else {
            Issue.record("ends: \(Self.ends(run))")
            return
        }
        #expect(error.code == .tooLarge)
    }

    @Test("A request released before its answer is whole ends as the answer does: withdrawn by the far side")
    func answerWithdrawnBeforeWhole() throws {
        let (run, stream) = try Self.asking()
        run.feed([Self.answerOpen(count: 2), WireFrames.message(1, HostileItems.offer.items[0]), Unit.end(stream)])
        #expect(Self.ends(run).isEmpty)
        run.feed([WireFrames.reset(1, code: ErrorCode.cancelled.rawValue)])
        #expect(Self.ends(run) == [.resetByPeer(WireError(.cancelled))])
        #expect(!Self.received(run))
    }

    @Test("A request released before its answer is whole ends as the answer does: with the connection")
    func connectionEndsBeforeAnswerWhole() throws {
        let (run, stream) = try Self.asking()
        run.feed([Self.answerOpen(count: 2), WireFrames.message(1, HostileItems.offer.items[0]), Unit.end(stream)])
        #expect(Self.ends(run).isEmpty)
        run.feed([WireFrames.reset(0, code: ErrorCode.cancelled.rawValue)])
        guard case .connectionClosedByPeer? = Self.ends(run).first, Self.ends(run).count == 1 else {
            Issue.record("ends: \(Self.ends(run))")
            return
        }
    }

    @Test("A request released before its answer is whole ends completed after the answer arrives")
    func answerWholeAfterRelease() throws {
        let (run, stream) = try Self.asking()
        run.feed([Self.answerOpen(count: 1), Unit.end(stream)])
        #expect(Self.ends(run).isEmpty)
        run.feed([WireFrames.message(1, HostileItems.offer.items[0]), Unit.end(1)])
        let received = run.itemOutputs.firstIndex { if case .event(.offerReceived) = $0 { true } else { false } }
        let ended = run.itemOutputs.firstIndex {
            if case .event(.requestEnded(.local, Self.request, .completed)) = $0 { true } else { false }
        }
        #expect(Self.ends(run).count == 1)
        #expect(received.flatMap { received in ended.map { received < $0 } } == true, "\(run.itemOutputs)")
    }

    @Test("A clipboard offer refused before it opens releases no far-side offer and withdraws none of this side's")
    func refusedOfferLeavesEveryOfferStanding() throws {
        let run = Regression.host()
        #expect(run.offerItems(SimItems.offer(9, [[SimItems.representation(.file, size: 64)]])) == nil)
        let own = try #require(run.written.first { $0.type == .open && $0.streamID != .session }).streamID.rawValue
        run.feed([
            WireFrames.open(1, .clipboardOfferByPeer, body: HostileItems.header(count: 1)),
            WireFrames.message(1, HostileItems.offer.items[0]), Unit.end(1),
        ])
        #expect(Self.received(run))
        let written = run.written.count

        let refusal = run.offerItems(SimItems.offer(10, [[HostileItems.misnamed[0].representation]]))
        #expect(refusal?.code == .internal)
        let after = run.written.dropFirst(written)
        #expect(!after.contains { [1, own].contains($0.streamID.rawValue) }, "\(Array(after))")
        #expect(!run.itemOutputs.contains { if case .event(.offerEnded) = $0 { true } else { false } })
    }
}
