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
    /// The bulk sweep's pull: large enough to span many bulk windows' frames, small
    /// enough that every 4 KiB boundary runs in CI.
    static let pullSize = 512 << 10

    static func pullWorld(seed: UInt64, faults: [Fault]) -> SimWorld {
        var options = SimOptions()
        options.bundles = [SimHub.bundle(size: pullSize, tag: 31)]
        options.faults = faults
        let world = SimWorld(seed: seed, options: options)
        world.addPeer(UpdateScenarios.peerWithInstaller())
        world.run(until: .sec(30))
        return world
    }

    /// The cut offsets a bulk scenario takes: every 4 KiB boundary of the bytes
    /// the host writes on the pull's link, plus 100 seeded offsets, all short of
    /// the link's end so that every cut lands.
    static var cutOffsets: [Int] {
        let written = pullWorld(seed: 0, faults: []).links[0].bytesWritten(by: .host)
        var generator = SplitMix64(seed: 0xC07)
        // The seeds move the link's length by a few control frames; the margin keeps every cut short of it.
        let limit = written - 256
        let boundaries = Array(stride(from: 0, to: limit, by: 4096))
        return boundaries + (0..<100).map { _ in generator.int(in: 1...limit) }
    }

    @Test("A 512 KiB pull cut anywhere ends every stream once and stages on a later connection")
    func pullCuts() {
        for (index, offset) in Self.cutOffsets.enumerated() {
            let world = Self.pullWorld(
                seed: UInt64(index), faults: [.cut(.hostToPeer(link: 0), afterByte: offset...offset)])
            var failures = world.violations
            if world.hub.updateResults.last?.result.kind != .staged {
                failures.append("no staged result: \(world.hub.updateResults) closures \(world.hub.updateClosures)")
            }
            if !failures.isEmpty {
                Issue.record("cut at \(offset): \(failures.joined(separator: "; "))")
                return
            }
        }
    }

    @Test("Log forwarding while the host returns credit in small paced increments never closes INTERNAL")
    func pacedLogCredit() {
        for seed in UInt64(0)..<20 {
            let run = HostileRun(local: .peer, seed: seed)
            var ring = LogRing()
            var handled = 0
            func serve() {
                while handled < run.peerEffects.count {
                    let effect = run.peerEffects[handled]
                    handled += 1
                    switch effect {
                    case .logs(.mode(let mode)): ring.setMode(mode)
                    case .logs(.ready): if let batch = ring.takeBatch() { run.input(.logs(.batch(batch))) }
                    default: break
                    }
                }
            }
            var policy = Kernova_V2_PolicyUpdate()
            var logs = Kernova_V2_FeaturePolicy()
            logs.feature = .logs
            logs.version = 1
            logs.enabled = true
            policy.features = [logs]
            run.feed(WireFrames.bytes([HostileRow.hostHello, WireFrames.session { $0.policy = policy }]))
            serve()
            var granted = 262_144
            for step in 0..<400 {
                for number in 0..<8 {
                    let record = LogRecordValue(
                        timestampMilliseconds: 0, level: .info, subsystem: "s", category: "c",
                        segments: [LogSegmentValue(text: String(repeating: "r", count: 1_500 + number))])
                    if ring.append(record) { run.input(.logs(.recordsAvailable)) }
                }
                serve()
                run.feed(WireFrames.bytes([WireFrames.window(1, 1_024)], preamble: false))
                granted += 1_024
                serve()
                run.advance(.ms(10), step: .ms(10))
                serve()
                _ = step
            }
            let spent = run.written.filter { $0.streamID.rawValue == 1 && $0.type == .data }.reduce(0) {
                $0 + $1.payload.count
            }
            let batches = run.written.filter { $0.streamID.rawValue == 1 && $0.type == .data }.count
            if run.closure != nil || spent > granted || batches < 10 {
                Issue.record(
                    "seed \(seed): closure \(String(describing: run.closure)), spent \(spent) of \(granted), \(batches) batches"
                )
                return
            }
        }
    }

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
            guard let first = link.peer?.openTestBulk(.UNRECOGNIZED(9000), consumes: true, now: now) else { return }
            link.peer?.resetTestStream(first, now: now)
            let second = link.peer?.openTestBulk(.UNRECOGNIZED(9000), consumes: true, now: now)
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
