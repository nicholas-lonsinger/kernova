#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaWire

/// Which role opens a stream kind.
public enum OpenerRole: Sendable, Equatable {
    /// Only the host opens it.
    case host
    /// Only a peer opens it.
    case peer
}

/// What one direction of a stream kind carries.
public enum StreamDirection: Sendable, Equatable {
    /// Nothing but END and RESET.
    case nothing
    /// MESSAGE DATA only.
    case messages
    /// Raw DATA only; such a direction is raised to the bulk target.
    case rawData
}

/// Which machine of an endpoint serves a kind. Every item-set offer kind, whichever feature's, belongs to
/// the offer registry the item-transfer machine keeps; the simulation's bulk kinds to its test sink.
package enum KindOwner: Sendable, Equatable {
    case power, update, logs, itemTransfer, itemOffer, dragTake
    case testBulk
}

/// One row of the static kind table.
public struct StreamKindDescriptor: Sendable {
    /// The kind the row describes.
    public var kind: StreamKind
    /// The feature whose usability gates new streams of the kind; nil for a
    /// test kind, which is always usable.
    public var feature: FeatureID?
    /// The role that opens it.
    public var openerRole: OpenerRole
    /// What the opener sends.
    public var openerToAcceptor: StreamDirection
    /// What the acceptor sends.
    public var acceptorToOpener: StreamDirection
    /// At most this many open at once per connection; nil for any number.
    public var maxPerConnection: Int?
    /// The RESET code for an OPEN past `maxPerConnection`.
    public var duplicateCode: ErrorCode
    /// The opener's END answers the acceptor's: one the acceptor receives before its own END was handed out
    /// is a violation, which the connection resets `STREAM_PROTOCOL_ERROR`.
    public var acceptorEndsFirst: Bool
    /// The machine serving accepted streams of the kind; nil only for the
    /// placeholder row a refused OPEN of an unknown kind carries.
    package var owner: KindOwner?
    let isValidOpenBody: @Sendable (Data) -> Bool

    package init(
        kind: StreamKind, feature: FeatureID?, owner: KindOwner?, openerRole: OpenerRole,
        openerToAcceptor: StreamDirection, acceptorToOpener: StreamDirection, maxPerConnection: Int?,
        duplicateCode: ErrorCode = .streamProtocolError, acceptorEndsFirst: Bool = false,
        isValidOpenBody: @escaping @Sendable (Data) -> Bool
    ) {
        self.kind = kind
        self.feature = feature
        self.owner = owner
        self.openerRole = openerRole
        self.openerToAcceptor = openerToAcceptor
        self.acceptorToOpener = acceptorToOpener
        self.maxPerConnection = maxPerConnection
        self.duplicateCode = duplicateCode
        self.acceptorEndsFirst = acceptorEndsFirst
        self.isValidOpenBody = isValidOpenBody
    }

    /// The kinds every production endpoint serves.
    public static let production: [StreamKindDescriptor] = [
        StreamKindDescriptor(
            kind: .powerRequest, feature: .power, owner: .power, openerRole: .host, openerToAcceptor: .nothing,
            acceptorToOpener: .messages, maxPerConnection: nil,
            isValidOpenBody: { (try? Kernova_V2_PowerRequest(serializedBytes: $0)) != nil }),
        StreamKindDescriptor(
            kind: .updatePull, feature: .update, owner: .update, openerRole: .peer, openerToAcceptor: .nothing,
            acceptorToOpener: .rawData, maxPerConnection: 1, duplicateCode: .updateInProgress, acceptorEndsFirst: true,
            isValidOpenBody: { (try? Kernova_V2_UpdatePull(serializedBytes: $0)) != nil }),
        StreamKindDescriptor(
            kind: .logForward, feature: .logs, owner: .logs, openerRole: .peer, openerToAcceptor: .messages,
            acceptorToOpener: .nothing, maxPerConnection: 1,
            isValidOpenBody: { (try? Kernova_V2_LogOpen(serializedBytes: $0)) != nil }),
        StreamKindDescriptor(
            kind: .itemPullByHost, feature: .itemTransfer, owner: .itemTransfer, openerRole: .host,
            openerToAcceptor: .nothing, acceptorToOpener: .rawData, maxPerConnection: nil, acceptorEndsFirst: true,
            isValidOpenBody: { (try? PullRequest(serializedBytes: $0)) != nil }),
        StreamKindDescriptor(
            kind: .itemPullByPeer, feature: .itemTransfer, owner: .itemTransfer, openerRole: .peer,
            openerToAcceptor: .nothing, acceptorToOpener: .rawData, maxPerConnection: nil, acceptorEndsFirst: true,
            isValidOpenBody: { (try? PullRequest(serializedBytes: $0)) != nil }),
        itemOffer(.clipboardOfferByHost, feature: .clipboard, openerRole: .host),
        itemOffer(.clipboardOfferByPeer, feature: .clipboard, openerRole: .peer),
        itemOffer(.dropOffer, feature: .drop, openerRole: .host),
        itemOffer(.dragOffer, feature: .drag, openerRole: .peer),
        StreamKindDescriptor(
            kind: .dragTake, feature: .drag, owner: .dragTake, openerRole: .host, openerToAcceptor: .nothing,
            acceptorToOpener: .nothing, maxPerConnection: nil,
            isValidOpenBody: { (try? Kernova_V2_DragTake(serializedBytes: $0))?.token.count == 16 }),
    ]

    /// An item-set offer kind: an `ItemSetHeader` OPEN followed by `Item` messages, any number at once.
    private static func itemOffer(_ kind: StreamKind, feature: FeatureID, openerRole: OpenerRole)
        -> StreamKindDescriptor
    {
        StreamKindDescriptor(
            kind: kind, feature: feature, owner: .itemOffer, openerRole: openerRole, openerToAcceptor: .messages,
            acceptorToOpener: .nothing, maxPerConnection: nil, isValidOpenBody: ItemOfferRegistry.isValidHeader)
    }

    /// The simulation's bulk kinds: 9000 opened by a peer, 9001 by the
    /// host, each carrying raw DATA from acceptor to opener, any number at once.
    package static let testBulk: [StreamKindDescriptor] = [
        StreamKindDescriptor(
            kind: .testBulkByPeer, feature: nil, owner: .testBulk, openerRole: .peer, openerToAcceptor: .nothing,
            acceptorToOpener: .rawData, maxPerConnection: nil, isValidOpenBody: { _ in true }),
        StreamKindDescriptor(
            kind: .testBulkByHost, feature: nil, owner: .testBulk, openerRole: .host, openerToAcceptor: .nothing,
            acceptorToOpener: .rawData, maxPerConnection: nil, isValidOpenBody: { _ in true }),
    ]

    /// What this side sends on a stream of the kind, given whether it opened it.
    func sending(asOpener: Bool) -> StreamDirection {
        asOpener ? openerToAcceptor : acceptorToOpener
    }

    /// What this side receives on a stream of the kind.
    func receiving(asOpener: Bool) -> StreamDirection {
        asOpener ? acceptorToOpener : openerToAcceptor
    }

    /// The ErrorCode range a received RESET of this kind keeps as sent, past 50–99.
    var featureCodeRange: ClosedRange<Int>? {
        switch feature {
        case .power: 100...119
        case .update: 120...139
        case .logs: 140...199
        case .itemTransfer, .clipboard, .drop, .drag: 1000...1199
        default: nil
        }
    }
}

/// The fixed facts about each feature the core implements.
struct FeatureDescriptor: Sendable {
    var feature: FeatureID
    var frozen: Bool
    var policyGoverned: Bool
    var version: UInt32
    /// Whether a far side's `params` decode as the feature's capability message.
    var paramsDecode: @Sendable (Data) -> Bool

    static let all: [FeatureDescriptor] = [
        FeatureDescriptor(
            feature: .power, frozen: true, policyGoverned: false, version: 1,
            paramsDecode: { PowerOffer(params: $0) != nil }),
        FeatureDescriptor(
            feature: .update, frozen: true, policyGoverned: false, version: 1,
            paramsDecode: { (try? Kernova_V2_UpdateCapability(serializedBytes: $0)) != nil }),
        FeatureDescriptor(
            feature: .logs, frozen: false, policyGoverned: true, version: 1,
            paramsDecode: { (try? Kernova_V2_LogCapability(serializedBytes: $0)) != nil }),
        FeatureDescriptor(
            feature: .itemTransfer, frozen: false, policyGoverned: false, version: 1,
            paramsDecode: { (try? Kernova_V2_ItemTransferCapability(serializedBytes: $0)) != nil }),
        FeatureDescriptor(
            feature: .clipboard, frozen: false, policyGoverned: true, version: 1,
            paramsDecode: { (try? Kernova_V2_ClipboardCapability(serializedBytes: $0)) != nil }),
        FeatureDescriptor(
            feature: .drop, frozen: false, policyGoverned: true, version: 1,
            paramsDecode: { (try? Kernova_V2_DropCapability(serializedBytes: $0)) != nil }),
        FeatureDescriptor(
            feature: .drag, frozen: false, policyGoverned: true, version: 1,
            paramsDecode: { (try? Kernova_V2_DragCapability(serializedBytes: $0)) != nil }),
    ]

    static func lookup(_ feature: FeatureID) -> FeatureDescriptor? {
        all.first { $0.feature == feature }
    }
}

/// The receiver policy a connection judges the far side by.
/// Nothing here is frozen; tests shorten it.
public struct ReceiverPolicy: Sendable, Equatable {
    /// Silence after which the far side is unresponsive.
    public var unresponsiveAfter: CoreDuration
    /// Silence after which the connection closes `LIVENESS_EXPIRED`.
    public var closeAfter: CoreDuration
    /// How long the far side's Hello may take.
    public var helloTimeout: CoreDuration
    /// How often this side sends a PING, each due one interval after the last was
    /// due; below the frozen 5 s maximum so timer and write latency stay inside it.
    public var pingInterval: CoreDuration
    /// A judged deadline found passed fires only this much raw time later.
    public var expiryConfirmation: CoreDuration
    /// A step longer than this charges nothing to the far side.
    public var suspendedStep: CoreDuration
    /// The receive window a raw-DATA direction is raised to.
    public var bulkReceiveTarget: Int
    /// Unreturned connection credit is sent once it reaches this.
    public var connectionReplenishThreshold: Int
    /// Raw DATA a sender may hold queued.
    public var senderRawBudget: Int
    /// The OPEN bucket's capacity.
    public var openBucketCapacity: Int
    /// OPENs the bucket refills per second of raw time.
    public var openBucketRefillPerSecond: Int
    /// How long a closing connection waits for its RESET(0) to be handed out.
    public var closingDeadline: CoreDuration
    /// Diagnostics emitted per minute before the rest are counted.
    public var diagnosticsPerMinute: Int

    /// The values a shipping endpoint runs with.
    public static let production = ReceiverPolicy(
        unresponsiveAfter: .seconds(15), closeAfter: .seconds(30), helloTimeout: .seconds(10),
        pingInterval: .seconds(4),
        expiryConfirmation: .seconds(1), suspendedStep: .seconds(10), bulkReceiveTarget: 8_388_608,
        connectionReplenishThreshold: 4_194_304, senderRawBudget: 2_097_152, openBucketCapacity: 64,
        openBucketRefillPerSecond: 32, closingDeadline: .seconds(1), diagnosticsPerMinute: 20)

    /// Creates a policy.
    public init(
        unresponsiveAfter: CoreDuration, closeAfter: CoreDuration, helloTimeout: CoreDuration,
        pingInterval: CoreDuration, expiryConfirmation: CoreDuration, suspendedStep: CoreDuration,
        bulkReceiveTarget: Int, connectionReplenishThreshold: Int, senderRawBudget: Int, openBucketCapacity: Int,
        openBucketRefillPerSecond: Int, closingDeadline: CoreDuration, diagnosticsPerMinute: Int
    ) {
        self.unresponsiveAfter = unresponsiveAfter
        self.closeAfter = closeAfter
        self.helloTimeout = helloTimeout
        self.pingInterval = pingInterval
        self.expiryConfirmation = expiryConfirmation
        self.suspendedStep = suspendedStep
        self.bulkReceiveTarget = bulkReceiveTarget
        self.connectionReplenishThreshold = connectionReplenishThreshold
        self.senderRawBudget = senderRawBudget
        self.openBucketCapacity = openBucketCapacity
        self.openBucketRefillPerSecond = openBucketRefillPerSecond
        self.closingDeadline = closingDeadline
        self.diagnosticsPerMinute = diagnosticsPerMinute
    }
}

/// The protocol's numbers no configuration changes; all but the low-water mark are frozen.
enum Limits {
    static let initialStreamWindow = 262_144
    static let initialConnectionWindow = 16_777_216
    static let maxWindow = Int(WireConstants.maxWindow)
    static let maxConcurrentStreams = 64
    static let writableLowWater = 65_536
    static let protocolVersion: UInt32 = 1
}
