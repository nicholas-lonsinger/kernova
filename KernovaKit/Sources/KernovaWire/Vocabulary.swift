/// The protocol's one error vocabulary: RESET payloads, END outcomes, absences.
public typealias ErrorCode = Kernova_V2_ErrorCode

/// A unit of capability, version, policy and routing.
public typealias FeatureID = Kernova_V2_FeatureId

/// Why a feature is absent.
public typealias AbsenceReason = Kernova_V2_AbsenceReason

/// What a power request asks the guest to do.
public typealias PowerAction = Kernova_V2_PowerAction

/// How an update payload is packaged.
public typealias PayloadFormat = Kernova_V2_PayloadFormat

/// What an OPEN asks for.
public typealias StreamKind = Kernova_V2_StreamKind

/// What a representation's bytes are: a canonical MIME type and namespaced native names.
public typealias TypeDescriptor = Kernova_V2_TypeDescriptor

/// A container codec a destination decodes besides plain bytes.
public typealias Codec = Kernova_V2_Codec

/// One form of an offered item: its type, and whether it travels as bytes, a file or a folder.
public typealias Representation = Kernova_V2_Representation

/// One item of an offer: its representations, best first.
public typealias OfferedItem = Kernova_V2_Item

/// What a pull asks for, and the limits its container must keep.
public typealias PullRequest = Kernova_V2_PullRequest

/// One entry of a transfer container: its place in the tree, its metadata, and how its bytes travel.
public typealias EntryHeader = Kernova_V2_EntryHeader

/// The counts a transfer container states last.
public typealias EndRecord = Kernova_V2_EndRecord

extension StreamKind {
    /// The simulation's raw-DATA kind a peer opens.
    package static let testBulkByPeer = StreamKind.UNRECOGNIZED(9000)
    /// The simulation's raw-DATA kind the host opens.
    package static let testBulkByHost = StreamKind.UNRECOGNIZED(9001)
    /// The simulation's item-set offer kind the host opens.
    package static let testItemOfferByHost = StreamKind.UNRECOGNIZED(9002)
    /// The simulation's item-set offer kind a peer opens.
    package static let testItemOfferByPeer = StreamKind.UNRECOGNIZED(9003)
}
