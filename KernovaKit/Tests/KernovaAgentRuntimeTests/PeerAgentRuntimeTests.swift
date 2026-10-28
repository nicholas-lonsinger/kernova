#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import Dispatch
import KernovaAgentCore
import KernovaAgentRuntime
import KernovaSynchronization
import KernovaWire
import Testing

/// The peer runtime's dial schedule and connection handling, on scripted streams and a manual clock, on
/// every OS.
@Suite("Peer agent runtime")
struct PeerAgentRuntimeTests {
    @Test("A transient dial failure is redialed after its backoff, not before")
    func transientRedial() async {
        let harness = PeerRuntimeHarness()
        harness.runtime.start()
        var dials = harness.dialer.dials.waiter()
        _ = await dials.next { $0 == 1 }
        harness.dialer.answer(1, .failure(.transient))
        await harness.settle()
        #expect(harness.scheduler.armed == [Fixture.at(milliseconds: 1_000)])

        harness.scheduler.advance(to: Fixture.at(milliseconds: 999))
        await harness.settle()
        #expect(harness.dialer.dials.elements == [1])
        // The fire runs on the runtime's queue and dials inside that step.
        harness.scheduler.advance(to: Fixture.at(milliseconds: 1_000))
        await harness.settle()
        #expect(harness.dialer.dials.elements == [1, 2])
        #expect(harness.scheduler.armed.isEmpty)
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

    @Test("retry_after stretches the redial, and generation 2's Hello carries a report made during generation 1")
    func retryAfterAndCarriedReports() async {
        let power = FakePowerAdapter(handsOff: false, initial: .absent(.notOnConsole, debugDetail: ""))
        let harness = PeerRuntimeHarness(power: power)
        harness.runtime.start()
        let first = await harness.connect(1)
        power.report(.availability(.available(PowerOffer(actions: [.restart]))))
        await harness.pump(first)

        var arms = harness.scheduler.arms.waiterFromNow()
        first.far.command(.close(.duplicatePeer, retryAfter: .seconds(20)))
        await harness.pump(first)
        _ = await arms.next { $0 == Fixture.at(milliseconds: 20_000) }
        #expect(first.stream.shutdowns == 1)

        harness.scheduler.advance(to: Fixture.at(milliseconds: 19_999))
        await harness.settle()
        #expect(harness.dialer.dials.elements == [1])
        harness.scheduler.advance(to: Fixture.at(milliseconds: 20_000))
        let second = await harness.connect(2)
        var hellos = second.far.events.waiter()
        let hello = await hellos.next {
            if case .featuresChanged = $0 { return true }
            return false
        }
        guard case .featuresChanged(let table) = hello else { return }
        #expect(table[.power].isAvailable)
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

        let writes = second.stream.writeCount
        harness.power.report(.handedOff(held))
        await harness.pump(second)
        #expect(second.stream.writeCount == writes)

        let accepted = PowerRequestID(generation: ConnectionGeneration(rawValue: 1), rawValue: 3)
        second.far.command(.requestPower(accepted, .shutdown))
        await harness.pump(second)
        let next = await performed.next { _ in true }
        #expect(next.generation == ConnectionGeneration(rawValue: 2))
    }

    @Test("A cancel the adapter cannot confirm ends the request .unconfirmed and frees the ledger for the next")
    func unconfirmedCancelFreesLedger() async {
        let harness = PeerRuntimeHarness(power: FakePowerAdapter(accepts: false))
        harness.runtime.start()
        let link = await harness.connect(1)
        let first = PowerRequestID(generation: ConnectionGeneration(rawValue: 1), rawValue: 1)
        link.far.command(.requestPower(first, .shutdown))
        await harness.pump(link)
        var performed = harness.power.performed.waiter()
        _ = await performed.next { _ in true }

        link.far.command(.cancelPower(first))
        await harness.pump(link)
        var cancelled = harness.power.cancelled.waiter()
        _ = await cancelled.next { _ in true }

        let second = PowerRequestID(generation: ConnectionGeneration(rawValue: 1), rawValue: 2)
        link.far.command(.requestPower(second, .shutdown))
        await harness.pump(link)
        #expect(harness.power.performed.elements.count == 2)
        #expect(!link.far.events.elements.contains(.power(second, .indeterminate)))
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

    @Test("close() twice on a live connection: both complete once its stream is shut down, and nothing redials")
    func closeTwice() async {
        let harness = PeerRuntimeHarness()
        harness.runtime.start()
        let link = await harness.connect(1)
        let completions = Recorder<Int>()
        harness.runtime.close { completions.record(1) }
        harness.runtime.close { completions.record(2) }
        await harness.settle()
        #expect(completions.elements.isEmpty)

        await harness.pump(link)
        var done = completions.waiter()
        _ = await done.next { $0 == 2 }
        #expect(completions.elements == [1, 2])
        #expect(link.stream.shutdowns == 1)
        harness.scheduler.advance(to: Fixture.at(milliseconds: 60_000))
        await harness.settle()
        #expect(harness.dialer.dials.elements == [1])
        #expect(harness.stops.elements.isEmpty)
    }

    @Test("setPeerState reaches the live connection")
    func peerStateReachesDriver() async {
        let harness = PeerRuntimeHarness()
        harness.runtime.start()
        let link = await harness.connect(1)
        let changed = PeerSessionState(console: .off, sessionID: "1", userName: "user")
        harness.runtime.setPeerState(changed)
        await harness.pump(link)
        var events = link.far.events.waiter()
        _ = await events.next { $0 == .peerStateChanged(changed) }
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

        init(content: Data) {
            far = FarPeer(clock: scheduler)
            source = FakePayloadSource(content: content)
            let runtime = HostConnectionRuntime(
                claim: Fixture.hostClaim, scheduler: scheduler, payloadSource: source, logger: Fixture.logger)
            let events = events
            connection = runtime.accept(
                stream, policy: PolicySnapshot(),
                bundles: [BundledPayload(os: .linux, architecture: .arm64, scope: .user, manifest: manifest)],
                deliveringOn: hub
            ) { events.record($0) }
        }

        func pump() async {
            await exchange(stream, queues: [hub], read: far.read, output: far.output)
        }
    }

    @Test("A pull is read from the payload source by position and installed")
    func pullServed() async {
        let content = FakePayloadSource.payload(Int(Self.manifest.payloadSize))
        let harness = Harness(content: content)
        await harness.pump()
        var events = harness.events.waiter()
        let result = await events.next {
            if case .update(.result) = $0 { return true }
            return false
        }
        #expect(
            result
                == .update(
                    .result(
                        UpdatePullID(generation: harness.connection.generation, stream: StreamID(rawValue: 1)),
                        UpdateResultValue(kind: .staged))))
        let reads = harness.source.reads.elements
        #expect(reads.first?.offset == 0)
        #expect(zip(reads, reads.dropFirst()).allSatisfy { $0.offset + UInt64($0.count) == $1.offset })
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

    @Test("now never goes backwards")
    func monotonic() {
        let scheduler = SystemScheduler()
        var last = scheduler.now
        for _ in 0..<10_000 {
            let now = scheduler.now
            #expect(now >= last)
            last = now
        }
    }
}
