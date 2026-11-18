#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaAgentCore
import KernovaAgentSimulation
import KernovaWire

/// CLIPBOARD, DROP and DRAG between a real host and peer, over item transfer. Property 12 checks every run:
/// each side holds at most one clipboard offer of its own.
enum ItemFeatureScenarios {
    static let all: [Scenario] = [
        clipboardReplaces, clipboardReleasesFarSide, replacedMidPull, wrongRoleOffers, offerRequestAnswered,
        offerRequestRefused, dragTaken,
        dragRefused, dragTakenOnce, dragWithdrawnWhileAsked, dragHandshake, dragStepsAtOnce, dragCalledOff,
        systemPeerServesNone, policyOff,
    ]

    static func options(_ options: inout SimOptions) {
        options.serveItems()
    }

    static func items(_ world: SimWorld, _ side: SimSide) -> SimItemSide? {
        world.links.first?.items(side)
    }

    static func ends(_ world: SimWorld, _ side: SimSide, _ origin: ItemOfferOrigin) -> [StreamClosure] {
        items(world, side)?.offersEnded.filter { $0.origin == origin }.map(\.closure) ?? []
    }

    static let file = SimItems.representation(.file, size: 300_000)

    static let clipboardReplaces = Scenario(
        name: "clipboard: each side's new clipboard offer withdraws its previous one ITEM_OFFER_REPLACED", seeds: 30,
        end: .sec(3),
        options: options,
        script: { world in
            world.addPeer(.session())
            for (tag, side, at) in [(UInt8(1), SimSide.peer, SimTime.ms(500)), (2, .host, .ms(1_500))] {
                world.at(in: at...at + .ms(100)) { world in
                    world.offerItems(SimItems.offer(tag, [[file]]), from: side)
                }
                world.at(in: at + .ms(200)...at + .ms(300)) { world in
                    world.offerItems(SimItems.offer(tag + 10, [[file]]), from: side)
                }
            }
        },
        expect: { world in
            var failures: [String] = []
            for (side, first, second) in [(SimSide.peer, UInt8(1), UInt8(11)), (.host, 2, 12)] {
                let far: SimSide = side == .host ? .peer : .host
                failures += expectThat(
                    items(world, side)?.offerRefusals.isEmpty == true, "\(side)'s offers opened")
                let local =
                    items(world, side)?.offersEnded.filter { $0.origin == .local && $0.token == SimItems.token(first) }
                    ?? []
                failures += expectThat(
                    local.map(\.closure) == [.resetLocally(WireError(.itemOfferReplaced))]
                        && local.allSatisfy { $0.feature == .clipboard },
                    "\(side) withdrew its first clipboard offer: \(local)")
                let received = items(world, far)?.offersReceived.map(\.header) ?? []
                failures += expectThat(
                    received.filter { [SimItems.token(first), SimItems.token(second)].contains($0.token) }.map(
                        \.feature)
                        == [.clipboard, .clipboard],
                    "\(far) received both clipboard offers: \(received)")
                let remote =
                    items(world, far)?.offersEnded.filter { $0.origin == .remote && $0.token == SimItems.token(first) }
                    ?? []
                failures += expectThat(
                    remote.map(\.closure) == [.resetByPeer(WireError(.itemOfferReplaced))],
                    "\(far) saw the first withdrawn: \(remote)")
            }
            return failures
        })

    static let clipboardReleasesFarSide = Scenario(
        name:
            "clipboard: a side's clipboard offer first releases every clipboard offer of the far side's it holds, so the far side hears its own end before the new offer",
        seeds: 20, end: .sec(3), options: options,
        script: { world in
            world.addPeer(.session())
            world.at(in: .ms(500) ... .ms(600)) { world in world.offerItems(SimItems.offer(1, [[file]]), from: .peer) }
            world.at(in: .ms(1_000) ... .ms(1_100)) { world in
                world.offerItems(SimItems.offer(2, [[file]]), from: .host)
            }
            world.at(in: .ms(1_500) ... .ms(1_600)) { world in
                world.offerItems(SimItems.offer(3, [[file]]), from: .peer)
            }
        },
        expect: { world in
            var failures: [String] = []
            for (side, held, next) in [(SimSide.peer, UInt8(1), UInt8(2)), (.host, 2, 3)] {
                let far: SimSide = side == .host ? .peer : .host
                let ended = items(world, side)?.offersEnded.first {
                    $0.origin == .local && $0.token == SimItems.token(held)
                }
                let arrived = items(world, side)?.offersReceived.first { $0.header.token == SimItems.token(next) }
                failures += expectThat(
                    ended.map { if case .completed = $0.closure { true } else { false } } == true,
                    "\(far)'s offer released \(side)'s: \(String(describing: ended))")
                failures += expectThat(
                    (ended?.time).flatMap { time in arrived.map { time <= $0.time } } == true,
                    "\(side) heard its offer end before \(far)'s arrived: \(String(describing: ended)), \(String(describing: arrived))"
                )
            }
            return failures
        })

    static let replacedMidPull = Scenario(
        name: "clipboard: a pull of the offer a new clipboard offer replaced ends ITEM_OFFER_STALE", seeds: 20,
        end: .sec(6),
        options: { options in
            Self.options(&options)
            options.faults = [.consumerStall(.host, .itemPullByHost, peer: 0, in: .at(.ms(950)), for: .sec(3))]
        },
        script: { world in
            world.addPeer(.session())
            world.at(.ms(500)) { world in
                world.offerItems(
                    SimItems.offer(1, [[SimItems.representation(.file, size: ItemScenarios.pastWindow)]]), from: .peer)
            }
            world.at(ItemScenarios.pullAt) { world in world.pullItem(SimItems.request(1), by: .host) }
            world.at(in: .ms(1_500) ... .ms(2_500)) { world in
                world.offerItems(SimItems.offer(2, [[file]]), from: .peer)
            }
        },
        expect: { world in
            let pull = ItemScenarios.onePull(world, .host)
            let served = items(world, .peer)?.servesEnded.first?.result
            return expectThat(
                pull.map { ItemScenarios.resetCode($0.1) } == .itemOfferStale,
                "the host's pull: \(ItemScenarios.ended(world, .host))")
                + expectThat(
                    ItemScenarios.resetCode(served) == .itemOfferStale,
                    "the peer reset its serve: \(String(describing: served))")
        })

    static let wrongRoleOffers = Scenario(
        name: "items: a role offering a feature it does not offer is refused UNSUPPORTED_KIND, and nothing opens",
        seeds: 5, end: .sec(2), options: options,
        script: { world in
            world.addPeer(.session())
            world.at(.ms(500)) { world in
                world.offerItems(SimItems.offer(1, [[file]]), feature: .drop, from: .peer)
                world.offerItems(SimItems.offer(2, []), feature: .drag, from: .host)
                world.offerItems(SimItems.offer(3, [[file]]), feature: .logs, from: .host)
            }
        },
        expect: { world in
            expectThat(
                items(world, .peer)?.offerRefusals.map(\.code) == [.unsupportedKind]
                    && items(world, .host)?.offerRefusals.map(\.code) == [.unsupportedKind, .unsupportedKind],
                "refusals: peer \(String(describing: items(world, .peer)?.offerRefusals)), host \(String(describing: items(world, .host)?.offerRefusals))"
            )
                + expectThat(
                    items(world, .peer)?.offersReceived.isEmpty == true
                        && items(world, .host)?.offersReceived.isEmpty == true, "an offer opened")
        })

    /// The token of the host's clipboard offer requests in these scenarios.
    static let requestToken = SimItems.token(5)

    static let offerRequestAnswered = Scenario(
        name:
            "clipboard: the host's request withdraws no clipboard offer and its next clipboard offer leaves it open; the peer answers with an ordinary clipboard offer naming it, releasing the host's offer it holds, then releases the request",
        seeds: 20, end: .sec(3), options: options,
        script: { world in
            world.addPeer(.session())
            world.at(.ms(500)) { world in
                world.links.first?.items(.peer).offerRequestAnswer = .offer(SimItems.offer(9, [[file]]).items)
                world.offerItems(SimItems.offer(1, [[file]]), from: .peer)
                world.offerItems(SimItems.offer(2, [[file]]), from: .host)
            }
            world.at(.ms(700)) { world in
                world.requestClipboardOffer(requestToken)
                world.offerItems(SimItems.offer(3, [[file]]), from: .host)
            }
        },
        expect: { world in
            let host = items(world, .host)
            let local = host?.offersEnded.filter { $0.origin == .local } ?? []
            let completed = { (closure: StreamClosure) -> Bool in
                if case .completed = closure { true } else { false }
            }
            let request = host?.requestsEnded.filter { $0.origin == .local } ?? []
            let answers = items(world, .peer)?.requestAnswers ?? []
            let received = host?.offersReceived.map(\.header).filter { !$0.request.isEmpty } ?? []
            let requests = items(world, .peer)?.requestsReceived.map(\.token) ?? []
            let offeredRequest = items(world, .peer)?.offersReceived.contains { $0.header.token == requestToken }
            return expectThat(host?.offerRefusals.isEmpty == true, "the host's offers and request opened")
                + expectThat(
                    local.first?.token == SimItems.token(2)
                        && local.first?.closure == .resetLocally(WireError(.itemOfferReplaced))
                        // The answer releases the host's next offer when it arrived first.
                        && local.dropFirst().allSatisfy {
                            $0.token == SimItems.token(3)
                                && (completed($0.closure) || $0.closure == .resetByPeer(WireError(.cancelled)))
                        }
                        && local.allSatisfy { $0.feature == .clipboard },
                    "the host's next clipboard offer withdrew only its previous one: \(local)")
                + expectThat(
                    request.map(\.token) == [requestToken]
                        && request.allSatisfy { if case .completed = $0.closure { true } else { false } },
                    "the peer released the request: \(request)")
                + expectThat(
                    requests == [requestToken] && offeredRequest == false,
                    "the peer heard the request once, and never as an offer: \(requests)")
                + expectThat(
                    answers.count == 1
                        && received.map(\.token) == answers.map(\.token)
                        && received.allSatisfy { $0.request == requestToken && $0.feature == .clipboard },
                    "the host received the answer naming its request: \(received)")
                + expectThat(
                    ends(world, .host, .remote).count == 1 && ends(world, .host, .remote).allSatisfy(completed),
                    "the host's next clipboard offer released the peer's: \(ends(world, .host, .remote))")
        })

    static let offerRequestRefused = Scenario(
        name:
            "clipboard: the peer refuses the host's request CLIPBOARD_NOTHING_TO_COPY; a peer's request is refused UNSUPPORTED_KIND and nothing opens",
        seeds: 5, end: .sec(2), options: options,
        script: { world in
            world.addPeer(.session())
            world.at(.ms(500)) { world in
                world.links.first?.items(.peer).offerRequestAnswer = .refuse(WireError(.clipboardNothingToCopy))
                world.requestClipboardOffer(requestToken)
                world.requestClipboardOffer(SimItems.token(6), by: .peer)
            }
        },
        expect: { world in
            let local = items(world, .host)?.requestsEnded.filter { $0.origin == .local } ?? []
            return expectThat(
                local.map(\.token) == [requestToken]
                    && local.map(\.closure) == [.resetByPeer(WireError(.clipboardNothingToCopy))],
                "the request: \(local)")
                + expectThat(
                    items(world, .peer)?.offerRefusals.map(\.code) == [.unsupportedKind],
                    "the peer's request: \(String(describing: items(world, .peer)?.offerRefusals))")
                + expectThat(items(world, .host)?.offersReceived.isEmpty == true, "the host received an offer")
        })

    /// The items a drag's take lists.
    static var dragItems: [OfferedItem] { SimItems.offer(1, [[file]]).items }

    /// One session peer offering a drag at 500 ms whose take's `TARGETED` lists ``dragItems``.
    static func dragOffered(_ world: SimWorld) {
        world.addPeer(.session())
        world.at(.ms(500)) { world in
            world.links.first?.items(.peer).takeItems = dragItems
            world.offerItems(SimItems.offer(1, []), feature: .drag, from: .peer)
        }
    }

    static let dragTaken = Scenario(
        name: "drag: the host takes the peer's drag → CAUGHT, pulls it → LANDED, and its release ends the offer",
        seeds: 20, end: .sec(3), options: options,
        script: { world in
            dragOffered(world)
            world.at(.ms(700)) { world in world.takeDrag(SimItems.token(1)) }
            world.at(.ms(900)) { world in world.pullItem(SimItems.request(1), by: .host) }
            world.at(.ms(1_500)) { world in world.releaseOffer(SimItems.token(1), by: .host) }
        },
        expect: { world in
            let host = items(world, .host)
            let id = host?.takes.first.flatMap { try? $0.result.get() }
            return expectThat(id != nil, "the take opened: \(String(describing: host?.takes))")
                + expectThat(
                    items(world, .peer)?.takesRequested.map(\.token) == [SimItems.token(1)],
                    "the peer was asked once")
                + expectThat(
                    host?.takesEnded.map(\.result) == [.caught(nil)] && host?.takesEnded.first?.id == id,
                    "the take ended caught: \(String(describing: host?.takesEnded))")
                + expectThat(
                    ItemScenarios.isLanded(ItemScenarios.onePull(world, .host)?.1),
                    "the pull: \(ItemScenarios.ended(world, .host))")
                + expectThat(
                    host?.pullsEnded.map(\.feature) == [.drag]
                        && items(world, .peer)?.servesEnded.map(\.feature) == [.drag],
                    "both ends of the pull name DRAG: \(String(describing: host?.pullsEnded))")
                + expectThat(
                    ends(world, .peer, .local).count == 1
                        && ends(world, .peer, .local).allSatisfy {
                            if case .completed = $0 { true } else { false }
                        }, "the release completed the drag offer: \(ends(world, .peer, .local))")
        })

    static let dragRefused = Scenario(
        name: "drag: the peer refuses a take DRAG_PRESS_OVER, and its drag stays offered", seeds: 20, end: .sec(2),
        options: options,
        script: { world in
            dragOffered(world)
            world.at(.ms(600)) { world in
                world.links.first?.items(.peer).takeAnswer = .refused(WireError(.dragPressOver))
            }
            world.at(.ms(700)) { world in world.takeDrag(SimItems.token(1)) }
        },
        expect: { world in
            expectThat(
                items(world, .host)?.takesEnded.map(\.result) == [.refused(WireError(.dragPressOver))],
                "the take: \(String(describing: items(world, .host)?.takesEnded))")
                + expectThat(ends(world, .host, .remote).isEmpty, "the drag offer ended")
        })

    static let dragTakenOnce = Scenario(
        name:
            "drag: a second take of a taken drag is refused DRAG_NOT_CURRENT; one naming a clipboard offer never opens",
        seeds: 20, end: .sec(2), options: options,
        script: { world in
            dragOffered(world)
            world.at(.ms(550)) { world in world.offerItems(SimItems.offer(2, [[file]]), from: .peer) }
            world.at(.ms(700)) { world in world.takeDrag(SimItems.token(1)) }
            world.at(.ms(900)) { world in world.takeDrag(SimItems.token(1)) }
            world.at(.ms(900)) { world in world.takeDrag(SimItems.token(2)) }
        },
        expect: { world in
            let host = items(world, .host)
            return expectThat(
                host?.takesEnded.map(\.result) == [.caught(nil), .refused(WireError(.dragNotCurrent))],
                "the takes: \(String(describing: host?.takesEnded))")
                + expectThat(
                    host?.takes.last.map {
                        if case .failure(let error) = $0.result { error.code == .itemOfferStale } else { false }
                    } == true,
                    "the take of a clipboard offer: \(String(describing: host?.takes.last))")
                + expectThat(items(world, .peer)?.takesRequested.count == 1, "the peer was asked again")
        })

    static let dragWithdrawnWhileAsked = Scenario(
        name: "drag: a take whose drag is withdrawn before the peer answers is refused DRAG_NOT_CURRENT", seeds: 20,
        end: .sec(2), options: options,
        script: { world in
            dragOffered(world)
            world.at(.ms(600)) { world in world.links.first?.items(.peer).takeAnswer = nil }
            world.at(.ms(700)) { world in world.takeDrag(SimItems.token(1)) }
            world.at(.ms(900)) { world in world.withdrawOffer(SimItems.token(1), from: .peer) }
            world.at(.ms(1_000)) { world in
                guard let link = world.links.first, let id = link.items(.peer).takesRequested.first?.id else { return }
                world.peerInput(.dragTake(id, .caught(sizes: nil)), link: link, after: 0)
            }
        },
        expect: { world in
            expectThat(
                items(world, .host)?.takesEnded.map(\.result) == [.refused(WireError(.dragNotCurrent))],
                "the take: \(String(describing: items(world, .host)?.takesEnded))")
        })

    /// The peer's owner answers takes by hand from here on.
    static func answersByHand(_ world: SimWorld) {
        world.at(.ms(600)) { world in world.links.first?.items(.peer).takeAnswer = nil }
    }

    /// The peer's owner says `answer` on the take it was asked about first.
    static func answer(_ answer: DragTakeAnswer, _ world: SimWorld) {
        guard let link = world.links.first, let id = link.items(.peer).takesRequested.first?.id else { return }
        world.peerInput(.dragTake(id, answer), link: link, after: 0)
    }

    static let dragHandshake = Scenario(
        name:
            "drag: a take carries the host's controls and the peer's steps both ways until the peer's CAUGHT, which the host's END completes",
        seeds: 20, end: .sec(2), options: options,
        script: { world in
            dragOffered(world)
            answersByHand(world)
            world.at(.ms(700)) { world in world.takeDrag(SimItems.token(1)) }
            world.at(.ms(800)) { world in answer(.report(.armed), world) }
            world.at(.ms(850)) { world in answer(.report(.targeted(dragItems)), world) }
            world.at(.ms(900)) { world in world.controlTakes(.catcher(shown: false)) }
            world.at(.ms(950)) { world in world.controlTakes(.deliver) }
            world.at(.ms(1_000)) { world in answer(.report(.delivering), world) }
            world.at(.ms(1_050)) { world in answer(.caught(sizes: nil), world) }
            world.at(.ms(1_100)) { world in world.controlTakes(.catcher(shown: true)) }
        },
        expect: { world in
            let host = items(world, .host)
            let peer = items(world, .peer)
            return expectThat(
                host?.takeReports.map(\.report) == [.armed, .targeted(dragItems), .delivering],
                "the host heard: \(String(describing: host?.takeReports))")
                + expectThat(
                    peer?.takeControls.map(\.control) == [.catcher(shown: false), .deliver],
                    "the peer heard, and nothing after its END: \(String(describing: peer?.takeControls))")
                + expectThat(
                    host?.takesEnded.map(\.result) == [.caught(nil)],
                    "the take: \(String(describing: host?.takesEnded))")
                + expectThat(peer?.takesCancelled.isEmpty == true, "the peer heard its own END as a cancel")
                + expectThat(ends(world, .host, .remote).isEmpty, "the drag offer ended with the take")
        })

    static let dragStepsAtOnce = Scenario(
        name: "drag: steps and an END the peer says in one turn all reach the host, in order, the END last",
        seeds: 20, end: .sec(2), options: options,
        script: { world in
            dragOffered(world)
            answersByHand(world)
            world.at(.ms(700)) { world in world.takeDrag(SimItems.token(1)) }
            world.at(.ms(800)) { world in
                guard let link = world.links.first, let id = link.items(.peer).takesRequested.first?.id else { return }
                link.peer?.handle(.dragTake(id, .report(.armed)), now: world.localNow(world.process(of: link, .peer)))
                link.peer?.handle(
                    .dragTake(id, .report(.targeted(dragItems))), now: world.localNow(world.process(of: link, .peer)))
                link.peer?.handle(
                    .dragTake(id, .caught(sizes: nil)), now: world.localNow(world.process(of: link, .peer)))
                world.drain(link, .peer)
            }
        },
        expect: { world in
            let host = items(world, .host)
            return expectThat(
                host?.takeReports.map(\.report) == [.armed, .targeted(dragItems)],
                "the host heard: \(String(describing: host?.takeReports))")
                + expectThat(
                    host?.takesEnded.map(\.result) == [.caught(nil)],
                    "the take: \(String(describing: host?.takesEnded))")
                + expectThat(
                    (host?.takeReports.last?.time).map { last in host?.takesEnded.first.map { $0.time >= last } ?? false
                    }
                        ?? false, "the END came after the steps")
        })

    static let dragCalledOff = Scenario(
        name: "drag: the host calls a take off, the peer hears it once, and its later answer is dropped",
        seeds: 20, end: .sec(2), options: options,
        script: { world in
            dragOffered(world)
            answersByHand(world)
            world.at(.ms(700)) { world in world.takeDrag(SimItems.token(1)) }
            world.at(.ms(800)) { world in answer(.report(.armed), world) }
            world.at(.ms(900)) { world in world.cancelTakes() }
            world.at(.ms(1_000)) { world in answer(.caught(sizes: nil), world) }
        },
        expect: { world in
            let host = items(world, .host)
            let peer = items(world, .peer)
            let calledOff = host?.takesEnded.map(\.result).allSatisfy {
                if case .closed(.resetLocally(let error)) = $0 { error.code == .cancelled } else { false }
            }
            return expectThat(
                host?.takesEnded.count == 1 && calledOff == true,
                "the take: \(String(describing: host?.takesEnded))")
                + expectThat(
                    peer?.takesCancelled.count == 1, "the peer heard: \(String(describing: peer?.takesCancelled))")
                + expectThat(ends(world, .host, .remote).isEmpty, "the drag offer ended with the take")
        })

    static let systemPeerServesNone = Scenario(
        name: "items: a system peer serving every item adapter advertises CLIPBOARD, DROP and DRAG NOT_SERVED_BY_ROLE",
        seeds: 5, end: .sec(2), options: options,
        script: { world in
            world.addPeer(.system())
            world.at(.ms(500)) { world in world.offerItems(SimItems.offer(1, [[file]]), from: .peer) }
            world.at(.ms(500)) { world in world.offerItems(SimItems.offer(2, [[file]]), feature: .drop, from: .host) }
        },
        expect: { world in
            guard let status = world.hub.connected.first?.status else { return ["no peer connected"] }
            var failures: [String] = []
            for feature in [FeatureID.clipboard, .drop, .drag] {
                failures += expectThat(
                    status[feature] == .absent(.notServedByRole, debugDetail: ""), "\(feature): \(status[feature])")
            }
            failures += expectThat(status[.itemTransfer].isAvailable, "item transfer: \(status[.itemTransfer])")
            let refused = (items(world, .peer)?.offerRefusals ?? []) + (items(world, .host)?.offerRefusals ?? [])
            failures += expectThat(
                refused.map(\.code) == [.featureUnavailable, .featureUnavailable]
                    && refused.allSatisfy { $0.absence == .notServedByRole }, "offers: \(refused)")
            return failures
        })

    static let policyOff = Scenario(
        name: "clipboard: the policy turning clipboard off ends the open offers DISABLED_BY_POLICY, and their pulls",
        seeds: 20, end: .sec(6),
        options: { options in
            Self.options(&options)
            options.faults = [.consumerStall(.host, .itemPullByHost, peer: 0, in: .at(.ms(950)), for: .sec(3))]
        },
        script: { world in
            world.addPeer(.session())
            world.at(.ms(500)) { world in
                world.offerItems(
                    SimItems.offer(1, [[SimItems.representation(.file, size: ItemScenarios.pastWindow)]]), from: .peer)
                world.offerItems(SimItems.offer(2, [[file]]), from: .host)
            }
            world.at(ItemScenarios.pullAt) { world in world.pullItem(SimItems.request(1), by: .host) }
            world.at(in: .ms(1_500) ... .ms(2_500)) { world in
                var policy = SimItems.policy(PolicySnapshot([FeaturePolicyValue(feature: .logs, enabled: true)]))
                policy = PolicySnapshot(
                    policy.entries.map {
                        $0.feature == .clipboard ? FeaturePolicyValue(feature: .clipboard, enabled: false) : $0
                    })
                world.hub.setPolicy(policy, world: world)
            }
        },
        expect: { world in
            var failures = expectThat(
                ItemScenarios.onePull(world, .host).map { ItemScenarios.resetCode($0.1) } == .itemOfferStale,
                "the host's pull: \(ItemScenarios.ended(world, .host))")
            for side in [SimSide.host, .peer] {
                let ended = items(world, side)?.offersEnded ?? []
                failures += expectThat(
                    ended.count == 2
                        && ended.allSatisfy {
                            switch $0.closure {
                            case .resetLocally(let error), .resetByPeer(let error): error.code == .disabledByPolicy
                            default: false
                            }
                        }, "\(side)'s offers ended: \(ended)")
            }
            return failures
        })
}
