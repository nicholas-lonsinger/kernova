#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaContainer
import KernovaFileTree
import KernovaWire

/// Why an item could not be read into a container, and the entry it failed at.
public struct TreeReadFailure: Error, Equatable, Sendable {
    /// What went wrong.
    public enum Reason: Equatable, Sendable {
        /// A file-system call failed.
        case system(TreeFileSystemError)
        /// The entry changed while it was read: replaced after its directory listed it, or a file whose size
        /// or modification time moved, or that ended before its size.
        case changed
        /// A directory the reader was inside was moved.
        case moved
        /// The container format cannot carry the entry.
        case notCarried(NotCarried)
        /// The files total more than the pull's byte ceiling.
        case exceedsByteCeiling(UInt64)
    }

    /// What about an entry the container format cannot carry.
    public enum NotCarried: Equatable, Sendable {
        /// The item is not what its representation's storage names: a directory for FOLDER, a regular file
        /// for FILE.
        case rootType(FileKind)
        /// The entry is a FIFO, device, socket, or another type that is not a file, directory or symlink.
        case type(FileKind)
        /// The name is longer than 255 bytes.
        case name
        /// The symlink's target is longer than 1,023 bytes or empty.
        case symlinkTarget
        /// The entry's extended attributes do not fit one header record — a resource fork near 64 KiB or
        /// larger, most often.
        case metadataTooLarge
    }

    /// The entry's path as byte components, first the item's own name.
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
        case .exceedsByteCeiling(let ceiling):
            error.code = .tooLarge
            error.limit = ceiling
        case .notCarried(.metadataTooLarge):
            error.code = .tooLarge
            error.limit = UInt64(ContainerRecord.maxHeaderPayload)
        case .system(let failure):
            error.code = .readFailed
            item.posixErrno = failure.code
        case .changed, .moved, .notCarried:
            error.code = .readFailed
        }
        error.posixErrno = item.posixErrno
        error.item = item
        return error
    }
}
