#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaAgentCore
import KernovaAgentSimulation
import KernovaWire
import Testing

/// One simulation scenario: options, a script run on the world, an end time
/// and end-of-run expectations beyond `PropertyChecker`'s properties. What the
/// seed varies lives in the options' fault windows and the script's windowed
/// steps, which the world draws from.
struct Scenario: Sendable, CustomTestStringConvertible {
    var name: String
    var seeds = 200
    var end: SimTime = .sec(20)
    var options: @Sendable (inout SimOptions) -> Void = { _ in }
    var script: @Sendable (SimWorld) -> Void
    var expect: @Sendable (SimWorld) -> [String] = { _ in [] }

    var testDescription: String { name }

    /// The seeds a run covers: `KERNOVA_SIM_SEEDS` raises the count for a nightly run,
    /// `KERNOVA_SIM_SEED` replays one.
    var seedList: [UInt64] {
        let environment = ProcessInfo.processInfo.environment
        if let one = environment["KERNOVA_SIM_SEED"].flatMap(UInt64.init) { return [one] }
        let count = environment["KERNOVA_SIM_SEEDS"].flatMap(Int.init) ?? seeds
        return (0..<UInt64(count)).map { $0 &* 0x9E37_79B9 &+ 17 }
    }

    /// One run; the violations and the transcript hash.
    func run(seed: UInt64, recordsEvents: Bool = false) -> (violations: [String], hash: UInt64, world: SimWorld) {
        var options = SimOptions()
        self.options(&options)
        let world = SimWorld(seed: seed, options: options)
        world.recordsEvents = recordsEvents
        script(world)
        world.run(until: end)
        return (world.violations + expect(world), world.transcript.value, world)
    }

    /// Every seed twice (property 10), failing with the seed and scenario.
    func runAllSeeds() {
        for seed in seedList {
            let first = run(seed: seed)
            let second = run(seed: seed)
            if !first.violations.isEmpty {
                let replay = run(seed: seed, recordsEvents: true)
                let tail = replay.world.events.suffix(40).joined(separator: "\n")
                Issue.record(
                    "\(name) seed \(seed) (KERNOVA_SIM_SEED=\(seed)):\n\(first.violations.joined(separator: "\n"))\n--- events ---\n\(tail)"
                )
                return
            }
            if first.hash != second.hash {
                Issue.record("property 10: \(name) seed \(seed) ran differently twice")
                return
            }
        }
    }
}

// MARK: - Expectation helpers

extension SimWorld {
    func hostClosures(code: ErrorCode) -> Int {
        checker.closures.filter { entry in
            guard entry.side == .host else { return false }
            switch entry.closure {
            case .closedLocally(let error), .closedByPeer(let error): return error.code == code
            default: return false
            }
        }.count
    }

    func closures(_ side: SimSide, local code: ErrorCode) -> [(time: SimTime, link: Int)] {
        checker.closures.compactMap { entry in
            guard entry.side == side, case .closedLocally(let error) = entry.closure, error.code == code else {
                return nil
            }
            return (entry.time, entry.link)
        }
    }

    func closures(_ side: SimSide, byPeer code: ErrorCode) -> [(time: SimTime, link: Int)] {
        checker.closures.compactMap { entry in
            guard entry.side == side, case .closedByPeer(let error) = entry.closure, error.code == code else {
                return nil
            }
            return (entry.time, entry.link)
        }
    }

    var finalRouting: RoutingOutput? {
        hub.routingOutputs.last { output in
            switch output.output {
            case .ask, .progress, .busy: false
            default: true
            }
        }?.output
    }

    var liveLinks: [SimLink] {
        links.filter { $0.state(.host) == .established && $0.state(.peer) == .established }
    }

    /// When fault `index` took effect.
    func faultTime(_ index: Int) -> SimTime? { faults[index].tookEffectAt }

    /// Whether the peer wrote an ACCEPTED on link `link`'s power request by the
    /// time fault `index` took effect: what a lost connection's outcome turns on.
    func acceptedBefore(fault index: Int, link: Int = 0) -> Bool {
        guard let at = faultTime(index), link < links.count else { return false }
        return links[link].wire.contains { record in
            guard record.side == .peer, record.time <= at, record.stream % 2 == 0, record.type == .data,
                record.flags.contains(.message),
                let progress = try? Kernova_V2_PowerProgress(serializedBytes: record.payload)
            else { return false }
            return progress.stage == .accepted
        }
    }
}

func expectThat(_ condition: Bool, _ message: @autoclosure () -> String) -> [String] {
    condition ? [] : [message()]
}
