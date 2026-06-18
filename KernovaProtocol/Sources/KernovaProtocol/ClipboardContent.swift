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
        /// Where a representation's bytes live.
        ///
        /// Streaming chooses its sink by this, not by size: an `.inMemory`
        /// representation reassembles in RAM (the pasteboard API needs the
        /// bytes resident, and the consuming app holds them in RAM too, so RAM
        /// is the natural bound); a `.file` representation is streamed to/from
        /// disk in chunks and never read whole.
        public enum Source: Equatable, Sendable {
            /// Bytes resident in memory — text, RTF, inline images, small
            /// payloads.
            case inMemory(Data)

            /// Bytes on disk, never loaded whole. `byteCount` is a stat result;
            /// `sha256` is the digest the stream computed over the bytes, or
            /// `nil` before a transfer has produced one (e.g. offer-time on the
            /// sender side, where the file is named but not yet read).
            case file(url: URL, byteCount: Int, sha256: Data?)

            /// A representation a peer has offered but whose bytes have not been
            /// pulled — the lazy-receive placeholder. Carries only the advertised
            /// `byteCount`; `inMemoryData` and `fileURL` are `nil` until a
            /// `ClipboardRequest` streams the bytes and the rep is replaced by
            /// `.inMemory`/`.file`. Used host-side to render a metadata-only
            /// preview (type · size · filename) without pulling, and is never
            /// handed to the sender.
            case pendingRemote(byteCount: Int)
        }

        /// Uniform Type Identifier naming the format.
        ///
        /// For example `"public.utf8-plain-text"` or `"public.png"`.
        /// Dynamic (`dyn.*`) identifiers pass through untouched so legacy
        /// pasteboard types round-trip exactly.
        public let uti: String

        /// Where the representation's bytes live (memory or disk).
        public let source: Source

        /// Suggested filename when this representation is a file payload.
        ///
        /// A copied/dragged image file → `"photo.png"`; `""` for inline-only
        /// content. A receiver with a non-empty filename streams the bytes to a
        /// local temp file and offers its file URL so a Finder paste creates the
        /// file. Deliberately **not** part of the digest.
        public let filename: String

        /// Creates a representation from an explicit byte source.
        public init(uti: String, source: Source, filename: String = "") {
            self.uti = uti
            self.source = source
            self.filename = filename
        }

        /// Creates an in-memory representation from a UTI and its raw bytes,
        /// optionally tagged with a suggested filename for file payloads.
        ///
        /// The common case for text, RTF, inline images, and small payloads.
        public init(uti: String, data: Data, filename: String = "") {
            self.init(uti: uti, source: .inMemory(data), filename: filename)
        }

        /// Creates a disk-backed representation from a file URL and its stat'd
        /// size — the bytes are streamed on demand, never read to build it.
        ///
        /// `sha256` is the byte digest once a transfer has computed it (reused
        /// as the content digest so a multi-GB file is never re-hashed); `nil`
        /// when the file is only named (offer time on the sender side).
        public init(
            uti: String, fileURL: URL, byteCount: Int, sha256: Data? = nil, filename: String
        ) {
            self.init(
                uti: uti,
                source: .file(url: fileURL, byteCount: byteCount, sha256: sha256),
                filename: filename
            )
        }

        /// Creates a metadata-only placeholder for a peer-offered representation
        /// whose bytes have not been pulled — the lazy-receive preview, replaced
        /// by `.inMemory`/`.file` once a `ClipboardRequest` streams the bytes.
        public init(pendingRemoteUTI uti: String, byteCount: Int, filename: String = "") {
            self.init(uti: uti, source: .pendingRemote(byteCount: byteCount), filename: filename)
        }

        /// Size of the representation's bytes, without loading a file-backed
        /// payload.
        public var byteCount: Int {
            switch source {
            case .inMemory(let data): return data.count
            case .file(_, let byteCount, _): return byteCount
            case .pendingRemote(let byteCount): return byteCount
            }
        }

        /// `true` for a not-yet-pulled remote representation — no resident bytes
        /// and no on-disk file, only advertised metadata.
        public var isPendingRemote: Bool {
            if case .pendingRemote = source { return true }
            return false
        }

        /// The in-memory bytes, or `nil` for a file-backed representation
        /// (whose bytes must be streamed rather than read whole).
        public var inMemoryData: Data? {
            if case .inMemory(let data) = source { return data }
            return nil
        }

        /// The on-disk URL for a file-backed representation, or `nil` when the
        /// bytes are in memory.
        public var fileURL: URL? {
            if case .file(let url, _, _) = source { return url }
            return nil
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

    /// Creates content with an already-computed digest.
    ///
    /// Backs `makeOffActor(representations:)` so the O(payload) hash can run on
    /// a background executor; the result is assembled here without re-hashing.
    private init(representations: [Representation], precomputedDigest: Data) {
        self.representations = representations
        self.digest = precomputedDigest
    }

    /// Creates content from ordered representations off the caller's actor.
    ///
    /// The synchronous `init` computes the SHA-256 `digest` over every byte of
    /// every representation — fine for small payloads, but a multi-hundred-
    /// millisecond stall on the `@MainActor` (host) or the guest agent's main
    /// run loop for a 100 MiB clipboard file. This `async` factory is not
    /// actor-isolated, so awaiting it from those contexts runs the hash on the
    /// cooperative executor and resumes with the finished, `Sendable` value.
    /// Use it on the large-payload create/receive paths; keep the synchronous
    /// `init` for small, latency-insensitive content.
    public static func makeOffActor(
        representations: [Representation]
    ) async -> ClipboardContent {
        ClipboardContent(
            representations: representations,
            precomputedDigest: computeDigest(of: representations)
        )
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
    ///
    /// Text is always in-memory; a file-backed representation (whose bytes are
    /// not resident) yields `nil` here rather than triggering a disk read.
    public var text: String? {
        guard
            let representation = representations.first(where: { $0.uti == Self.utf8TextUTI }),
            let data = representation.inMemoryData
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Sum of all representations' payload sizes in bytes, without loading any
    /// file-backed payload.
    public var totalByteCount: Int {
        representations.reduce(0) { $0 + $1.byteCount }
    }

    /// Digest comparison — equivalent to full structural equality (SHA-256
    /// collision resistance) at a constant 32-byte cost.
    public static func == (lhs: ClipboardContent, rhs: ClipboardContent) -> Bool {
        lhs.digest == rhs.digest
    }

    /// Hashes the representations with a length-prefixed canonical encoding.
    ///
    /// For each representation: the big-endian `UInt64` byte count of the UTI,
    /// the UTI bytes, then a byte-stable digest of its payload. For an
    /// `.inMemory` representation that digest is the length-prefixed bytes
    /// themselves (so an all-inline payload hashes identically to the
    /// pre-streaming encoding); for a `.file` representation it is the SHA-256
    /// the stream computed over the bytes — never the file path, name, or mtime
    /// (those differ between the host and guest temp copies and would break
    /// cross-process echo suppression). A file representation whose digest is
    /// not yet known (offer time on the sender side) folds in only its byte
    /// count as a placeholder; such representations are echo-suppressed by
    /// change-count and staging-path guards rather than by digest equality.
    /// Length prefixes prevent collisions from shifting bytes across the
    /// uti/payload or representation boundaries; a one-byte source tag separates
    /// the inline-bytes and file-digest domains so the two can never alias.
    private static func computeDigest(of representations: [Representation]) -> Data {
        var hasher = SHA256()
        for representation in representations {
            withUnsafeBytes(of: UInt64(representation.uti.utf8.count).bigEndian) {
                hasher.update(bufferPointer: $0)
            }
            hasher.update(data: Data(representation.uti.utf8))
            // A one-byte domain tag separates the inline-bytes domain from the
            // file-digest domain, so a 32-byte inline payload can never alias a
            // file rep's SHA-256 under the same UTI. [N1]
            switch representation.source {
            case .inMemory(let data):
                hasher.update(data: Data([0]))
                withUnsafeBytes(of: UInt64(data.count).bigEndian) {
                    hasher.update(bufferPointer: $0)
                }
                hasher.update(data: data)
            case .file(_, let byteCount, let sha256):
                if let sha256 {
                    hasher.update(data: Data([1]))
                    withUnsafeBytes(of: UInt64(sha256.count).bigEndian) {
                        hasher.update(bufferPointer: $0)
                    }
                    hasher.update(data: sha256)
                } else {
                    // Placeholder identity before the bytes have been streamed.
                    hasher.update(data: Data([2]))
                    withUnsafeBytes(of: UInt64(byteCount).bigEndian) {
                        hasher.update(bufferPointer: $0)
                    }
                }
            case .pendingRemote(let byteCount):
                // Distinct domain tag (3) so a metadata-only placeholder hashes
                // deterministically AND is never digest-equal to its eventual
                // materialized (.inMemory/.file) form. Echo suppression for these
                // relies on change-count/identity guards, not digest equality.
                hasher.update(data: Data([3]))
                withUnsafeBytes(of: UInt64(byteCount).bigEndian) {
                    hasher.update(bufferPointer: $0)
                }
            }
        }
        return Data(hasher.finalize())
    }
}
