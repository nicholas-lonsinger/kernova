#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import SwiftProtobuf

/// Why a payload does not decode as a wire message.
public enum WireDecodingError: Error, Equatable, Sendable {
    /// The bytes are not an encoding of the message.
    case malformed
    /// A current-only message, the payload's own or one inside it, holds a field this build's schema does not
    /// define: the sender's build defines another shape of it.
    case unknownField
}

/// A message `kernova_v2.proto` marks FROZEN. It changes only additively, so a field this build does not define
/// was added by a newer build, and `init(wire:)` ignores it.
public protocol FrozenWireMessage: SwiftProtobuf.Message {}

/// A message `kernova_v2.proto` leaves current-only. Its shape changes with no compatibility path, so
/// `init(wire:)` refuses it when it, or a current-only message inside it, holds a field this build does not
/// define. A frozen message inside it is held to its own rule.
public protocol CurrentOnlyWireMessage: SwiftProtobuf.Message {}

extension FrozenWireMessage {
    /// The message `bytes` encode, a field this build does not define ignored.
    ///
    /// - Throws: `WireDecodingError.malformed` when the bytes are not an encoding of it.
    public init(wire bytes: Data) throws(WireDecodingError) {
        self = try decodedIgnoringUnknownFields(bytes)
    }
}

extension CurrentOnlyWireMessage {
    /// The message `bytes` encode, once no current-only message in it holds a field this build does not define.
    ///
    /// - Throws: `WireDecodingError.malformed` when the bytes are not an encoding of it, `.unknownField` when a
    ///   current-only message in it holds such a field.
    public init(wire bytes: Data) throws(WireDecodingError) {
        let message: Self = try decodedIgnoringUnknownFields(bytes)
        var finder = UnknownFieldFinder()
        do {
            try message.traverse(visitor: &finder)
        } catch {
            throw .unknownField
        }
        self = message
    }
}

/// SwiftProtobuf's binary decode, which keeps a field the schema does not define as the message's unknown fields.
private func decodedIgnoringUnknownFields<Message: SwiftProtobuf.Message>(_ bytes: Data) throws(WireDecodingError)
    -> Message
{
    do {
        return try Message(serializedBytes: bytes)
    } catch {
        throw .malformed
    }
}

/// Throws at the first unknown field of the message it traverses or of a current-only message inside it, never
/// entering a frozen one.
private struct UnknownFieldFinder: Visitor {
    struct Found: Error {}

    mutating func visitUnknown(bytes: Data) throws { throw Found() }

    mutating func visitSingularMessageField<M: SwiftProtobuf.Message>(value: M, fieldNumber: Int) throws {
        guard !(value is any FrozenWireMessage) else { return }
        try value.traverse(visitor: &self)
    }

    mutating func visitSingularDoubleField(value: Double, fieldNumber: Int) throws {}
    mutating func visitSingularInt64Field(value: Int64, fieldNumber: Int) throws {}
    mutating func visitSingularUInt64Field(value: UInt64, fieldNumber: Int) throws {}
    mutating func visitSingularBoolField(value: Bool, fieldNumber: Int) throws {}
    mutating func visitSingularStringField(value: String, fieldNumber: Int) throws {}
    mutating func visitSingularBytesField(value: Data, fieldNumber: Int) throws {}
    mutating func visitSingularEnumField<E: Enum>(value: E, fieldNumber: Int) throws {}
    mutating func visitMapField<KeyType, ValueType: MapValueType>(
        fieldType: _ProtobufMap<KeyType, ValueType>.Type, value: _ProtobufMap<KeyType, ValueType>.BaseType,
        fieldNumber: Int
    ) throws {}
    mutating func visitMapField<KeyType, ValueType>(
        fieldType: _ProtobufEnumMap<KeyType, ValueType>.Type, value: _ProtobufEnumMap<KeyType, ValueType>.BaseType,
        fieldNumber: Int
    ) throws where ValueType.RawValue == Int {}
    mutating func visitMapField<KeyType, ValueType>(
        fieldType: _ProtobufMessageMap<KeyType, ValueType>.Type,
        value: _ProtobufMessageMap<KeyType, ValueType>.BaseType, fieldNumber: Int
    ) throws {
        for message in value.values { try visitSingularMessageField(value: message, fieldNumber: fieldNumber) }
    }
}

// Each message's mode, as the proto's FROZEN marks give it.

extension Kernova_V2_Open: FrozenWireMessage {}
extension Kernova_V2_Error: FrozenWireMessage {}
extension Kernova_V2_ItemFailure: FrozenWireMessage {}
extension Kernova_V2_SessionMessage: FrozenWireMessage {}
extension Kernova_V2_Hello: FrozenWireMessage {}
extension Kernova_V2_PeerIdentity: FrozenWireMessage {}
extension Kernova_V2_PeerState: FrozenWireMessage {}
extension Kernova_V2_FeatureAdvert: FrozenWireMessage {}
extension Kernova_V2_Absence: FrozenWireMessage {}
extension Kernova_V2_CapabilityUpdate: FrozenWireMessage {}
extension Kernova_V2_PolicyUpdate: FrozenWireMessage {}
extension Kernova_V2_FeaturePolicy: FrozenWireMessage {}
extension Kernova_V2_SessionExtension: CurrentOnlyWireMessage {}
extension Kernova_V2_PowerCapability: FrozenWireMessage {}
extension Kernova_V2_PowerRequest: FrozenWireMessage {}
extension Kernova_V2_PowerProgress: FrozenWireMessage {}
extension Kernova_V2_PowerOutcome: FrozenWireMessage {}
extension Kernova_V2_BlockingApp: FrozenWireMessage {}
extension Kernova_V2_UpdateCapability: FrozenWireMessage {}
extension Kernova_V2_UpdateManifest: FrozenWireMessage {}
extension Kernova_V2_UpdateAvailable: FrozenWireMessage {}
extension Kernova_V2_UpdatePull: FrozenWireMessage {}
extension Kernova_V2_UpdateResult: FrozenWireMessage {}
extension Kernova_V2_LogCapability: CurrentOnlyWireMessage {}
extension Kernova_V2_LogPolicy: CurrentOnlyWireMessage {}
extension Kernova_V2_LogOpen: CurrentOnlyWireMessage {}
extension Kernova_V2_LogSegment: CurrentOnlyWireMessage {}
extension Kernova_V2_LogRecord: CurrentOnlyWireMessage {}
extension Kernova_V2_LogBatch: CurrentOnlyWireMessage {}
extension Kernova_V2_ItemTransferCapability: CurrentOnlyWireMessage {}
extension Kernova_V2_TypeDescriptor: CurrentOnlyWireMessage {}
extension Kernova_V2_Representation: CurrentOnlyWireMessage {}
extension Kernova_V2_Item: CurrentOnlyWireMessage {}
extension Kernova_V2_ItemSetHeader: CurrentOnlyWireMessage {}
extension Kernova_V2_PullRequest: CurrentOnlyWireMessage {}
extension Kernova_V2_PullOutcome: CurrentOnlyWireMessage {}
extension Kernova_V2_Timespec: CurrentOnlyWireMessage {}
extension Kernova_V2_Xattr: CurrentOnlyWireMessage {}
extension Kernova_V2_PlainStorage: CurrentOnlyWireMessage {}
extension Kernova_V2_Lz4Storage: CurrentOnlyWireMessage {}
extension Kernova_V2_DecmpfsStorage: CurrentOnlyWireMessage {}
extension Kernova_V2_EntryHeader: CurrentOnlyWireMessage {}
extension Kernova_V2_EndRecord: CurrentOnlyWireMessage {}
extension Kernova_V2_ClipboardCapability: CurrentOnlyWireMessage {}
extension Kernova_V2_ClipboardPolicy: CurrentOnlyWireMessage {}
extension Kernova_V2_DropCapability: CurrentOnlyWireMessage {}
extension Kernova_V2_DropPolicy: CurrentOnlyWireMessage {}
extension Kernova_V2_DropLanded: CurrentOnlyWireMessage {}
extension Kernova_V2_DragCapability: CurrentOnlyWireMessage {}
extension Kernova_V2_DragPolicy: CurrentOnlyWireMessage {}
extension Kernova_V2_DragTake: CurrentOnlyWireMessage {}
extension Kernova_V2_DragTakeControl: CurrentOnlyWireMessage {}
extension Kernova_V2_DragCatcher: CurrentOnlyWireMessage {}
extension Kernova_V2_DragDeliver: CurrentOnlyWireMessage {}
extension Kernova_V2_DragTakeReport: CurrentOnlyWireMessage {}
extension Kernova_V2_DragTakeOutcome: CurrentOnlyWireMessage {}
