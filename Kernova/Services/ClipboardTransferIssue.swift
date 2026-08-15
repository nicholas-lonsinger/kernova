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
        /// Not enough disk space on the receiving side to stage a streamed
        /// payload. `needed` is the transfer size, `nil` when the payload
        /// declared none — a streamed folder archive's compressed size is not
        /// known until its last byte. `available` is the staging volume's free
        /// capacity when known.
        case diskFull(needed: Int?, available: Int?)

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
            kind: .diskFull(needed: info.neededBytes, available: info.availableBytes),
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

    /// Raised when a Copy to Mac still on the host pasteboard is superseded: the
    /// stale promise is retracted rather than left advertised but unservable.
    ///
    /// `hasSuccessor` is whether a guest offer took the retracted one's place —
    /// an offer the host could promise does, a release or an offer whose reps all
    /// filtered out does not. Only the first leaves Copy to Mac a next step.
    static func staleCopyRetracted(hasSuccessor: Bool) -> ClipboardTransferIssue {
        let removal =
            "The guest clipboard changed, so the earlier copy was removed from the Mac clipboard"
        return ClipboardTransferIssue(
            kind: .staleCopyRetracted(
                message: hasSuccessor
                    ? "\(removal) — use Copy to Mac to bring over the new copy." : "\(removal)."),
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

    /// Raised when a copied item's archive arrived but could not be unpacked
    /// into the file or folder the paste would create.
    static func pasteUnpackFailed() -> ClipboardTransferIssue {
        ClipboardTransferIssue(
            kind: .localFailure(
                code: ClipboardErrorCode.pasteFailed.rawValue,
                message: "The copied item couldn't be unpacked, so nothing was pasted."),
            date: Date())
    }

    /// Raised when an automatic passthrough forward left unreadable items out of
    /// the offer; `note` is the intake's own wording, the same sentence the
    /// window's own paste/drop gestures show inline.
    static func forwardSkippedItems(note: String) -> ClipboardTransferIssue {
        ClipboardTransferIssue(
            kind: .localFailure(
                code: ClipboardErrorCode.forwardItemsSkipped.rawValue, message: note),
            date: Date())
    }

    /// Raised when none of the items dropped on the VM display could be read, so
    /// nothing was offered to the guest.
    static func dropItemsUnreadable() -> ClipboardTransferIssue {
        ClipboardTransferIssue(
            kind: .localFailure(
                code: ClipboardErrorCode.dropFailed.rawValue,
                message: "Those items couldn't be read, so nothing was sent to the VM."),
            date: Date())
    }

    /// Raised when the drop offer itself could not be sent to the guest.
    static func dropSendFailed() -> ClipboardTransferIssue {
        ClipboardTransferIssue(
            kind: .localFailure(
                code: ClipboardErrorCode.dropFailed.rawValue,
                message: "The connection to the VM dropped, so the files weren't sent."),
            date: Date())
    }

    /// Raised when the VM's drop connection ended while files were still on their
    /// way, so the drop never finished.
    static func dropInterrupted(fileCount: Int) -> ClipboardTransferIssue {
        let subject = fileCount == 1 ? "The file" : "The files"
        return ClipboardTransferIssue(
            kind: .localFailure(
                code: ClipboardErrorCode.dropFailed.rawValue,
                message: "\(subject) stopped transferring when the VM disconnected."),
            date: Date())
    }

    /// Raised when the guest reports it could not put the dropped files in its
    /// Downloads folder.
    ///
    /// Composed from the guest's machine-readable `code`, never from its message
    /// text: the sentence a user reads is written on this side. The code is
    /// carried into the issue too, so every surface renders the same specific
    /// outcome rather than the dropdown falling back to the generic line.
    ///
    /// The wording says the drop did not finish rather than that nothing was
    /// saved: a batch that fails partway leaves the files it already moved in
    /// Downloads, and a message claiming otherwise would send the user looking
    /// for something that is there.
    static func dropFailed(code: ClipboardErrorCode?) -> ClipboardTransferIssue {
        let resolved = code ?? .dropFailed
        let message: String
        switch resolved {
        case .dropDiskFull:
            message = "The VM ran out of disk space, so the drop didn't finish."
        case .dropDownloadsDenied:
            message =
                "The guest agent isn't allowed to use the VM's Downloads folder, so the drop didn't finish."
        default:
            message =
                "The drop didn't finish — some files may not be in the VM's Downloads folder."
        }
        return ClipboardTransferIssue(
            kind: .localFailure(code: resolved.rawValue, message: message), date: Date())
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

// MARK: - Display copy

extension ClipboardTransferIssue {
    /// The full sentence every surface renders for this issue — the clipboard
    /// window's banner and the status-item notice alike.
    ///
    /// `pasteLimitBytes` is the ceiling in force now, which only a peer-reported
    /// over-cap paste needs: every other message either carries its own figure or
    /// names none.
    func displayMessage(pasteLimitBytes: Int) -> String {
        switch kind {
        case .diskFull(let needed, let available):
            let detail =
                [
                    needed.map { "\(DataFormatters.formatBytes(UInt64($0))) needed" },
                    available.map { "\(DataFormatters.formatBytes(UInt64($0))) free" },
                ]
                .compactMap { $0 }
                .joined(separator: ", ")
            let base = "Not enough disk space to receive the clipboard payload"
            return detail.isEmpty ? base : "\(base) (\(detail))"
        case .peerReportedError(let code, _):
            switch ClipboardErrorCode(rawValue: code) {
            case .pasteDiskFull:
                return "The guest ran out of disk space receiving the clipboard file"
            case .pasteTooLarge:
                return
                    "Too large to paste into the guest — over the \(ClipboardPasteLimit.displayLimit(pasteLimitBytes)) clipboard transfer limit"
            case .pasteTimeout:
                return "The clipboard transfer to the guest timed out"
            case .pasteFailed, .copyTooLarge, .pasteIncompleteSet, .forwardItemsSkipped,
                .dropDiskFull, .dropDownloadsDenied, .dropFailed, .none:
                return "Clipboard transfer failed on the guest side"
            }
        case .localFailure(_, let message):
            return message
        case .staleCopyRetracted(let message):
            return message
        }
    }

    /// The status-item notice's bold first line, naming the VM and which
    /// direction the clipboard failed to move in.
    func noticeHeadline(vmName: String) -> String {
        switch kind {
        case .diskFull:
            return "Clipboard not pasted from \(Self.quoted(vmName))."
        case .peerReportedError:
            return "Clipboard not pasted into \(Self.quoted(vmName))."
        case .staleCopyRetracted:
            return "Clipboard changed in \(Self.quoted(vmName))."
        case .localFailure(let code, _):
            switch ClipboardErrorCode(rawValue: code) {
            case .copyTooLarge:
                return "Clipboard not copied from \(Self.quoted(vmName))."
            case .forwardItemsSkipped:
                return "Clipboard not copied to \(Self.quoted(vmName))."
            case .pasteIncompleteSet, .pasteTimeout, .pasteFailed:
                return "Clipboard not pasted from \(Self.quoted(vmName))."
            case .dropFailed, .dropDiskFull, .dropDownloadsDenied:
                return "Files not copied to \(Self.quoted(vmName))."
            case .pasteDiskFull, .pasteTooLarge, .none:
                return "Clipboard issue with \(Self.quoted(vmName))."
            }
        }
    }

    /// Whether a surface may add that the Mac clipboard still holds what it held
    /// before.
    ///
    /// True only for the over-cap copy refusal, the one outcome that refuses the
    /// publish whole and so leaves the previous contents in place; after any
    /// other issue the sentence would be a guess.
    var includesStaleClipboardContext: Bool {
        guard case .localFailure(let code, _) = kind else { return false }
        return ClipboardErrorCode(rawValue: code) == .copyTooLarge
    }

    /// Whether a host surface that interrupts may present this issue.
    ///
    /// docs/CLIPBOARD.md §13 — report a refusal on the side that made the
    /// gesture. Every kind but `.peerReportedError` refuses a gesture made on
    /// this Mac, or has its consequence here; a `.peerReportedError` refuses the
    /// guest user's own paste, which the guest agent's own dropdown reveals over
    /// there, so the host records it for the menu line and interrupts nobody.
    var warrantsInterruptingNotice: Bool {
        switch kind {
        case .diskFull, .localFailure, .staleCopyRetracted: return true
        case .peerReportedError: return false
        }
    }

    /// The compact fragment the status-item dropdown shows under the VM's row —
    /// no trailing period, since it reads as a menu line rather than prose.
    var menuLineText: String {
        switch kind {
        case .diskFull:
            return "Clipboard: paste from the guest failed"
        case .staleCopyRetracted:
            return "Clipboard: earlier copy was removed"
        case .peerReportedError(let code, _):
            return ClipboardErrorCode(rawValue: code) == .pasteTooLarge
                ? "Clipboard: too large to paste into the guest"
                : "Clipboard: paste into the guest failed"
        case .localFailure(let code, _):
            switch ClipboardErrorCode(rawValue: code) {
            case .copyTooLarge: return "Clipboard: too large to copy to your Mac"
            case .pasteTimeout: return "Clipboard: paste from the guest timed out"
            case .pasteIncompleteSet, .pasteFailed: return "Clipboard: paste from the guest failed"
            case .forwardItemsSkipped: return "Clipboard: some items weren't forwarded"
            case .dropDiskFull: return "Drop: the VM ran out of disk space"
            case .dropDownloadsDenied: return "Drop: the VM's Downloads folder is off limits"
            case .dropFailed: return "Drop: the files didn't reach the VM"
            case .pasteDiskFull, .pasteTooLarge, .none:
                return "Clipboard: transfer didn't complete"
            }
        }
    }

    private static func quoted(_ name: String) -> String { "\u{201C}\(name)\u{201D}" }
}
