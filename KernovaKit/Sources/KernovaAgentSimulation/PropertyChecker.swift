#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaAgentCore
import KernovaWire

/// Decodes one link's bytes as written and as delivered, for the wire-level
/// properties: no frame before its OPEN (2) and credit (4).
final class LinkObserver {
    let link: Int
    private var written: [SimSide: FrameDecoder] = [.host: FrameDecoder(), .peer: FrameDecoder()]
    private var delivered: [SimSide: FrameDecoder] = [.host: FrameDecoder(), .peer: FrameDecoder()]
    /// OPENs written, per opener side.
    private var opened: [SimSide: Set<UInt32>] = [.host: [], .peer: []]
    /// Per writer side: DATA bytes spent per stream, raw bytes spent on the connection.
    private var spent: [SimSide: [UInt32: Int]] = [.host: [:], .peer: [:]]
    private var rawSpent: [SimSide: Int] = [.host: 0, .peer: 0]
    /// Per writer side: credit the far side's WINDOWs granted, as delivered to the writer.
    private var granted: [SimSide: [UInt32: Int]] = [.host: [:], .peer: [:]]
    private var rawGranted: [SimSide: Int] = [.host: 0, .peer: 0]
    private var failed: Set<SimSide> = []

    init(link: Int) {
        self.link = link
    }

    func written(_ bytes: Data, by side: SimSide, world: SimWorld) {
        guard !failed.contains(side) else { return }
        written[side]?.append(bytes)
        while true {
            let frame: Frame?
            do {
                frame = try written[side]?.nextFrame()
            } catch {
                failed.insert(side)
                if !world.options.hostile {
                    world.checker.fail("link \(link) \(side) wrote an undecodable frame: \(error)")
                }
                return
            }
            guard let frame else { return }
            check(written: frame, by: side, world: world)
        }
    }

    func delivered(_ bytes: Data, to side: SimSide, world: SimWorld) {
        delivered[side]?.append(bytes)
        while let frame = try? delivered[side]?.nextFrame() {
            guard frame.type == .window else { continue }
            let increment = frame.payload.reduce(0) { $0 << 8 | Int($1) }
            // A WINDOW delivered to `side` grants `side` credit.
            if frame.streamID == .session {
                rawGranted[side, default: 0] += increment
            } else {
                granted[side, default: [:]][frame.streamID.rawValue, default: 0] += increment
            }
        }
    }

    private func check(written frame: Frame, by side: SimSide, world: SimWorld) {
        let id = frame.streamID.rawValue
        guard id != 0 else { return }
        let openerIsHost = id % 2 == 0
        let writerIsOpener = (side == .host) == openerIsHost
        if frame.type == .open {
            opened[side, default: []].insert(id)
            return
        }
        if writerIsOpener, !(opened[side]?.contains(id) ?? false), !world.options.hostile {
            world.checker.fail("property 2: link \(link) \(side) sent \(frame.type) on stream \(id) before its OPEN")
        }
        guard frame.type == .data, !world.options.hostile else { return }
        let count = frame.payload.count
        let streamSpent = (spent[side]?[id] ?? 0) + count
        spent[side, default: [:]][id] = streamSpent
        let streamGranted = 262_144 + (granted[side]?[id] ?? 0)
        if streamSpent > streamGranted {
            world.checker.fail(
                "property 4: link \(link) \(side) spent \(streamSpent) on stream \(id) of \(streamGranted)")
        }
        if !frame.flags.contains(.message) {
            let total = (rawSpent[side] ?? 0) + count
            rawSpent[side] = total
            let connectionGranted = 16_777_216 + (rawGranted[side] ?? 0)
            if total > connectionGranted {
                world.checker.fail("property 4: link \(link) \(side) spent \(total) raw bytes of \(connectionGranted)")
            }
        }
    }
}

/// The §10.3 properties, checked after every step and at the end of a run.
package final class PropertyChecker {
    private struct SideKey: Hashable {
        var link: Int
        var side: SimSide
    }

    private struct StreamKey: Hashable {
        var link: Int
        var stream: UInt32
    }

    private struct SideState {
        var open: Set<UInt32> = []
        var closed: Set<UInt32> = []
        var closedConnection = false
        var closure: ConnectionClosure?
        var liveness: [(time: SimTime, change: LivenessChange)] = []
    }

    let options: SimOptions
    package private(set) var violations: [String] = []
    private var sides: [SideKey: SideState] = [:]
    /// Per stream direction (writer side): the hashes of what was sent, and how many were delivered.
    private var sentChain: [SideKey: [StreamKey: [UInt64]]] = [:]
    private var deliveredCount: [SideKey: [StreamKey: Int]] = [:]
    package private(set) var closures: [(time: SimTime, link: Int, side: SimSide, closure: ConnectionClosure)] = []
    package private(set) var livenessEvents: [(time: SimTime, link: Int, side: SimSide, change: LivenessChange)] = []
    package private(set) var lastFrameAt: [Int: [SimSide: SimTime]] = [:]

    init(options: SimOptions) {
        self.options = options
    }

    package func fail(_ message: String) {
        if violations.count < 50 { violations.append(message) }
    }

    func discard(link: SimLink, side: SimSide) {
        sides[SideKey(link: link.id, side: side)]?.closedConnection = true
    }

    // MARK: Traces (properties 1, 3, 6)

    func trace(_ entries: [ConnectionTrace], link: SimLink, side: SimSide, world: SimWorld) {
        let key = SideKey(link: link.id, side: side)
        var state = sides[key] ?? SideState()
        defer { sides[key] = state }
        for entry in entries {
            if state.closedConnection {
                fail("property 3: link \(link.id) \(side) emitted \(entry) after .closed")
                continue
            }
            switch entry {
            case .localOpened(let id, _):
                state.open.insert(id.rawValue)
            case .sent(let id, _, let bytes):
                sentChain[key, default: [:]][StreamKey(link: link.id, stream: id.rawValue), default: []].append(
                    FNV64.of(bytes))
            case .event(let event):
                checkEvent(event, &state, link: link, side: side, world: world)
            }
        }
    }

    private func checkEvent(
        _ event: ConnectionEvent, _ state: inout SideState, link: SimLink, side: SimSide, world: SimWorld
    ) {
        func requireOpen(_ id: StreamID) {
            if state.closed.contains(id.rawValue) {
                fail("property 1: link \(link.id) \(side) event on stream \(id.rawValue) after its close: \(event)")
            } else if !state.open.contains(id.rawValue) {
                fail("property 1: link \(link.id) \(side) event on stream \(id.rawValue), never opened: \(event)")
            }
        }
        lastFrameAt[link.id, default: [:]][side] = world.now
        switch event {
        case .opened(let id, _, _):
            if state.open.contains(id.rawValue) || state.closed.contains(id.rawValue) {
                fail("property 1: link \(link.id) \(side) opened stream \(id.rawValue) twice")
            }
            state.open.insert(id.rawValue)
        case .message(let id, let payload), .data(let id, let payload):
            requireOpen(id)
            delivered(payload, on: id, link: link, to: side)
        case .remoteEnded(let id, _), .writable(let id):
            requireOpen(id)
        case .streamClosed(let id, _):
            requireOpen(id)
            state.open.remove(id.rawValue)
            state.closed.insert(id.rawValue)
        case .closed(let closure):
            state.closedConnection = true
            state.closure = closure
            closures.append((world.now, link.id, side, closure))
            if !options.hostile, case .closedLocally(let error) = closure, error.code == .flowControlError {
                fail("property 4: link \(link.id) \(side) closed FLOW_CONTROL_ERROR")
            }
            if !options.hostile, case .closedLocally(let error) = closure, error.code == .internal {
                fail("§9.6: link \(link.id) \(side) closed INTERNAL: \(error.debugDetail)")
            }
            if !options.hostile, case .closedLocally(let error) = closure, error.code == .protocolError {
                fail("link \(link.id) \(side) closed PROTOCOL_ERROR: \(error.debugDetail)")
            }
            if options.liveness == .quiet, case .closedLocally(let error) = closure,
                error.code == .livenessExpired || error.code == .helloTimeout
            {
                fail("property 7: link \(link.id) \(side) closed \(error.code)")
            }
        case .liveness(let change):
            livenessEvents.append((world.now, link.id, side, change))
            if options.liveness == .quiet {
                fail("property 7: link \(link.id) \(side) liveness verdict \(change)")
            }
        case .helloReceived, .remoteAdvertsChanged, .peerStateChanged, .policyChanged, .updateAvailable,
            .diagnostic:
            break
        }
    }

    private func delivered(_ payload: Data, on id: StreamID, link: SimLink, to side: SimSide) {
        let writer = SideKey(link: link.id, side: side == .host ? .peer : .host)
        let stream = StreamKey(link: link.id, stream: id.rawValue)
        let index = deliveredCount[writer]?[stream] ?? 0
        deliveredCount[writer, default: [:]][stream] = index + 1
        guard let chain = sentChain[writer]?[stream], index < chain.count else {
            if !options.hostile {
                fail("property 6: link \(link.id) stream \(id.rawValue) delivered more than was sent")
            }
            return
        }
        if chain[index] != FNV64.of(payload), !options.hostile {
            fail("property 6: link \(link.id) stream \(id.rawValue) item \(index) differs from what was sent")
        }
    }

    // MARK: Memory (property 5)

    func footprint(_ link: SimLink, _ side: SimSide, world: SimWorld) {
        guard let footprint = link.footprint(side) else { return }
        let where_ = "property 5: link \(link.id) \(side)"
        if footprint.heldRawBytes > 16_777_216 { fail("\(where_) holds \(footprint.heldRawBytes) raw bytes") }
        if footprint.decoderBufferedBytes > 10 + 1_048_576 + 65_536 + 1_048_576 {
            fail("\(where_) decoder holds \(footprint.decoderBufferedBytes)")
        }
        if footprint.queuedRawBytes > 2_097_152 { fail("\(where_) queues \(footprint.queuedRawBytes) raw bytes") }
        if footprint.maxQueuedMessagesPerStream > 1 {
            fail("\(where_) queues \(footprint.maxQueuedMessagesPerStream) messages on one stream")
        }
        if footprint.controlFrames > 2 * 128 + 8 { fail("\(where_) holds \(footprint.controlFrames) control frames") }
        if footprint.streamRecords > 3 * 64 + 64 { fail("\(where_) holds \(footprint.streamRecords) stream records") }
        if footprint.pendingEvents > 0 { fail("\(where_) left \(footprint.pendingEvents) events undrained") }
        let ring = world.peers[link.peerIndex].ring
        if ring.count > LogRing.capacity { fail("\(where_) ring holds \(ring.count)") }
    }

    // MARK: Endpoint events

    func hostEvent(_ event: HostEvent, link: SimLink, world: SimWorld) {
        world.transcript.add("h\(link.id)\(event)")
    }

    func peerEvent(_ event: PeerEvent, link: SimLink, world: SimWorld) {
        world.transcript.add("p\(link.id)\(event)")
    }

    // MARK: End of run

    func endOfRun(_ world: SimWorld) {
        for link in world.links {
            for side in [SimSide.host, .peer] {
                let state = sides[SideKey(link: link.id, side: side)] ?? SideState()
                let established = link.state(side) == .established || link.state(side) == .handshaking
                if !state.open.isEmpty, !established, !link.shutDown.contains(side) || !state.closedConnection {
                    if !(state.closedConnection) {
                        fail("property 1: link \(link.id) \(side) left streams \(state.open.sorted()) open")
                    }
                }
                if link.shutDown.contains(side), !state.closedConnection, link.state(side) != nil {
                    fail("property 3: link \(link.id) \(side) ended without .closed")
                }
            }
            checkConservation(link, world)
        }
        checkRouting(world)
        checkIdentity(world)
    }

    /// Property 4 at quiescence: §3.4's conservation equation, each direction.
    private func checkConservation(_ link: SimLink, _ world: SimWorld) {
        guard link.toHost.isEmpty, link.toPeer.isEmpty, !link.toHost.writePending, !link.toPeer.writePending,
            link.state(.host) == .established, link.state(.peer) == .established,
            let host = link.footprint(.host), let peer = link.footprint(.peer)
        else { return }
        for (sender, receiver, name) in [(host, peer, "host→peer"), (peer, host, "peer→host")] {
            let total =
                sender.connectionSendCredit + sender.queuedRawBytes + receiver.heldRawBytes
                + receiver.unreturnedConnectionCredit
            if total != 16_777_216 {
                fail(
                    "property 4: link \(link.id) \(name) conserves \(total): credit \(sender.connectionSendCredit) queued \(sender.queuedRawBytes) held \(receiver.heldRawBytes) unreturned \(receiver.unreturnedConnectionCredit)"
                )
            }
        }
    }

    /// Property 8: §6.4's order, no second ask, ACPI only after every refusal.
    private func checkRouting(_ world: SimWorld) {
        var asked: [PeerHandle] = []
        var concluded = false
        for (_, output) in world.hub.routingOutputs {
            switch output {
            case .ask(let peer, _):
                if concluded { asked = [] }
                concluded = false
                if asked.contains(peer) { fail("property 8: peer \(peer.rawValue) asked twice in one routing") }
                asked.append(peer)
            case .acpi(_, let refusals):
                if refusals.count != asked.count {
                    fail("property 8: ACPI after \(refusals.count) of \(asked.count) refusals")
                }
                concluded = true
            case .busy, .progress:
                break
            default:
                concluded = true
            }
        }
        for ask in world.hub.asks where ask.expectedFirst != ask.peer {
            fail("property 8: asked \(ask.peer.rawValue) where §6.4 orders \(ask.expectedFirst?.rawValue ?? 0) first")
        }
    }

    /// Property 9: no identity key displaced twice within 20 s.
    private func checkIdentity(_ world: SimWorld) {
        var last: [String: SimTime] = [:]
        for displacement in world.hub.displacements {
            if let previous = last[displacement.key], displacement.time - previous < .sec(20) {
                fail("property 9: \(displacement.key) displaced twice within 20 s")
            }
            last[displacement.key] = displacement.time
        }
    }
}
