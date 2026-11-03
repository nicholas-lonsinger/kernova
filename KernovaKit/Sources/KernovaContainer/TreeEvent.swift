#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaWire

/// One step of building a tree, in depth-first pre-order: what a tree writer consumes, whichever format
/// produced it. A file's events are `beginFile`, its data's `bytes` and `zeros` in order, then — when its
/// header declares a resource fork — `resourceFork` and the fork's `bytes` and `zeros`, then `finishFile`;
/// every `enterDirectory` is matched by one `leaveDirectory` before `end`.
public enum TreeEvent: Equatable, Sendable {
    /// Create the directory `header` describes in the current directory, and make it current.
    case enterDirectory(EntryHeader)
    /// Create the regular file or INLINE data `header` describes. Its data's bytes follow; decmpfs storage
    /// has none.
    case beginFile(EntryHeader)
    /// The current file's data has all its bytes; the `bytes` and `zeros` that follow are its resource
    /// fork's.
    case resourceFork
    /// The next bytes of the current file's data, or of its resource fork once `resourceFork` came.
    case bytes(Data)
    /// The next bytes of the current file's data or resource fork, all zero.
    case zeros(UInt64)
    /// The current file has all its bytes.
    case finishFile
    /// Create the symlink `header` describes in the current directory, never following it.
    case symlink(EntryHeader)
    /// Leave the current directory; its parent is current again.
    case leaveDirectory
    /// The end record arrived and its counts match. Bytes after it may not have been seen yet, so the tree
    /// is not whole until `ContainerDecoder.finish()` returns: commit nothing before then.
    case end
}

/// What the pull's destination accepts, which a container is held to on both sides.
public struct ContainerAcceptance: Equatable, Sendable {
    /// The most logical bytes the entries may land, each entry's `ValidatedEntry.landedByteCount`.
    public var byteCeiling: UInt64
    /// The decmpfs compression types the destination lands as they are.
    public var decmpfsTypes: Set<UInt32>
    /// Whether chunks may be LZ4 blocks.
    public var acceptsLZ4: Bool
    /// The pulled representation's storage, which fixes the root entry's type: DATA for INLINE, FILE for
    /// FILE, DIRECTORY for FOLDER.
    public var storage: Representation.Storage

    /// An acceptance of the given limits.
    ///
    /// - Parameters:
    ///   - storage: The pulled representation's storage.
    ///   - byteCeiling: The most logical bytes the entries may land.
    ///   - decmpfsTypes: The decmpfs compression types the destination lands as they are.
    ///   - acceptsLZ4: Whether chunks may be LZ4 blocks.
    public init(
        storage: Representation.Storage, byteCeiling: UInt64, decmpfsTypes: Set<UInt32>, acceptsLZ4: Bool
    ) {
        self.storage = storage
        self.byteCeiling = byteCeiling
        self.decmpfsTypes = decmpfsTypes
        self.acceptsLZ4 = acceptsLZ4
    }

    /// What `pull` accepts, for a representation of `storage`.
    ///
    /// - Parameters:
    ///   - pull: The pull.
    ///   - storage: The storage of the representation it names.
    public init(_ pull: PullRequest, storage: Representation.Storage) {
        self.init(
            storage: storage, byteCeiling: pull.byteCeiling, decmpfsTypes: Set(pull.decmpfsTypes),
            acceptsLZ4: pull.codecs.contains(.lz4))
    }

    /// The rules of what lands that every consumer of entries holds `entry` to, after entries that landed
    /// `landed` bytes: its decmpfs type is one this acceptance lists, and its landed bytes keep the total
    /// within the byte ceiling.
    ///
    /// - Parameters:
    ///   - entry: The entry.
    ///   - landed: The logical bytes the entries before it land.
    /// - Returns: The logical bytes the entries land with it.
    /// - Throws: `ContainerError.decmpfsTypeNotAccepted` or `.exceedsByteCeiling`.
    public func admitLanding(_ entry: ValidatedEntry, after landed: UInt64) throws(ContainerError) -> UInt64 {
        if let decmpfs = entry.decmpfs, !decmpfsTypes.contains(decmpfs.compressionType) {
            throw .decmpfsTypeNotAccepted(decmpfs.compressionType)
        }
        let size = entry.landedByteCount
        guard landed <= byteCeiling, size <= byteCeiling - landed else {
            throw .exceedsByteCeiling(declared: landed &+ size, ceiling: byteCeiling)
        }
        return landed + size
    }
}
