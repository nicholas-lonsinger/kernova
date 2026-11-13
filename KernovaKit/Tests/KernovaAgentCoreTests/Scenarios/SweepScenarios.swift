#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaAgentCore
import KernovaAgentSimulation
import KernovaWire
import Testing

@Suite("Simulation sweeps")
struct SweepSuite {
    @Test(
        "A RESET queued before its OPEN was handed out sends nothing for that id, and the next OPEN takes the next id")
    func resetBeforeOpen() throws {
        var options = SimOptions()
        options.testKinds = true
        options.testBulkBytes = 1 << 20
        let world = SimWorld(seed: 1, options: options)
        world.addPeer(.session())
        world.at(.sec(1)) { world in
            guard let link = world.peers[0].link else { return }
            let now = world.localNow(.peer(0))
            guard let first = link.peer?.openTestBulk(.testBulkByPeer, consumes: true, now: now) else { return }
            link.peer?.resetTestStream(first, now: now)
            let second = link.peer?.openTestBulk(.testBulkByPeer, consumes: true, now: now)
            world.drain(link, .peer)
            world.marks["skipped"] = Int(first.rawValue)
            world.marks["second"] = second.map { Int($0.rawValue) }
        }
        world.run(until: .sec(5))
        #expect(world.violations.isEmpty, "\(world.violations)")
        let skipped = try #require(world.marks["skipped"].map(UInt32.init))
        let second = try #require(world.marks["second"].map(UInt32.init))
        let wire = world.links[0].wire
        #expect(
            !wire.contains { $0.stream == skipped }, "frames on the skipped id: \(wire.filter { $0.stream == skipped })"
        )
        #expect(second == skipped + 2)
        let peerOpens = wire.filter { $0.side == .peer && $0.type == .open }.map(\.stream)
        #expect(peerOpens.last == second, "the peer's OPENs: \(peerOpens)")
    }
}
