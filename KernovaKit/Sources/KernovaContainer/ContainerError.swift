import KernovaWire

/// Why a container was refused, by its decoder or by the encoder producing it.
public enum ContainerError: Error, Equatable, Sendable {
    // MARK: Framing

    /// A record's first byte names no `ContainerRecordKind`.
    case unknownRecordKind(UInt8)
    /// A record declares a payload length its kind does not admit.
    case recordLengthOutOfRange(kind: ContainerRecordKind, length: Int)
    /// A record's CRC32C does not match its kind, length and payload.
    case checksumMismatch(kind: ContainerRecordKind)
    /// A header record's payload is not an `EntryHeader`.
    case headerUndecodable
    /// An end record's payload is not an `EndRecord`.
    case endUndecodable
    /// Bytes follow the end record.
    case bytesAfterEnd
    /// The input ended before the end record.
    case truncated

    // MARK: Entries

    /// An entry's type is unspecified or unknown.
    case unknownEntryType
    /// The first entry is not at depth 0.
    case firstEntryNotAtRoot(depth: UInt32)
    /// An entry other than the first is at depth 0: a container holds one representation.
    case secondRootEntry
    /// An entry's depth is greater than the number of directories it lies inside.
    case depthBeyondParent(depth: UInt32, enteredDirectories: Int)
    /// An entry's name is empty, `.` or `..`, longer than 255 bytes, or holds `/` or NUL.
    case invalidName
    /// A DATA entry has a name or metadata: it is an INLINE representation's bytes and nothing else.
    case dataEntryNotBare
    /// An entry's storage is missing where its type needs one, present where it takes none, or decmpfs on
    /// an entry that is not a regular file.
    case storageNotAllowed(EntryHeader.TypeEnum)
    /// An entry's storage is LZ4, which the pull did not list among its codecs.
    case lz4NotAccepted
    /// A symlink's target is empty or holds NUL.
    case invalidSymlinkTarget
    /// An entry lists `com.apple.decmpfs` among its extended attributes rather than as its storage.
    case decmpfsAttributeOutsideStorage
    /// A decmpfs storage's attribute is not a well-formed `decmpfs_disk_header`.
    case malformedDecmpfsAttribute(DecmpfsHeaderError)
    /// A decmpfs storage's compression type is not one the pull accepted.
    case decmpfsTypeNotAccepted(UInt32)
    /// The entries' declared sizes total more than the pull's byte ceiling.
    case exceedsByteCeiling(declared: UInt64, ceiling: UInt64)

    // MARK: Chunks

    /// A header or end record arrives while the current entry still owes bytes.
    case entryIncomplete(remaining: UInt64)
    /// A chunk or zero run arrives with no entry owing bytes.
    case chunkOutsideEntry
    /// A zero run, or an LZ4 chunk, of no bytes.
    case emptyChunk
    /// A chunk carries more bytes than its entry still owes.
    case chunkPastEntrySize(count: UInt64, remaining: UInt64)
    /// An LZ4 chunk in an entry whose storage is not LZ4.
    case lz4ChunkOutsideLZ4Storage
    /// An LZ4 chunk's block is malformed or its declared size out of range; the range check comes before
    /// anything is allocated.
    case lz4(LZ4BlockError)

    // MARK: End

    /// The container ends before any entry.
    case noEntry
    /// The end record's counts are not the container's.
    case endCountsMismatch(stated: Counts, counted: Counts)

    /// A container's entry and byte counts.
    public struct Counts: Equatable, Sendable {
        /// Entries.
        public var entries: UInt64
        /// Bytes the entries' chunks carried, after decompression.
        public var bytes: UInt64

        /// Counts of `entries` and `bytes`.
        public init(entries: UInt64, bytes: UInt64) {
            self.entries = entries
            self.bytes = bytes
        }
    }

    /// The code a pull ends with when this refuses its container.
    public var errorCode: ErrorCode {
        switch self {
        case .exceedsByteCeiling: .tooLarge
        case .decmpfsTypeNotAccepted: .itemDecmpfsRefused
        default: .itemContainerMalformed
        }
    }
}
