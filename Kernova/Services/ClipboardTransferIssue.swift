import Foundation
import KernovaKit

/// A user-visible clipboard transfer problem, surfaced by `ClipboardServicing`
/// implementations for the clipboard window to display.
///
/// `date` doubles as the re-fire identity: two issues of the same kind from
/// separate failures compare unequal, so the window can re-show a transient
/// message it has already dismissed once.
struct ClipboardTransferIssue: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// Not enough disk space on the receiving side to stage a streamed file.
        /// `needed` is the transfer size; `available` is the staging volume's
        /// free capacity when known.
        case diskFull(needed: Int, available: Int?)

        /// The peer rejected a clipboard message (e.g. format unavailable,
        /// delivery failure on its side).
        case peerReportedError(code: String, message: String)

        /// This side refused the transfer, so `message` is already the sentence
        /// to show — nothing crossed the wire to be translated.
        case localRefusal(code: String, message: String)

        /// The host retracted its own promised pasteboard write because the
        /// guest clipboard moved on; `message` is already the sentence to show.
        case staleCopyRetracted(message: String)
    }

    let kind: Kind
    let date: Date
}

extension ClipboardTransferIssue {
    /// Shown for a Copy to Mac refused over the deadline-safe cap, wherever it
    /// surfaces: the click's own outcome and the transfer issue an automatic
    /// passthrough publish raises are the same refusal.
    static let overCopyBudgetMessage =
        "Too large to copy to your Mac — over the \(ClipboardStreamTuning.maxDeadlineSafePasteDisplayLimit) clipboard transfer limit."

    /// The refusal this host raises when a Copy-to-Mac gesture's paste-bound reps
    /// exceed the deadline-safe cap.
    static func overCopyBudget() -> ClipboardTransferIssue {
        ClipboardTransferIssue(
            kind: .localRefusal(
                code: ClipboardErrorCode.copyTooLarge.rawValue, message: overCopyBudgetMessage),
            date: Date())
    }

    /// Raised when a newer guest offer (or a release) supersedes a Copy to Mac
    /// still on the host pasteboard: the stale promise is retracted rather than
    /// left advertised but unservable.
    static func staleCopyRetracted() -> ClipboardTransferIssue {
        ClipboardTransferIssue(
            kind: .staleCopyRetracted(
                message:
                    "The guest clipboard changed, so the earlier copy was removed from the Mac clipboard — use Copy to Mac to bring over the new copy."
            ),
            date: Date())
    }

    /// The refusal this host raises when a paste fires after the VM session
    /// ended with only part of the copied file set materialized: nothing is
    /// served rather than an incomplete set.
    static func partialFileSetUnservable() -> ClipboardTransferIssue {
        ClipboardTransferIssue(
            kind: .localRefusal(
                code: ClipboardErrorCode.pasteIncompleteSet.rawValue,
                message:
                    "The VM disconnected before every copied file transferred, so nothing was pasted."
            ),
            date: Date())
    }
}
