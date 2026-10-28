#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

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

    @Test("A turn arms the timer under its lock, then writes, then delivers; readMore follows the turn")
    func turnOrder() async {
        let harness = PeerDriverHarness()
        harness.driver.start()
        await harness.settle()
        #expect(harness.journal.take() == ["start", "arm", "write"])
        #expect(harness.scheduler.armed == [Fixture.firstPing])

        harness.stream.completeWrite()
        await harness.settle()
        harness.hostReads()
        let hello = harness.far.output()
        _ = harness.journal.take()
        // At the PING's deadline, the turn that reads the Hello also writes the PING and re-arms.
        harness.scheduler.set(now: Fixture.firstPing)
        harness.stream.deliver(.received(hello))
        await harness.settle()
        let journal = harness.journal.take()
        let write = journal.firstIndex(of: "write")
        let arm = journal.firstIndex(of: "arm")
        let event = journal.firstIndex { $0.hasPrefix("event ") }
        let readMore = journal.firstIndex(of: "readMore")
        #expect(write != nil && arm != nil && event != nil && readMore != nil)
        if let write, let arm, let event, let readMore {
            #expect(arm < write && write < event && event < readMore)
        }
        #expect(journal.last == "readMore")
        #expect(journal.filter { $0 == "readMore" }.count == 1)
        #expect(
            journal.filter { $0.hasPrefix("event ") }
                == ["event established", "event policyReceived", "event updateAvailable"])
    }

    @Test("Nothing is written while a write is outstanding")
    func oneWriteAtATime() async {
        let harness = PeerDriverHarness(power: .absent(.notOnConsole, debugDetail: ""))
        await harness.handshake()
        #expect(!harness.stream.hasPendingWrite)
        let before = harness.stream.writeCount

        harness.driver.handle(Self.available)
        await harness.settle()
        #expect(harness.stream.writeCount == before + 1)

        harness.driver.handle(.peerState(PeerSessionState(console: .off, sessionID: "1", userName: "user")))
        await harness.settle()
        #expect(harness.stream.writeCount == before + 1)

        harness.stream.completeWrite()
        await harness.settle()
        #expect(harness.stream.writeCount == before + 2)
        #expect(harness.stream.overlappingWrites == 0)
    }

    @Test("A close finishes once its final write completes; shutdown, then ended, exactly once")
    func finalWriteFinishes() async {
        let harness = PeerDriverHarness()
        await harness.handshake()
        _ = harness.takeEvents()

        harness.driver.close(.shuttingDown)
        await harness.settle()
        #expect(harness.stream.hasPendingWrite)
        #expect(harness.stream.shutdowns == 0)
        #expect(harness.ended.elements.isEmpty)
        #expect(harness.takeEvents() == [.closed(.closedLocally(WireError(.shuttingDown)))])

        _ = harness.journal.take()
        harness.stream.completeWrite()
        await harness.settle()
        #expect(harness.journal.take() == ["shutdown", "ended"])
        #expect(harness.ended.elements == [.closedLocally(WireError(.shuttingDown))])
        #expect(harness.scheduler.armed.isEmpty)

        harness.stream.deliver(.ended(.eof))
        harness.driver.handle(Self.available)
        harness.driver.close(.shuttingDown)
        await harness.settle()
        #expect(harness.stream.shutdowns == 1)
        #expect(harness.ended.elements.count == 1)
        #expect(harness.takeEvents().isEmpty)
    }

    @Test("The read side ending while the final write is in flight finishes the connection at once")
    func readEndDuringFinalWrite() async {
        let harness = PeerDriverHarness()
        await harness.handshake()
        harness.driver.close(.shuttingDown)
        await harness.settle()
        #expect(harness.stream.hasPendingWrite)

        harness.stream.deliver(.ended(.eof))
        await harness.settle()
        #expect(harness.stream.shutdowns == 1)
        #expect(harness.ended.elements == [.closedLocally(WireError(.shuttingDown))])
    }

    @Test("A final write that fails finishes the connection at once")
    func finalWriteFails() async {
        let harness = PeerDriverHarness()
        await harness.handshake()
        harness.driver.close(.shuttingDown)
        await harness.settle()
        harness.stream.completeWrite(.system(32))
        await harness.settle()
        #expect(harness.stream.shutdowns == 1)
        #expect(harness.ended.elements == [.closedLocally(WireError(.shuttingDown))])
    }

    @Test("The read side's end finishes the connection and shuts the stream down exactly once")
    func readEndShutsDownOnce() async {
        let harness = PeerDriverHarness(power: .absent(.notOnConsole, debugDetail: ""))
        await harness.handshake()
        _ = harness.takeEvents()
        harness.driver.handle(Self.available)
        await harness.settle()
        #expect(harness.stream.hasPendingWrite)

        harness.stream.deliver(.ended(.eof))
        await harness.settle()
        #expect(harness.takeEvents() == [.closed(.transportLost)])
        #expect(harness.stream.shutdowns == 1)
        #expect(harness.ended.elements == [.transportLost])

        harness.stream.deliver(.ended(.eof))
        harness.scheduler.advance(to: Fixture.at(milliseconds: 60_000))
        await harness.settle()
        #expect(harness.stream.shutdowns == 1)
        #expect(harness.ended.elements.count == 1)
        #expect(harness.takeEvents().isEmpty)
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

    @Test("After a write error a local close drops its final frame and finishes at once")
    func writeErrorThenLocalClose() async {
        let harness = PeerDriverHarness(power: .absent(.notOnConsole, debugDetail: ""))
        await harness.handshake()
        _ = harness.takeEvents()
        harness.driver.handle(Self.available)
        await harness.settle()
        harness.stream.completeWrite(.system(32))
        await harness.settle()

        harness.driver.close(.shuttingDown)
        await harness.settle()
        #expect(harness.takeEvents() == [.closed(.closedLocally(WireError(.shuttingDown)))])
        #expect(harness.stream.shutdowns == 1)
        #expect(!harness.stream.hasPendingWrite)
    }

    @Test("The timer is re-armed to each turn's deadline, one fire at a time")
    func timerRearms() async {
        let harness = PeerDriverHarness()
        harness.driver.start()
        await harness.settle()
        harness.stream.completeWrite()
        await harness.settle()
        #expect(harness.scheduler.armed == [Fixture.firstPing])

        harness.scheduler.advance(to: Fixture.firstPing)
        await harness.settle()
        #expect(harness.stream.hasPendingWrite)
        #expect(harness.scheduler.armed.count == 1)
        let next = harness.scheduler.armed.first
        #expect(next.map { $0 > Fixture.firstPing } == true)

        harness.stream.completeWrite()
        harness.hostReads()
        harness.stream.deliver(.received(harness.far.output()))
        await harness.settle()
        #expect(harness.scheduler.armed.count == 1)

        harness.stream.deliver(.ended(.eof))
        await harness.settle()
        #expect(harness.scheduler.armed.isEmpty)
    }

    @Test("A fire before its deadline does nothing and the timer is armed again for the same deadline")
    func earlyFireRearms() async {
        let harness = PeerDriverHarness()
        harness.driver.start()
        await harness.settle()
        harness.stream.completeWrite()
        await harness.settle()
        let writes = harness.stream.writeCount

        harness.scheduler.fireEarliestEarly()
        await harness.settle()
        #expect(harness.scheduler.armed == [Fixture.firstPing])
        #expect(harness.stream.writeCount == writes)
    }

    @Test("A fire queued behind a turn that re-armed is refused; one fire stays armed, at the new deadline")
    func staleFireRefused() async {
        let harness = PeerDriverHarness()
        harness.driver.start()
        await harness.settle()
        harness.stream.completeWrite()
        await harness.settle()
        harness.hostReads()
        let hello = harness.far.output()

        // The turn reading the Hello at 5 s sends the PING and re-arms; the 5 s fire queues behind it.
        harness.scheduler.set(now: Fixture.firstPing)
        harness.stream.deliver(.received(hello))
        harness.scheduler.advance(to: Fixture.firstPing)
        await harness.settle()
        #expect(harness.scheduler.armed.count == 1)
        #expect(harness.scheduler.armed.first.map { $0 > Fixture.firstPing } == true)
    }

    @Test("Reads from 1 byte to 262,144 bytes are all accepted, a frame split across two reads included")
    func everyReadSizeIsAccepted() async {
        let harness = PeerDriverHarness()
        harness.driver.start()
        await harness.settle()
        harness.stream.completeWrite()
        await harness.settle()
        harness.hostReads()
        for byte in harness.far.output() {
            harness.stream.deliver(.received(Data([byte])))
            await harness.settle()
        }
        #expect(harness.takeEvents().contains(.policyReceived))

        let ping = FrameEncoder.encode(Frame(streamID: .session, type: .ping, payload: Data(count: 8)))
            .reduce(into: Data()) { $0.append($1) }
        var bytes = Data()
        while bytes.count < ByteStreamLimits.maxReceive + ping.count { bytes.append(ping) }
        harness.far.command(.close(.superseded, retryAfter: nil))
        bytes.append(harness.far.output())
        let readsBefore = harness.stream.readMores
        harness.stream.deliver(.received(Data(bytes.prefix(ByteStreamLimits.maxReceive))))
        harness.stream.deliver(.received(Data(bytes.dropFirst(ByteStreamLimits.maxReceive))))
        await harness.settle()
        #expect(harness.stream.readMores == readsBefore + 2)
        #expect(harness.takeEvents() == [.closed(.closedByPeer(WireError(.superseded)))])
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
