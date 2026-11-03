#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaWire

/// One step of building a tree, in depth-first pre-order: what a tree writer consumes, whichever format
/// produced it. A file's events are `beginFile`, its `bytes` and `zeros` in order, then `finishFile`; every
/// `enterDirectory` is matched by one `leaveDirectory` before `end`.
public enum TreeEvent: Equatable, Sendable {
    /// Create the directory `header` describes in the current directory, and make it current.
    case enterDirectory(EntryHeader)
    /// Create the regular file or INLINE data `header` describes. Its bytes follow; for decmpfs storage
    /// they are the resource fork.
    case beginFile(EntryHeader)
    /// The current file's next bytes.
    case bytes(Data)
    /// The current file's next bytes, all zero.
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
    /// The most logical bytes the entries may land: each file's size, and for decmpfs storage the larger of
    /// the attribute's uncompressed size and the resource fork.
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
}
