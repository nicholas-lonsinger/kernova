#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaAgentCore
import KernovaAgentSimulation
import KernovaContainer
import KernovaWire
import SwiftProtobuf
import Testing

/// A far peer's offer of one FOLDER item, and its container.
enum HostileItems {
    static let representation = SimItems.representation(.folder, size: 600)
    static let offer = SimItems.offer(7, [[representation]])
    static let request = SimItems.request(7)
    static let peerHello = WireFrames.hello(role: .sessionPeer, items: true)
    static let pullStream: UInt32 = 2

    static var container: Data {
        (try? SimItems.container(request, representation, accepting: ContainerAcceptance(request, storage: .folder)))
            ?? Data()
    }

    /// A PolicyUpdate enabling LOGS, CLIPBOARD, DROP and DRAG.
    static var policy: Kernova_V2_PolicyUpdate {
        var update = Kernova_V2_PolicyUpdate()
        update.features = [FeatureID.logs, .clipboard, .drop, .drag].map { feature in
            var policy = Kernova_V2_FeaturePolicy()
            policy.feature = feature
            policy.version = 1
            policy.enabled = true
            return policy
        }
        return update
    }

    static func take(_ token: Data) -> Kernova_V2_DragTake {
        var take = Kernova_V2_DragTake()
        take.token = token
        return take
    }

    static func header(token: Data = SimItems.token(7), count: UInt32) -> Kernova_V2_ItemSetHeader {
        var header = Kernova_V2_ItemSetHeader()
        header.token = token
        header.count = count
        return header
    }

    /// A real host that received `offer` from the far peer on stream 1 and pulled it on stream 2.
    static func pulling(seed: UInt64) -> (HostileRun, ItemPullID?) {
        let run = HostileRun(local: .host, seed: seed, items: true)
        run.feed(
            [
                peerHello, WireFrames.open(1, .clipboardOfferByPeer, body: header(count: 1)),
                WireFrames.message(1, offer.items[0]), Unit.end(1),
            ], preamble: true)
        return (run, try? run.pullItem(request)?.get())
    }

    /// The codes of the serves that ended reset by this side, in order.
    static func servesResetLocally(_ run: HostileRun) -> [ErrorCode] {
        run.itemEnds.compactMap {
            if case .serveEnded(_, .closed(.resetLocally(let error))) = $0 { error.code } else { nil }
        }
    }

    /// The host's END on the pull, as a `PullOutcome`.
    static func outcome(_ run: HostileRun) -> Kernova_V2_PullOutcome? {
        run.written.last { $0.type == .end && $0.streamID.rawValue == pullStream }
            .flatMap { try? Kernova_V2_PullOutcome(serializedBytes: $0.payload) }
    }

    /// What breaks the pull's exactly-once ending: one `.pullEnded`, its sink released once and holding nothing.
    static func endedOnce(_ run: HostileRun, _ id: ItemPullID) -> [String] {
        let terminals = run.itemOutputs.filter { $0 == .sink(.commit(id)) || $0 == .sink(.abort(id)) }.count
        return expectThat(run.itemEnds.count == 1, "ends: \(run.itemEnds)")
            + expectThat(terminals == 1, "\(terminals) commits or aborts")
            + expectThat(!run.itemSink.holds(id), "the sink holds the pull") + run.itemSink.violations
            + run.traceViolations
            + expectThat(
                run.itemSink.maxBufferedBytes <= PropertyChecker.sinkBufferBound,
                "the decoder held \(run.itemSink.maxBufferedBytes) bytes")
    }
}

@Suite("Item pulls against a hostile far side")
struct ItemHostileTests {
    @Test("A container cut at every byte, then the far side's END: the pull ends once, landing only when whole")
    func cutThenEnd() throws {
        let container = HostileItems.container
        try #require(container.count > 600)
        for cut in 0...container.count {
            let (run, pulled) = HostileItems.pulling(seed: UInt64(cut))
            let id = try #require(pulled, "cut \(cut): no pull")
            var frames: [Frame] = []
            if cut > 0 { frames.append(Unit.raw(HostileItems.pullStream, container.prefix(cut))) }
            frames.append(Unit.end(HostileItems.pullStream))
            run.feed(frames)
            var failures = HostileItems.endedOnce(run, id)
            let outcome = HostileItems.outcome(run)
            if cut == container.count {
                failures += expectThat(
                    run.itemEnds == [.pullEnded(id, .landed(.named(Data("item".utf8))))], "whole: \(run.itemEnds)")
                failures += expectThat(outcome?.kind == .landed, "END \(String(describing: outcome))")
                failures += expectThat(
                    run.itemSink.landed[id] == SimItems.digest(HostileItems.request, HostileItems.representation),
                    "landed other bytes")
            } else {
                guard case .pullEnded(_, .failed(let error))? = run.itemEnds.first else {
                    Issue.record("cut \(cut): \(run.itemEnds)")
                    return
                }
                failures += expectThat(error.code == .itemContainerMalformed, "refused \(error)")
                failures += expectThat(
                    outcome?.kind == .failed && outcome?.error.code == .itemContainerMalformed,
                    "END \(String(describing: outcome))")
            }
            failures += expectThat(run.closure == nil, "the connection closed")
            if !failures.isEmpty {
                Issue.record("cut \(cut) of \(container.count): \(failures.joined(separator: "; "))")
                return
            }
        }
    }

    @Test("The transport ending at every byte of the pull's frames ends the pull once, landing only when whole")
    func cutTransport() throws {
        let wire = WireFrames.bytes(
            [Unit.raw(HostileItems.pullStream, HostileItems.container), Unit.end(HostileItems.pullStream)],
            preamble: false)
        for cut in 0...wire.count {
            let (run, pulled) = HostileItems.pulling(seed: UInt64(cut))
            let id = try #require(pulled, "cut \(cut): no pull")
            if cut > 0 { run.feed(wire.prefix(cut)) }
            run.host?.transportEnded(now: run.now)
            run.drain()
            var failures = HostileItems.endedOnce(run, id)
            let expected: ItemPullResult =
                cut == wire.count ? .landed(.named(Data("item".utf8))) : .closed(.connectionLost)
            failures += expectThat(run.itemEnds == [.pullEnded(id, expected)], "ends \(run.itemEnds)")
            if !failures.isEmpty {
                Issue.record("cut \(cut) of \(wire.count): \(failures.joined(separator: "; "))")
                return
            }
        }
    }
}

extension HostileRows {
    /// A far side opening `kind`, which its role never opens.
    static func wrongRole(_ kind: StreamKind, at local: SimSide, body: some SwiftProtobuf.Message) -> HostileRow {
        HostileRow(
            name: "\(local == .host ? "a peer" : "the host") opening \(kind) → RESET UNSUPPORTED_KIND", local: local,
            items: true, outcome: .streamReset(.unsupportedKind)
        ) { run in
            let hello =
                local == .host ? HostileItems.peerHello : WireFrames.hello(role: .host, items: true)
            // A peer opens odd stream ids, the host even ones.
            run.feed([hello, WireFrames.open(local == .host ? 1 : 2, kind, body: body)], preamble: true)
        } expect: { run in
            expectThat(run.itemOutputs.isEmpty, "the endpoint acted on it: \(run.itemOutputs)")
        }
    }

    static let itemRows: [HostileRow] = [
        wrongRole(.dropOffer, at: .host, body: HostileItems.header(count: 0)),
        wrongRole(.clipboardOfferByHost, at: .host, body: HostileItems.header(count: 0)),
        wrongRole(.dragTake, at: .host, body: HostileItems.take(SimItems.token(7))),
        wrongRole(.dragOffer, at: .peer, body: HostileItems.header(count: 0)),
        wrongRole(.clipboardOfferByPeer, at: .peer, body: HostileItems.header(count: 0)),
        HostileRow(
            name: "a DRAG_TAKE whose token is not 16 bytes → RESET MALFORMED_MESSAGE", local: .peer, items: true,
            outcome: .streamReset(.malformedMessage)
        ) { run in
            run.feed(
                [
                    WireFrames.hello(role: .host, items: true), WireFrames.session { $0.policy = HostileItems.policy },
                    WireFrames.open(2, .dragTake, body: HostileItems.take(Data([1]))),
                ], preamble: true)
        },
        HostileRow(
            name: "ITEM_PULL of a token no offer holds → RESET ITEM_OFFER_STALE", local: .host, items: true,
            outcome: .streamReset(.itemOfferStale)
        ) { run in
            run.feed(
                [HostileItems.peerHello, WireFrames.open(1, .itemPullByPeer, body: SimItems.request(9))], preamble: true
            )
        } expect: { run in
            expectThat(run.itemOutputs.isEmpty, "the host served: \(run.itemOutputs)")
        },
        HostileRow(
            name: "ITEM_PULL naming no representation → RESET ITEM_REPRESENTATION_UNAVAILABLE", local: .host,
            items: true, outcome: .streamReset(.itemRepresentationUnavailable)
        ) { run in
            run.feed([HostileItems.peerHello], preamble: true)
            _ = run.offerItems(SimItems.offer(9, [[HostileItems.representation]]))
            run.feed([WireFrames.open(1, .itemPullByPeer, body: SimItems.request(9, item: 3))])
        },
        HostileRow(
            name: "ITEM_PULL ended by the puller before the container → RESET STREAM_PROTOCOL_ERROR", local: .host,
            items: true, outcome: .streamReset(.streamProtocolError)
        ) { run in
            run.feed([HostileItems.peerHello], preamble: true)
            _ = run.offerItems(SimItems.offer(9, [[SimItems.representation(.file, size: 1 << 20)]]))
            run.feed([WireFrames.open(1, .itemPullByPeer, body: SimItems.request(9)), Unit.end(1)])
        } expect: { run in
            let ends = run.itemEnds
            return expectThat(
                HostileItems.servesResetLocally(run) == [.streamProtocolError] && ends.count == 1, "ends: \(ends)")
                + expectThat(run.itemSource.heldCount == 0, "the source holds the pull")
        },
        HostileRow(
            name: "an offer of more Items than its count → RESET STREAM_PROTOCOL_ERROR", local: .host,
            items: true, outcome: .streamReset(.streamProtocolError)
        ) { run in
            let item = HostileItems.offer.items[0]
            run.feed(
                [
                    HostileItems.peerHello,
                    WireFrames.open(1, .clipboardOfferByPeer, body: HostileItems.header(count: 1)),
                    WireFrames.message(1, item), WireFrames.message(1, item),
                ], preamble: true)
        },
        HostileRow(
            name: "an offer's END short of its count → RESET STREAM_PROTOCOL_ERROR", local: .host, items: true,
            outcome: .streamReset(.streamProtocolError)
        ) { run in
            run.feed(
                [
                    HostileItems.peerHello,
                    WireFrames.open(1, .clipboardOfferByPeer, body: HostileItems.header(count: 2)),
                    WireFrames.message(1, HostileItems.offer.items[0]), Unit.end(1),
                ], preamble: true)
        } expect: { run in
            let received = run.itemOutputs.contains { if case .event(.offerReceived) = $0 { true } else { false } }
            return expectThat(!received, "the short offer was received")
        },
        HostileRow(
            name: "an offer Item that does not decode → RESET MALFORMED_MESSAGE", local: .host, items: true,
            outcome: .streamReset(.malformedMessage)
        ) { run in
            run.feed(
                [
                    HostileItems.peerHello,
                    WireFrames.open(1, .clipboardOfferByPeer, body: HostileItems.header(count: 1)),
                    Unit.rawMessage(1, Data([0xFF, 0xFF, 0xFF])),
                ], preamble: true)
        },
        HostileRow(
            name: "an offer OPEN whose token is not 16 bytes → RESET MALFORMED_MESSAGE", local: .host,
            items: true, outcome: .streamReset(.malformedMessage)
        ) { run in
            run.feed(
                [
                    HostileItems.peerHello,
                    WireFrames.open(1, .clipboardOfferByPeer, body: HostileItems.header(token: Data([1]), count: 1)),
                ], preamble: true)
        },
        HostileRow(
            name: "a second offer of an open token → RESET STREAM_PROTOCOL_ERROR", local: .host, items: true,
            outcome: .streamReset(.streamProtocolError)
        ) { run in
            run.feed(
                [
                    HostileItems.peerHello,
                    WireFrames.open(1, .clipboardOfferByPeer, body: HostileItems.header(count: 0)),
                    WireFrames.open(3, .clipboardOfferByPeer, body: HostileItems.header(count: 0)),
                ], preamble: true)
        },
    ]
}
