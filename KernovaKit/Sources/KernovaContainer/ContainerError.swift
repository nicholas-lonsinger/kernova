#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

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
    /// Anything follows the end.
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
    /// An entry event's depth is less than the directories entered: the ones it lies outside were not left.
    case directoryNotLeft(depth: UInt32, enteredDirectories: Int)
    /// An entry event creates another type than its header's: a directory's header on `beginFile`, say.
    case eventTypeMismatch(EntryHeader.TypeEnum)
    /// An event its place in the stream does not admit: a leave with no directory entered, a fork's start or a
    /// file's finish with no file open or a fork already started, or the end inside a directory.
    case eventOutOfOrder
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
    /// The first entry's type is not the one the pulled representation's storage sends.
    case rootTypeMismatch(EntryHeader.TypeEnum, expected: Representation.Storage)
    /// A DATA entry other than the first: DATA is only ever an INLINE representation's sole entry.
    case dataEntryNotRoot
    /// An entry's mode has bits above `07777`.
    case modeOutOfRange(UInt32)
    /// An entry's `darwin_flags` hold these bits, which the format does not carry.
    case darwinFlagsNotAllowed(UInt32)
    /// A time's nanoseconds are above 999,999,999.
    case nanosecondsOutOfRange(UInt32)
    /// An extended attribute's name is empty, longer than 255 bytes, or holds NUL.
    case invalidXattrName
    /// An extended attribute the format does not carry: not Finder tags or a `user.` attribute. A resource
    /// fork is one: it travels as the entry's own chunks.
    case xattrNotAllowed(Data)
    /// Two of an entry's extended attributes share a name.
    case duplicateXattrName(Data)
    /// A header or end record holds a field the current schema does not define.
    case unknownFields
    /// An entry other than a regular file declares a resource fork.
    case resourceForkNotAllowed(EntryHeader.TypeEnum)
    /// A file's data is larger than any file a POSIX system holds, `Int64.max` bytes.
    case fileTooLarge(UInt64)
    /// A resource fork is larger than `ValidatedEntry.maxResourceForkByteCount`.
    case resourceForkTooLarge(UInt64)
    /// A decmpfs storage's attribute is not a well-formed `decmpfs_disk_header`.
    case malformedDecmpfsAttribute(DecmpfsHeaderError)
    /// A decmpfs storage's compression type has no known layout (`DecmpfsHeader.payload(of:)`).
    case decmpfsTypeUnknown(UInt32)
    /// A decmpfs storage carries no compressed bytes where its type keeps them: nothing past the attribute's
    /// header, or no resource fork.
    case decmpfsPayloadMissing(UInt32)
    /// A decmpfs storage's compression type is not one the pull accepted.
    case decmpfsTypeNotAccepted(UInt32)
    /// The entries' declared sizes total more than the pull's byte ceiling.
    case exceedsByteCeiling(declared: UInt64, ceiling: UInt64)

    // MARK: Chunks

    /// An entry, a leave or the end arrives while the current file still owes bytes, a resource fork starts
    /// before the data has all its bytes, or a file finishes short.
    case entryIncomplete(remaining: UInt64)
    /// A chunk, zero run, or `bytes` or `zeros` event arrives with no file open.
    case chunkOutsideEntry
    /// A file's resource fork begins, but its header declares none.
    case resourceForkUndeclared
    /// A zero run, an LZ4 chunk, or a `bytes` or `zeros` event, of no bytes.
    case emptyChunk
    /// A chunk carries more bytes than its entry's data, or its resource fork, still owes.
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
