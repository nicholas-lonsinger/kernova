#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaAgentCore
import KernovaAgentSimulation
import KernovaWire

/// Item pulls between a real host and peer. Property 11 checks every run: each pull ends exactly once on each
/// side, its sink committed or aborted and its source released first, and the sink's decoder stays bounded.
enum ItemScenarios {
    static let all: [Scenario] = [
        landsEveryStorage, peerPulls, stalledReceiver, deathWhileStalled, deathInFlight, sourceCeiling,
        sinkCeiling, withdrawnMidPull, releasedMidPull, staleToken, cancelled,
    ]

    /// Past the 8 MiB bulk receive window, so a stalled sink holds the pull at its credit.
    static let pastWindow = 12 << 20
    /// The pull a scenario's host makes, at 1 s.
    static let pullAt: SimTime = .sec(1)

    static func options(_ options: inout SimOptions) {
        options.serveItems()
    }

    /// One session peer offering, at 500 ms, one item of these representations.
    static func peerOffers(_ world: SimWorld, _ representations: [Representation]) {
        world.addPeer(.session())
        world.at(.ms(500)) { world in world.offerItems(SimItems.offer(1, [representations]), from: .peer) }
    }

    /// The one pull `side` ended, or a failure naming what it ended instead.
    static func onePull(_ world: SimWorld, _ side: SimSide) -> (ItemPullID, ItemPullResult)? {
        guard let link = world.links.first, link.items(side).pullsEnded.count == 1 else { return nil }
        let ended = link.items(side).pullsEnded[0]
        return (ended.id, ended.result)
    }

    static func ended(_ world: SimWorld, _ side: SimSide) -> String {
        guard let link = world.links.first else { return "no link" }
        return "pulls \(link.items(side).pulls.map(\.result)), ended \(link.items(side).pullsEnded.map(\.result))"
    }

    static func resetCode(_ result: ItemPullResult?) -> ErrorCode? {
        switch result {
        case .closed(.resetByPeer(let error)), .closed(.resetLocally(let error)): error.code
        default: nil
        }
    }

    /// One representation of each storage.
    static let everyStorage = [
        SimItems.representation(.inline, size: 100), SimItems.representation(.file, size: 300_000),
        SimItems.representation(.folder, size: 2_000_000),
    ]

    static let landsEveryStorage = Scenario(
        name: "items: the host pulls each storage of a peer's offer, and each lands", seeds: 30, end: .sec(3),
        options: options,
        script: { world in
            peerOffers(world, everyStorage)
            world.at(.ms(800)) { world in world.readItem(SimItems.token(1), by: .host) }
            for index in 0..<3 {
                world.at(in: .ms(800) ... .ms(900)) { world in
                    world.pullItem(SimItems.request(1, representation: UInt32(index)), by: .host)
                }
            }
        },
        expect: { world in
            guard let link = world.links.first else { return ["no link"] }
            let host = link.items(.host)
            var failures: [String] = []
            failures += expectThat(link.items(.peer).offerRefusals.isEmpty, "the peer's offer opened")
            failures += expectThat(host.offersReceived.count == 1, "the host received the offer once")
            failures += expectThat(host.pullsEnded.count == 3, "three pulls ended: \(ended(world, .host))")
            let read = host.reads.first?.result
            failures += expectThat(
                read?.representations == everyStorage, "the host read the offered item")
            for ended in host.pullsEnded {
                guard ended.result == .landed,
                    let request = host.pulls.first(where: { (try? $0.result.get()) == ended.id })?.request,
                    let offered = read
                else {
                    failures.append("pull \(ended.id.stream.rawValue) ended \(ended.result)")
                    continue
                }
                let representation = offered.representations[Int(request.representation)]
                failures += expectThat(
                    host.sink.landed[ended.id] == SimItems.digest(request, representation),
                    "pull \(ended.id.stream.rawValue) landed other bytes")
            }
            failures += expectThat(
                link.items(.peer).servesEnded.map(\.result) == [.landed, .landed, .landed],
                "the peer served three landings: \(link.items(.peer).servesEnded.map(\.result))")
            failures += expectThat(link.items(.peer).source.heldCount == 0, "the peer's source released every pull")
            return failures
        })

    static let peerPulls = Scenario(
        name: "items: a peer pulls the host's offer, and it lands", seeds: 30, end: .sec(3), options: options,
        script: { world in
            world.addPeer(.session())
            world.at(.ms(500)) { world in
                world.offerItems(
                    SimItems.offer(2, [[SimItems.representation(.file, size: 1 << 20)]]), from: .host)
            }
            world.at(in: .ms(800) ... .ms(900)) { world in world.pullItem(SimItems.request(2), by: .peer) }
        },
        expect: { world in
            let pull = onePull(world, .peer)
            return expectThat(pull?.1 == .landed, "the peer's pull landed: \(ended(world, .peer))")
                + expectThat(
                    world.links.first?.items(.host).servesEnded.map(\.result) == [.landed],
                    "the host served one landing")
        })

    static let stalledReceiver = Scenario(
        name: "items: a stalled receiver holds the pull at its credit, then it lands", seeds: 10, end: .sec(6),
        options: { options in
            Self.options(&options)
            options.faults = [.consumerStall(.host, .itemPullByHost, peer: 0, in: .at(.ms(950)), for: .sec(3))]
        },
        script: { world in
            peerOffers(world, [SimItems.representation(.file, size: pastWindow)])
            world.at(pullAt) { world in world.pullItem(SimItems.request(1), by: .host) }
            // Mid-stall, the peer has sent no more than the host's credit allows.
            world.at(.ms(2_500)) { world in
                world.marks["sent"] = world.links.first?.bytesWritten(by: .peer) ?? 0
            }
        },
        expect: { world in
            let pull = world.links.first?.items(.host).pullsEnded.first
            return expectThat(pull?.result == .landed, "the pull landed: \(ended(world, .host))")
                + expectThat((pull?.time ?? 0) >= .ms(3_950), "the pull waited out the stall")
                + expectThat(
                    (world.marks["sent"] ?? .max) < 8 << 20 + 1 << 20,
                    "mid-stall the peer had written \(world.marks["sent"] ?? -1) bytes")
        })

    static let deathWhileStalled = Scenario(
        name: "items: the serving peer dies mid-pull, and the host's pull ends once", seeds: 10, end: .sec(6),
        options: { options in
            Self.options(&options)
            options.faults = [
                .consumerStall(.host, .itemPullByHost, peer: 0, in: .at(.ms(950)), for: .sec(3)),
                .peerDeath(peer: 0, in: .ms(1_200) ... .ms(2_500)),
            ]
        },
        script: { world in
            peerOffers(world, [SimItems.representation(.file, size: pastWindow)])
            world.at(pullAt) { world in world.pullItem(SimItems.request(1), by: .host) }
        },
        expect: { world in
            guard case .closed? = onePull(world, .host)?.1 else {
                return ["the host's pull did not end once, closed: \(ended(world, .host))"]
            }
            return []
        })

    static let deathInFlight = Scenario(
        name: "items: the serving peer dies at any instant of a pull, and the host's pull ends once", seeds: 40,
        end: .sec(3),
        options: { options in
            Self.options(&options)
            options.faults = [.peerDeath(peer: 0, in: .us(1_000_001) ... .ms(1_025))]
        },
        script: { world in
            peerOffers(world, [SimItems.representation(.folder, size: 6 << 20)])
            world.at(pullAt) { world in world.pullItem(SimItems.request(1), by: .host) }
        },
        expect: { world in
            switch onePull(world, .host)?.1 {
            case .landed?, .closed?: []
            default: ["the host's pull did not end once: \(ended(world, .host))"]
            }
        })

    static let sourceCeiling = Scenario(
        name: "items: a pull past its byte ceiling is reset TOO_LARGE by the source", seeds: 20, end: .sec(3),
        options: options,
        script: { world in
            peerOffers(world, [SimItems.representation(.file, size: 300_000)])
            world.at(pullAt) { world in world.pullItem(SimItems.request(1, ceiling: 1_000), by: .host) }
        },
        expect: { world in
            let result = onePull(world, .host)?.1
            guard case .closed(.resetByPeer(let error))? = result else { return ["host: \(ended(world, .host))"] }
            return expectThat(error.code == .tooLarge && error.limit == 1_000, "reset \(error)")
                + expectThat(
                    resetCode(world.links.first?.items(.peer).servesEnded.first?.result) == .tooLarge,
                    "the peer served a TOO_LARGE reset")
        })

    static let sinkCeiling = Scenario(
        name: "items: a container past the byte ceiling is refused TOO_LARGE by the sink", seeds: 20, end: .sec(3),
        options: options,
        script: { world in
            peerOffers(world, [SimItems.representation(.folder, size: 300_000)])
            world.at(.ms(900)) { world in world.links.first?.items(.peer).source.ignoresCeiling = true }
            world.at(pullAt) { world in world.pullItem(SimItems.request(1, ceiling: 1_000), by: .host) }
        },
        expect: { world in
            let result = onePull(world, .host)?.1
            guard case .failed(let error)? = result else { return ["host: \(ended(world, .host))"] }
            let served = world.links.first?.items(.peer).servesEnded.first?.result
            return expectThat(error.code == .tooLarge, "refused \(error)")
                + expectThat(
                    resetCode(served) == .tooLarge, "the peer's pull was reset TOO_LARGE: \(String(describing: served))"
                )
        })

    static let withdrawnMidPull = Scenario(
        name: "items: the offer withdrawn mid-pull resets the pull ITEM_OFFER_STALE", seeds: 20, end: .sec(6),
        options: { options in
            Self.options(&options)
            options.faults = [.consumerStall(.host, .itemPullByHost, peer: 0, in: .at(.ms(950)), for: .sec(3))]
        },
        script: { world in
            peerOffers(world, [SimItems.representation(.file, size: pastWindow)])
            world.at(pullAt) { world in world.pullItem(SimItems.request(1), by: .host) }
            world.at(in: .ms(1_500) ... .ms(2_500)) { world in world.withdrawOffer(SimItems.token(1), from: .peer) }
        },
        expect: { world in
            let pull = onePull(world, .host)
            let served = world.links.first?.items(.peer).servesEnded.first?.result
            let offerEnds =
                world.links.first?.items(.host).offersEnded.filter { $0.origin == .remote }.map(\.closure) ?? []
            return expectThat(
                pull.map { resetCode($0.1) } == .itemOfferStale, "the host's pull: \(ended(world, .host))")
                + expectThat(
                    resetCode(served) == .itemOfferStale, "the peer reset its serve: \(String(describing: served))")
                + expectThat(
                    offerEnds == [.resetByPeer(WireError(.cancelled))],
                    "the host saw the peer's offer withdrawn: \(offerEnds)")
        })

    static let releasedMidPull = Scenario(
        name: "items: the receiver releasing the offer mid-pull ends the pull ITEM_OFFER_STALE", seeds: 20,
        end: .sec(6),
        options: { options in
            Self.options(&options)
            options.faults = [.consumerStall(.host, .itemPullByHost, peer: 0, in: .at(.ms(950)), for: .sec(3))]
        },
        script: { world in
            peerOffers(world, [SimItems.representation(.file, size: pastWindow)])
            world.at(pullAt) { world in world.pullItem(SimItems.request(1), by: .host) }
            world.at(in: .ms(1_500) ... .ms(2_500)) { world in world.releaseOffer(SimItems.token(1), by: .host) }
        },
        expect: { world in
            let offerEnds =
                world.links.first?.items(.peer).offersEnded.filter { $0.origin == .local }.map(\.closure) ?? []
            return expectThat(
                onePull(world, .host).map { resetCode($0.1) } == .itemOfferStale,
                "the host's pull: \(ended(world, .host))")
                + expectThat(
                    offerEnds.count == 1
                        && offerEnds.allSatisfy {
                            if case .completed = $0 { true } else { false }
                        }, "the peer's offer completed: \(offerEnds)")
        })

    static let staleToken = Scenario(
        name: "items: a pull crossing its offer's withdrawal ends ITEM_OFFER_STALE", seeds: 60, end: .sec(3),
        options: options,
        script: { world in
            peerOffers(world, [SimItems.representation(.file, size: pastWindow)])
            world.at(.ms(1_000)) { world in world.withdrawOffer(SimItems.token(1), from: .peer) }
            world.at(in: .ms(995) ... .ms(1_005)) { world in world.pullItem(SimItems.request(1), by: .host) }
        },
        expect: { world in
            guard let host = world.links.first?.items(.host), let asked = host.pulls.first?.result else {
                return ["no pull"]
            }
            switch asked {
            case .failure(let error):
                return expectThat(
                    error.code == .itemOfferStale && host.pullsEnded.isEmpty, "refused \(error), \(ended(world, .host))"
                )
            case .success:
                let result = onePull(world, .host)?.1
                return expectThat(
                    resetCode(result) == .itemOfferStale || result == .landed, "the pull: \(ended(world, .host))")
            }
        })

    static let cancelled = Scenario(
        name: "items: a cancelled pull ends once on both sides", seeds: 20, end: .sec(6),
        options: { options in
            Self.options(&options)
            options.faults = [.consumerStall(.host, .itemPullByHost, peer: 0, in: .at(.ms(950)), for: .sec(3))]
        },
        script: { world in
            peerOffers(world, [SimItems.representation(.file, size: pastWindow)])
            world.at(pullAt) { world in world.pullItem(SimItems.request(1), by: .host) }
            world.at(in: .ms(1_100) ... .ms(2_000)) { world in world.cancelPulls(by: .host) }
        },
        expect: { world in
            let pull = onePull(world, .host)
            let served = world.links.first?.items(.peer).servesEnded.first?.result
            return expectThat(pull?.1 == .closed(.resetLocally(WireError(.cancelled))), "host: \(ended(world, .host))")
                + expectThat(
                    served == .closed(.resetByPeer(WireError(.cancelled))), "peer: \(String(describing: served))")
        })
}
