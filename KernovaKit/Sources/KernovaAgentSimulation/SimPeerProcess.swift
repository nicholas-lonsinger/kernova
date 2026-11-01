#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaAgentCore
import KernovaWire

/// One agent process: its dial schedule, its current endpoint, its log ring,
/// and fake adapters whose answers are scripted.
package final class SimPeerProcess {
    package let index: Int
    package var spec: PeerSpec
    package var agent: PeerAgent?
    package var link: SimLink?
    package var ring = LogRing()
    /// The process's power ledger: process-scoped, as the runtime keeps it, so an
    /// accepted request outlives the connection it arrived on.
    package private(set) var powerLedger = PowerLedger()
    package var clockOffset: Int64 = 86_400_000_000_000
    package var suspendedUntil: SimTime?
    var deferred: [(Bool, (SimWorld) -> Void)] = []
    package var isDead = false
    package var stopped: StopReason?
    var agentToken = 0
    package private(set) var instanceID = Data()
    package private(set) var starts = 0
    // Power adapter
    package private(set) var performed: [(time: SimTime, id: PowerRequestID, action: PowerAction)] = []
    private var cancelled: Set<PowerRequestID> = []
    // Installer
    package var currentHash: Data
    package var rejectedHash: Data?
    package private(set) var installed: [Data] = []
    package private(set) var pullsStarted: [Data] = []
    /// The consumer-stall fault holding the installer's consumption, while one does.
    var consumerStall: Int?
    private var heldConsumption: [(UpdatePullID, Int)] = []
    private var received: [UpdatePullID: (bytes: Data, count: Int)] = [:]
    /// Log records appended, and those still to deliver.
    package private(set) var logsAppended = 0
    package private(set) var logsEvictedByMode = 0

    init(index: Int, spec: PeerSpec) {
        self.index = index
        self.spec = spec
        currentHash = spec.claim.payloadHash
        rejectedHash = spec.installer?.rejectedHash
    }

    func start(world: SimWorld) {
        starts += 1
        instanceID = spec.instanceID ?? world.rng.bytes(16)
        ring = LogRing()
        powerLedger = PowerLedger()
        agent = PeerAgent(now: world.localNow(.peer(index)))
    }

    var updateAvailability: Availability<UpdateOffer> {
        guard let installer = spec.installer else { return .absent(.notImplemented, debugDetail: "") }
        return .available(UpdateOffer(formats: installer.formats, rejectedHash: rejectedHash))
    }

    func makeEndpoint(generation: ConnectionGeneration, world: SimWorld) -> PeerEndpoint {
        var claim = spec.claim
        claim.instanceID = instanceID
        claim.payloadHash = currentHash
        var configuration = PeerConfiguration(
            claim: claim, state: spec.state, power: spec.power.offer,
            logs: spec.logs ? .available(NoParams()) : .absent(.notImplemented, debugDetail: ""),
            update: updateAvailability)
        configuration.powerLedger = powerLedger
        configuration.receiverPolicy = world.options.receiverPolicy
        let version = spec.protocolVersion
        let testKinds = world.options.testKinds
        let hostile = world.options.hostile
        configuration.tweak = { connection in
            connection.recordsTrace = true
            connection.assertsOnMisuse = !hostile
            connection.protocolVersion = version
            if testKinds { connection.addTestKinds() }
        }
        var endpoint = PeerEndpoint(configuration, generation: generation, now: world.localNow(.peer(index)))
        endpoint.testSink.bytesPerStream = world.options.testBulkBytes
        return endpoint
    }

    func linkEnded(_ link: SimLink, world: SimWorld) {
        guard self.link === link else { return }
        self.link = nil
        drainEnded(link, world: world)
    }

    private func drainEnded(_ link: SimLink, world: SimWorld) {
        world.drainAgent(index)
    }

    // MARK: Effects and events

    func handle(_ effect: PeerEffect, link: SimLink, world: SimWorld) {
        switch effect {
        case .power(let power):
            handlePower(power, link: link, world: world)
        case .logs(.mode(let mode)):
            ring.setMode(mode)
        case .logs(.ready):
            if let batch = ring.takeBatch() {
                link.peer?.handle(.logs(.batch(batch)), now: world.localNow(.peer(index)))
            }
        case .update(let update):
            handleUpdate(update, link: link, world: world)
        }
    }

    func handle(_ event: PeerEvent, link: SimLink, world: SimWorld) {
        switch event {
        case .policyReceived:
            agent?.policyReceived(link.generation, now: world.localNow(.peer(index)))
            world.drainAgent(index)
            confirmSwitch()
        case .closed(let closure):
            agent?.connectionEnded(link.generation, closure, now: world.localNow(.peer(index)))
            world.drainAgent(index)
        case .established, .hostLiveness, .updateAvailable, .diagnostic:
            break
        }
    }

    // MARK: Logs

    /// The logger emits `count` records; the sink posts `.recordsAvailable` after
    /// an append into an empty ring.
    package func emitLogs(_ count: Int, world: SimWorld) {
        var post = false
        for number in 0..<count {
            let record = LogRecordValue(
                timestampMilliseconds: Int64(world.now / 1_000_000), level: .notice, subsystem: "app.kernova.agent",
                category: "sim", segments: [LogSegmentValue(text: "record \(logsAppended + number)")])
            if ring.mode == .discarding { logsEvictedByMode += 1 }
            if ring.append(record) { post = true }
        }
        logsAppended += count
        guard post, let link else { return }
        world.perform(.peer(index)) { world in
            guard self.link === link else { return }
            link.peer?.handle(.logs(.recordsAvailable), now: world.localNow(.peer(self.index)))
            world.drain(link, .peer)
        }
    }

    // MARK: Power

    private func handlePower(_ effect: PowerEffect, link: SimLink, world: SimWorld) {
        powerLedger.record(effect)
        let starts = self.starts
        switch effect {
        case .perform(let id, let action, _):
            performed.append((world.now, id, action))
            var delay: SimTime = 0
            for step in spec.power.steps {
                delay += world.rng.time(in: step.after)
                let input = Self.input(step.report, id)
                world.at(world.now + delay) { world in
                    guard !self.cancelled.contains(id) else { return }
                    self.report(input, process: starts, world: world)
                }
            }
        case .cancel(let id):
            switch spec.power.onCancel {
            case .confirm(let after):
                cancelled.insert(id)
                world.at(world.now + world.rng.time(in: after)) { world in
                    self.report(.cancelled(id), process: starts, world: world)
                }
            case .silent(let after):
                cancelled.insert(id)
                world.at(world.now + world.rng.time(in: after)) { world in
                    self.report(.unconfirmed(id), process: starts, world: world)
                }
            case .acceptFirst:
                break
            }
        }
    }

    /// The adapter's report, as the runtime's reporter takes it: into the
    /// process's ledger, then to whichever endpoint is current. A report from an
    /// earlier run of the process went with that process.
    private func report(_ input: PowerInput, process: Int, world: SimWorld) {
        guard process == starts, !isDead else { return }
        powerLedger.record(input)
        guard let link else { return }
        world.peerInput(index, .power(input), after: 0, link: link)
    }

    static func input(_ report: PowerReport, _ id: PowerRequestID) -> PowerInput {
        switch report {
        case .accepted: .accepted(id)
        case .refused(let code): .refused(id, WireError(code))
        case .askingApps: .askingApps(id)
        case .waitingOnApps(let apps): .waitingOnApps(id, apps)
        case .handedOff: .handedOff(id)
        case .blocked(let apps): .blocked(id, apps)
        case .cancelledInGuest: .cancelledInGuest(id)
        case .failed(let code): .failed(id, WireError(code))
        }
    }

    // MARK: Installer

    private func handleUpdate(_ effect: UpdateEffect, link: SimLink, world: SimWorld) {
        guard let installer = spec.installer else { return }
        switch effect {
        case .payload(let id, let bytes):
            var entry = received[id] ?? (Data(), 0)
            if entry.count == 0 { pullsStarted.append(Data()) }
            entry.bytes.append(bytes)
            entry.count += bytes.count
            received[id] = entry
            if let fail = installer.failAfter, entry.count >= fail.bytes {
                world.peerInput(
                    index, .update(.failed(id, WireError(fail.code))),
                    after: world.rng.time(in: installer.consumeDelay), link: link)
                return
            }
            if let stall = consumerStall {
                heldConsumption.append((id, bytes.count))
                world.faultTookEffect(stall)
            } else {
                world.peerInput(
                    index, .update(.consumed(id, bytes.count)), after: world.rng.time(in: installer.consumeDelay),
                    link: link)
            }
        case .complete(let id, let manifest):
            let bytes = received[id]?.bytes ?? Data()
            received[id] = nil
            let matches = bytes == world.content(of: manifest)
            let installDelay = world.rng.time(in: installer.installDelay)
            if matches {
                installed.append(manifest.payloadHash)
                world.peerInput(index, .update(.installed(id)), after: installDelay, link: link)
                world.at(world.now + installDelay + .ms(10)) { world in
                    self.switchTo(manifest.payloadHash, world: world)
                }
            } else {
                rejectedHash = manifest.payloadHash
                world.peerInput(
                    index, .update(.rejected(id, WireError(.updateHashMismatch))), after: installDelay,
                    link: link)
                pushAvailability(link: link, world: world)
            }
        case .abort(let id):
            received[id] = nil
        case .recordRejected(let hash):
            rejectedHash = hash
            pushAvailability(link: link, world: world)
        case .clearRejected:
            rejectedHash = nil
            pushAvailability(link: link, world: world)
        }
    }

    private func pushAvailability(link: SimLink, world: SimWorld) {
        world.peerInput(index, .update(.availability(updateAvailability)), after: .us(10), link: link)
    }

    func releaseConsumer(world: SimWorld) {
        consumerStall = nil
        guard let link else { return }
        for (id, count) in heldConsumption {
            world.peerInput(index, .update(.consumed(id, count)), after: 0, link: link)
        }
        heldConsumption = []
    }

    // MARK: Switching slots

    private var previousHash: Data?
    private var switchUnconfirmed = false

    /// The installer switched `current` and relaunches the new version.
    private func switchTo(_ hash: Data, world: SimWorld) {
        previousHash = currentHash
        currentHash = hash
        switchUnconfirmed = true
        let hangs = spec.installer?.newVersionHangs ?? false
        world.restartPeer(index, hung: hangs)
        // The fake rollback check: every 30 s while unconfirmed, reverting past 120 s.
        for tick in 1...5 {
            world.at(world.now + .sec(30 * UInt64(tick))) { world in self.rollbackCheck(world: world, at: tick * 30) }
        }
    }

    private func rollbackCheck(world: SimWorld, at elapsed: Int) {
        guard switchUnconfirmed, elapsed > 120, let previousHash else { return }
        switchUnconfirmed = false
        rejectedHash = currentHash
        currentHash = previousHash
        world.log("peer \(index) rolls back")
        world.restartPeer(index)
    }

    /// The new version completed Hello and its first PolicyUpdate.
    private func confirmSwitch() {
        switchUnconfirmed = false
    }
}
