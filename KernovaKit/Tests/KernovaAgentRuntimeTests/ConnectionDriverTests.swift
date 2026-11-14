#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import Dispatch
import KernovaAgentCore
import KernovaAgentRuntime
import KernovaLogging
import KernovaSynchronization
import KernovaWire
import Testing

/// The driver's rules, over a scripted stream and a hand-run clock: every turn is one input, and the test
/// waits only for the driver queue to drain.
@Suite("Connection driver")
struct ConnectionDriverTests {
    private static let available = PeerInput.power(
        .availability(.available(PowerOffer(actions: [.shutdown, .restart]))))

    @Test("An input and a close sent before start() run after the stream starts, as the hub sends a new connection")
    func sentBeforeStartRunsAfterIt() async {
        let harness = PeerDriverHarness()
        harness.driver.handle(Self.available)
        harness.driver.close(.shuttingDown)
        harness.driver.start()
        await harness.settle()
        #expect(harness.journal.take().prefix(2) == ["start", "arm"])
        #expect(harness.stream.writeCount == 1)
    }

    @Test("A write error ends nothing: later frames are dropped and the RESET(0) still in the stream is read")
    func writeErrorEndsNothing() async {
        let harness = PeerDriverHarness(power: .absent(.notOnConsole, debugDetail: ""))
        await harness.handshake()
        _ = harness.takeEvents()
        harness.driver.handle(Self.available)
        await harness.settle()
        let writes = harness.stream.writeCount

        harness.stream.completeWrite(.system(32))
        harness.driver.handle(.peerState(PeerSessionState(console: .off, sessionID: "1", userName: "user")))
        await harness.settle()
        #expect(harness.takeEvents().isEmpty)
        #expect(harness.stream.shutdowns == 0)
        #expect(harness.stream.writeCount == writes)

        let superseded = WireError(.superseded)
        harness.far.command(.close(.superseded, retryAfter: nil))
        harness.stream.deliver(.received(harness.far.output()))
        await harness.settle()
        #expect(harness.takeEvents() == [.closed(.closedByPeer(superseded))])
        #expect(harness.stream.shutdowns == 1)
        #expect(harness.ended.elements == [.closedByPeer(superseded)])
        #expect(harness.stream.writeCount == writes)
    }

    @Test("An in-turn answer is fed before the turn takes its transmit, so it goes out in the same write")
    func inTurnFeedSharesTheWrite() async {
        let answered = Locked(false)
        let batch = LogBatchValue(
            records: [
                LogRecordValue(timestampMilliseconds: 0, level: .notice, subsystem: "s", category: "c", segments: [])
            ],
            droppedBefore: 0)
        let harness = PeerDriverHarness(policy: Fixture.logsEnabled) { effect in
            guard case .logs(.ready) = effect else { return .consumed }
            let first = answered.withLock { answered in
                defer { answered = true }
                return !answered
            }
            return first ? .feed(.logs(.batch(batch))) : .consumed
        }
        await harness.handshake()
        #expect(harness.stream.writeCount == 1)
        let frames = Fixture.frames(harness.stream.takeWritten())
        let open = frames.first { $0.type == .open }
        #expect(open != nil)
        #expect(frames.contains { $0.type == .data && $0.flags.contains(.message) && $0.streamID == open?.streamID })
    }

    @Test("A diagnostic is logged at its level and never delivered as an event")
    func diagnosticsAreLogged() async {
        let (logger, records) = Fixture.recordingLogger()
        let harness = PeerDriverHarness(policy: Fixture.logsEnabled, logger: logger)
        await harness.handshake()
        let open = Fixture.frames(harness.stream.takeWritten()).first { $0.type == .open }
        guard let stream = open?.streamID else {
            Issue.record("the peer opened no LOG_FORWARD")
            return
        }
        harness.stream.completeWrite()
        _ = harness.journal.take()
        let end = FrameEncoder.encode(Frame(streamID: stream, type: .end, payload: Data()))
            .reduce(into: Data()) { $0.append($1) }
        harness.stream.deliver(.received(end))
        await harness.settle()
        var logged = records.waiter()
        let record = await logged.next { $0.1.contains("LOG_FORWARD") }
        #expect(record.0 == .notice)
        #expect(!harness.journal.take().contains("event diagnostic"))
    }
}

/// The one timer slot both the driver and the peer runtime arm.
@Suite("Timer slot")
struct TimerSlotTests {
    @Test("A fire is taken once; a cancelled fire's token is refused; a taken slot arms the same deadline again")
    func slot() async {
        let scheduler = ManualScheduler(now: Fixture.t0)
        let queue = DispatchQueue(label: "app.kernova.tests.slot")
        let fired = Recorder<UInt64>()
        var slot = TimerSlot()
        slot.arm(Fixture.at(milliseconds: 1_000), scheduler: scheduler, queue: queue) { fired.record($0) }
        slot.arm(Fixture.at(milliseconds: 1_000), scheduler: scheduler, queue: queue) { fired.record($0) }
        #expect(scheduler.armed == [Fixture.at(milliseconds: 1_000)])

        scheduler.advance(to: Fixture.at(milliseconds: 1_000))
        var waiter = fired.waiter()
        let stale = await waiter.next { _ in true }
        slot.arm(Fixture.at(milliseconds: 2_000), scheduler: scheduler, queue: queue) { fired.record($0) }
        let staleTaken = slot.take(stale)
        #expect(!staleTaken)
        #expect(scheduler.armed == [Fixture.at(milliseconds: 2_000)])

        scheduler.advance(to: Fixture.at(milliseconds: 2_000))
        let current = await waiter.next { _ in true }
        let currentTaken = slot.take(current)
        let takenTwice = slot.take(current)
        #expect(currentTaken)
        #expect(!takenTwice)
        slot.arm(Fixture.at(milliseconds: 2_000), scheduler: scheduler, queue: queue) { fired.record($0) }
        #expect(scheduler.armed == [Fixture.at(milliseconds: 2_000)])
    }
}
