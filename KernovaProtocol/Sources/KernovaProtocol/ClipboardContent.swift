import CryptoKit
import Foundation

/// One logical clipboard payload: an ordered list of UTI-tagged
/// representations, mirroring the (type, data) pairs of a single
/// `NSPasteboardItem`.
///
/// Order is meaningful — it matches the source pasteboard's fidelity order
/// (richest representation first) and is preserved across the wire.
///
/// Equality is digest-based: a SHA-256 over a length-prefixed canonical
/// encoding of every (uti, data) pair, computed once at init. Dedup and
/// echo-suppression state can therefore retain the 32-byte `digest` instead
/// of a second copy of multi-megabyte payloads.
public struct ClipboardContent: Equatable, Sendable {
    /// One (type, data) pair of the payload.
    public struct Representation: Equatable, Sendable {
        /// Uniform Type Identifier naming the format.
        ///
        /// For example `"public.utf8-plain-text"` or `"public.png"`.
        /// Dynamic (`dyn.*`) identifiers pass through untouched so legacy
        /// pasteboard types round-trip exactly.
        public let uti: String

        /// The representation's raw bytes.
        public let data: Data

        /// Creates a representation from a UTI and its raw bytes.
        public init(uti: String, data: Data) {
            self.uti = uti
            self.data = data
        }
    }

    /// The UTI of UTF-8 plain text.
    ///
    /// The format shared with peers that predate UTI support; matches the
    /// raw value of `NSPasteboard.PasteboardType.string`.
    public static let utf8TextUTI = "public.utf8-plain-text"

    /// Content carrying no representations.
    ///
    /// Never offered to a peer.
    public static let empty = ClipboardContent(representations: [])

    /// Ordered representations, richest first.
    public let representations: [Representation]

    /// SHA-256 over a length-prefixed canonical encoding of `representations`.
    ///
    /// Stable across processes (used for echo suppression on both ends of
    /// the clipboard channel).
    public let digest: Data

    /// Creates content from ordered representations, computing the digest.
    public init(representations: [Representation]) {
        self.representations = representations
        self.digest = Self.computeDigest(of: representations)
    }

    /// Content holding a single UTF-8 plain-text representation.
    ///
    /// The empty string normalizes to `.empty` — "empty text" and "no
    /// content" are deliberately the same non-offerable value, resolved here
    /// once rather than at every call site.
    public init(text: String) {
        if text.isEmpty {
            self = .empty
        } else {
            self.init(representations: [
                Representation(uti: Self.utf8TextUTI, data: Data(text.utf8))
            ])
        }
    }

    /// `true` when there are no representations.
    public var isEmpty: Bool { representations.isEmpty }

    /// The UTF-8 plain-text representation decoded as a string, or `nil`
    /// when no such representation exists or its bytes are not valid UTF-8.
    public var text: String? {
        guard let representation = representations.first(where: { $0.uti == Self.utf8TextUTI })
        else { return nil }
        return String(data: representation.data, encoding: .utf8)
    }

    /// Sum of all representations' payload sizes in bytes.
    public var totalByteCount: Int {
        representations.reduce(0) { $0 + $1.data.count }
    }

    /// Digest comparison — equivalent to full structural equality (SHA-256
    /// collision resistance) at a constant 32-byte cost.
    public static func == (lhs: ClipboardContent, rhs: ClipboardContent) -> Bool {
        lhs.digest == rhs.digest
    }

    /// Hashes the representations with a length-prefixed canonical encoding.
    ///
    /// For each representation: the big-endian `UInt64` byte count of the
    /// UTI, the UTI bytes, the big-endian `UInt64` byte count of the data,
    /// then the data bytes. Length prefixes prevent collisions from shifting
    /// bytes across the uti/data or representation boundaries.
    private static func computeDigest(of representations: [Representation]) -> Data {
        var hasher = SHA256()
        for representation in representations {
            withUnsafeBytes(of: UInt64(representation.uti.utf8.count).bigEndian) {
                hasher.update(bufferPointer: $0)
            }
            hasher.update(data: Data(representation.uti.utf8))
            withUnsafeBytes(of: UInt64(representation.data.count).bigEndian) {
                hasher.update(bufferPointer: $0)
            }
            hasher.update(data: representation.data)
        }
        return Data(hasher.finalize())
    }
}

// MARK: - Proto bridging

extension ClipboardContent {
    /// Builds content from the representations of an inbound
    /// `ClipboardData` frame, preserving order.
    public init(protoRepresentations: [Kernova_V1_ClipboardRepresentation]) {
        self.init(
            representations: protoRepresentations.map {
                Representation(uti: $0.uti, data: $0.data)
            }
        )
    }

    /// The representations encoded for an outbound `ClipboardData` frame,
    /// preserving order.
    public var protoRepresentations: [Kernova_V1_ClipboardRepresentation] {
        representations.map { representation in
            Kernova_V1_ClipboardRepresentation.with {
                $0.uti = representation.uti
                $0.data = representation.data
            }
        }
    }
}
