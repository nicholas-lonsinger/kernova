#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// Why a `com.apple.decmpfs` attribute is not a well-formed `decmpfs_disk_header`.
public enum DecmpfsHeaderError: Error, Equatable, Sendable {
    /// The attribute is longer than `MAX_DECMPFS_XATTR_SIZE`.
    case tooLarge(byteCount: Int)
    /// The attribute is shorter than the header.
    case truncated(byteCount: Int)
    /// The header's magic is not `cmpf`.
    case badMagic(UInt32)
}

/// The header a `com.apple.decmpfs` attribute begins with: XNU's packed `decmpfs_disk_header`
/// (`bsd/sys/decmpfs.h`), a `UInt32` magic, a `UInt32` compression type and a `UInt64` size, little-endian.
/// The kernel acts on these fields, so they are the type and size a decmpfs entry has.
public struct DecmpfsHeader: Equatable, Sendable {
    /// `DECMPFS_MAGIC`, ASCII `cmpf` read as a little-endian `UInt32`.
    public static let magic: UInt32 = 0x636D_7066

    /// `MAX_DECMPFS_XATTR_SIZE`: the longest attribute the kernel reads.
    public static let maxAttributeByteCount = 3_802

    /// The header's size: magic, type and size.
    public static let byteCount = 16

    /// Where a decmpfs type keeps the compressed bytes.
    public enum Payload: Sendable, Equatable {
        /// In the attribute, after its 16-byte header.
        case attribute
        /// In the resource fork.
        case resourceFork
    }

    /// Where `type` keeps its compressed bytes, or nil for a type of no known layout.
    ///
    /// Types 1, 3, 7, 9, 11, 13 and 15 keep them in the attribute; types 4, 8, 10, 12, 14 and 16 in the resource
    /// fork (docs/research/2026-10-24-decmpfs-pass-through.md: finding 2 for types 4, 7, 8, 9 and 14 decoded
    /// from real files, finding 7 for files of types 3, 7, 9, 11, 13 and 15 built in the attribute and 8, 10, 12,
    /// 14 and 16 built in the fork, all read back, and for type 1, which XNU itself registers as raw data in the
    /// attribute). XNU's `bsd/sys/decmpfs.h` names no other layout; the decoders are AppleFSCompression's.
    public static func payload(of type: UInt32) -> Payload? {
        switch type {
        case 1, 3, 7, 9, 11, 13, 15: .attribute
        case 4, 8, 10, 12, 14, 16: .resourceFork
        default: nil
        }
    }

    /// The decmpfs compression type, `compression_type`.
    public var compressionType: UInt32

    /// The file's logical size, `uncompressed_size`.
    public var uncompressedSize: UInt64

    /// The header `attribute` begins with.
    ///
    /// - Parameter attribute: A `com.apple.decmpfs` attribute's value.
    /// - Throws: `DecmpfsHeaderError` when the attribute is too long, too short for the header, or carries
    ///   the wrong magic.
    public init(attribute: Data) throws(DecmpfsHeaderError) {
        guard attribute.count <= Self.maxAttributeByteCount else { throw .tooLarge(byteCount: attribute.count) }
        guard attribute.count >= Self.byteCount else { throw .truncated(byteCount: attribute.count) }
        let magic = littleEndian(UInt32.self, in: attribute, at: 0)
        guard magic == Self.magic else { throw .badMagic(magic) }
        compressionType = littleEndian(UInt32.self, in: attribute, at: 4)
        uncompressedSize = littleEndian(UInt64.self, in: attribute, at: 8)
    }
}
