#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaWire
import SwiftProtobuf

/// Writes a container's records from its entries: `entry(_:)` for each header in depth-first pre-order,
/// `bytes(_:)` for a file's data until it has all it declared and then for its resource fork's, then `end()`.
/// It holds the container to the same rules as `ContainerDecoder`, so what it writes the decoder accepts.
/// After it throws, discard it.
///
/// It is a `ContainerRecordAdmission` writing straight into a `ContainerRecordWriter`, each LZ4 candidate tried
/// in the caller as it is written.
public struct ContainerEncoder {
    /// The most bytes one chunk carries.
    public static let chunkByteCount = 262_144

    private var admission: ContainerRecordAdmission
    private var writer: ContainerRecordWriter

    /// An encoder of a container `acceptance` admits, compressing chunks as `policy` allows.
    ///
    /// - Parameters:
    ///   - acceptance: What the pull's destination accepts.
    ///   - policy: When to try LZ4 on a chunk.
    public init(accepting acceptance: ContainerAcceptance, policy: ChunkCompressionPolicy) {
        admission = ContainerRecordAdmission(accepting: acceptance)
        writer = ContainerRecordWriter(policy: policy)
    }

    /// The header record of the next entry.
    ///
    /// - Parameter header: The entry, at its depth in pre-order.
    /// - Returns: The record's bytes.
    /// - Throws: `ContainerError` when the entry breaks a container rule or its header is too large.
    public mutating func entry(_ header: EntryHeader) throws(ContainerError) -> Data {
        written(try admission.entry(header))
    }

    /// The records carrying the current entry's next bytes, as `ContainerRecordAdmission.bytes(_:)` admits them.
    ///
    /// - Parameter bytes: The entry's next bytes, no more than its data, or its fork, still owes.
    /// - Returns: The records' bytes, possibly none while zeros are pending.
    /// - Throws: `ContainerError` when no entry owes bytes or `bytes` is more than it owes.
    public mutating func bytes(_ bytes: Data) throws(ContainerError) -> Data {
        written(try admission.bytes(bytes))
    }

    /// The end record, stating the container's counts.
    ///
    /// - Returns: The record's bytes.
    /// - Throws: `ContainerError` when the current entry still owes bytes or no entry was written.
    public mutating func end() throws(ContainerError) -> Data {
        written(try admission.end())
    }

    /// The records carrying the current entry's next `count` bytes, all zero, as
    /// `ContainerRecordAdmission.zeros(_:)` admits them.
    ///
    /// - Parameter count: The zero bytes, no more than the entry's data, or its fork, still owes.
    /// - Returns: The records' bytes, possibly none while zeros are pending.
    /// - Throws: `ContainerError` when no entry owes bytes or `count` is more than it owes.
    public mutating func zeros(_ count: UInt64) throws(ContainerError) -> Data {
        written(try admission.zeros(count))
    }

    /// The records `event` adds, as `ContainerRecordAdmission.admit(_:)` admits them.
    ///
    /// - Parameter event: The next event of a tree in depth-first pre-order.
    /// - Returns: The records' bytes, possibly none.
    /// - Throws: `ContainerError` when the event breaks a container rule.
    public mutating func encode(_ event: TreeEvent) throws(ContainerError) -> Data {
        written(try admission.admit(event))
    }

    private mutating func written(_ records: [AdmittedRecord]) -> Data {
        var bytes = Data()
        for record in records { writer.write(record, to: &bytes) }
        return bytes
    }

    /// A proto3 message's bytes; with no required fields, serializing it cannot fail.
    static func serialized(_ message: some SwiftProtobuf.Message) -> Data {
        do {
            return try message.serializedBytes()
        } catch {
            preconditionFailure("a proto3 message always serializes: \(error)")
        }
    }
}

extension EntryHeader {
    /// Whether the header fits one header record, whose payload lengths `ContainerRecordKind.header` states.
    public var fitsHeaderRecord: Bool {
        ContainerRecordKind.header.payloadLengths.contains(ContainerEncoder.serialized(self).count)
    }
}
