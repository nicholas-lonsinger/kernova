#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaAgentCore
import KernovaAgentRuntime
import KernovaWire
import Testing

/// §9.5's driver rules, over a scripted stream and a hand-run clock: every turn is one input, and the test
/// waits only for the driver queue to drain.
@Suite("Connection driver")
struct ConnectionDriverTests {
    private static let available = PeerInput.power(
        .availability(.available(PowerOffer(actions: [.shutdown, .restart]))))

    @Test("A turn writes, then arms the timer, then delivers; readMore follows the turn")
    func turnOrder() async {
        let harness = PeerDriverHarness()
        harness.driver.start()
        await harness.settle()
        #expect(harness.journal.take() == ["start", "write", "arm"])
        #expect(harness.scheduler.armed == [Fixture.at(milliseconds: 5_000)])

        harness.stream.completeWrite()
        await harness.settle()
        harness.hostReads()
        harness.stream.deliver(.received(harness.hostOutput()))
        await harness.settle()
        let journal = harness.journal.take()
        let events = journal.filter { $0.hasPrefix("event ") }
        #expect(events == ["event established", "event policyReceived", "event updateAvailable"])
        #expect(journal.last == "readMore")
        #expect(journal.filter { $0 == "readMore" }.count == 1)
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

    @Test("The final write ends the transport once it completes, and shutdown follows exactly once")
    func finalWriteThenTransportEnds() async {
        let harness = PeerDriverHarness()
        await harness.handshake()
        _ = harness.takeEvents()

        harness.driver.close(.shuttingDown)
        await harness.settle()
        #expect(harness.stream.hasPendingWrite)
        #expect(harness.stream.shutdowns == 0)
        #expect(harness.takeEvents() == [.closed(.closedLocally(WireError(.shuttingDown)))])

        harness.stream.completeWrite()
        await harness.settle()
        #expect(harness.stream.shutdowns == 1)
        #expect(harness.scheduler.armed.isEmpty)

        harness.stream.deliver(.ended(.eof))
        harness.driver.handle(Self.available)
        harness.driver.close(.shuttingDown)
        await harness.settle()
        #expect(harness.stream.shutdowns == 1)
        #expect(harness.takeEvents().isEmpty)
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

        harness.stream.deliver(.ended(.eof))
        harness.scheduler.advance(to: Fixture.at(milliseconds: 60_000))
        await harness.settle()
        #expect(harness.stream.shutdowns == 1)
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
        harness.host(.close(.superseded, retryAfter: nil))
        harness.stream.deliver(.received(harness.hostOutput()))
        await harness.settle()
        #expect(harness.takeEvents() == [.closed(.closedByPeer(superseded))])
        #expect(harness.stream.shutdowns == 1)
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
        #expect(harness.scheduler.armed == [Fixture.at(milliseconds: 5_000)])

        harness.scheduler.advance(to: Fixture.at(milliseconds: 5_000))
        await harness.settle()
        #expect(harness.stream.hasPendingWrite)
        #expect(harness.scheduler.armed.count == 1)
        let next = harness.scheduler.armed.first
        #expect(next.map { $0 > Fixture.at(milliseconds: 5_000) } == true)

        harness.stream.completeWrite()
        harness.hostReads()
        harness.stream.deliver(.received(harness.hostOutput()))
        await harness.settle()
        #expect(harness.scheduler.armed.count == 1)

        harness.stream.deliver(.ended(.eof))
        await harness.settle()
        #expect(harness.scheduler.armed.isEmpty)
    }

    @Test("Reads from 1 byte to 262,144 bytes are all accepted")
    func everyReadSizeIsAccepted() async {
        let harness = PeerDriverHarness()
        harness.driver.start()
        await harness.settle()
        harness.stream.completeWrite()
        await harness.settle()
        harness.hostReads()
        let handshake = harness.hostOutput()
        for byte in handshake {
            harness.stream.deliver(.received(Data([byte])))
            await harness.settle()
        }
        #expect(harness.takeEvents().contains(.policyReceived))

        let ping = FrameEncoder.encode(Frame(streamID: .session, type: .ping, payload: Data(count: 8)))
            .reduce(into: Data()) { $0.append($1) }
        var pings = Data()
        while pings.count < ByteStreamLimits.maxReceive + ping.count { pings.append(ping) }
        let readsBefore = harness.stream.readMores
        harness.stream.deliver(.received(Data(pings.prefix(ByteStreamLimits.maxReceive))))
        harness.stream.deliver(.received(Data(pings.dropFirst(ByteStreamLimits.maxReceive))))
        await harness.settle()
        #expect(harness.stream.readMores == readsBefore + 2)
        #expect(harness.takeEvents().isEmpty)
        #expect(harness.stream.shutdowns == 0)
    }
}
