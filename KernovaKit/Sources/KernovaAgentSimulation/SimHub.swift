#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaAgentCore
import KernovaWire

/// What the hub's power routing saw, in order: each output, and each result
/// from a peer it asked.
package enum RoutingLogEntry: Sendable, Equatable {
    case output(RoutingOutput)
    case result(PeerHandle, PowerRequestResult)
}

/// The host's hub model: one VM, its connections, identity conflicts, power
/// routing and the update payload source. It reaches each connection only
/// through its endpoint's events and asynchronous commands, as the runtime's hub does.
package final class SimHub {
    package struct Peer {
        package var link: SimLink
        package var claim: PeerClaim
        package var state: PeerSessionState
        package var status = FeatureStatusTable()
        package var order: UInt64
        package var unresponsive = false
        package var closing = false
    }

    package struct Ask: Equatable {
        package var time: SimTime
        package var peer: PeerHandle
        package var expectedFirst: PeerHandle?
    }

    let options: SimOptions
    package private(set) var connected: [Peer] = []
    package var bundles: [BundledPayload]
    package var policy: PolicySnapshot
    package var routing = PowerRouting()
    package private(set) var routingOutputs: [(time: SimTime, output: RoutingOutput)] = []
    package private(set) var routingLog: [RoutingLogEntry] = []
    package private(set) var asks: [Ask] = []
    package private(set) var powerResults: [(time: SimTime, peer: PeerHandle, result: PowerRequestResult)] = []
    package private(set) var logRecords: [LogRecordValue] = []
    package private(set) var logDropped: UInt64 = 0
    package private(set) var updateResults: [(time: SimTime, result: UpdateResultValue)] = []
    package private(set) var updateClosures: [(time: SimTime, closure: StreamClosure)] = []
    package private(set) var displacements: [(time: SimTime, key: String, code: ErrorCode)] = []
    package private(set) var closures: [(time: SimTime, link: Int, closure: ConnectionClosure)] = []
    package private(set) var helloCount = 0
    var peersFrozen = false
    private var order: UInt64 = 0
    private var nextPowerID: UInt64 = 0
    private var pending: [PowerRequestID: PeerHandle] = [:]
    /// Every link whose host endpoint this hub made and has not seen close,
    /// handshaking ones included: each holds a policy and bundles to keep current.
    private var endpoints: [SimLink] = []

    init(options: SimOptions) {
        self.options = options
        bundles = options.bundles
        policy = options.hostPolicy
    }

    func makeEndpoint(for link: SimLink, world: SimWorld) -> HostEndpoint {
        var configuration = HostConfiguration(
            claim: PeerClaim(role: .host, versionLabel: "Kernova 2.0"),
            sessionToken: world.rng.bytes(16), policy: policy, bundles: bundles)
        configuration.receiverPolicy = options.receiverPolicy
        let testKinds = options.testKinds
        let hostile = options.hostile
        configuration.tweak = { connection in
            connection.recordsTrace = true
            connection.assertsOnMisuse = !hostile
            if testKinds { connection.addTestKinds() }
        }
        var endpoint = HostEndpoint(configuration, generation: link.generation, now: world.localNow(.host))
        endpoint.testSink.bytesPerStream = options.testBulkBytes
        endpoints.append(link)
        if peersFrozen { endpoint.handle(.setPeerFrozen(true), now: world.localNow(.host)) }
        return endpoint
    }

    /// The routing view of every established, open connection.
    package var routingPeers: [RoutingPeer] {
        connected.filter { !$0.closing }.map { peer in
            RoutingPeer(
                handle: peer.link.hubHandle, role: peer.claim.role, state: peer.state, connectedOrder: peer.order,
                features: peer.status)
        }
    }

    // MARK: Hub commands

    /// The user asks to stop or restart the VM.
    package func requestPower(_ action: PowerAction, world: SimWorld) {
        routing.begin(action, peers: routingPeers)
        drainRouting(world)
    }

    package func setBundles(_ bundles: [BundledPayload], world: SimWorld) {
        self.bundles = bundles
        for link in endpoints {
            world.hostCommand(.setBundles(bundles), link: link)
        }
    }

    package func setPolicy(_ policy: PolicySnapshot, world: SimWorld) {
        self.policy = policy
        for link in endpoints {
            world.hostCommand(.setPolicy(policy), link: link)
        }
    }

    private func drainRouting(_ world: SimWorld) {
        while let output = routing.pollOutput() {
            routingOutputs.append((world.now, output))
            routingLog.append(.output(output))
            world.log("routing: \(output)")
            guard case .ask(let handle, let action, _) = output,
                let peer = connected.first(where: { $0.link.hubHandle == handle })
            else { continue }
            let expected = Self.expectedCandidates(action, peers: routingPeers, asked: asks.map(\.peer)).first
            asks.append(Ask(time: world.now, peer: handle, expectedFirst: expected))
            nextPowerID += 1
            let id = PowerRequestID(generation: peer.link.generation, rawValue: nextPowerID)
            pending[id] = handle
            world.hostCommand(.requestPower(id, action), link: peer.link)
        }
    }

    /// The order the hub asks power providers in, restated independently of
    /// `PowerRouting` for the checker: with a system peer that knows the console,
    /// the session peers on its console session (newest first) when the console
    /// is on; without one, every session peer on a console; then the system peer.
    static func expectedCandidates(_ action: PowerAction, peers: [RoutingPeer], asked: [PeerHandle]) -> [PeerHandle] {
        var ordered: [RoutingPeer] = []
        let system = peers.first { $0.role == .systemPeer }
        let sessions = peers.filter { $0.role == .sessionPeer }.sorted { $0.connectedOrder > $1.connectedOrder }
        if let system, system.state.console != .unknown {
            if system.state.console == .on {
                ordered += sessions.filter { $0.state.sessionID == system.state.consoleSessionID }
            }
        } else {
            ordered += sessions.filter { $0.state.console == .on }
        }
        ordered += peers.filter { $0.role == .systemPeer }
        return ordered.filter { $0.powerUsable && $0.actions.contains(action) && !asked.contains($0.handle) }
            .map(\.handle)
    }

    // MARK: Events

    func handle(_ event: HostEvent, link: SimLink, world: SimWorld) {
        switch event {
        case .helloReceived(let claim, let state):
            helloCount += 1
            order += 1
            connected.append(Peer(link: link, claim: claim, state: state, order: order))
            resolveConflicts(link, world: world)
            let key = Self.key(claim, state)
            let holders = connected.filter { !$0.closing && Self.key($0.claim, $0.state) == key }.count
            if holders > 1 { world.checker.fail("property 9: the hub holds \(holders) connections for \(key)") }
        case .peerStateChanged(let state):
            update(link) { $0.state = state }
        case .featuresChanged(let status):
            update(link) { $0.status = status }
        case .liveness(let change):
            update(link) {
                if case .unresponsive = change { $0.unresponsive = true } else { $0.unresponsive = false }
            }
        case .power(let id, let result):
            powerResults.append((world.now, link.hubHandle, result))
            guard let handle = pending[id] else { return }
            routingLog.append(.result(handle, result))
            switch result {
            case .accepted, .progress: break
            default: pending[id] = nil
            }
            routing.handle(result, from: handle, peers: routingPeers)
            drainRouting(world)
        case .log(let delivery):
            switch delivery {
            case .records(let records): logRecords += records
            case .dropped(let count): logDropped += count
            }
        case .update(let serve):
            handleUpdate(serve, link: link, world: world)
        case .diagnostic(let diagnostic):
            world.log("host diagnostic: \(diagnostic)")
        case .closed(let closure):
            closures.append((world.now, link.id, closure))
            world.log("host link \(link.id) closed: \(closure)")
            connected.removeAll { $0.link === link }
            endpoints.removeAll { $0 === link }
        }
    }

    private func update(_ link: SimLink, _ change: (inout Peer) -> Void) {
        guard let index = connected.firstIndex(where: { $0.link === link }) else { return }
        change(&connected[index])
    }

    static func key(_ claim: PeerClaim, _ state: PeerSessionState) -> String {
        switch claim.role {
        case .sessionPeer: "session/\(state.sessionID)"
        case .systemPeer: "system"
        case .host: "host"
        }
    }

    /// Identity conflicts as the hub applies them: the incoming connection
    /// against each existing one with its key.
    private func resolveConflicts(_ link: SimLink, world: SimWorld) {
        guard let incoming = connected.last, incoming.link === link else { return }
        let incomingParty = ConflictParty(claim: incoming.claim, state: incoming.state)
        for index in connected.indices.dropLast() where !connected[index].closing {
            let existing = connected[index]
            let party = ConflictParty(
                claim: existing.claim, state: existing.state, isUnresponsive: existing.unresponsive)
            let key = Self.key(incoming.claim, incoming.state)
            switch PeerConflict.resolve(existing: party, incoming: incomingParty) {
            case .noConflict:
                continue
            case .closeExisting(let code, let retryAfter):
                connected[index].closing = true
                displacements.append((world.now, key, code))
                world.hostCommand(.close(code, retryAfter: retryAfter), link: existing.link)
            case .closeIncoming(let code, let retryAfter):
                connected[connected.count - 1].closing = true
                world.hostCommand(.close(code, retryAfter: retryAfter), link: link)
                return
            }
        }
    }

    // MARK: The payload source

    private func handleUpdate(_ event: UpdateServeEvent, link: SimLink, world: SimWorld) {
        switch event {
        case .pullRequested:
            break
        case .result(_, let result):
            updateResults.append((world.now, result))
        case .closed(_, let closure):
            updateClosures.append((world.now, closure))
        }
    }

    /// The payload source: each read is served from the content its manifest names.
    func handle(_ effect: HostEffect, link: SimLink, world: SimWorld) {
        switch effect {
        case .read(let id, let manifest, let offset, let maxBytes):
            let bytes = FixturePayloadSource.read(world.content(of: manifest), offset: offset, maxBytes: maxBytes)
            world.hostPayload(.bytes(id, bytes), link: link, after: options.payloadSourceDelay)
        }
    }

    /// A bundle whose payload is `size` deterministic bytes identified by `tag`.
    package static func bundle(
        size: Int, tag: UInt64, os: OSFamily = .linux, scope: InstallScope = .user, format: PayloadFormat = .executable
    ) -> BundledPayload {
        let manifest = UpdateManifestValue(
            payloadHash: tagHash(tag), payloadSize: UInt64(size), format: format, versionLabel: "2.\(tag)")
        return BundledPayload(os: os, architecture: .arm64, scope: scope, manifest: manifest)
    }

    /// The bytes the payload source serves for `manifest`, and the fake installer expects.
    package static func expectedContent(_ manifest: UpdateManifestValue) -> Data {
        SimPayload.content(size: Int(manifest.payloadSize), tag: FNV64.of(manifest.payloadHash))
    }

    /// The manifest hash for `tag`: the digest of the content the source serves for it.
    package static func tagHash(_ tag: UInt64) -> Data {
        var hash = FNV64()
        hash.add(tag)
        return Data(repeating: UInt8(truncatingIfNeeded: tag), count: 24) + withUnsafeBytes(of: hash.value) { Data($0) }
    }
}
