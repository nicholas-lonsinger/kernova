import CryptoKit
import Foundation

/// One logical clipboard payload: an ordered list of UTI-tagged representations,
/// mirroring the (type, data) pairs of a single `NSPasteboardItem`.
///
/// Order is meaningful — richest representation first, preserved across the wire.
/// A representation with an empty `filename` is an alternative encoding of one
/// *inline* item; each with a non-empty `filename` is a distinct *file* the
/// receiver materializes. Equality is digest-based (SHA-256 computed once at
/// init), so dedup state can retain the 32-byte `digest`, not the payload.
public struct ClipboardContent: Equatable, Sendable {
    /// One (type, data) pair of the payload.
    public struct Representation: Equatable, Sendable {
        /// Where a representation's bytes live.
        ///
        /// Streaming chooses its sink by this, not by size: `.inMemory`
        /// reassembles in RAM, `.file` streams in chunks and is never read whole.
        public enum Source: Equatable, Sendable {
            /// Bytes resident in memory — text, RTF, inline images, small
            /// payloads.
            case inMemory(Data)

            /// Bytes on disk, never loaded whole. `byteCount` is a stat result;
            /// `sha256` is the digest the stream computed over the bytes, or
            /// `nil` before a transfer has produced one (offer time on the sender
            /// side, where the file is named but not yet read).
            case file(url: URL, byteCount: Int, sha256: Data?)

            /// A representation a peer has offered but whose bytes have not been
            /// pulled. Carries only the advertised `byteCount`; replaced by
            /// `.inMemory`/`.file` once a `ClipboardRequest` streams the bytes.
            /// Renders a metadata-only preview host-side, and is never handed to
            /// the sender.
            case pendingRemote(byteCount: Int)

            /// A copied **source directory** whose tree is walked and streamed on
            /// demand rather than archived at copy time. Producer side only, and
            /// refused by the stream sender: the producer walks it for a listing,
            /// opens a confined child, or archives it at *request* time.
            case directory(url: URL, estimatedByteCount: Int)
        }

        /// Uniform Type Identifier naming the format.
        ///
        /// Dynamic (`dyn.*`) identifiers pass through untouched so legacy
        /// pasteboard types round-trip exactly.
        public let uti: String

        /// Where the representation's bytes live (memory or disk).
        public let source: Source

        /// Suggested filename when this representation is a file payload; `""`
        /// for inline-only content.
        ///
        /// A receiver with a non-empty filename streams the bytes to a local temp
        /// file and offers its file URL, so a Finder paste creates the file.
        /// **Part of the digest**, so two files that share bytes+UTI but differ
        /// only by name stay distinguishable.
        public let filename: String

        /// `true` when this file representation is a *directory* (folder, or an
        /// OS package such as `.app`/`.rtfd`) whose bytes are an in-process
        /// AppleArchive of the tree rather than a single file's bytes.
        ///
        /// The receiver extracts the archive and offers the folder's URL. Implies
        /// a non-empty `filename` and a file-backed source. **Excluded from the
        /// digest**: the archive's SHA-256 and the folded `filename` already
        /// identify the content, and the receiver re-applies it from the offer.
        public let isDirectory: Bool

        /// Creates a representation from an explicit byte source.
        public init(
            uti: String, source: Source, filename: String = "", isDirectory: Bool = false
        ) {
            self.uti = uti
            self.source = source
            self.filename = filename
            self.isDirectory = isDirectory
        }

        /// Creates an in-memory representation from a UTI and its raw bytes,
        /// optionally tagged with a suggested filename for file payloads.
        public init(uti: String, data: Data, filename: String = "") {
            self.init(uti: uti, source: .inMemory(data), filename: filename)
        }

        /// Creates a disk-backed representation from a file URL and its stat'd
        /// size — the bytes are streamed on demand, never read to build it.
        ///
        /// `sha256` is the byte digest once a transfer has computed it — reused as
        /// the content digest so a multi-GB file is never re-hashed — and `nil`
        /// when the file is only named. For `isDirectory` the URL is the folder
        /// itself and `byteCount` its tree, while `sha256` stays the digest of
        /// the archive that carried it over the wire.
        public init(
            uti: String, fileURL: URL, byteCount: Int, sha256: Data? = nil, filename: String,
            isDirectory: Bool = false
        ) {
            self.init(
                uti: uti,
                source: .file(url: fileURL, byteCount: byteCount, sha256: sha256),
                filename: filename,
                isDirectory: isDirectory
            )
        }

        /// Creates a metadata-only placeholder for a peer-offered representation
        /// whose bytes have not been pulled.
        public init(
            pendingRemoteUTI uti: String, byteCount: Int, filename: String = "",
            isDirectory: Bool = false
        ) {
            self.init(
                uti: uti, source: .pendingRemote(byteCount: byteCount), filename: filename,
                isDirectory: isDirectory)
        }

        /// Creates a producer-side directory representation backed by its source
        /// folder.
        ///
        /// No archive is built: the tree is walked and streamed on demand, with
        /// `estimatedByteCount` a stat-walk estimate for the offer. `uti` is the
        /// folder's content type — a package UTI for a bundle, so the pasted tree
        /// opens as a package.
        public init(
            directorySourceURL url: URL, estimatedByteCount: Int, filename: String,
            uti: String = ClipboardArchive.directoryUTI
        ) {
            self.init(
                uti: uti,
                source: .directory(url: url, estimatedByteCount: estimatedByteCount),
                filename: filename, isDirectory: true)
        }

        /// Size of the representation's bytes, without loading a file-backed
        /// payload.
        public var byteCount: Int {
            switch source {
            case .inMemory(let data): return data.count
            case .file(_, let byteCount, _): return byteCount
            case .pendingRemote(let byteCount): return byteCount
            case .directory(_, let byteCount): return byteCount
            }
        }

        /// `true` for a not-yet-pulled remote representation — no resident bytes
        /// and no on-disk file, only advertised metadata.
        public var isPendingRemote: Bool {
            if case .pendingRemote = source { return true }
            return false
        }

        /// The source folder URL for a producer-side `.directory` representation,
        /// or `nil` otherwise.
        public var directorySourceURL: URL? {
            if case .directory(let url, _) = source { return url }
            return nil
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
    /// Matches the raw value of `NSPasteboard.PasteboardType.string`.
    public static let utf8TextUTI = "public.utf8-plain-text"

    /// Content carrying no representations.
    ///
    /// Never offered to a peer.
    public static let empty = ClipboardContent(representations: [])

    /// Maximum representations an offer may advertise.
    ///
    /// A `transfer_id` packs the representation index into its low 16 bits
    /// (`(generation << 16) | repIndex`), so an index past `0xFFFF` would alias
    /// a lower one. Offer builders truncate to this and log.
    public static let maxOfferableRepresentations = 0xFFFF

    /// Ordered representations, richest first.
    public let representations: [Representation]

    /// `true` when the source pasteboard marked this snapshot confidential
    /// (`org.nspasteboard.ConcealedType`, the convention password managers use).
    ///
    /// The content still syncs so it can be pasted into the peer; the host
    /// clipboard window hides it behind a placeholder rather than rendering the
    /// secret. **Excluded from the digest** — it changes how content is
    /// *displayed*, not its identity, so two snapshots with the same bytes stay
    /// echo-suppressed regardless of the flag.
    public let isConcealed: Bool

    /// SHA-256 over a length-prefixed canonical encoding of `representations`.
    ///
    /// Stable across processes (used for echo suppression on both ends of
    /// the clipboard channel).
    public let digest: Data

    /// Creates content from ordered representations, computing the digest.
    public init(representations: [Representation], isConcealed: Bool = false) {
        self.representations = representations
        self.isConcealed = isConcealed
        self.digest = Self.computeDigest(of: representations)
    }

    /// Creates content with an already-computed digest.
    ///
    /// Backs the digest-reusing factories so the O(payload) hash is paid at most once.
    private init(representations: [Representation], isConcealed: Bool, precomputedDigest: Data) {
        self.representations = representations
        self.isConcealed = isConcealed
        self.digest = precomputedDigest
    }

    /// Creates content from ordered representations off the caller's actor.
    ///
    /// The synchronous `init` hashes every byte of every representation — a
    /// multi-hundred-millisecond stall on the `@MainActor` or the guest agent's
    /// main run loop for a 100 MiB payload. This factory is not actor-isolated, so
    /// awaiting it runs the hash on the cooperative executor. Use it on the
    /// large-payload create/receive paths.
    public static func makeOffActor(
        representations: [Representation], isConcealed: Bool = false
    ) async -> ClipboardContent {
        ClipboardContent(
            representations: representations,
            isConcealed: isConcealed,
            precomputedDigest: computeDigest(of: representations)
        )
    }

    /// Returns a copy with `isConcealed` set, **without** recomputing the digest.
    ///
    /// The flag is excluded from the digest, so re-stamping it — as the snapshot
    /// path does after `ClipboardSnapshotPolicy.evaluate` — must not pay a second
    /// SHA-256 over a large payload. Returns `self` when the flag already matches.
    public func withConcealed(_ concealed: Bool) -> ClipboardContent {
        guard concealed != isConcealed else { return self }
        return ClipboardContent(
            representations: representations, isConcealed: concealed, precomputedDigest: digest)
    }

    /// Content holding a single UTF-8 plain-text representation.
    ///
    /// The empty string normalizes to `.empty`: "empty text" and "no content" are
    /// deliberately the same non-offerable value, resolved here rather than at
    /// every call site.
    public init(text: String, isConcealed: Bool = false) {
        if text.isEmpty {
            self = .empty
        } else {
            self.init(
                representations: [
                    Representation(uti: Self.utf8TextUTI, data: Data(text.utf8))
                ], isConcealed: isConcealed)
        }
    }

    /// Content holding a single UTF-8 plain-text representation, built off the
    /// caller's actor.
    ///
    /// The off-actor twin of `init(text:)` for the editor commit path: a large
    /// pasted-then-edited buffer must not pay the UTF-8 copy *or* the SHA-256 on
    /// the `@MainActor` per keystroke (CLIPBOARD.md §8). The empty string
    /// normalizes to `.empty`, identically to `init(text:)`.
    public static func makeOffActor(text: String, isConcealed: Bool = false) async -> ClipboardContent {
        guard !text.isEmpty else { return .empty }
        return await makeOffActor(
            representations: [Representation(uti: utf8TextUTI, data: Data(text.utf8))],
            isConcealed: isConcealed)
    }

    /// `true` when there are no representations.
    public var isEmpty: Bool { representations.isEmpty }

    /// The UTF-8 plain-text representation decoded as a string, or `nil`
    /// when no such representation exists or its bytes are not valid UTF-8.
    ///
    /// Text is always in-memory; a file-backed representation yields `nil` here
    /// rather than triggering a disk read.
    public var text: String? {
        guard
            let representation = representations.first(where: { $0.uti == Self.utf8TextUTI }),
            let data = representation.inMemoryData
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Sum of all representations' payload sizes in bytes, without loading any
    /// file-backed payload.
    ///
    /// Saturates at `Int.max`: a peer-declared size reaches this sum.
    public var totalByteCount: Int {
        representations.reduce(0) { $0.saturatingAdding($1.byteCount) }
    }

    /// Caps the representation list to `maxOfferableRepresentations`.
    ///
    /// Returns the content unchanged in the common case (no recompute);
    /// `truncatedFrom` is the original representation count when truncation
    /// happened — so a caller can log it — and `nil` otherwise.
    public func cappedToOfferLimit() -> (content: ClipboardContent, truncatedFrom: Int?) {
        guard representations.count > Self.maxOfferableRepresentations else {
            return (self, nil)
        }
        return (
            ClipboardContent(
                representations: Array(representations.prefix(Self.maxOfferableRepresentations)),
                isConcealed: isConcealed),
            representations.count
        )
    }

    /// Digest comparison — equivalent to full structural equality (SHA-256
    /// collision resistance) at a constant 32-byte cost.
    public static func == (lhs: ClipboardContent, rhs: ClipboardContent) -> Bool {
        lhs.digest == rhs.digest
    }

    /// Hashes the representations with a length-prefixed canonical encoding.
    ///
    /// Per representation: length-prefixed UTI, length-prefixed `filename`, a
    /// one-byte source tag, then a byte-stable payload digest — the inline bytes,
    /// or the SHA-256 the stream computed for a file. The `filename` is folded in so
    /// `[a.bin, b.bin] → [a.bin, c.bin]` with byte-identical b/c isn't silently
    /// echo-suppressed. The file *path* and mtime are never hashed: they differ
    /// between host and guest temp copies and would break echo suppression.
    private static func computeDigest(of representations: [Representation]) -> Data {
        var hasher = SHA256()
        for representation in representations {
            withUnsafeBytes(of: UInt64(representation.uti.utf8.count).bigEndian) {
                hasher.update(bufferPointer: $0)
            }
            hasher.update(data: Data(representation.uti.utf8))
            let filenameBytes = Data(representation.filename.utf8)
            withUnsafeBytes(of: UInt64(filenameBytes.count).bigEndian) {
                hasher.update(bufferPointer: $0)
            }
            hasher.update(data: filenameBytes)
            // The one-byte domain tag keeps a 32-byte inline payload from aliasing
            // a file rep's SHA-256 under the same UTI.
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
                // A metadata-only placeholder is never digest-equal to its eventual
                // materialized form; echo suppression for these relies on
                // change-count/identity guards, not digest equality.
                hasher.update(data: Data([3]))
                withUnsafeBytes(of: UInt64(byteCount).bigEndian) {
                    hasher.update(bufferPointer: $0)
                }
            case .directory(_, let byteCount):
                // A producer-side source directory is identified by its folded
                // folder name plus this estimate — stable per poll tick, so the
                // producer's own offer dedup works. Not cross-process matched.
                hasher.update(data: Data([4]))
                withUnsafeBytes(of: UInt64(byteCount).bigEndian) {
                    hasher.update(bufferPointer: $0)
                }
            }
        }
        return Data(hasher.finalize())
    }
}
