#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

import KernovaAgentCore

extension ClipboardTransferFailure {
    /// What a readout says of a pull that ended in `error`: `fileCount` is how many files a drop or drag was still
    /// carrying, nil for a clipboard transfer, which speaks of the clipboard.
    public init(pullEndedWith error: WireError, fileCount: Int?) {
        self =
            switch error.code {
            case .itemOfferStale, .cancelled, .shuttingDown: .interrupted(fileCount: fileCount)
            case .writeFailed where error.posixErrno == ENOSPC: .diskFull(needed: nil, available: nil)
            case .writeFailed, .itemUnpackRefused, .itemDecmpfsRefused: .stagingFailed
            case .readFailed: .sourceUnreadable
            case .tooLarge: .tooLarge(limitBytes: Int(clamping: error.limit))
            default: .transferFailed
            }
    }
}
