#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaWire

/// What a peer endpoint is created with: who it is, its state, and each
/// implemented feature's current availability from the adapters' last reports.
public struct PeerConfiguration: Sendable {
    /// The peer's claim, its process's instance id included.
    public var claim: PeerClaim
    /// The initial session state.
    public var state: PeerSessionState
    /// The power adapter's availability; absent `NOT_IMPLEMENTED` without one.
    public var power: Availability<PowerOffer>
    /// The process's power ledger: the request the adapter still holds from an
    /// earlier connection, which a new request waits behind.
    public var powerLedger = PowerLedger()
    /// Whether this build forwards logs.
    public var logs: Availability<NoParams>
    /// The installer's formats and rejected hash; absent `NOT_IMPLEMENTED` without one.
    public var update: Availability<UpdateOffer>
    /// The receiver policy the host is judged by.
    public var receiverPolicy: ReceiverPolicy = .production
    /// What this side serves of item transfer, clipboard, drop and drag. A system peer advertises the last
    /// three absent `NOT_SERVED_BY_ROLE` whatever this says.
    public var items = ItemFeatureAvailability.notImplemented
    #if DEBUG
    /// Changes the connection's configuration once the endpoint has built it.
    package var tweakForTesting: @Sendable (inout ConnectionConfiguration) -> Void = { _ in }
    #endif

    /// Creates a configuration.
    public init(
        claim: PeerClaim, state: PeerSessionState, power: Availability<PowerOffer>, logs: Availability<NoParams>,
        update: Availability<UpdateOffer>
    ) {
        self.claim = claim
        self.state = state
        self.power = power
        self.logs = logs
        self.update = update
    }
}

/// Everything a peer's adapters and runtime feed its endpoint.
public enum PeerInput: Sendable, Equatable {
    /// The session state changed.
    case peerState(PeerSessionState)
    /// The power adapter's report.
    case power(PowerInput)
    /// The log sink's or runtime's input.
    case logs(LogInput)
    /// The installer's report.
    case update(UpdateInput)
    /// The item source's answer or the item sink's report; one naming another generation is dropped.
    case items(ItemTransferInput)
    /// The answer to a take of this side's drag; one to a take already ended is dropped.
    case dragTake(DragTakeID, DragTakeAnswer)
    /// Offer, withdraw, release, pull, cancel or read items; answered as `ItemCommand` says.
    case itemCommand(ItemCommand)
}

/// What a peer endpoint asks its adapters and runtime to do.
public typealias PeerEffect = EndpointEffect<PeerRoleEffect>

/// What a peer endpoint asks of its power adapter, log ring and installer.
public enum PeerRoleEffect: Sendable, Equatable {
    /// For the power adapter.
    case power(PowerEffect)
    /// For the log ring and its runtime.
    case logs(LogEffect)
    /// For the installer.
    case update(UpdateEffect)
}

/// What a peer endpoint tells the shell's UI and the dial schedule.
public typealias PeerEvent = EndpointEvent<PeerRoleEvent>

/// What only a peer endpoint tells the shell's UI and the dial schedule.
public enum PeerRoleEvent: Sendable, Equatable {
    /// The host's Hello was read.
    case established(host: PeerClaim)
    /// A `PolicyUpdate` arrived (coalesced): the host's policy as it stands.
    case policyReceived(PolicySnapshot)
    /// What the host offers (coalesced).
    case updateAvailable(UpdateManifestValue?)
    /// A feature that offers items became usable on the connection, or stopped being usable: the Hello, the
    /// adverts and the host's policy decide it, and the connection's end makes every one unusable. Once per
    /// change, after the event that caused it and before anything the change ends.
    case itemFeatureUsable(FeatureID, Bool)
}

/// One peer connection's whole state, owned by its driver.
package typealias PeerEndpoint = Endpoint<PeerMachines>

extension PeerConfiguration: EndpointConfiguration {
    package var connectionConfiguration: ConnectionConfiguration {
        ConnectionConfiguration(claim: claim, initialState: state, adverts: [], policy: receiverPolicy)
    }
}

/// A peer endpoint's power, logs and update machines, and the features that offer items it last said are usable.
package struct PeerMachines: RoleMachines {
    package var power: PowerResponder
    package var logs: LogForwarder
    package var update: UpdateClient
    /// The features that offer items `.itemFeatureUsable` last said are usable.
    private var usableItemFeatures: Set<FeatureID> = []

    /// The machines of a connection that just connected.
    package init(_ configuration: PeerConfiguration, generation: ConnectionGeneration) {
        power = PowerResponder(
            availability: configuration.power, ledger: configuration.powerLedger, generation: generation)
        logs = LogForwarder(availability: configuration.logs)
        update = UpdateClient(
            availability: configuration.update, ownHash: configuration.claim.payloadHash, generation: generation)
    }

    /// The host's policy and its offer coalesce.
    package static func slot(of event: PeerRoleEvent) -> PeerEventSlot? {
        switch event {
        case .policyReceived: .policy
        case .updateAvailable: .updateAvailable
        case .established, .itemFeatureUsable: nil
        }
    }

    /// Carries out the session state or an adapter's report; leaves item commands, item answers and drag answers to
    /// the endpoint.
    package mutating func handle(_ input: PeerInput, connection: inout Connection, now: CoreInstant) -> SharedInput? {
        switch input {
        case .peerState(let state):
            if connection.isAcceptingInput { connection.setPeerState(state) }
        case .power(let input):
            power.handle(input: input, connection: &connection)
        case .logs(let input):
            logs.handle(input: input, connection: &connection)
        case .update(let input):
            update.handle(input: input, connection: &connection)
        case .items(let input):
            return .items(input)
        case .dragTake(let id, let answer):
            return .dragTake(id, answer)
        case .itemCommand(let command):
            return .itemCommand(command)
        }
        return nil
    }

    /// The shell hears the host's Hello, its policy, which every machine then hears, and its offer, which the update
    /// client hears first. The host sends no peer state: the connection closes on one before it reaches here.
    package mutating func receive(
        _ message: SessionMessage, connection: inout Connection
    ) -> (event: PeerRoleEvent?, shared: SharedInput?) {
        switch message {
        case .hello(let hello):
            return (.established(host: hello.claim), nil)
        case .policy(let policy):
            return (.policyReceived(policy), .policyChanged)
        case .updateAvailable(let manifest):
            update.offerChanged(manifest, connection: &connection)
            return (.updateAvailable(manifest), nil)
        case .peerState:
            return (nil, nil)
        }
    }

    /// `.itemFeatureUsable` for each feature that offers items whose usability changed; once `closed`, every one is
    /// unusable.
    package mutating func reportUsability(of connection: Connection, closed: Bool) -> [PeerRoleEvent] {
        var changes: [PeerRoleEvent] = []
        for feature in ItemFeatureAvailability.offering.sorted(by: { $0.rawValue < $1.rawValue }) {
            let usable = !closed && connection.usability(feature).isAvailable
            guard usable != usableItemFeatures.contains(feature) else { continue }
            if usable { usableItemFeatures.insert(feature) } else { usableItemFeatures.remove(feature) }
            changes.append(.itemFeatureUsable(feature, usable))
        }
        return changes
    }
}

/// The peer's events that coalesce.
package enum PeerEventSlot: Hashable, Sendable {
    case policy, updateAvailable
}
