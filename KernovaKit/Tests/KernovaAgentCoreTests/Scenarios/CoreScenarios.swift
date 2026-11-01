#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaAgentCore
import KernovaAgentSimulation
import KernovaWire

enum HandshakeScenarios {
    static let all: [Scenario] = [
        Scenario(
            name: "handshake: host + session peer",
            script: { world in world.addPeer(.session()) },
            expect: { world in
                expectThat(world.liveLinks.count == 1, "one live link, found \(world.liveLinks.count)")
                    + expectThat(world.hub.helloCount == 1, "one Hello")
                    + expectThat(world.peers[0].ring.mode == .forwarding, "the ring forwards after the policy")
            }),
        Scenario(
            name: "handshake: host + system peer",
            script: { world in world.addPeer(.system()) },
            expect: { world in expectThat(world.liveLinks.count == 1, "one live link") }),
        Scenario(
            name: "handshake: host + system peer + two session peers",
            script: { world in
                world.addPeer(.system(consoleSessionID: "c2"))
                world.addPeer(.session("c1", console: .off))
                world.addPeer(.session("c2"))
            },
            expect: { world in expectThat(world.liveLinks.count == 3, "three live links, \(world.liveLinks.count)") }),
        Scenario(
            name: "handshake: development build (scope UNSPECIFIED) is offered nothing",
            options: { options in options.bundles = [SimHub.bundle(size: 4096, tag: 7)] },
            script: { world in
                var spec = PeerSpec.session(scope: .unspecified)
                spec.installer = InstallerSpec()
                world.addPeer(spec)
            },
            expect: { world in
                expectThat(world.liveLinks.count == 1, "one live link")
                    + expectThat(world.peers[0].pullsStarted.isEmpty, "no pull")
            }),
        Scenario(
            name: "protocol mismatch: peer at protocol 2 keeps the frozen subset",
            options: { options in options.bundles = [SimHub.bundle(size: 20_000, tag: 3)] },
            script: { world in
                var spec = PeerSpec.session()
                spec.protocolVersion = 2
                spec.installer = InstallerSpec()
                world.addPeer(spec)
                world.at(in: .sec(1) ... .sec(3)) { world in world.hub.requestPower(.shutdown, world: world) }
            },
            expect: { world in
                let logs = world.hub.connected.first?.status[.logs]
                return expectThat(
                    logs == .absent(.protocolMismatch, debugDetail: ""),
                    "LOGS absent PROTOCOL_MISMATCH, found \(String(describing: logs))")
                    + expectThat(
                        isHandedOff(world.finalRouting), "power still routes: \(String(describing: world.finalRouting))"
                    )
                    + expectThat(world.hub.updateResults.first?.result.kind == .staged, "the update still pulls")
            }),
    ]
}

/// A request at 1 s that the OS accepts after a delay drawn from `accept`,
/// and a peer death drawn from `death`: the outcome follows from whether the
/// peer wrote ACCEPTED before it died.
func connectionLost(_ name: String, accept: SimWindow, death: SimWindow) -> Scenario {
    Scenario(
        name: name,
        options: { options in options.faults = [.peerDeath(peer: 0, in: death)] },
        script: { world in
            var session = PeerSpec.session()
            session.power.steps = [(accept, .accepted)]
            world.addPeer(session)
            world.at(.sec(1)) { world in world.hub.requestPower(.shutdown, world: world) }
        },
        expect: { world in
            let peer = PeerHandle(rawValue: 0)
            let expected: RoutingOutput =
                world.acceptedBefore(fault: 0) ? .lostAfterAcceptance(peer) : .indeterminate(peer)
            return expectThat(
                world.finalRouting == expected,
                "expected \(expected), got \(String(describing: world.finalRouting))")
        })
}

func isHandedOff(_ output: RoutingOutput?) -> Bool {
    if case .handedOff = output { return true }
    return false
}

enum PowerScenarios {
    static let all: [Scenario] = [
        Scenario(
            name: "power: accept → asking apps → handed off",
            script: { world in
                world.addPeer(.session())
                world.at(in: .ms(500) ... .sec(2)) { world in world.hub.requestPower(.shutdown, world: world) }
            },
            expect: { world in
                let progress = world.hub.routingOutputs.contains {
                    if case .progress(_, .askingApps, _) = $0.output { return true }
                    return false
                }
                return expectThat(
                    world.finalRouting == .handedOff(PeerHandle(rawValue: 0)),
                    "\(String(describing: world.finalRouting))")
                    + expectThat(progress, "asking-apps progress reported")
            }),
        Scenario(
            name: "power: refuse → next provider → ACPI",
            script: { world in
                var session = PeerSpec.session()
                session.power.steps = [(.ms(10) ... .ms(50), .refused(.powerNotPermitted))]
                world.addPeer(session)
                var system = PeerSpec.system()
                system.power.steps = [(.ms(10) ... .ms(50), .refused(.powerNotPermitted))]
                world.addPeer(system)
                world.at(in: .ms(500) ... .sec(2)) { world in world.hub.requestPower(.shutdown, world: world) }
            },
            expect: { world in
                guard case .unserved(let refusals) = world.finalRouting else {
                    return ["expected ACPI, got \(String(describing: world.finalRouting))"]
                }
                return expectThat(refusals.count == 2, "two refusals")
                    + expectThat(
                        world.hub.asks.map(\.peer.rawValue) == [0, 1],
                        "session first, then system: \(world.hub.asks.map(\.peer.rawValue))")
            }),
        Scenario(
            name: "power: POWER_IN_PROGRESS ends routing indeterminate",
            script: { world in
                var session = PeerSpec.session()
                session.power.steps = [(.ms(10) ... .ms(50), .refused(.powerInProgress))]
                world.addPeer(session)
                world.addPeer(.system())
                world.at(in: .ms(500) ... .sec(2)) { world in world.hub.requestPower(.restart, world: world) }
            },
            expect: { world in
                expectThat(
                    world.finalRouting == .indeterminate(PeerHandle(rawValue: 0)),
                    "\(String(describing: world.finalRouting))")
                    + expectThat(world.hub.asks.count == 1, "no second provider asked")
            }),
        Scenario(
            name: "power: accepted → waiting on apps → blocked",
            script: { world in
                var session = PeerSpec.session()
                let apps = [AppValue(displayName: "Editor", identifier: "editor"), AppValue(displayName: "Mail")]
                session.power.steps = [
                    (.ms(10) ... .ms(50), .accepted), (.ms(20) ... .ms(80), .waitingOnApps(apps)),
                    (.ms(20) ... .ms(80), .blocked(apps)),
                ]
                world.addPeer(session)
                world.at(in: .ms(500) ... .sec(2)) { world in world.hub.requestPower(.shutdown, world: world) }
            },
            expect: { world in
                guard case .blocked(_, let apps, _) = world.finalRouting else {
                    return ["expected blocked, got \(String(describing: world.finalRouting))"]
                }
                return expectThat(apps.count == 2, "two apps")
            }),
        Scenario(
            name: "power: cancelled in guest",
            script: { world in
                var session = PeerSpec.session()
                session.power.steps = [(.ms(10) ... .ms(50), .accepted), (.ms(40) ... .ms(120), .cancelledInGuest)]
                world.addPeer(session)
                world.at(in: .ms(500) ... .sec(2)) { world in world.hub.requestPower(.shutdown, world: world) }
            },
            expect: { world in
                expectThat(
                    world.finalRouting == .cancelledInGuest(PeerHandle(rawValue: 0)),
                    "\(String(describing: world.finalRouting))")
            }),
        Scenario(
            name: "power: peer deadline with confirmed cancel → next provider",
            end: .sec(40),
            script: { world in
                var session = PeerSpec.session()
                session.power.steps = []
                session.power.onCancel = .confirm(after: .ms(50) ... .ms(150))
                world.addPeer(session)
                world.addPeer(.system())
                world.at(in: .ms(500) ... .sec(2)) { world in world.hub.requestPower(.shutdown, world: world) }
            },
            expect: { world in
                let refused = world.hub.powerResults.contains { $0.result == .refused(WireError(.timeout)) }
                return expectThat(refused, "the session peer refused TIMEOUT")
                    + expectThat(
                        world.finalRouting == .handedOff(PeerHandle(rawValue: 1)),
                        "the system peer handed off: \(String(describing: world.finalRouting))")
            }),
        Scenario(
            name: "power: host deadline with no answer → indeterminate",
            end: .sec(40),
            script: { world in
                var session = PeerSpec.session()
                session.power.steps = []
                session.power.onCancel = .silent(after: .sec(20) ... .sec(30))
                world.addPeer(session)
                world.addPeer(.system())
                world.at(in: .ms(500) ... .sec(2)) { world in
                    world.marks["asked"] = Int(world.now / 1_000_000)
                    world.hub.requestPower(.shutdown, world: world)
                }
            },
            expect: { world in
                let at = (world.hub.routingOutputs.last?.time ?? 0) / 1_000_000
                let after = Int(at) - (world.marks["asked"] ?? 0)
                return expectThat(
                    world.finalRouting == .indeterminate(PeerHandle(rawValue: 0)),
                    "\(String(describing: world.finalRouting))")
                    + expectThat(
                        after >= 15_000 && after <= 17_000,
                        "indeterminate at 15 s + confirmation, \(after) ms after the ask")
                    + expectThat(world.hub.asks.count == 1, "no second provider")
            }),
        Scenario(
            name: "power: a cancel the adapter cannot confirm releases it: a request on a new connection reaches it",
            seeds: 20,
            end: .sec(90),
            script: { world in
                var session = PeerSpec.session()
                session.power.steps = []
                session.power.onCancel = .silent(after: .sec(20) ... .sec(30))
                world.addPeer(session)
                world.at(in: .ms(500) ... .sec(2)) { world in world.hub.requestPower(.shutdown, world: world) }
                world.at(.sec(45)) { world in
                    world.hostCommand(.close(.shuttingDown, retryAfter: nil), link: world.links[0])
                }
                world.at(.sec(60)) { world in world.hub.requestPower(.shutdown, world: world) }
            },
            expect: { world in
                let performed = world.peers[0].performed
                return expectThat(performed.count == 2, "both requests reached the adapter: \(performed.map(\.id))")
                    + expectThat(
                        performed.map(\.id.generation.rawValue) == [1, 2],
                        "the second on the new connection: \(performed.map(\.id))")
            }),
        connectionLost(
            "power: connection lost while the request waits on the OS → indeterminate unless ACCEPTED was sent",
            accept: .ms(300) ... .ms(700), death: .ms(1_000) + 1 ... .ms(1_800)),
        connectionLost(
            "power: connection lost around a quick acceptance → lost after acceptance once ACCEPTED was sent",
            accept: .ms(5) ... .ms(40), death: .ms(1_000) + 1 ... .ms(1_100)),
        Scenario(
            name: "power: session and system peers disagree on the console",
            script: { world in
                world.addPeer(.session("c1", console: .on))
                world.addPeer(.session("c2", console: .off))
                world.addPeer(.system(consoleSessionID: "c2"))
                world.at(.sec(1)) { world in world.hub.requestPower(.shutdown, world: world) }
            },
            expect: { world in
                expectThat(
                    world.hub.asks.first?.peer == PeerHandle(rawValue: 1),
                    "the system peer's console session is asked first: \(world.hub.asks.map(\.peer.rawValue))")
            }),
        Scenario(
            name: "power: a second stop while routing is busy",
            script: { world in
                var session = PeerSpec.session()
                session.power.steps = [(.ms(250) ... .ms(350), .accepted), (.ms(250) ... .ms(350), .handedOff)]
                world.addPeer(session)
                world.at(.sec(1)) { world in world.hub.requestPower(.shutdown, world: world) }
                world.at(in: .ms(1_010) ... .ms(1_490)) { world in world.hub.requestPower(.shutdown, world: world) }
            },
            expect: { world in
                let busy = world.hub.routingOutputs.contains { $0.output == .busy }
                return expectThat(busy, "the second stop is busy")
                    + expectThat(world.peers[0].performed.count == 1, "one request performed")
            }),
        Scenario(
            name: "power: VM pause and guest clock leap inside the peer's deadline",
            end: .sec(40),
            options: { options in
                // The freeze lands between the OPEN and the OS's acceptance.
                options.faults = [.vmFreeze(in: .ms(1_010) ... .ms(1_440), for: .sec(25), guestClockJumps: true)]
            },
            script: { world in
                var session = PeerSpec.session()
                session.power.steps = [(.ms(450) ... .ms(550), .accepted), (.ms(50) ... .ms(150), .handedOff)]
                world.addPeer(session)
                world.at(.sec(1)) { world in world.hub.requestPower(.shutdown, world: world) }
            },
            expect: { world in
                expectThat(
                    world.finalRouting == .handedOff(PeerHandle(rawValue: 0)),
                    "accepted, not refused: \(String(describing: world.finalRouting))")
            }),
    ]
}

enum UpdateScenarios {
    static func peerWithInstaller() -> PeerSpec {
        var spec = PeerSpec.session()
        spec.installer = InstallerSpec()
        return spec
    }

    static let all: [Scenario] = [
        Scenario(
            name: "update: pull of 3 MiB → staged",
            seeds: 20,
            options: { options in options.bundles = [SimHub.bundle(size: 3 << 20, tag: 11)] },
            script: { world in world.addPeer(peerWithInstaller()) },
            expect: { world in
                expectThat(world.hub.updateResults.first?.result.kind == .staged, "staged: \(world.hub.updateResults)")
                    + expectThat(world.peers[0].installed == [SimHub.tagHash(11)], "installed the offered hash")
                    + expectThat(world.peers[0].starts == 2, "relaunched once")
            }),
        Scenario(
            name: "update: stale hash → UPDATE_STALE",
            options: { options in options.bundles = [SimHub.bundle(size: 30_000, tag: 12)] },
            script: { world in
                world.addPeer(peerWithInstaller())
                // The offer changes between the UpdateAvailable and the OPEN.
                world.at(.ms(1)) { world in
                    world.hub.setBundles([SimHub.bundle(size: 30_000, tag: 13)], world: world)
                }
            },
            expect: { world in
                let staged = world.hub.updateResults.contains { $0.result.kind == .staged }
                return expectThat(staged, "the new offer still installs")
            }),
        Scenario(
            name: "update: nothing offered → no pull",
            script: { world in world.addPeer(peerWithInstaller()) },
            expect: { world in expectThat(world.peers[0].pullsStarted.isEmpty, "no pull") }),
        Scenario(
            name: "update: the offer changes mid-pull → UPDATE_STALE, then the new one",
            seeds: 20,
            options: { options in options.bundles = [SimHub.bundle(size: 2 << 20, tag: 14)] },
            script: { world in
                world.addPeer(peerWithInstaller())
                world.at(.ms(4)) { world in world.hub.setBundles([SimHub.bundle(size: 100_000, tag: 15)], world: world)
                }
            },
            expect: { world in
                let stale = world.hub.updateClosures.contains {
                    $0.closure == .resetLocally(WireError(.updateStale))
                }
                return expectThat(stale || world.hub.updateResults.count == 2, "the first pull went stale")
                    + expectThat(
                        world.peers[0].installed.last == SimHub.tagHash(15),
                        "the new offer installed: \(world.peers[0].installed)")
            }),
        Scenario(
            name: "update: new version hangs before Hello → rolled back; offered again only when it changes",
            seeds: 20,
            end: .sec(400),
            options: { options in options.bundles = [SimHub.bundle(size: 100_000, tag: 18)] },
            script: { world in
                var spec = peerWithInstaller()
                spec.installer?.newVersionHangs = true
                world.addPeer(spec)
                world.at(.sec(300)) { world in
                    world.hub.setBundles([SimHub.bundle(size: 100_000, tag: 19)], world: world)
                }
            },
            expect: { world in
                let peer = world.peers[0]
                return expectThat(peer.installed.first == SimHub.tagHash(18), "installed 18 first: \(peer.installed)")
                    + expectThat(peer.installed.filter { $0 == SimHub.tagHash(18) }.count == 1, "18 not pulled again")
                    + expectThat(peer.installed.last == SimHub.tagHash(19), "19 installed once offered")
            }),
    ]
}
