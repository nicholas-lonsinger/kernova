#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaWire

/// What a host endpoint is created with.
public struct HostConfiguration: Sendable {
    /// The host's claim: role HOST, Kernova's version label.
    public var claim: PeerClaim
    /// The 16 random bytes the runtime drew for this connection.
    public var sessionToken: Data
    /// The VM's policy for policy-governed features.
    public var policy: PolicySnapshot
    /// The payloads the host bundles.
    public var bundles: [BundledPayload]
    /// The receiver policy the peer is judged by.
    public var receiverPolicy: ReceiverPolicy = .production
    /// What this side serves of item transfer, clipboard, drop and drag.
    public var items = ItemFeatureAvailability.notImplemented
    #if DEBUG
    /// Changes the connection's configuration once the endpoint has built it.
    package var tweakForTesting: @Sendable (inout ConnectionConfiguration) -> Void = { _ in }
    #endif

    /// Creates a configuration.
    public init(claim: PeerClaim, sessionToken: Data, policy: PolicySnapshot, bundles: [BundledPayload]) {
        self.claim = claim
        self.sessionToken = sessionToken
        self.policy = policy
        self.bundles = bundles
    }
}

/// What the hub tells one host endpoint; ids are the hub's.
public enum HostCommand: Sendable, Equatable {
    /// The VM was live-paused (`true`) or resumed.
    case setPeerFrozen(Bool)
    /// Ask the peer to perform `action`, without waiting for apps when `ignoringApps`.
    case requestPower(PowerRequestID, PowerAction, ignoringApps: Bool = false)
    /// The VM's policy changed.
    case setPolicy(PolicySnapshot)
    /// The bundled payloads changed; re-sends `UpdateAvailable` and resets a pull it makes stale.
    case setBundles([BundledPayload])
    /// Close the connection (`SUPERSEDED`, `DUPLICATE_PEER`, `SHUTTING_DOWN`).
    case close(ErrorCode, retryAfter: CoreDuration?)
    /// Offer, withdraw, release, pull, cancel, take or read items; answered as `ItemCommand` says.
    case items(ItemCommand)
}

/// What a host endpoint's driver feeds it: the hub's commands, and the payload source's and item adapters'
/// answers to the endpoint's effects. The hub can send only the first.
package enum HostInput: Sendable, Equatable {
    /// A hub command.
    case hub(HostCommand)
    /// The payload source's answer.
    case payload(PayloadInput)
    /// The item source's answer or the item sink's report; one naming another generation is dropped.
    case items(ItemTransferInput)
}

/// The update payload source's answer to the outstanding `.read`; one naming another generation is dropped.
package enum PayloadInput: Sendable, Equatable {
    /// The bytes read: 1 … `maxBytes` of them. None, short of the payload's size, fails the pull.
    case bytes(UpdatePullID, Data)
    /// The read failed.
    case failed(UpdatePullID, WireError)
}

/// What a host endpoint tells the hub.
public typealias HostEvent = EndpointEvent<HostRoleEvent>

/// What only a host endpoint tells the hub.
public enum HostRoleEvent: Sendable, Equatable {
    /// The peer's Hello was read.
    case helloReceived(PeerClaim, PeerSessionState)
    /// The peer's state changed (coalesced).
    case peerStateChanged(PeerSessionState)
    /// Some feature's usability changed (coalesced).
    case featuresChanged(FeatureStatusTable)
    /// A power request's progress or result.
    case power(PowerRequestID, PowerRequestResult)
    /// Forwarded guest log records.
    case log(LogDelivery)
    /// An update pull's progress.
    case update(UpdateServeEvent)
}

/// What a host endpoint asks of its update payload source.
package enum HostRoleEffect: Sendable, Equatable {
    /// Read 1 … `maxBytes` bytes of `manifest`'s payload from `offset`, and answer with `.bytes` or `.failed`.
    case read(UpdatePullID, UpdateManifestValue, offset: UInt64, maxBytes: Int)
}

/// One accepted connection's whole state, owned by its driver.
package typealias HostEndpoint = Endpoint<HostMachines>

extension HostConfiguration: EndpointConfiguration {
    package var connectionConfiguration: ConnectionConfiguration {
        ConnectionConfiguration(
            claim: claim, adverts: [], sessionToken: sessionToken, hostPolicy: policy, hostBundles: bundles,
            policy: receiverPolicy)
    }
}

/// A host endpoint's power, logs and update machines, and the feature table the hub last heard.
package struct HostMachines: RoleMachines {
    package var power: PowerRequester
    package var logs = LogReceiver()
    package var update: UpdateServer
    private var lastStatus: FeatureStatusTable?

    /// The machines of a connection just accepted.
    package init(_ configuration: HostConfiguration, generation: ConnectionGeneration) {
        power = PowerRequester(generation: generation)
        update = UpdateServer(generation: generation)
    }

    /// The peer's state and the feature table coalesce.
    package static func slot(of event: HostRoleEvent) -> HostEventSlot? {
        switch event {
        case .peerStateChanged: .peerState
        case .featuresChanged: .features
        case .helloReceived, .power, .log, .update: nil
        }
    }

    /// Carries out a hub command or a payload answer; leaves item commands, item answers and a policy change to the
    /// endpoint.
    package mutating func handle(_ input: HostInput, connection: inout Connection, now: CoreInstant) -> SharedInput? {
        switch input {
        case .hub(.setPeerFrozen(let frozen)):
            connection.setPeerFrozen(frozen, now: now)
        case .hub(.requestPower(let id, let action, let ignoringApps)):
            power.request(id, action, ignoringApps: ignoringApps, connection: &connection)
        case .hub(.setPolicy(let policy)):
            connection.setPolicy(policy)
            return .policyChanged
        case .hub(.setBundles(let bundles)):
            connection.setBundles(bundles)
            update.offerChanged(connection.offeredUpdate, connection: &connection)
        case .hub(.close(let code, let retryAfter)):
            connection.close(code, retryAfter: retryAfter, now: now)
        case .hub(.items(let command)):
            return .itemCommand(command)
        case .payload(.bytes(let id, let data)):
            update.bytes(id, data, connection: &connection)
        case .payload(.failed(let id, let error)):
            update.failed(id, error, connection: &connection)
        case .items(let input):
            return .items(input)
        }
        return nil
    }

    /// The hub hears the peer's Hello and each change of its state. A peer sends no policy or offer: the connection
    /// closes on either before it reaches here.
    package func receive(
        _ message: SessionMessage, connection: inout Connection
    ) -> (event: HostRoleEvent?, shared: SharedInput?) {
        switch message {
        case .hello(let hello): (.helloReceived(hello.claim, hello.state ?? PeerSessionState()), nil)
        case .peerState(let state): (.peerStateChanged(state), nil)
        case .policy, .updateAvailable: (nil, nil)
        }
    }

    /// The feature table, once the peer's Hello is read and whenever it changed; the hub hears a connection's end
    /// from `.closed`.
    package mutating func reportUsability(of connection: Connection, closed: Bool) -> [HostRoleEvent] {
        guard !closed, connection.remoteHello != nil else { return [] }
        let status = connection.featureStatus
        guard status != lastStatus else { return [] }
        lastStatus = status
        return [.featuresChanged(status)]
    }
}

/// The host's events that coalesce.
package enum HostEventSlot: Hashable, Sendable {
    case peerState, features
}
