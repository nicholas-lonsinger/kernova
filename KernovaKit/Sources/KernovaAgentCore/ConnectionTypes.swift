#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaWire

/// What a connection is configured with: its role, its Hello, its receiver
/// policy and its kind table. Frozen constants are not configurable.
package struct ConnectionConfiguration: Sendable {
    /// This side's claim; its role decides id parity and which Hello it accepts.
    package var claim: PeerClaim
    /// Peers only: the initial state the Hello carries.
    package var initialState: PeerSessionState?
    /// This side's adverts, one per feature.
    package var adverts: [(FeatureID, LocalAdvert)]
    /// Host only: the 16 random bytes the runtime drew for this connection.
    package var sessionToken: Data
    /// Host only: the VM's policy at accept; it seeds `Connection.currentPolicy`,
    /// which `setPolicy` replaces and the Hello-time `PolicyUpdate` carries.
    package var hostPolicy: PolicySnapshot
    /// Host only: the bundles at accept; they seed the connection's bundles,
    /// which `setBundles` replaces and the Hello-time offer comes from.
    package var hostBundles: [BundledPayload]
    /// The receiver policy the far side is judged by.
    package var policy: ReceiverPolicy
    /// The kinds this connection serves.
    package var kinds: [StreamKindDescriptor]
    package var protocolVersion: UInt32 = Limits.protocolVersion
    #if DEBUG
    package var assertsOnMisuseForTesting = true
    package var recordsTraceForTesting = false
    package var firstLocalStreamIDForTesting: UInt64?
    #endif

    /// Creates a configuration over the production kinds.
    package init(
        claim: PeerClaim, initialState: PeerSessionState? = nil, adverts: [(FeatureID, LocalAdvert)],
        sessionToken: Data = Data(), hostPolicy: PolicySnapshot = PolicySnapshot(), hostBundles: [BundledPayload] = [],
        policy: ReceiverPolicy = .production
    ) {
        self.claim = claim
        self.initialState = initialState
        self.adverts = adverts
        self.sessionToken = sessionToken
        self.hostPolicy = hostPolicy
        self.hostBundles = hostBundles
        self.policy = policy
        self.kinds = StreamKindDescriptor.production
    }
}

/// The far side's Hello, normalized.
package struct RemoteHello: Sendable, Equatable {
    /// Its session layer's version.
    package var protocolVersion: UInt32
    /// Who it claims to be.
    package var claim: PeerClaim
    /// Peers only: its initial state.
    package var state: PeerSessionState?
    /// Its adverts in feature order, unknown features dropped.
    package var adverts: [FeatureAdvertValue]
    /// Host only: the session token, kept and unused.
    package var sessionToken: Data
}

/// One feature as a side advertised it.
package struct FeatureAdvertValue: Sendable, Equatable {
    /// The feature.
    package var feature: FeatureID
    /// Its version and availability.
    package var advert: LocalAdvert

    /// Creates an advert row.
    package init(feature: FeatureID, advert: LocalAdvert) {
        self.feature = feature
        self.advert = advert
    }
}

/// One output of a connection, for the endpoint (or a test) to act on.
package enum ConnectionEvent: Sendable, Equatable {
    /// The far side's Hello was read; the connection is established.
    case helloReceived(RemoteHello)
    /// The far side's adverts changed.
    case remoteAdvertsChanged
    /// Host: the peer's state changed.
    case peerStateChanged(PeerSessionState)
    /// Peer: a `PolicyUpdate` arrived.
    case policyChanged(PolicySnapshot)
    /// Peer: an `UpdateAvailable` arrived.
    case updateAvailable(UpdateManifestValue?)
    /// A liveness verdict.
    case liveness(LivenessChange)
    /// The far side opened a stream this side accepted.
    case opened(StreamID, StreamKind, body: Data)
    /// A message arrived on a stream.
    case message(StreamID, Data)
    /// Raw bytes arrived on a stream; they hold credit until `consumed`.
    case data(StreamID, Data)
    /// The far side sent END.
    case remoteEnded(StreamID, body: Data)
    /// A stream became writable again.
    case writable(StreamID)
    /// A stream ended; nothing more comes for it.
    case streamClosed(StreamID, StreamClosure)
    /// A stream of this kind that this side opened left the table, freeing the
    /// concurrency and per-kind slots it held: `canOpen` may now allow what it refused.
    case slotFreed(StreamKind)
    /// A note for the runtime's log.
    case diagnostic(Diagnostic)
    /// The connection ended; nothing more comes.
    case closed(ConnectionClosure)
}

/// Frames ready for the transport. Write `chunks` in order; once one marked
/// `isFinal` is written, report it with `finalTransmitWritten`, and close the
/// transport on the turn that finds the connection `finished`.
public struct Transmit: Sendable, Equatable {
    /// The bytes, as headers and uncopied payloads.
    public var chunks: [Data]
    /// It holds the connection's RESET(0); nothing follows.
    public var isFinal: Bool
}

/// The phases of one stream, from this side.
package enum StreamPhase: Sendable, Equatable {
    /// Both halves open.
    case open
    /// This side sent END.
    case localEnded
    /// The far side sent END.
    case remoteEnded
    /// Terminal.
    case closed
}
