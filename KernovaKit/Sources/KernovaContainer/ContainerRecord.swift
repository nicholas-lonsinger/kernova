#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaWire

/// What a container record holds; the value is the record's first byte. The header, chunk, zero-run and end
/// kinds and the framing are in the update profile, frozen (`kernova_v2.proto`, "The update profile").
public enum ContainerRecordKind: UInt8, Sendable, CaseIterable {
    /// A protobuf `EntryHeader`.
    case header = 1
    /// Entry bytes as they are.
    case chunk = 2
    /// Entry bytes as one LZ4 block: a little-endian `UInt32` decompressed size, then the block.
    case lz4Chunk = 3
    /// A run of zero bytes: a little-endian `UInt64` count, and no bytes.
    case zeroRun = 4
    /// A protobuf `EndRecord`.
    case end = 5

    /// The payload lengths a record of this kind may declare. The decoder refuses any other from the
    /// record's prefix, before it waits for or holds the payload.
    public var payloadLengths: ClosedRange<Int> {
        switch self {
        case .header: 0...ContainerRecord.maxHeaderPayload
        case .chunk: 1...ContainerRecord.maxChunkPayload
        case .lz4Chunk: (ContainerRecord.lz4SizeByteCount + 1)...ContainerRecord.maxChunkPayload
        case .zeroRun: 8...8
        case .end: 0...ContainerRecord.maxEndPayload
        }
    }
}

/// The framing every record of a transfer container shares: `[u8 kind][u32 length][u32 CRC32C][payload]`,
/// little-endian, where the CRC32C covers the kind and length bytes and then the payload.
public enum ContainerRecord {
    /// The kind, length and checksum before each payload.
    public static let prefixByteCount = 9

    /// The largest header payload: the size of a MESSAGE frame, which an `EntryHeader` was sized against.
    public static let maxHeaderPayload = WireConstants.maxControlPayload

    /// The largest chunk payload, and the most bytes one LZ4 chunk may decompress to: one raw DATA frame.
    public static let maxChunkPayload = WireConstants.maxRawDataPayload

    /// The largest end payload. An `EndRecord` is two varints, at most 22 bytes.
    public static let maxEndPayload = 64

    /// The bytes before an LZ4 chunk's block that state its decompressed size.
    public static let lz4SizeByteCount = 4

    /// Appends one record of `kind` holding `payload` to `container`.
    ///
    /// - Parameters:
    ///   - kind: The record's kind.
    ///   - payload: The payload, whose length `kind.payloadLengths` must admit.
    ///   - container: The bytes to append to.
    public static func append(_ kind: ContainerRecordKind, payload: Data, to container: inout Data) {
        precondition(kind.payloadLengths.contains(payload.count), "a \(kind) payload of \(payload.count) bytes")
        let length = UInt32(payload.count)
        let prefix = prefixBytes(kind: kind.rawValue, length: length)
        container.append(contentsOf: prefix)
        container.append(contentsOf: littleEndianBytes(checksum(kind: kind.rawValue, length: length, payload: payload)))
        container.append(payload)
    }

    /// The CRC32C of a record: its kind byte, its length, then its payload.
    static func checksum(kind: UInt8, length: UInt32, payload: Data) -> UInt32 {
        var crc = CRC32C()
        crc.update(prefixBytes(kind: kind, length: length))
        crc.update(payload)
        return crc.value
    }

    private static func prefixBytes(kind: UInt8, length: UInt32) -> [UInt8] {
        [kind] + littleEndianBytes(length)
    }
}

func littleEndianBytes<Integer: FixedWidthInteger>(_ value: Integer) -> [UInt8] {
    (0..<(Integer.bitWidth / 8)).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
}

/// The little-endian integer at `offset` bytes into `bytes`, which must hold it.
func littleEndian<Integer: FixedWidthInteger>(_: Integer.Type, in bytes: Data, at offset: Int) -> Integer {
    var value: Integer = 0
    let start = bytes.startIndex + offset
    for index in 0..<(Integer.bitWidth / 8) {
        value |= Integer(bytes[start + index]) << (index * 8)
    }
    return value
}
