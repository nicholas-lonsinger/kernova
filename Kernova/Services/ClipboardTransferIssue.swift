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

        /// This side produced the outcome — a transfer it refused, or one it
        /// could not complete — so `message` is already the sentence to show;
        /// nothing crossed the wire to be translated.
        case localFailure(code: String, message: String)

        /// The host retracted its own promised pasteboard write because the
        /// guest clipboard moved on; `message` is already the sentence to show.
        case staleCopyRetracted(message: String)
    }

    let kind: Kind
    let date: Date
}

extension ClipboardTransferIssue {
    /// The notice a staging pre-flight raises for a payload the volume has no
    /// room for, clamping the peer-declared size and the queried capacity into
    /// the display type.
    static func diskFull(needed: UInt64, available: Int64?) -> ClipboardTransferIssue {
        ClipboardTransferIssue(
            kind: .diskFull(
                needed: Int(clamping: needed), available: available.map { Int(clamping: $0) }),
            date: Date())
    }

    /// The notice an aborted transfer raises when the receiving volume filled
    /// mid-stream, carrying whatever numbers the abort knew.
    static func diskFull(from info: ClipboardStreamAbortInfo) -> ClipboardTransferIssue {
        ClipboardTransferIssue(
            kind: .diskFull(needed: info.neededBytes ?? 0, available: info.availableBytes),
            date: Date())
    }

    /// Shown for a Copy to Mac refused over the deadline-safe cap, wherever it
    /// surfaces: the click's own outcome and the transfer issue an automatic
    /// passthrough publish raises are the same refusal.
    static func overCopyBudgetMessage(limitBytes: Int) -> String {
        "Too large to copy to your Mac — over the \(ClipboardPasteLimit.displayLimit(limitBytes)) clipboard transfer limit."
    }

    /// The refusal this host raises when a Copy-to-Mac gesture's paste-bound reps
    /// exceed the deadline-safe cap.
    static func overCopyBudget(limitBytes: Int) -> ClipboardTransferIssue {
        ClipboardTransferIssue(
            kind: .localFailure(
                code: ClipboardErrorCode.copyTooLarge.rawValue,
                message: overCopyBudgetMessage(limitBytes: limitBytes)),
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
            kind: .localFailure(
                code: ClipboardErrorCode.pasteIncompleteSet.rawValue,
                message:
                    "The VM disconnected before every copied file transferred, so nothing was pasted."
            ),
            date: Date())
    }

    /// Raised when a paste-time pull reaches its inactivity backstop: the guest
    /// stopped sending and the pasteboard fire served nothing.
    static func pasteTimedOut() -> ClipboardTransferIssue {
        ClipboardTransferIssue(
            kind: .localFailure(
                code: ClipboardErrorCode.pasteTimeout.rawValue,
                message: "The transfer from the guest timed out, so nothing was pasted."),
            date: Date())
    }

    /// Raised when a paste-time pull ends in an abort (the request never went
    /// out, or the stream failed) other than the receiving volume filling, which
    /// `diskFull` reports with its own numbers.
    static func pasteTransferFailed() -> ClipboardTransferIssue {
        ClipboardTransferIssue(
            kind: .localFailure(
                code: ClipboardErrorCode.pasteFailed.rawValue,
                message: "The transfer from the guest failed, so nothing was pasted."),
            date: Date())
    }

    /// Raised when a copied folder's archive arrived but could not be unpacked
    /// into a real folder for the paste to create.
    static func pasteFolderUnpackFailed() -> ClipboardTransferIssue {
        ClipboardTransferIssue(
            kind: .localFailure(
                code: ClipboardErrorCode.pasteFailed.rawValue,
                message: "The copied folder couldn't be unpacked, so nothing was pasted."),
            date: Date())
    }

    /// Raised when a copied file's bytes arrived but could not be written to a
    /// file on this Mac for the paste to serve.
    static func pasteFileStagingFailed() -> ClipboardTransferIssue {
        ClipboardTransferIssue(
            kind: .localFailure(
                code: ClipboardErrorCode.pasteFailed.rawValue,
                message: "The copied file couldn't be saved to disk, so nothing was pasted."),
            date: Date())
    }
}
