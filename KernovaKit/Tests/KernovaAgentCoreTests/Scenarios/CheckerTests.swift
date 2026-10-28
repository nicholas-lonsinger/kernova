#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaAgentCore
import KernovaAgentSimulation
import KernovaWire
import Testing

/// The checkers' own oracles, fed synthetic input, so a check cannot go dead.
@Suite("Simulation checkers")
struct CheckerTests {
    static let stream = StreamID(rawValue: 1)

    @Test("The trace checker fails a .closed while a stream is still open")
    func closedWithOpenStream() {
        let violations = TraceChecker.violations([
            .localOpened(Self.stream, .logForward), .event(.closed(.transportLost)),
        ])
        #expect(violations.count == 1 && violations[0].hasPrefix("property 1"), "\(violations)")
    }

    @Test("The trace checker passes a stream closed before its connection, and fails anything after .closed")
    func orderedClose() {
        #expect(
            TraceChecker.violations([
                .event(.opened(Self.stream, .logForward, body: Data())),
                .event(.streamClosed(Self.stream, .connectionLost)), .event(.closed(.transportLost)),
            ]).isEmpty)
        let late = TraceChecker.violations([.event(.closed(.transportLost)), .event(.writable(Self.stream))])
        #expect(late.count == 1 && late[0].hasPrefix("property 3"), "\(late)")
    }

    @Test("Routing fails an ask after a peer accepted, until the routing concludes")
    func askAfterAccepted() {
        let first = PeerHandle(rawValue: 0)
        let second = PeerHandle(rawValue: 1)
        let afterAccept = PropertyChecker.routingViolations([
            .output(.ask(first, .shutdown)), .result(first, .accepted), .output(.ask(second, .shutdown)),
        ])
        #expect(afterAccept == ["property 8: peer 1 asked after an ACCEPTED"])
        let nextRouting = PropertyChecker.routingViolations([
            .output(.ask(first, .shutdown)), .result(first, .accepted), .output(.handedOff(first)),
            .output(.ask(first, .shutdown)),
        ])
        #expect(nextRouting.isEmpty, "\(nextRouting)")
    }

    @Test("The pending-event bound is sampled before the drain, where a receive's events still wait")
    func pendingEventsSampledBeforeDrain() {
        let world = SimWorld(seed: 1, options: SimOptions())
        world.addPeer(.session())
        world.run(until: .sec(2))
        #expect(world.violations.isEmpty, "\(world.violations)")
        #expect(world.checker.maxPendingEvents > 0)
    }

    @Test("A fault whose window the run never reaches fails the run")
    func faultThatNeverFires() {
        var options = SimOptions()
        options.faults = [.peerDeath(peer: 0, in: .at(.sec(10)))]
        let world = SimWorld(seed: 1, options: options)
        world.addPeer(.session())
        world.run(until: .sec(5))
        #expect(world.violations.contains { $0.hasPrefix("fault 0 never took effect") }, "\(world.violations)")
    }

    @Test("A cut past the bytes the link carries fails the run")
    func cutThatNeverFires() {
        var options = SimOptions()
        options.faults = [.cut(.peerToHost(link: 0), afterByte: 1_000_000...1_000_000)]
        let world = SimWorld(seed: 1, options: options)
        world.addPeer(.session())
        world.run(until: .sec(5))
        #expect(world.violations.contains { $0.hasPrefix("fault 0 never took effect") }, "\(world.violations)")
    }

    @Test("A consumer stall over a consumer that receives nothing fails the run")
    func stallThatNeverFires() {
        var options = SimOptions()
        options.faults = [.consumerStall(.peer, .updatePull, peer: 0, in: .at(.sec(1)), for: .sec(2))]
        let world = SimWorld(seed: 1, options: options)
        world.addPeer(.session())
        world.run(until: .sec(5))
        #expect(world.violations.contains { $0.hasPrefix("fault 0 never took effect") }, "\(world.violations)")
    }
}
