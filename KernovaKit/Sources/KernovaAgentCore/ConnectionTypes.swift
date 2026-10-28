#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaWire

/// What a connection is configured with: its role, its Hello, its receiver
/// policy and its kind table. Frozen constants are not configurable.
public struct ConnectionConfiguration: Sendable {
    /// This side's claim; its role decides id parity and which Hello it accepts.
    public var claim: PeerClaim
    /// Peers only: the initial state the Hello carries.
    public var initialState: PeerSessionState?
    /// This side's adverts, one per feature.
    public var adverts: [(FeatureID, LocalAdvert)]
    /// Host only: the 16 random bytes the runtime drew for this connection.
    public var sessionToken: Data
    /// Host only: the VM's policy, sent right after the peer's Hello.
    public var hostPolicy: PolicySnapshot
    /// Host only: the bundles whose offer for the peer goes right after the policy.
    public var hostBundles: [BundledPayload]
    /// The receiver policy the far side is judged by.
    public var policy: ReceiverPolicy
    /// The kinds this connection serves.
    public var kinds: [StreamKindDescriptor]
    package var protocolVersion: UInt32 = Limits.protocolVersion
    package var assertsOnMisuse = true
    package var recordsTrace = false
    package var firstLocalStreamID: UInt64?

    /// Creates a configuration over the production kinds.
    public init(
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

    /// The production kinds plus the simulation's bulk kinds.
    package mutating func addTestKinds() {
        kinds += StreamKindDescriptor.testBulk
    }
}

/// The far side's Hello, normalized.
public struct RemoteHello: Sendable, Equatable {
    /// Its session layer's version.
    public var protocolVersion: UInt32
    /// Who it claims to be.
    public var claim: PeerClaim
    /// Peers only: its initial state.
    public var state: PeerSessionState?
    /// Its adverts in feature order, unknown features dropped.
    public var adverts: [FeatureAdvertValue]
    /// Host only: the session token, kept and unused.
    public var sessionToken: Data
}

/// One feature as a side advertised it.
public struct FeatureAdvertValue: Sendable, Equatable {
    /// The feature.
    public var feature: FeatureID
    /// Its version and availability.
    public var advert: LocalAdvert

    /// Creates an advert row.
    public init(feature: FeatureID, advert: LocalAdvert) {
        self.feature = feature
        self.advert = advert
    }
}

/// One output of a connection, for the endpoint (or a test) to act on.
public enum ConnectionEvent: Sendable, Equatable {
    /// The far side's Hello was read; the connection is established.
    case helloReceived(RemoteHello)
    /// The far side's adverts changed (coalesced).
    case remoteAdvertsChanged
    /// Host: the peer's state changed (coalesced).
    case peerStateChanged(PeerSessionState)
    /// Peer: a `PolicyUpdate` arrived (coalesced).
    case policyChanged(PolicySnapshot)
    /// Peer: an `UpdateAvailable` arrived (coalesced).
    case updateAvailable(UpdateManifestValue?)
    /// A liveness verdict.
    case liveness(LivenessChange)
    /// The far side opened a stream that passed §3.6's checks.
    case opened(StreamID, StreamKind, body: Data)
    /// A message arrived on a stream.
    case message(StreamID, Data)
    /// Raw bytes arrived on a stream; they hold credit until `consumed`.
    case data(StreamID, Data)
    /// The far side sent END.
    case remoteEnded(StreamID, body: Data)
    /// A stream became writable again (§3.4 S4).
    case writable(StreamID)
    /// A stream ended; nothing more comes for it.
    case streamClosed(StreamID, StreamClosure)
    /// A note for the runtime's log.
    case diagnostic(Diagnostic)
    /// The connection ended; nothing more comes.
    case closed(ConnectionClosure)
}

/// Frames ready for the transport. Write `chunks` in order; after one marked
/// `isFinal`, close the transport.
public struct Transmit: Sendable, Equatable {
    /// The bytes, as headers and uncopied payloads.
    public var chunks: [Data]
    /// It holds the connection's RESET(0); nothing follows.
    public var isFinal: Bool

    /// The total byte count.
    public var byteCount: Int { chunks.reduce(0) { $0 + $1.count } }
}

/// A connection's current memory and credit, for the simulation's bounds and
/// conservation checks (§10.3).
public struct MemoryFootprint: Sendable, Equatable {
    /// Raw DATA delivered to machines and not yet consumed.
    public var heldRawBytes: Int
    /// Bytes the decoder holds.
    public var decoderBufferedBytes: Int
    /// Raw DATA queued and not yet handed out.
    public var queuedRawBytes: Int
    /// The most MESSAGE frames queued on any one stream.
    public var maxQueuedMessagesPerStream: Int
    /// Pending control frames: session snapshots, WINDOWs, PING, stream RESETs.
    public var controlFrames: Int
    /// Events not yet polled.
    public var pendingEvents: Int
    /// Streams in the table, refused ones awaiting their RESET included.
    public var streamRecords: Int
    /// Credit this side may still spend sending raw DATA.
    public var connectionSendCredit: Int
    /// Raw DATA the far side may still send this side.
    public var connectionReceiveRemaining: Int
    /// Connection credit owed back to the far side, a queued WINDOW included.
    public var unreturnedConnectionCredit: Int
}

/// The phases of one stream, from this side (§3.2).
public enum StreamPhase: Sendable, Equatable {
    /// Both halves open.
    case open
    /// This side sent END.
    case localEnded
    /// The far side sent END.
    case remoteEnded
    /// Terminal.
    case closed
}

/// What the simulation reads of a connection beside its events.
package enum ConnectionTrace: Sendable, Equatable {
    case localOpened(StreamID, StreamKind)
    case sent(StreamID, isMessage: Bool, Data)
    case event(ConnectionEvent)
}
