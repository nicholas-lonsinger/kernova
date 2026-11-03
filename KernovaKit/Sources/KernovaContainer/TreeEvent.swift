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
    /// The tree is complete and its counts verified.
    case end
}

/// What the pull's destination accepts, which a container is held to on both sides.
public struct ContainerAcceptance: Equatable, Sendable {
    /// The most bytes the entries' chunks may carry, after decompression.
    public var byteCeiling: UInt64
    /// The decmpfs compression types the destination lands as they are.
    public var decmpfsTypes: Set<UInt32>
    /// Whether chunks may be LZ4 blocks.
    public var acceptsLZ4: Bool

    /// An acceptance of the given limits.
    ///
    /// - Parameters:
    ///   - byteCeiling: The most bytes the entries' chunks may carry, after decompression.
    ///   - decmpfsTypes: The decmpfs compression types the destination lands as they are.
    ///   - acceptsLZ4: Whether chunks may be LZ4 blocks.
    public init(byteCeiling: UInt64, decmpfsTypes: Set<UInt32>, acceptsLZ4: Bool) {
        self.byteCeiling = byteCeiling
        self.decmpfsTypes = decmpfsTypes
        self.acceptsLZ4 = acceptsLZ4
    }

    /// What `pull` accepts.
    public init(_ pull: PullRequest) {
        self.init(
            byteCeiling: pull.byteCeiling, decmpfsTypes: Set(pull.decmpfsTypes), acceptsLZ4: pull.codecs.contains(.lz4))
    }
}
