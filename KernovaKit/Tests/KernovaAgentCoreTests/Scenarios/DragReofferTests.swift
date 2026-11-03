#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaAgentCore
import KernovaAgentSimulation
import KernovaWire
import Testing

/// A delivering catch's reoffer: the taken offer stays open until the host releases it, and the host ends the
/// take only once the reoffer it names has arrived whole — whichever stream's frames come first — or as CAUGHT
/// with no reoffer when it names anything but a DRAG offer opened after the take.
@Suite("DragReoffer")
struct DragReofferTests {
    static let taken = SimItems.token(1)
    static let reoffer = SimItems.token(4)
    static let file = SimItems.representation(.file, size: 64)

    /// A real host holding the far peer's DRAG_OFFER of `taken` on stream 1, more DRAG_OFFERs of `others` on
    /// the streams after it, and its take of `taken`.
    static func taking(others: [Data] = []) throws -> (HostileRun, DragTakeID) {
        let run = HostileRun(local: .host, seed: 1, items: true)
        var frames = [HostileItems.peerHello] + offer(taken, on: 1, items: 1)
        for (index, token) in others.enumerated() { frames += offer(token, on: UInt32(3 + 2 * index), items: 1) }
        run.feed(frames, preamble: true)
        let id = try #require(run.takeDrag(taken)).get()
        return (run, id)
    }

    /// The far peer's whole offer of `token` on `stream`: its OPEN, `items` Items, and its END.
    static func offer(_ token: Data, on stream: UInt32, kind: StreamKind = .dragOffer, items: Int) -> [Frame] {
        [WireFrames.open(stream, kind, body: HostileItems.header(token: token, count: UInt32(items)))]
            + (0..<items).map { _ in WireFrames.message(stream, SimItems.offer(4, [[file]]).items[0]) }
            + [Unit.end(stream)]
    }

    /// The peer's CAUGHT END on take `id`, naming `reoffer`.
    static func caught(_ id: DragTakeID, reoffer: Data) -> Frame {
        var outcome = Kernova_V2_DragTakeOutcome()
        outcome.kind = .caught
        outcome.reoffer = reoffer
        return Unit.end(id.stream.rawValue, Unit.encode(outcome))
    }

    /// How the host's takes ended, in order.
    static func ended(_ run: HostileRun) -> [DragTakeResult] {
        run.hostEvents.compactMap { if case .dragTake(.ended(_, let result)) = $0 { result } else { nil } }
    }

    /// The index among the host's events of the first one `matches` holds for.
    static func position(_ run: HostileRun, _ matches: (HostEvent) -> Bool) -> Int? {
        run.hostEvents.firstIndex(where: matches)
    }

    @Test("a CAUGHT arriving before its reoffer's later items ends the take only once the reoffer is whole")
    func caughtBeforeTheReofferIsWhole() throws {
        let (run, id) = try Self.taking()
        let reoffer = Self.offer(Self.reoffer, on: 3, items: 3)
        run.feed([reoffer[0], reoffer[1], Self.caught(id, reoffer: Self.reoffer)])
        #expect(Self.ended(run).isEmpty, "the take ended before its reoffer was whole")

        run.feed(Array(reoffer[2...]))
        #expect(Self.ended(run) == [.caught(reoffer: Self.reoffer)])
        let received = Self.position(run) {
            if case .items(.offerReceived(let header)) = $0 { header.token == Self.reoffer } else { false }
        }
        let ended = Self.position(run) { if case .dragTake(.ended) = $0 { true } else { false } }
        #expect(try #require(received) < (try #require(ended)), "the take ended before its reoffer arrived")
        for item in 0..<3 { #expect(run.readItem(Self.reoffer, item: UInt32(item)) != nil, "item \(item) unread") }
        #expect(run.pullItem(SimItems.request(4, item: 2)).map { (try? $0.get()) != nil } == true)
        #expect(
            !run.itemOutputs.contains { if case .event(.offerEnded) = $0 { true } else { false } },
            "an offer ended: \(run.itemOutputs)")
        #expect(run.state == ConnectionState.established)
    }

    @Test("a CAUGHT arriving before its reoffer opens waits for it")
    func caughtBeforeTheReofferOpens() throws {
        let (run, id) = try Self.taking()
        run.feed([Self.caught(id, reoffer: Self.reoffer)])
        #expect(Self.ended(run).isEmpty)
        run.feed(Self.offer(Self.reoffer, on: 3, items: 2))
        #expect(Self.ended(run) == [.caught(reoffer: Self.reoffer)])
    }

    @Test("a CAUGHT naming an offer of another feature ends with no reoffer")
    func reofferOfAnotherFeature() throws {
        let (run, id) = try Self.taking()
        run.feed(Self.offer(Self.reoffer, on: 3, kind: .clipboardOfferByPeer, items: 1))
        run.feed([Self.caught(id, reoffer: Self.reoffer)])
        #expect(Self.ended(run) == [.caught(reoffer: nil)])
        #expect(run.state == ConnectionState.established)
    }

    @Test("a CAUGHT naming the taken offer, or one opened before the take, ends with no reoffer")
    func staleReoffer() throws {
        let (named, takenID) = try Self.taking()
        named.feed([Self.caught(takenID, reoffer: Self.taken)])
        #expect(Self.ended(named) == [.caught(reoffer: nil)])

        let earlier = SimItems.token(5)
        let (run, id) = try Self.taking(others: [earlier])
        run.feed([Self.caught(id, reoffer: earlier)])
        #expect(Self.ended(run) == [.caught(reoffer: nil)])
        #expect(run.state == ConnectionState.established)
    }

    @Test("a CAUGHT naming the reoffer another take carries on in ends with no reoffer")
    func anotherTakesReoffer() throws {
        let second = SimItems.token(2)
        let (run, first) = try Self.taking(others: [second])
        let other = try #require(run.takeDrag(second)).get()
        run.feed(Self.offer(Self.reoffer, on: 5, items: 1))
        run.feed([Self.caught(first, reoffer: Self.reoffer)])
        run.feed([Self.caught(other, reoffer: Self.reoffer)])
        #expect(Self.ended(run) == [.caught(reoffer: Self.reoffer), .caught(reoffer: nil)])
    }

    @Test("a reoffer that ends before it is whole ends its take with no reoffer")
    func reofferEndsUnfinished() throws {
        let (run, id) = try Self.taking()
        let reoffer = Self.offer(Self.reoffer, on: 3, items: 2)
        run.feed([reoffer[0], Self.caught(id, reoffer: Self.reoffer)])
        #expect(Self.ended(run).isEmpty)
        run.feed([WireFrames.reset(3, code: Int(ErrorCode.cancelled.rawValue))])
        #expect(Self.ended(run) == [.caught(reoffer: nil)])
    }

    @Test("a take waiting on its reoffer ends with none once called off, or once the taken offer ends")
    func waitingEnds() throws {
        let (calledOff, id) = try Self.taking()
        calledOff.feed([Self.caught(id, reoffer: Self.reoffer)])
        calledOff.item(.cancelTake(id))
        #expect(Self.ended(calledOff) == [.caught(reoffer: nil)])
        calledOff.feed(Self.offer(Self.reoffer, on: 3, items: 1))
        #expect(Self.ended(calledOff) == [.caught(reoffer: nil)], "the take ended twice")

        let (withdrawn, other) = try Self.taking()
        withdrawn.feed([Self.caught(other, reoffer: Self.reoffer)])
        withdrawn.feed([WireFrames.reset(1, code: Int(ErrorCode.cancelled.rawValue))])
        #expect(Self.ended(withdrawn) == [.caught(reoffer: nil)])
    }

    @Test("the peer answering CAUGHT under a reoffer, its writer stalled, resets nothing; the host's release ends the taken offer")
    func takenOfferStaysOpenThroughCaught() throws {
        let run = HostileRun(local: .peer, seed: 1, items: true)
        run.feed(
            [WireFrames.hello(role: .host, items: true), WireFrames.session { $0.policy = HostileItems.policy }],
            preamble: true)
        #expect(run.offerItems(SimItems.offer(1, [[Self.file]]), feature: .drag) == nil)
        run.feed([WireFrames.open(2, .dragTake, body: HostileItems.take(Self.taken))])
        let id = try #require(
            run.peerEvents.compactMap { event -> DragTakeID? in
                if case .dragTake(.requested(let id, _)) = event { return id }
                return nil
            }.first)
        run.writerStalled = true
        #expect(run.offerItems(SimItems.offer(4, [[Self.file], [Self.file], [Self.file]]), feature: .drag) == nil)
        run.input(.dragTake(id, .caught(reoffer: Self.reoffer)))
        run.writerStalled = false
        run.drain()

        #expect(!run.written.contains { $0.type == .reset }, "the peer reset a stream: \(run.written)")
        #expect(run.written.contains { $0.type == .end && $0.streamID == id.stream }, "no CAUGHT went out")
        let takenEnded = {
            run.peerEvents.contains {
                if case .items(.offerEnded(_, .local, let token, _)) = $0 { token == Self.taken } else { false }
            }
        }
        #expect(!takenEnded(), "the taken offer ended before the host released it")
        let takenStream = try #require(
            run.written.first { frame in
                guard frame.type == .open, let open = try? Kernova_V2_Open(serializedBytes: frame.payload) else {
                    return false
                }
                return (try? Kernova_V2_ItemSetHeader(serializedBytes: open.body))?.token == Self.taken
            }?.streamID)
        run.feed([Unit.end(takenStream.rawValue)])
        #expect(takenEnded(), "the host's release did not end the taken offer")
    }
}
