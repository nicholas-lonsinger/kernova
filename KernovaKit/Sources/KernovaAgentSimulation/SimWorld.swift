#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaAgentCore
import KernovaWire

/// One connection: a host end, a peer end, and a pipe each way.
package final class SimLink {
    package let id: Int
    package let peerIndex: Int
    package let generation: ConnectionGeneration
    package let hubHandle: PeerHandle
    package var host: HostEndpoint?
    package var peer: PeerEndpoint?
    let toPeer: SimPipe
    let toHost: SimPipe
    var timerToken: [SimSide: Int] = [.host: 0, .peer: 0]
    var armed: [SimSide: CoreInstant?] = [.host: nil, .peer: nil]
    var shutDown: Set<SimSide> = []
    let observer: LinkObserver

    init(id: Int, peerIndex: Int, generation: ConnectionGeneration, options: SimOptions) {
        self.id = id
        self.peerIndex = peerIndex
        self.generation = generation
        hubHandle = PeerHandle(rawValue: UInt64(id))
        toPeer = SimPipe(options.hostToPeer)
        toHost = SimPipe(options.peerToHost)
        observer = LinkObserver(link: id)
    }

    func pipe(writtenBy side: SimSide) -> SimPipe { side == .host ? toPeer : toHost }
    func pipe(readBy side: SimSide) -> SimPipe { side == .host ? toHost : toPeer }

    package func footprint(_ side: SimSide) -> MemoryFootprint? {
        switch side {
        case .host: host?.connection.footprint
        case .peer: peer?.connection.footprint
        }
    }

    package func state(_ side: SimSide) -> ConnectionState? {
        switch side {
        case .host: host?.state
        case .peer: peer?.state
        }
    }
}

/// The deterministic world (§10.1): one host, N peers, links, faults, and the
/// property checker watching every step.
package final class SimWorld {
    package let seed: UInt64
    package let options: SimOptions
    package var rng: SplitMix64
    package private(set) var now: SimTime = 0
    private var agenda = Agenda()
    package private(set) var links: [SimLink] = []
    package private(set) var peers: [SimPeerProcess] = []
    package let hub: SimHub
    package let checker: PropertyChecker
    package var transcript = FNV64()
    /// Each process's clock starts a day in, so a clock stepping back never reaches the origin.
    package var hostOffset: Int64 = 86_400_000_000_000
    package var hostSuspendedUntil: SimTime?
    var hostDeferred: [(Bool, (SimWorld) -> Void)] = []
    package var events: [String] = []
    /// Scenario scratch: named values a script records for its expectations.
    package var marks: [String: Int] = [:]
    private var payloads: [Data: Data] = [:]

    /// The payload a manifest names, generated once per run.
    package func content(of manifest: UpdateManifestValue) -> Data {
        if let cached = payloads[manifest.payloadHash], cached.count == Int(manifest.payloadSize) { return cached }
        let content = SimHub.expectedContent(manifest)
        payloads[manifest.payloadHash] = content
        return content
    }
    package var recordsEvents = false

    package init(seed: UInt64, options: SimOptions) {
        self.seed = seed
        self.options = options
        rng = SplitMix64(seed: seed)
        hub = SimHub(options: options)
        checker = PropertyChecker(options: options)
        for fault in options.faults { schedule(fault) }
    }

    // MARK: Building a scenario

    @discardableResult
    package func addPeer(_ spec: PeerSpec) -> Int {
        let index = peers.count
        let process = SimPeerProcess(index: index, spec: spec)
        peers.append(process)
        at(spec.startAt) { world in world.startProcess(index) }
        return index
    }

    /// Runs `action` at world time `time`.
    package func at(_ time: SimTime, _ action: @escaping (SimWorld) -> Void) {
        agenda.push(max(time, now), action)
    }

    package func log(_ text: @autoclosure () -> String) {
        guard recordsEvents else { return }
        events.append("\(now / 1_000_000)ms \(text())")
    }

    /// Runs until the agenda is empty or `end`, then the end-of-run checks.
    package func run(until end: SimTime) {
        while let time = agenda.nextTime, time <= end, let entry = agenda.pop() {
            now = entry.time
            entry.action(self)
        }
        now = max(now, end)
        checker.endOfRun(self)
    }

    package var violations: [String] { checker.violations }

    // MARK: Clocks

    package func localNow(_ process: SimProcess) -> CoreInstant {
        let offset = process == .host ? hostOffset : peers[peerIndex(process)].clockOffset
        let value = Int64(now) + offset
        return CoreInstant(nanoseconds: UInt64(max(0, value)))
    }

    package func worldTime(_ instant: CoreInstant, _ process: SimProcess) -> SimTime {
        let offset = process == .host ? hostOffset : peers[peerIndex(process)].clockOffset
        let value = Int64(clamping: instant.nanoseconds) - offset
        return max(now, SimTime(max(0, value)))
    }

    private func peerIndex(_ process: SimProcess) -> Int {
        if case .peer(let index) = process { return index }
        return 0
    }

    package func process(of link: SimLink, _ side: SimSide) -> SimProcess {
        side == .host ? .host : .peer(link.peerIndex)
    }

    /// Whether the process processes nothing now (hung, frozen, asleep).
    package func isSuspended(_ process: SimProcess) -> Bool {
        switch process {
        case .host:
            return hostSuspendedUntil.map { now < $0 } ?? false
        case .peer(let index):
            if peers[index].isDead { return true }
            if let until = peers[index].suspendedUntil, now < until { return true }
            return hostSuspendedUntil.map { now < $0 } ?? false
        }
    }

    /// Runs `action` for `process` now, or when it resumes; timers first on resume.
    package func perform(_ process: SimProcess, isTimer: Bool = false, _ action: @escaping (SimWorld) -> Void) {
        guard isSuspended(process) else { return action(self) }
        switch process {
        case .host:
            hostDeferred.append((isTimer, action))
        case .peer(let index):
            guard !peers[index].isDead else { return }
            peers[index].deferred.append((isTimer, action))
        }
    }

    package func resume(_ process: SimProcess) {
        var deferred: [(Bool, (SimWorld) -> Void)]
        switch process {
        case .host:
            deferred = hostDeferred
            hostDeferred = []
        case .peer(let index):
            deferred = peers[index].deferred
            peers[index].deferred = []
        }
        let ordered = deferred.filter { $0.0 } + deferred.filter { !$0.0 }
        for (_, action) in ordered { perform(process, action) }
        for link in links {
            pumpRead(link, .host)
            pumpRead(link, .peer)
        }
    }

    // MARK: Processes and dialing

    package func startProcess(_ index: Int) {
        let process = peers[index]
        process.start(world: self)
        drainAgent(index)
    }

    package func drainAgent(_ index: Int) {
        let process = peers[index]
        while let effect = process.agent?.pollEffect() {
            switch effect {
            case .dial:
                at(now + .ms(1)) { world in world.perform(.peer(index)) { world in world.dial(index) } }
            case .stop(let reason):
                process.stopped = reason
                log("peer \(index) stops: \(reason)")
            }
        }
        if let deadline = process.agent?.nextDeadline {
            process.agentToken += 1
            let token = process.agentToken
            at(worldTime(deadline, .peer(index))) { world in
                world.perform(.peer(index), isTimer: true) { world in
                    guard process.agentToken == token else { return }
                    process.agent?.handleTimeout(now: world.localNow(.peer(index)))
                    world.drainAgent(index)
                }
            }
        }
    }

    package func dial(_ index: Int) {
        let process = peers[index]
        guard !process.isDead, var agent = process.agent else { return }
        let generation = agent.dialSucceeded(now: localNow(.peer(index)))
        process.agent = agent
        let link = SimLink(id: links.count, peerIndex: index, generation: generation, options: options)
        links.append(link)
        for fault in options.faults {
            if case .cut(let direction, let after) = fault {
                switch direction {
                case .hostToPeer(let id) where id == link.id: link.toPeer.cutAfter = after
                case .peerToHost(let id) where id == link.id: link.toHost.cutAfter = after
                default: break
                }
            }
        }
        process.link = link
        link.peer = process.makeEndpoint(generation: generation, world: self)
        link.host = hub.makeEndpoint(for: link, world: self)
        log("link \(link.id): peer \(index) generation \(generation.rawValue)")
        drain(link, .host)
        drain(link, .peer)
    }

    // MARK: Driving one end

    /// One driver turn's outputs: events and effects, the write, the timer, shutdown.
    package func drain(_ link: SimLink, _ side: SimSide) {
        let process = process(of: link, side)
        switch side {
        case .host:
            while let event = link.host?.pollEvent() {
                checker.hostEvent(event, link: link, world: self)
                hub.handle(event, link: link, world: self)
            }
            if let trace = link.host?.takeTrace() { checker.trace(trace, link: link, side: .host, world: self) }
        case .peer:
            let peer = peers[link.peerIndex]
            var progressed = true
            while progressed {
                progressed = false
                while let effect = link.peer?.pollEffect() {
                    progressed = true
                    peer.handle(effect, link: link, world: self)
                }
                while let event = link.peer?.pollEvent() {
                    progressed = true
                    checker.peerEvent(event, link: link, world: self)
                    peer.handle(event, link: link, world: self)
                }
            }
            if let trace = link.peer?.takeTrace() { checker.trace(trace, link: link, side: .peer, world: self) }
        }
        checker.footprint(link, side, world: self)
        tryWrite(link, side)
        rearm(link, side, process)
        if link.state(side) == .finished { shutDown(link, side) }
    }

    package func rearm(_ link: SimLink, _ side: SimSide, _ process: SimProcess) {
        let deadline: CoreInstant? =
            switch side {
            case .host: link.host?.nextDeadline
            case .peer: link.peer?.nextDeadline
            }
        guard deadline != link.armed[side] ?? nil else { return }
        link.armed[side] = deadline
        link.timerToken[side, default: 0] += 1
        guard let deadline else { return }
        let token = link.timerToken[side] ?? 0
        at(worldTime(deadline, process)) { world in
            world.perform(process, isTimer: true) { world in
                guard link.timerToken[side] == token else { return }
                link.armed[side] = nil
                let local = world.localNow(process)
                switch side {
                case .host: link.host?.handleTimeout(now: local)
                case .peer: link.peer?.handleTimeout(now: local)
                }
                world.drain(link, side)
            }
        }
    }

    package func tryWrite(_ link: SimLink, _ side: SimSide) {
        let pipe = link.pipe(writtenBy: side)
        guard !pipe.writePending, pipe.hasCapacity, !link.shutDown.contains(side) else { return }
        let transmit: Transmit? =
            switch side {
            case .host:
                link.host?.pollTransmit(maxBytes: WireConstants.maxRawDataPayload + WireConstants.headerByteCount)
            case .peer:
                link.peer?.pollTransmit(maxBytes: WireConstants.maxRawDataPayload + WireConstants.headerByteCount)
            }
        guard let transmit else { return }
        var bytes = Data(capacity: transmit.byteCount)
        for chunk in transmit.chunks { bytes.append(chunk) }
        transcript.add(UInt64(link.id) << 1 | (side == .host ? 0 : 1))
        transcript.add(now)
        transcript.add(UInt64(bytes.count))
        transcript.add(bytes.prefix(4096))
        link.observer.written(bytes, by: side, world: self)
        // A write after the far side shut down goes nowhere; this side ends when its
        // own reader reaches EOF, after reading whatever the far side sent last.
        let write = pipe.write(bytes, now: now)
        pipe.writePending = true
        let process = process(of: link, side)
        let isFinal = transmit.isFinal
        let cut = pipe.isCut
        at(write.completesAt) { world in
            pipe.writePending = false
            world.scheduleRead(link, side == .host ? .peer : .host)
            if cut || isFinal {
                if isFinal { pipe.writerClosed = true }
                world.perform(process) { world in world.endTransport(link, side) }
                return
            }
            world.perform(process) { world in world.drain(link, side) }
        }
        scheduleRead(link, side == .host ? .peer : .host)
    }

    package func scheduleRead(_ link: SimLink, _ reader: SimSide) {
        let pipe = link.pipe(readBy: reader)
        guard !pipe.readScheduled, !link.shutDown.contains(reader) else { return }
        var time: SimTime
        if let next = pipe.nextReadable {
            time = max(now, next)
        } else if pipe.readerShouldEnd {
            time = now
        } else {
            return
        }
        if let until = pipe.stalledUntil, until > time { time = until }
        pipe.readScheduled = true
        at(time) { world in
            pipe.readScheduled = false
            world.perform(world.process(of: link, reader)) { world in world.pumpRead(link, reader) }
        }
    }

    /// One reader turn: a read of seeded size, or the transport's end.
    package func pumpRead(_ link: SimLink, _ reader: SimSide) {
        let pipe = link.pipe(readBy: reader)
        guard !link.shutDown.contains(reader), !pipe.readScheduled else { return }
        if let until = pipe.stalledUntil, now < until {
            return scheduleRead(link, reader)
        }
        if let next = pipe.nextReadable, next <= now {
            let size = rng.int(in: 1...pipe.parameters.maxRead)
            let bytes = pipe.read(upTo: size, now: now)
            link.observer.delivered(bytes, to: reader, world: self)
            let local = localNow(process(of: link, reader))
            switch reader {
            case .host: link.host?.receive(bytes, now: local)
            case .peer: link.peer?.receive(bytes, now: local)
            }
            drain(link, reader)
            tryWrite(link, reader == .host ? .peer : .host)
            scheduleRead(link, reader)
        } else if pipe.readerShouldEnd {
            pipe.eofDelivered = true
            endTransport(link, reader)
        } else {
            scheduleRead(link, reader)
        }
    }

    /// The transport ended for `side`: its endpoint hears `transportEnded` once.
    package func endTransport(_ link: SimLink, _ side: SimSide) {
        guard !link.shutDown.contains(side) else { return }
        let local = localNow(process(of: link, side))
        switch side {
        case .host: link.host?.transportEnded(now: local)
        case .peer: link.peer?.transportEnded(now: local)
        }
        drain(link, side)
        shutDown(link, side)
    }

    /// The driver's `stream.shutdown()`: both directions end for this side.
    package func shutDown(_ link: SimLink, _ side: SimSide) {
        guard !link.shutDown.contains(side) else { return }
        if link.state(side) != .finished {
            let local = localNow(process(of: link, side))
            switch side {
            case .host: link.host?.transportEnded(now: local)
            case .peer: link.peer?.transportEnded(now: local)
            }
            drainEventsOnly(link, side)
        }
        link.shutDown.insert(side)
        link.timerToken[side, default: 0] += 1
        link.pipe(writtenBy: side).writerClosed = true
        link.pipe(readBy: side).readerClosed = true
        let other: SimSide = side == .host ? .peer : .host
        at(now) { world in world.scheduleRead(link, other) }
        if side == .peer {
            peers[link.peerIndex].linkEnded(link, world: self)
        }
    }

    private func drainEventsOnly(_ link: SimLink, _ side: SimSide) {
        switch side {
        case .host:
            while let event = link.host?.pollEvent() {
                checker.hostEvent(event, link: link, world: self)
                hub.handle(event, link: link, world: self)
            }
            if let trace = link.host?.takeTrace() { checker.trace(trace, link: link, side: .host, world: self) }
        case .peer:
            while let effect = link.peer?.pollEffect() {
                peers[link.peerIndex].handle(effect, link: link, world: self)
            }
            while let event = link.peer?.pollEvent() {
                checker.peerEvent(event, link: link, world: self)
                peers[link.peerIndex].handle(event, link: link, world: self)
            }
            if let trace = link.peer?.takeTrace() { checker.trace(trace, link: link, side: .peer, world: self) }
        }
    }

    // MARK: Inputs from outside the endpoints

    /// Feeds a peer input to the peer's current endpoint after `delay`, if its generation still runs.
    package func peerInput(_ index: Int, _ input: PeerInput, after delay: SimTime, link: SimLink) {
        at(now + delay) { world in
            world.perform(.peer(index)) { world in
                guard world.peers[index].link === link, !link.shutDown.contains(.peer) else { return }
                link.peer?.handle(input, now: world.localNow(.peer(index)))
                world.drain(link, .peer)
            }
        }
    }

    /// Sends a hub command to a host endpoint (async, §9.7).
    package func hostCommand(_ command: HostCommand, link: SimLink, after delay: SimTime = 0) {
        at(now + delay) { world in
            world.perform(.host) { world in
                guard !link.shutDown.contains(.host) else { return }
                link.host?.handle(command, now: world.localNow(.host))
                world.drain(link, .host)
            }
        }
    }

    // MARK: Faults

    private func schedule(_ fault: Fault) {
        switch fault {
        case .cut:
            break
        case .peerDeath(let index, let time):
            at(time) { world in world.killPeer(index) }
        case .peerHang(let index, let time, let duration):
            at(time) { world in
                world.peers[index].suspendedUntil = time + duration
                world.log("peer \(index) hangs")
            }
            at(time + duration) { world in world.resume(.peer(index)) }
        case .readerStall(let side, let linkID, let time, let duration):
            at(time) { world in
                guard linkID < world.links.count else { return }
                world.links[linkID].pipe(readBy: side).stalledUntil = time + duration
            }
            at(time + duration) { world in
                guard linkID < world.links.count else { return }
                world.scheduleRead(world.links[linkID], side)
            }
        case .consumerStall(let index, let time, let duration):
            at(time) { world in world.peers[index].consumerStalled = true }
            at(time + duration) { world in world.peers[index].releaseConsumer(world: world) }
        case .vmFreeze(let time, let duration, let jumps):
            at(time) { world in
                for index in world.peers.indices {
                    world.peers[index].suspendedUntil = time + duration
                }
                for link in world.links where !link.shutDown.contains(.host) {
                    world.hostCommand(.setPeerFrozen(true), link: link)
                }
                world.hub.peersFrozen = true
            }
            at(time + duration) { world in
                world.hub.peersFrozen = false
                if jumps {
                    for peer in world.peers { peer.clockOffset += Int64(duration) }
                }
                for link in world.links where !link.shutDown.contains(.host) {
                    world.hostCommand(.setPeerFrozen(false), link: link)
                }
                for index in world.peers.indices { world.resume(.peer(index)) }
            }
        case .hostSleep(let time, let duration):
            at(time) { world in
                // The VMs auto-pause before the host sleeps.
                for link in world.links where !link.shutDown.contains(.host) {
                    link.host?.handle(.setPeerFrozen(true), now: world.localNow(.host))
                    world.drain(link, .host)
                }
                world.hub.peersFrozen = true
                world.hostSuspendedUntil = time + duration
                world.log("host sleeps")
            }
            at(time + duration) { world in
                world.hostOffset += Int64(duration)
                for peer in world.peers { peer.clockOffset += Int64(duration) }
                world.hostSuspendedUntil = nil
                world.hub.peersFrozen = false
                world.resume(.host)
                for link in world.links where !link.shutDown.contains(.host) {
                    world.hostCommand(.setPeerFrozen(false), link: link)
                }
                for index in world.peers.indices { world.resume(.peer(index)) }
            }
        case .clockStep(let process, let time, let step):
            at(time) { world in
                switch process {
                case .host: world.hostOffset += step
                case .peer(let index): world.peers[index].clockOffset += step
                }
            }
        }
    }

    package func killPeer(_ index: Int) {
        let process = peers[index]
        process.isDead = true
        process.deferred = []
        log("peer \(index) dies")
        if let link = process.link {
            link.shutDown.insert(.peer)
            link.timerToken[.peer, default: 0] += 1
            link.toHost.writerClosed = true
            link.toPeer.readerClosed = true
            checker.discard(link: link, side: .peer)
            link.peer = nil
            scheduleRead(link, .host)
        }
        process.link = nil
    }

    /// Restarts a peer's process (a new instance id), as an agent restart does.
    package func restartPeer(_ index: Int, hung: Bool = false) {
        if !peers[index].isDead { killPeer(index) }
        peers[index].isDead = false
        peers[index].stopped = nil
        peers[index].suspendedUntil = hung ? .max : nil
        startProcess(index)
    }
}
