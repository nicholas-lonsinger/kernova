#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaContainer
import KernovaFileTree
import KernovaWire

/// Why a tree did not land, and the entry it failed at.
public struct TreeWriteFailure: Error, Equatable, Sendable {
    /// What went wrong.
    public enum Reason: Equatable, Sendable {
        /// The container broke its grammar or a declared limit.
        case container(ContainerError)
        /// The events broke an order or a limit the writer holds every producer to.
        case event(TreeEventViolation)
        /// This OS does not land the entry: its path is longer than a path can be, or its name is one the
        /// volume does not store.
        case refused(TreeFileSystemError)
        /// A file-system call failed; a name already taken, `EEXIST`, among them.
        case system(TreeFileSystemError)
        /// A directory the writer created was moved or replaced while the writer was inside it.
        case moved
    }

    /// The entry's path as byte components, first the item's own name: the entry that failed, or, for a
    /// container the decoder refused, the file or directory the writer was in when it did. Empty before
    /// the item's own entry.
    public let path: [[UInt8]]
    /// What went wrong.
    public let reason: Reason

    /// A failure of `reason` at `path`.
    ///
    /// - Parameters:
    ///   - path: The entry's path as byte components, first the item's own name.
    ///   - reason: What went wrong.
    public init(path: [[UInt8]], reason: Reason) {
        self.path = path
        self.reason = reason
    }

    /// The error a pull ends with for this failure.
    public var wireError: Kernova_V2_Error {
        var error = Kernova_V2_Error()
        var item = Kernova_V2_ItemFailure()
        item.path = path.map { Data($0) }
        switch reason {
        case .container(let failure):
            error.code = failure.errorCode
        case .event(.exceedsByteCeiling(let ceiling)):
            error.code = .tooLarge
            error.limit = ceiling
        case .event(.decmpfsNotLanded):
            error.code = .itemDecmpfsRefused
        case .event:
            error.code = .itemContainerMalformed
        case .refused(let failure):
            error.code = .itemUnpackRefused
            item.posixErrno = failure.code
        case .system(let failure):
            error.code = .writeFailed
            item.posixErrno = failure.code
        case .moved:
            error.code = .writeFailed
        }
        error.posixErrno = item.posixErrno
        error.item = item
        return error
    }
}

/// An event a producer other than `ContainerDecoder` could send, which the writer refuses: the decoder's
/// grammar already refuses each of them.
public enum TreeEventViolation: Equatable, Sendable {
    /// The event is not one the writer's place in the tree admits: bytes with no file open, a leave with no
    /// directory entered, an entry before the root or after it ended, anything after the end.
    case outOfOrder
    /// The entry's header breaks a rule of `ValidatedEntry`, which every producer is held to.
    case invalidEntry(ContainerError)
    /// The entry's depth is not the number of directories the writer is inside.
    case depthMismatch(depth: UInt32, entered: Int)
    /// A file's bytes ran past, or ended short of, the size its header declared.
    case sizeMismatch(declared: UInt64, carried: UInt64)
    /// The entries' declared sizes total more than the writer's byte ceiling.
    case exceedsByteCeiling(UInt64)
    /// A file's storage is decmpfs, which this writer does not land.
    case decmpfsNotLanded
    /// The entry is not the file, directory or symlink the event creates, or a file has no storage.
    case typeNotLanded
    /// A file's bytes or zeros of no length.
    case emptyPiece
}
