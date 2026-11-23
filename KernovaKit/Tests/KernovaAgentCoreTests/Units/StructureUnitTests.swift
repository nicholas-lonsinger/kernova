#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

@testable import KernovaAgentCore
import KernovaAgentSimulation
import KernovaWire
import SwiftProtobuf
import Testing

extension CoreUnits {
    @Suite("Connection: stream ordering, slots and the shared send budget")
    struct ConnectionStructureUnitTests {
        @Test("The closing deadline finishes a connection whose final write never completes")
        func closingDeadlineFinishesUnwritten() {
            var wire = Wire.host()
            wire.establish()
            wire.connection.close(.shuttingDown, retryAfter: nil, now: wire.now)
            #expect(wire.connection.pollTransmit(maxBytes: 1 << 20)?.isFinal == true)
            #expect(wire.connection.nextDeadline == wire.now.advanced(by: .seconds(1)))
            wire.advance(by: .milliseconds(999))
            #expect(wire.connection.state == .closing)
            wire.advance(by: .milliseconds(1))
            #expect(wire.connection.state == .finished)
            #expect(wire.connection.nextDeadline == nil)
        }
    }

    @Suite("Endpoints: session snapshots, coalescing and deadlines")
    struct EndpointUnitTests {
        @Test("Snapshots read in one turn raise one event each on the host, the newest kept")
        func hostEventsCoalesce() {
            let run = HostileRun(local: .host, seed: 29)
            run.feed([WireFrames.hello(role: .sessionPeer)], preamble: true)
            let states = ["a", "b", "c"].map { name in
                WireFrames.session { message in
                    message.peerState.sessionID = "c1"
                    message.peerState.console = .on
                    message.peerState.userName = name
                }
            }
            let mark = run.hostEvents.count
            let frames = states + [Unit.capabilities(withdrawing: .power), Unit.capabilities()]
            run.feed(WireFrames.bytes(frames, preamble: false), maxSplit: 1 << 20)
            let events = Array(run.hostEvents.dropFirst(mark))
            #expect(
                events.filter { if case .role(.peerStateChanged) = $0 { true } else { false } } == [
                    .role(.peerStateChanged(PeerSessionState(console: .on, sessionID: "c1", userName: "c")))
                ])
            #expect(events.count { if case .role(.featuresChanged) = $0 { true } else { false } } == 1)
        }
    }
}
