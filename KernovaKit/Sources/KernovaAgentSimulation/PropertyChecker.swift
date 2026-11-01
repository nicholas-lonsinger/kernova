#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaAgentCore
import KernovaWire

/// One frame as a side wrote it.
package struct WireRecord: Sendable {
    package var time: SimTime
    package var side: SimSide
    package var stream: UInt32
    package var type: FrameType
    package var flags: FrameFlags
    package var length: Int
    /// The payload; empty for raw DATA, whose length alone is kept.
    package var payload: Data
}

/// Decodes one link's bytes as written and as delivered, for the wire-level
/// properties: no frame before its OPEN and OPENs in increasing id order (2),
/// and credit (4). Keeps every written frame for a scenario's expectations.
final class LinkObserver {
    let link: Int
    private var written: [SimSide: FrameDecoder] = [.host: FrameDecoder(), .peer: FrameDecoder()]
    private var delivered: [SimSide: FrameDecoder] = [.host: FrameDecoder(), .peer: FrameDecoder()]
    private(set) var frames: [WireRecord] = []
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
            let isRaw = frame.type == .data && !frame.flags.contains(.message)
            frames.append(
                WireRecord(
                    time: world.now, side: side, stream: frame.streamID.rawValue, type: frame.type, flags: frame.flags,
                    length: frame.payload.count, payload: isRaw ? Data() : frame.payload))
            check(written: frame, by: side, world: world)
        }
    }

    /// Takes the bytes one read delivers to `side`; returns how many frames on
    /// streams other than 0 the read completed.
    func delivered(_ bytes: Data, to side: SimSide, world: SimWorld) -> Int {
        delivered[side]?.append(bytes)
        var streamFrames = 0
        while let frame = try? delivered[side]?.nextFrame() {
            if frame.streamID != .session { streamFrames += 1 }
            guard frame.type == .window else { continue }
            let increment = frame.payload.reduce(0) { $0 << 8 | Int($1) }
            // A WINDOW delivered to `side` grants `side` credit.
            if frame.streamID == .session {
                rawGranted[side, default: 0] += increment
            } else {
                granted[side, default: [:]][frame.streamID.rawValue, default: 0] += increment
            }
        }
        return streamFrames
    }

    private func check(written frame: Frame, by side: SimSide, world: SimWorld) {
        let id = frame.streamID.rawValue
        guard id != 0 else { return }
        let openerIsHost = id % 2 == 0
        let writerIsOpener = (side == .host) == openerIsHost
        if frame.type == .open {
            if let highest = opened[side]?.max(), id <= highest, !world.options.hostile {
                world.checker.fail("property 2: link \(link) \(side) sent OPEN \(id) after OPEN \(highest)")
            }
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

/// Properties 1 and 3 over one endpoint's trace: a stream is opened once, has
/// events only while open, and closes once; every stream has closed by the
/// connection's `.closed`, and nothing follows it. The one checker every
/// harness runs — the world, a hostile run and a transcript replay.
package struct TraceChecker: Sendable {
    package private(set) var open: Set<UInt32> = []
    private var closed: Set<UInt32> = []
    package private(set) var connectionClosed = false
    /// The side ended without a `.closed` to come: its process died.
    private var discarded = false

    package init() {}

    /// Checks `entry`; returns what it breaks.
    package mutating func check(_ entry: ConnectionTrace) -> [String] {
        if connectionClosed || discarded { return ["property 3: \(entry) after .closed"] }
        switch entry {
        case .localOpened(let id, _):
            return opened(id, entry)
        case .sent:
            return []
        case .event(let event):
            switch event {
            case .opened(let id, _, _):
                return opened(id, entry)
            case .message(let id, _), .data(let id, _), .remoteEnded(let id, _), .writable(let id):
                return requireOpen(id, entry)
            case .streamClosed(let id, _):
                let violations = requireOpen(id, entry)
                open.remove(id.rawValue)
                closed.insert(id.rawValue)
                return violations
            case .closed:
                connectionClosed = true
                return open.isEmpty ? [] : ["property 1: .closed with streams \(open.sorted()) open"]
            case .helloReceived, .remoteAdvertsChanged, .peerStateChanged, .policyChanged, .updateAvailable,
                .liveness, .diagnostic, .slotFreed:
                return []
            }
        }
    }

    /// The side's process died: no `.closed` follows, and none is owed.
    package mutating func discard() {
        discarded = true
    }

    private mutating func opened(_ id: StreamID, _ entry: ConnectionTrace) -> [String] {
        let twice = open.contains(id.rawValue) || closed.contains(id.rawValue)
        open.insert(id.rawValue)
        return twice ? ["property 1: stream \(id.rawValue) opened twice: \(entry)"] : []
    }

    private func requireOpen(_ id: StreamID, _ entry: ConnectionTrace) -> [String] {
        if closed.contains(id.rawValue) { return ["property 1: \(entry) on stream \(id.rawValue) after its close"] }
        if !open.contains(id.rawValue) { return ["property 1: \(entry) on stream \(id.rawValue), never opened"] }
        return []
    }

    /// Every violation in `trace`.
    package static func violations(_ trace: [ConnectionTrace]) -> [String] {
        var checker = TraceChecker()
        return trace.flatMap { checker.check($0) }
    }
}

/// The properties a simulated run must hold, checked after every step and at
/// the end of the run:
///
/// 1. Every stream opens once, has events only while open, and has closed by its connection's `.closed`.
/// 2. No frame precedes its stream's OPEN, and each side's OPENs leave in increasing id order.
/// 3. Nothing follows a connection's `.closed`, and every connection that ended emitted one.
/// 4. No side spends credit it was not granted, per stream or per connection; at quiescence each
///    direction conserves the connection window; no conforming run closes FLOW_CONTROL_ERROR.
/// 5. Memory stays bounded: held and queued raw bytes, the decoder, control frames, stream
///    records, the log ring, and the events one receive turn leaves for the driver.
/// 6. A stream delivers exactly what its far side sent, in order.
/// 7. A `.quiet` run has no liveness verdict, no LIVENESS_EXPIRED close and no HELLO_TIMEOUT close,
///    whatever freeze, sleep or clock step it injects.
/// 8. Power routing asks candidates in the hub's order, asks no peer twice and none after one
///    accepted, and falls back to ACPI only after every asked peer refused.
/// 9. No identity key is displaced twice within 20 s, and the hub holds one connection per key.
/// 10. A seed replays to the same transcript (checked by the scenario runner).
///
/// Beyond these, a conforming run never closes INTERNAL or PROTOCOL_ERROR, and
/// every injected fault takes effect.
package final class PropertyChecker {
    private struct SideKey: Hashable {
        var link: Int
        var side: SimSide
    }

    private struct StreamKey: Hashable {
        var link: Int
        var stream: UInt32
    }

    let options: SimOptions
    package private(set) var violations: [String] = []
    private var traces: [SideKey: TraceChecker] = [:]
    /// Per stream direction (writer side): the hashes of what was sent, and how many were delivered.
    private var sentChain: [SideKey: [StreamKey: [UInt64]]] = [:]
    private var deliveredCount: [SideKey: [StreamKey: Int]] = [:]
    package private(set) var closures: [(time: SimTime, link: Int, side: SimSide, closure: ConnectionClosure)] = []
    package private(set) var livenessEvents: [(time: SimTime, link: Int, side: SimSide, change: LivenessChange)] = []
    /// When each side of each link read the far side's Hello.
    package private(set) var helloReceived: [(time: SimTime, link: Int, side: SimSide)] = []

    init(options: SimOptions) {
        self.options = options
    }

    package func fail(_ message: String) {
        if violations.count < 50 { violations.append(message) }
    }

    func discard(link: SimLink, side: SimSide) {
        traces[SideKey(link: link.id, side: side), default: TraceChecker()].discard()
    }

    // MARK: Traces (properties 1, 3, 6)

    func trace(_ entries: [ConnectionTrace], link: SimLink, side: SimSide, world: SimWorld) {
        let key = SideKey(link: link.id, side: side)
        var checker = traces[key] ?? TraceChecker()
        defer { traces[key] = checker }
        for entry in entries {
            for violation in checker.check(entry) { fail("link \(link.id) \(side): \(violation)") }
            switch entry {
            case .sent(let id, _, let bytes):
                sentChain[key, default: [:]][StreamKey(link: link.id, stream: id.rawValue), default: []].append(
                    FNV64.of(bytes))
            case .event(let event):
                checkEvent(event, link: link, side: side, world: world)
            case .localOpened:
                break
            }
        }
    }

    private func checkEvent(_ event: ConnectionEvent, link: SimLink, side: SimSide, world: SimWorld) {
        switch event {
        case .message(let id, let payload), .data(let id, let payload):
            delivered(payload, on: id, link: link, to: side)
        case .helloReceived:
            helloReceived.append((world.now, link.id, side))
        case .closed(let closure):
            closures.append((world.now, link.id, side, closure))
            guard case .closedLocally(let error) = closure else { return }
            if !options.hostile, error.code == .flowControlError {
                fail("property 4: link \(link.id) \(side) closed FLOW_CONTROL_ERROR")
            }
            if !options.hostile, error.code == .internal {
                fail("link \(link.id) \(side) closed INTERNAL: \(error.debugDetail)")
            }
            if !options.hostile, error.code == .protocolError {
                fail("link \(link.id) \(side) closed PROTOCOL_ERROR: \(error.debugDetail)")
            }
            if options.liveness == .quiet, error.code == .livenessExpired || error.code == .helloTimeout {
                fail("property 7: link \(link.id) \(side) closed \(error.code)")
            }
        case .liveness(let change):
            livenessEvents.append((world.now, link.id, side, change))
            if options.liveness == .quiet {
                fail("property 7: link \(link.id) \(side) liveness verdict \(change)")
            }
        case .opened, .remoteEnded, .writable, .streamClosed, .remoteAdvertsChanged, .peerStateChanged,
            .policyChanged, .updateAvailable, .diagnostic, .slotFreed:
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
        // One frame still arriving, whole header and largest payload, plus one read's bytes.
        let decoderBound =
            WireConstants.headerByteCount + WireConstants.maxRawDataPayload + link.pipe(readBy: side).parameters.maxRead
        if footprint.decoderBufferedBytes > decoderBound {
            fail("\(where_) decoder holds \(footprint.decoderBufferedBytes) of \(decoderBound)")
        }
        if footprint.queuedRawBytes > 2_097_152 { fail("\(where_) queues \(footprint.queuedRawBytes) raw bytes") }
        if footprint.maxQueuedMessagesPerStream > 1 {
            fail("\(where_) queues \(footprint.maxQueuedMessagesPerStream) messages on one stream")
        }
        if footprint.controlFrames > 2 * 128 + 8 { fail("\(where_) holds \(footprint.controlFrames) control frames") }
        if footprint.streamRecords > 3 * 64 + 64 { fail("\(where_) holds \(footprint.streamRecords) stream records") }
        let ring = world.peers[link.peerIndex].ring
        if ring.count > LogRing.capacity { fail("\(where_) ring holds \(ring.count)") }
    }

    /// Property 5 for the driver's queue, sampled after one `receive` and before
    /// its drain: the snapshots coalesce to one event per slot, so what the read
    /// adds is bounded by the slots, the session events that never repeat (the
    /// Hello, a liveness change, `.closed`), and at most two events for each
    /// stream frame read and each stream the turn may close.
    func pendingEvents(
        _ link: SimLink, _ side: SimSide, before: Int, streamFrames: Int, streams: Int, world: SimWorld
    ) {
        guard !options.hostile else { return }
        let pending = link.pendingEventCount(side)
        maxPendingEvents = max(maxPendingEvents, pending)
        let bound = before + Self.coalescingSlots + 3 + 2 * (streamFrames + streams)
        if pending > bound {
            fail(
                "property 5: link \(link.id) \(side) left \(pending) events after one read of \(streamFrames) stream frames (bound \(bound))"
            )
        }
    }

    /// The most events any receive turn left for its drain.
    package private(set) var maxPendingEvents = 0

    /// The endpoint event kinds that coalesce: peer state and features on the
    /// host, policy and the update offer on the peer.
    static let coalescingSlots = 2

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
                let closed = traces[SideKey(link: link.id, side: side)]?.connectionClosed ?? false
                if link.shutDown.contains(side), !closed, link.state(side) != nil {
                    fail("property 3: link \(link.id) \(side) ended without .closed")
                }
            }
            checkConservation(link, world)
        }
        for violation in Self.routingViolations(world.hub.routingLog) { fail(violation) }
        for ask in world.hub.asks where ask.expectedFirst != ask.peer {
            fail(
                "property 8: asked \(ask.peer.rawValue) where the order puts \(ask.expectedFirst?.rawValue ?? 0) first")
        }
        checkIdentity(world)
        for (index, fault) in world.faults.enumerated() where fault.tookEffectAt == nil {
            fail("fault \(index) never took effect: \(fault.fault) from \(fault.start / 1_000_000) ms")
        }
    }

    /// Property 4 at quiescence, each direction: the sender's credit, what it has
    /// queued, what the receiver holds and the credit it has not yet returned sum
    /// to the 16 MiB connection window.
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

    /// Property 8 over the hub's routing log, in the order the hub saw it: no
    /// peer asked twice in one routing, no ask once a peer accepted, ACPI only
    /// after every asked peer refused.
    package static func routingViolations(_ log: [RoutingLogEntry]) -> [String] {
        var violations: [String] = []
        var asked: [PeerHandle] = []
        var accepted = false
        var concluded = false
        for entry in log {
            switch entry {
            case .result(_, .accepted):
                accepted = true
            case .result:
                break
            case .output(let output):
                switch output {
                case .ask(let peer, _, _):
                    if concluded {
                        asked = []
                        accepted = false
                    }
                    concluded = false
                    if accepted { violations.append("property 8: peer \(peer.rawValue) asked after an ACCEPTED") }
                    if asked.contains(peer) {
                        violations.append("property 8: peer \(peer.rawValue) asked twice in one routing")
                    }
                    asked.append(peer)
                case .unserved(let refusals):
                    if refusals.count != asked.count {
                        violations.append("property 8: ACPI after \(refusals.count) of \(asked.count) refusals")
                    }
                    concluded = true
                case .busy, .progress:
                    break
                default:
                    concluded = true
                }
            }
        }
        return violations
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
