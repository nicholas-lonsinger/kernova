#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaAgentCore
import KernovaAgentRuntime
import KernovaAgentSimulation
import KernovaSynchronization
import KernovaWire
import Testing

/// A peer pull committed before its connection ends: the connection's end reaches the dial schedule and
/// `close(_:)` at once, and the pull's end follows its sink's publish report, whenever that comes.
@Suite("Peer runtime: a publish outlasting its connection")
struct PeerLandingTests {
    @Test("A publish that has not reported does not hold back the redial, and its pull ends once when it reports")
    func redialsPastAPublish() async throws {
        let (harness, sink, link) = await Self.committed()
        link.stream.deliver(.ended(.eof))
        await harness.pump(link)
        var dials = harness.dialer.dials.waiter()
        harness.scheduler.advance(to: Fixture.at(milliseconds: 60_000))
        _ = await dials.next { $0 == 2 }
        #expect(Self.pullsEnded(harness).isEmpty)

        let id = try #require(sink.committed.elements.first)
        sink.publish()
        var events = harness.events.waiter()
        _ = await events.next { if case .items(.pullEnded) = $0 { true } else { false } }
        await harness.settle()
        #expect(Self.pullsEnded(harness) == [.pullEnded(.clipboard, id, .landed(.inline(Data())))])
    }

    @Test("A publish that has not reported does not hold back close(), and its pull ends once when it reports")
    func closesPastAPublish() async throws {
        let (harness, sink, link) = await Self.committed()
        let completions = Recorder<Int>()
        harness.runtime.close { completions.record(1) }
        await harness.pump(link)
        var done = completions.waiter()
        _ = await done.next { _ in true }
        #expect(Self.pullsEnded(harness).isEmpty)

        let id = try #require(sink.committed.elements.first)
        sink.publish()
        var events = harness.events.waiter()
        _ = await events.next { if case .items(.pullEnded) = $0 { true } else { false } }
        await harness.settle()
        #expect(Self.pullsEnded(harness) == [.pullEnded(.clipboard, id, .landed(.inline(Data())))])
        #expect(completions.elements == [1])
    }

    /// A peer runtime on connection 1 whose sink was told to commit a pull of the far host's clipboard
    /// offer, and has not reported.
    private static func committed() async -> (PeerRuntimeHarness, HeldPublishSink, RuntimeLink) {
        let sink = HeldPublishSink()
        let harness = PeerRuntimeHarness(
            items: ItemAdapters(source: RegisteredItemAdapters(), sink: sink, features: [.clipboard]),
            far: { FarHost.offeringItems(clock: $0) })
        harness.runtime.start()
        let link = await harness.connect(1)
        link.far.command(
            .items(
                .offer(
                    ItemRequestID(rawValue: 1), SimItems.offer(1, [[SimItems.representation(.inline, size: 64)]]),
                    feature: .clipboard)))
        await harness.pump(link)
        var events = harness.events.waiter()
        _ = await events.next { if case .items(.offerReceived) = $0 { true } else { false } }
        harness.runtime.send(.pull(ItemRequestID(rawValue: 1), ItemPullOrder(SimItems.request(1), landing: .inline)))
        await harness.pump(link)
        var committed = sink.committed.waiter()
        _ = await committed.next { _ in true }
        return (harness, sink, link)
    }

    private static func pullsEnded(_ harness: PeerRuntimeHarness) -> [ItemTransferEvent] {
        harness.events.elements.compactMap { event in
            if case .items(let event) = event, case .pullEnded = event { event } else { nil }
        }
    }
}

/// Verifies every container and holds each commit's report until the test publishes it.
final class HeldPublishSink: ItemSink {
    private let held = Locked<[(ItemPullID, ItemSinkReporter)]>([])
    /// Each pull it was told to commit.
    let committed = Recorder<ItemPullID>()

    func handle(_ effect: ItemSinkEffect, reporter: ItemSinkReporter) {
        switch effect {
        case .bytes(let id, let bytes): reporter.report(.consumed(id, bytes.count))
        case .finish(let id): reporter.report(.verified(id))
        case .commit(let id):
            held.withLock { $0.append((id, reporter)) }
            committed.record(id)
        case .begin, .abort: break
        }
    }

    /// Reports every held commit published.
    func publish() {
        for (id, reporter) in held.withLock({ held in
            defer { held.removeAll() }; return held
        }) {
            reporter.report(.published(id, .inline(Data())))
        }
    }
}
