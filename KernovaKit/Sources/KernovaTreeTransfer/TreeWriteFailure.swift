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
        /// The container, or the events another producer made, broke a rule of the format: its grammar, an
        /// entry's rules, or a limit the pull declared.
        case container(ContainerError)
        /// This OS does not land the entry: its path is longer than a path can be, or its name is one the
        /// volume does not store.
        case refused(TreeFileSystemError)
        /// A file-system call failed; a name already taken, `EEXIST`, among them.
        case system(TreeFileSystemError)
        /// A directory the writer created was moved or replaced while the writer was inside it.
        case moved
        /// The volume did not take a file compressed: its decmpfs storage does not land, while the same file
        /// sent plain would.
        case notCompressed(NotCompressed)
    }

    /// The entry's path as byte components, first the item's own name: the entry that failed, or, for a
    /// container the decoder refused, the file or directory the writer was in when it did — the item itself
    /// before its own entry begins.
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
            if case .exceedsByteCeiling(_, let ceiling) = failure { error.limit = ceiling }
        case .notCompressed(let refusal):
            error.code = .itemDecmpfsRefused
            if case .flagRefused(let failure) = refusal { item.posixErrno = failure.code }
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
