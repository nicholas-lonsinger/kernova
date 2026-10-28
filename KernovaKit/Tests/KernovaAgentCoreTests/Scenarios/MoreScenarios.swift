#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaAgentCore
import KernovaAgentSimulation
import KernovaWire

enum IdentityScenarios {
    static let all: [Scenario] = [
        Scenario(
            name: "identity row 1: the same instance supersedes its own dead connection",
            script: { world in
                var first = PeerSpec.session()
                first.instanceID = Data(repeating: 7, count: 16)
                world.addPeer(first)
                var second = first
                second.startAt = .sec(2)
                world.addPeer(second)
            },
            expect: { world in
                expectThat(world.hub.displacements.map(\.code) == [.superseded], "\(world.hub.displacements)")
                    + expectThat(world.peers[0].stopped == .superseded, "the superseded process stops for good")
                    + expectThat(world.liveLinks.count == 1, "one live connection")
            }),
        Scenario(
            name: "identity row 2: a USER install outranks a SYSTEM-scope session peer",
            end: .sec(70),
            script: { world in
                world.addPeer(.session(scope: .user))
                var lower = PeerSpec.session(scope: .system)
                lower.startAt = .sec(1)
                world.addPeer(lower)
            },
            expect: { world in
                let refused = world.closures(.peer, byPeer: .duplicatePeer)
                return expectThat(!refused.isEmpty, "the lower rank is refused")
                    + expectThat(
                        world.liveLinks.count == 1 && world.liveLinks[0].peerIndex == 0, "the USER install stays")
                    + expectThat(refused.count <= 2, "the lower rank waits 60 s between attempts: \(refused.count)")
            }),
        Scenario(
            name: "identity row 2: an incoming USER install displaces a development build",
            script: { world in
                world.addPeer(.session(scope: .unspecified))
                var higher = PeerSpec.session(scope: .user)
                higher.startAt = .sec(1)
                world.addPeer(higher)
            },
            expect: { world in
                expectThat(world.hub.displacements.map(\.code) == [.duplicatePeer], "\(world.hub.displacements)")
                    + expectThat(world.liveLinks.first?.peerIndex == 1, "the USER install holds the identity")
            }),
        Scenario(
            name: "identity row 3: a restart beside a hung predecessor takes over on its retry",
            end: .sec(60),
            options: { options, _ in
                options.liveness = .scenarioChecked
                options.faults = [.peerHang(peer: 0, at: .sec(1), for: .sec(100))]
            },
            script: { world in
                world.addPeer(.session())
                var restarted = PeerSpec.session()
                restarted.startAt = .sec(5)
                world.addPeer(restarted)
            },
            expect: { world in
                let superseded = world.hub.displacements.filter { $0.code == .superseded }
                return expectThat(
                    superseded.count == 1, "the hung predecessor is superseded: \(world.hub.displacements)")
                    + expectThat(world.liveLinks.contains { $0.peerIndex == 1 }, "the restart holds the identity")
            }),
        Scenario(
            name: "identity row 4: two live instances dialing in a loop take no turns",
            end: .sec(120),
            script: { world in
                world.addPeer(.session())
                var second = PeerSpec.session()
                second.startAt = .sec(1)
                world.addPeer(second)
            },
            expect: { world in
                let refused = world.closures(.peer, byPeer: .duplicatePeer)
                return expectThat(world.hub.displacements.isEmpty, "the existing is never displaced")
                    + expectThat(refused.count >= 4 && refused.count <= 7, "retries every 20 s: \(refused.count)")
                    + expectThat(world.liveLinks.count == 1 && world.liveLinks[0].peerIndex == 0, "the first stays")
            }),
        Scenario(
            name: "identity: a guest process claiming the system role with USER scope is refused at Hello",
            end: .sec(10),
            options: { options, _ in options.hostile = true },
            script: { world in
                var spec = PeerSpec.system()
                spec.claim.scope = .user
                world.addPeer(spec)
            },
            expect: { world in
                expectThat(!world.closures(.host, local: .protocolError).isEmpty, "PROTOCOL_ERROR at Hello")
                    + expectThat(world.hub.helloCount == 0, "the hub never sees it")
            }),
        Scenario(
            name: "identity: a second SYSTEM-scope system peer beside a live one is row 4",
            end: .sec(30),
            script: { world in
                world.addPeer(.system())
                var second = PeerSpec.system()
                second.startAt = .sec(1)
                world.addPeer(second)
            },
            expect: { world in
                expectThat(world.hub.displacements.isEmpty, "the live system peer stays")
                    + expectThat(!world.closures(.peer, byPeer: .duplicatePeer).isEmpty, "the claimant is refused")
            }),
    ]
}

enum LogScenarios {
    static func record(_ world: SimWorld, _ key: String) {
        world.marks[key] = Int(world.now / 1_000_000)
    }

    static let all: [Scenario] = [
        Scenario(
            name: "logs: 10,000 records against a reader stall, then recovery",
            seeds: 30,
            end: .sec(30),
            options: { options, _ in options.faults = [.readerStall(.host, link: 0, at: .sec(1), for: .sec(5))] },
            script: { world in
                world.addPeer(.session())
                for burst in 0..<100 {
                    world.at(.sec(1) + .ms(UInt64(burst) * 20)) { world in world.peers[0].emitLogs(100, world: world) }
                }
            },
            expect: { world in
                let delivered = world.hub.logRecords.count
                let accounted = UInt64(delivered) + world.hub.logDropped + UInt64(world.peers[0].ring.count)
                let numbers = world.hub.logRecords.compactMap { Int($0.segments.first?.text.dropFirst(7) ?? "") }
                return expectThat(
                    accounted == 10_000,
                    "delivered \(delivered) + dropped \(world.hub.logDropped) + held \(world.peers[0].ring.count) ≠ 10,000"
                )
                    + expectThat(world.hub.logDropped > 0, "the stall drops records")
                    + expectThat(numbers == numbers.sorted(), "records arrive in order")
            }),
        Scenario(
            name: "logs: a flood past the 1 MiB/s credit return rate",
            seeds: 10,
            end: .sec(30),
            script: { world in
                world.addPeer(.session())
                for burst in 0..<20 {
                    world.at(.sec(1) + .ms(UInt64(burst) * 25)) { world in
                        let peer = world.peers[0]
                        var post = false
                        for _ in 0..<64 {
                            let record = LogRecordValue(
                                timestampMilliseconds: 0, level: .info, subsystem: "flood", category: "flood",
                                segments: [LogSegmentValue(text: String(repeating: "x", count: 4_000))])
                            if peer.ring.append(record) { post = true }
                        }
                        if post, let link = peer.link {
                            link.peer?.handle(.logs(.recordsAvailable), now: world.localNow(.peer(0)))
                            world.drain(link, .peer)
                        }
                    }
                }
            },
            expect: { world in
                let bytes = world.hub.logRecords.count * 4_000
                return expectThat(world.hub.logDropped > 0, "the ring drops what the rate cannot carry")
                    + expectThat(
                        bytes < 3 << 20, "at most about 1 MiB/s over the half second the flood lasts: \(bytes)")
            }),
    ]
}

enum StreamScenarios {
    static let all: [Scenario] = [
        Scenario(
            name: "streams: the 65th concurrent stream is refused locally",
            options: { options, _ in
                options.testKinds = true
                options.testBulkBytes = -1
            },
            script: { world in
                world.addPeer(.session())
                world.at(.sec(1)) { world in
                    guard let link = world.peers[0].link else { return }
                    var opened = 0
                    for _ in 0..<65
                    where link.peer?.openTestBulk(.UNRECOGNIZED(9000), consumes: false, now: world.localNow(.peer(0)))
                        != nil
                    {
                        opened += 1
                    }
                    world.marks["opened"] = opened
                    world.drain(link, .peer)
                }
            },
            // LOG_FORWARD holds one of the peer's 64 slots.
            expect: { world in
                expectThat(world.marks["opened"] == 63, "opened \(String(describing: world.marks["opened"]))")
            }),
        Scenario(
            name: "streams: two stalled bulk pulls beside a power request",
            seeds: 60,
            options: { options, _ in
                options.testKinds = true
                options.testBulkBytes = 40 << 20
            },
            script: { world in
                world.addPeer(.session())
                world.at(.sec(1)) { world in
                    guard let link = world.peers[0].link else { return }
                    for _ in 0..<2 {
                        _ = link.peer?.openTestBulk(.UNRECOGNIZED(9000), consumes: false, now: world.localNow(.peer(0)))
                    }
                    world.drain(link, .peer)
                }
                world.at(.sec(2)) { world in world.hub.requestPower(.shutdown, world: world) }
            },
            expect: { world in
                let done = world.hub.routingOutputs.last?.time ?? 0
                return expectThat(isHandedOff(world.finalRouting), "\(String(describing: world.finalRouting))")
                    + expectThat(done <= .ms(2_400), "on schedule: at \(done / 1_000_000) ms")
            }),
        Scenario(
            name: "streams: one stalled bulk consumer beside an active bulk stream",
            seeds: 20,
            options: { options, _ in
                options.testKinds = true
                options.testBulkBytes = 48 << 20
            },
            script: { world in
                world.addPeer(.session())
                world.at(.sec(1)) { world in
                    guard let link = world.peers[0].link else { return }
                    _ = link.peer?.openTestBulk(.UNRECOGNIZED(9000), consumes: false, now: world.localNow(.peer(0)))
                    _ = link.peer?.openTestBulk(.UNRECOGNIZED(9000), consumes: true, now: world.localNow(.peer(0)))
                    world.drain(link, .peer)
                }
                world.at(.ms(1_060)) { world in
                    let flows = world.peers[0].link?.peer?.testSink.flows ?? []
                    world.marks["active"] = flows.first { $0.consumes }?.delivered ?? (48 << 20)
                }
            },
            expect: { world in
                let active = world.marks["active"] ?? 0
                // 48 MiB at 6.4 GiB/s is 7.3 ms; 60 ms leaves room for credit round trips.
                return expectThat(active == 48 << 20, "the active stream finished within 60 ms: \(active)")
            }),
    ]
}

enum LivenessScenarios {
    static func quiet(_ name: String, _ faults: [Fault], end: SimTime = .sec(60)) -> Scenario {
        Scenario(
            name: "liveness: \(name)", seeds: 60, end: end,
            options: { options, _ in options.faults = faults },
            script: { world in
                world.addPeer(.session())
                world.addPeer(.system())
            },
            expect: { world in
                expectThat(world.liveLinks.count == 2, "both connections survive: \(world.liveLinks.count)")
            })
    }

    static let all: [Scenario] = [
        quiet("VM pause of 4 s", [.vmFreeze(at: .sec(3), for: .sec(4), guestClockJumps: true)]),
        quiet("VM pause of 9.9 s, clock leaps", [.vmFreeze(at: .sec(3), for: .ms(9_900), guestClockJumps: true)]),
        quiet("VM pause of 9.9 s, clock holds", [.vmFreeze(at: .sec(3), for: .ms(9_900), guestClockJumps: false)]),
        quiet("VM pause of 25 s", [.vmFreeze(at: .sec(3), for: .sec(25), guestClockJumps: true)]),
        quiet(
            "VM pause of 10 minutes", [.vmFreeze(at: .sec(3), for: .sec(600), guestClockJumps: true)], end: .sec(700)),
        quiet("host sleep of 3 s", [.hostSleep(at: .sec(3), for: .sec(3))]),
        quiet("host sleep of 1 hour", [.hostSleep(at: .sec(3), for: .sec(3_600))], end: .sec(3_700)),
        quiet("host clock steps back an hour", [.clockStep(.host, at: .sec(3), by: -3_600_000_000_000)]),
        quiet("host clock steps forward an hour", [.clockStep(.host, at: .sec(3), by: 3_600_000_000_000)]),
        quiet("peer clock steps forward 9 s", [.clockStep(.peer(0), at: .sec(3), by: 9_000_000_000)]),
        quiet("peer clock steps back an hour", [.clockStep(.peer(1), at: .sec(3), by: -3_600_000_000_000)]),
        quiet("consumer stall", [.consumerStall(peer: 0, at: .sec(2), for: .sec(30))]),
        quiet("a cut, then a redial", [.cut(.peerToHost(link: 0), afterByte: 5_000)]),
        quiet("a host reader stall of 10 s", [.readerStall(.host, link: 0, at: .sec(3), for: .sec(10))]),
        Scenario(
            name: "liveness: a peer hung 22 s is unresponsive once, then responsive",
            seeds: 60, end: .sec(60),
            options: { options, _ in
                options.liveness = .scenarioChecked
                options.faults = [.peerHang(peer: 0, at: .sec(3), for: .sec(22))]
            },
            script: { world in world.addPeer(.session()) },
            expect: { world in
                let host = world.checker.livenessEvents.filter { $0.side == .host }
                guard host.count == 2, case .unresponsive = host[0].change, host[1].change == .responsive else {
                    return ["host liveness \(host.map(\.change))"]
                }
                let at = host[0].time
                // The last frame before the hang left within one PING interval of it.
                return expectThat(
                    at >= .sec(3 + 15 - 5) && at <= .sec(3 + 15 + 1) + .ms(500), "unresponsive at \(at / 1_000_000) ms")
                    + expectThat(world.liveLinks.count == 1, "the connection survives")
            }),
        Scenario(
            name: "liveness: a peer hung 60 s is closed LIVENESS_EXPIRED",
            seeds: 60, end: .sec(90),
            options: { options, _ in
                options.liveness = .scenarioChecked
                options.faults = [.peerHang(peer: 0, at: .sec(3), for: .sec(60))]
            },
            script: { world in world.addPeer(.session()) },
            expect: { world in
                let closes = world.closures(.host, local: .livenessExpired)
                guard let close = closes.first else { return ["no LIVENESS_EXPIRED close"] }
                let unresponsive = world.checker.livenessEvents.filter { $0.side == .host }.count
                return expectThat(
                    close.time >= .sec(3 + 30 - 5) && close.time <= .sec(3 + 30 + 1) + .ms(500),
                    "closed at \(close.time / 1_000_000) ms")
                    + expectThat(unresponsive == 1, "one unresponsive verdict first")
            }),
        Scenario(
            name: "liveness: a host reader stalled 20 s judges the peer unresponsive, then responsive",
            seeds: 40, end: .sec(60),
            options: { options, _ in
                options.liveness = .scenarioChecked
                options.faults = [.readerStall(.host, link: 0, at: .sec(3), for: .sec(20))]
            },
            script: { world in world.addPeer(.session()) },
            expect: { world in
                let host = world.checker.livenessEvents.filter { $0.side == .host }.map(\.change)
                let peer = world.checker.livenessEvents.filter { $0.side == .peer }
                return expectThat(host.count == 2 && host.last == .responsive, "host liveness \(host)")
                    + expectThat(peer.isEmpty, "the peer still hears the host")
            }),
        Scenario(
            name: "liveness: peer death reads as transport lost, no verdict",
            options: { options, _ in options.faults = [.peerDeath(peer: 0, at: .sec(3))] },
            script: { world in world.addPeer(.session()) },
            expect: { world in
                expectThat(world.hub.closures.first?.closure == .transportLost, "\(world.hub.closures)")
            }),
    ]
}
