#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

import KernovaAgentCore
import KernovaWire

/// Why one item's pull failed, when the failure is the item's own and the transfer's other items go on.
public enum ItemPullFailure: Equatable, Sendable {
    /// This side was not permitted (`EPERM`) to write the item where it lands.
    case refused
    /// The far side could not read the item, at `entry` when it named the entry.
    case unreadable(entry: ItemEntry?)
    /// The item's bytes arrived but could not be written on this side.
    case unwritable
    /// The far side had nothing to serve for the item.
    case unsupplied
    /// Any other failure of the item's own.
    case failed
}

extension ClipboardTransferFailure {
    /// What a transfer whose pull ended in `error` failed with: the one reading of a pull's ending error, which
    /// every owner of a pull shares and each decides from whether the failure ends its other pulls.
    ///
    /// `fileCount` is how many files a drop or a drag was still carrying, for a pull its offer's or connection's
    /// end interrupted; nil for a paste, which speaks of the clipboard. `limitBytes` is the ceiling a `TOO_LARGE`
    /// pull was over as its owner set it, the error's own limit when nil: a pull ordered against what is left of a
    /// budget carries the remainder as its limit.
    public init(pullEndedWith error: WireError, fileCount: Int?, limitBytes: UInt64? = nil) {
        switch error.code {
        case .itemOfferStale, .cancelled, .shuttingDown: self = .interrupted(fileCount: fileCount)
        case .tooLarge: self = .tooLarge(limitBytes: Int(clamping: limitBytes ?? error.limit))
        case .readFailed: self = .itemFailed(.unreadable(entry: ItemEntry(unreadBy: error)))
        case .itemRepresentationUnavailable: self = .itemFailed(.unsupplied)
        case .writeFailed: self = Self.writeFailed(posixErrno: error.posixErrno)
        case .itemUnpackRefused, .itemDecmpfsRefused: self = .itemFailed(.unwritable)
        default: self = .transferFailed
        }
    }

    /// What a pull whose landing could not be written, with `posixErrno`, failed with.
    private static func writeFailed(posixErrno: Int32) -> Self {
        // Only a POSIX side lands a pull, so only its errno names a full volume or a refused write.
        #if canImport(Darwin) || os(Linux)
        switch posixErrno {
        case ENOSPC: return .diskFull(needed: nil, available: nil)
        case EPERM: return .itemFailed(.refused)
        default: break
        }
        #endif
        return .itemFailed(.unwritable)
    }
}

extension ItemEntry {
    /// The entry a `READ_FAILED` `error` names, bytes that aren't UTF-8 replaced, or nil when it names none.
    init?(unreadBy error: WireError) {
        self.init((error.item?.path ?? []).map { String(decoding: $0, as: UTF8.self) })
    }
}
