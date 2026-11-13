#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import Dispatch
import KernovaAgentCore
import KernovaAgentRuntime
import KernovaWire
import Testing

/// The peer runtime's dial schedule and connection handling, on scripted streams and a manual clock, on
/// every OS.
@Suite("Peer agent runtime")
struct PeerAgentRuntimeTests {
    @Test("The host connection reads connected from the host's Hello, and connecting once the connection ends")
    func hostConnectionFollowsTheConnection() async {
        let harness = PeerRuntimeHarness()
        harness.runtime.start()
        await harness.settle()
        #expect(harness.runtime.hostConnection == .connecting)

        let link = await harness.connect(1)
        var changes = harness.hostConnections.waiter()
        _ = await changes.next { $0 == .connected }
        #expect(harness.runtime.hostConnection == .connected)

        link.far.command(.close(.shuttingDown, retryAfter: nil))
        await harness.pump(link)
        _ = await changes.next { $0 == .connecting }
        #expect(harness.runtime.hostConnection == .connecting)
        #expect(harness.hostConnections.elements == [.connected, .connecting])
    }

    @Test("A dial timer that fires early is armed again, and dials at its deadline")
    func earlyDialFire() async {
        let harness = PeerRuntimeHarness()
        harness.runtime.start()
        var dials = harness.dialer.dials.waiter()
        _ = await dials.next { $0 == 1 }
        harness.dialer.answer(1, .failure(.transient))
        await harness.settle()

        harness.scheduler.fireEarliestEarly()
        await harness.settle()
        #expect(harness.scheduler.armed == [Fixture.at(milliseconds: 1_000)])
        #expect(harness.dialer.dials.elements == [1])
        harness.scheduler.advance(to: Fixture.at(milliseconds: 1_000))
        await harness.settle()
        #expect(harness.dialer.dials.elements == [1, 2])
    }

    @Test("The power ledger crosses connections, and a late report naming generation 1 reaches no stream")
    func ledgerAndLateReport() async {
        let harness = PeerRuntimeHarness()
        harness.runtime.start()
        let first = await harness.connect(1)
        let hostID = PowerRequestID(generation: ConnectionGeneration(rawValue: 1), rawValue: 1)
        first.far.command(.requestPower(hostID, .shutdown))
        await harness.pump(first)
        var performed = harness.power.performed.waiter()
        let held = await performed.next { _ in true }
        #expect(held.generation == ConnectionGeneration(rawValue: 1))

        first.far.command(.close(.shuttingDown, retryAfter: nil))
        await harness.pump(first)
        var dials = harness.dialer.dials.waiter()
        harness.scheduler.advance(to: Fixture.at(milliseconds: 1_000))
        _ = await dials.next { $0 == 2 }
        let second = await harness.connect(2)

        let refused = PowerRequestID(generation: ConnectionGeneration(rawValue: 1), rawValue: 2)
        second.far.command(.requestPower(refused, .shutdown))
        await harness.pump(second)
        var results = second.far.events.waiter()
        _ = await results.next { $0 == .power(refused, .indeterminate) }

        let writes = second.stream.calls.elements.filter { $0 == "write" }.count
        let events = second.far.events.elements.count
        harness.power.report(.handedOff(held))
        await harness.pump(second)
        #expect(second.stream.calls.elements.filter { $0 == "write" }.count == writes)
        #expect(second.far.events.elements.dropFirst(events).isEmpty)

        let accepted = PowerRequestID(generation: ConnectionGeneration(rawValue: 1), rawValue: 3)
        second.far.command(.requestPower(accepted, .shutdown))
        await harness.pump(second)
        let next = await performed.next { _ in true }
        #expect(next.generation == ConnectionGeneration(rawValue: 2))
    }

    @Test("close() with no connection completes at once, and a dial it outlived is shut down unstarted")
    func closeDuringDial() async {
        let harness = PeerRuntimeHarness()
        harness.runtime.start()
        var dials = harness.dialer.dials.waiter()
        _ = await dials.next { $0 == 1 }
        let completions = Recorder<Int>()
        harness.runtime.close { completions.record(1) }
        var done = completions.waiter()
        _ = await done.next { _ in true }

        let stream = ScriptedStream()
        harness.dialer.answer(1, .success(stream))
        await harness.settle()
        #expect(stream.calls.elements == ["shutdown"])
        #expect(harness.scheduler.armed.isEmpty)
        #expect(harness.stops.elements.isEmpty)
    }

    @Test("A session peer's new session closes its connection SHUTTING_DOWN and redials at once to say Hello with it")
    func sessionMoves() async {
        let harness = PeerRuntimeHarness()
        harness.runtime.start()
        let first = await harness.connect(1)
        let moved = PeerSessionState(console: .on, sessionID: "3", userName: "user")
        harness.runtime.setPeerState(moved)
        await harness.pump(first)
        var firstEvents = first.far.events.waiter()
        _ = await firstEvents.next { $0 == .closed(.closedByPeer(WireError(.shuttingDown))) }

        let second = await harness.connect(2)
        var secondEvents = second.far.events.waiter()
        _ = await secondEvents.next { event in
            if case .helloReceived(_, moved) = event { true } else { false }
        }
        // At once: the clock never moved, so no backoff came between the two dials.
        #expect(harness.scheduler.now == Fixture.t0)
        #expect(harness.dialer.dials.elements == [1, 2])
    }

    @Test("With no session the peer closes SHUTTING_DOWN and dials nothing, until a session dials at once")
    func sessionEnds() async {
        let harness = PeerRuntimeHarness()
        harness.runtime.start()
        let first = await harness.connect(1)
        harness.runtime.setPeerState(nil)
        await harness.pump(first)
        var firstEvents = first.far.events.waiter()
        _ = await firstEvents.next { $0 == .closed(.closedByPeer(WireError(.shuttingDown))) }
        await harness.settle()
        #expect(harness.scheduler.armed.isEmpty)
        harness.scheduler.advance(to: Fixture.at(milliseconds: 600_000))
        await harness.settle()
        #expect(harness.dialer.dials.elements == [1])

        harness.runtime.setPeerState(Fixture.peerState)
        let second = await harness.connect(2)
        var secondEvents = second.far.events.waiter()
        _ = await secondEvents.next { event in
            if case .helloReceived(_, Fixture.peerState) = event { true } else { false }
        }
    }

    @Test("SUPERSEDED stops the agent, and no dial timer stays armed")
    func stopDisarms() async {
        let harness = PeerRuntimeHarness()
        harness.runtime.start()
        let link = await harness.connect(1)
        link.far.command(.close(.superseded, retryAfter: nil))
        await harness.pump(link)
        var stops = harness.stops.waiter()
        #expect(await stops.next { _ in true } == .superseded)
        #expect(harness.scheduler.armed.isEmpty)
    }
}

/// The host runtime over a scripted stream, on every OS.
@Suite("Host connection runtime")
struct HostConnectionRuntimeTests {
    static let manifest = UpdateManifestValue(
        payloadHash: Data(repeating: 0xC3, count: 32), payloadSize: 3 * 1_048_576, format: .executable)

    final class Harness: Sendable {
        let scheduler = ManualScheduler(now: Fixture.t0)
        let stream = ScriptedStream()
        let far: FarPeer
        let hub = DispatchQueue(label: "app.kernova.tests.hub")
        let events = Recorder<HostEvent>()
        let source: FakePayloadSource
        let connection: HostConnection

        init(content: Data, items: ItemAdapters? = nil) {
            far = FarPeer(clock: scheduler)
            source = FakePayloadSource(content: content)
            let runtime = HostConnectionRuntime(
                claim: Fixture.hostClaim, scheduler: scheduler, payloadSource: source, items: items,
                logger: Fixture.logger)
            let events = events
            connection = runtime.makeConnection(
                stream, policy: PolicySnapshot(),
                bundles: [
                    BundledPayload(
                        os: .linux, architecture: .arm64, scope: .user, manifest: manifest, updatesInBand: true)
                ],
                deliveringOn: hub
            ) { events.record($0) }
            connection.start()
        }

        func pump() async {
            await exchange(stream, queues: [hub], read: far.read, output: far.output)
        }
    }

    @Test("A source that runs out short of the payload's size fails the pull READ_FAILED")
    func shortSourceFails() async {
        let harness = Harness(content: FakePayloadSource.payload(1_048_576 + 7))
        await harness.pump()
        var events = harness.events.waiter()
        let closed = await events.next {
            if case .update(.closed) = $0 { return true }
            return false
        }
        guard case .update(.closed(_, .resetLocally(let error))) = closed else {
            Issue.record("the pull ended \(closed)")
            return
        }
        #expect(error.code == .readFailed)
    }

    @Test(
        "Item transfer is advertised available with item adapters given, and absent NOT_IMPLEMENTED without",
        arguments: [true, false])
    func itemTransferAdvert(registered: Bool) async {
        let harness = Harness(content: Data(), items: registered ? RegisteredItemAdapters.adapters([.drop]) : nil)
        await harness.pump()
        let advert = harness.far.hostAdvert(.itemTransfer)
        if registered {
            #expect(advert == .available(Data()))
        } else if case .absent(let reason, _) = advert {
            #expect(reason == .notImplemented)
        } else {
            Issue.record("advertised \(String(describing: advert))")
        }
    }

    @Test("A hub command reaches the connection")
    func hubCommand() async {
        let harness = Harness(content: Data())
        harness.connection.send(.close(.shuttingDown, retryAfter: nil))
        await harness.pump()
        var events = harness.events.waiter()
        _ = await events.next { $0 == .closed(.closedLocally(WireError(.shuttingDown))) }
        #expect(harness.stream.shutdowns == 1)
    }
}

/// The platform scheduler, on the real clock.
@Suite("System scheduler")
struct SystemSchedulerTests {
    @Test("A fire runs on its queue at or after its deadline; a cancelled one never runs")
    func fires() async {
        let scheduler = SystemScheduler()
        let queue = DispatchQueue(label: "app.kernova.tests.scheduler")
        let key = DispatchSpecificKey<Int>()
        queue.setSpecific(key: key, value: 1)
        let fired = Recorder<(name: String, at: CoreInstant, onQueue: Bool)>()
        let start = scheduler.now
        let cancelled = scheduler.schedule(at: start.advanced(by: .milliseconds(5)), on: queue) {
            fired.record(("cancelled", scheduler.now, DispatchQueue.getSpecific(key: key) == 1))
        }
        cancelled.cancel()
        let deadline = start.advanced(by: .milliseconds(20))
        let held = scheduler.schedule(at: deadline, on: queue) {
            fired.record(("kept", scheduler.now, DispatchQueue.getSpecific(key: key) == 1))
        }
        var waiter = fired.waiter()
        let kept = await waiter.next { $0.name == "kept" }
        held.cancel()
        #expect(kept.at >= deadline)
        #expect(kept.onQueue)
        await flush(queue)
        #expect(fired.elements.map(\.name) == ["kept"])
    }
}
