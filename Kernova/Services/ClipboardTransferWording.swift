import Foundation
import KernovaKit

/// The sentences one refused clipboard or drop transfer is rendered with,
/// derived once from the failure and the gesture that produced it.
///
/// Every surface reads the same value: the status-item notice takes `headline`
/// and `message`, the clipboard window's banner takes `message`, and the
/// dropdown's per-VM line takes `menuLine`.
struct ClipboardTransferWording: Equatable {
    /// The notice's bold first line, naming the VM and which direction the
    /// clipboard failed to move in.
    let headline: String
    /// The full sentence — the window's banner and the notice's body.
    let message: String
    /// The compact fragment under the VM's dropdown row, with no trailing period
    /// since it reads as a menu line rather than prose.
    let menuLine: String
    /// Whether a surface may add that the Mac clipboard still holds what it held
    /// before.
    ///
    /// True only for the over-cap copy refusal, the one outcome that refuses the
    /// publish whole and so leaves the previous contents in place; after any
    /// other failure the sentence would be a guess.
    let mentionsMacClipboardKept: Bool

    /// Shown for a Copy to Mac refused over the deadline-safe cap, wherever it
    /// surfaces: the click's own inline outcome and the report an automatic
    /// passthrough publish raises are the same refusal.
    static func overCopyBudgetMessage(limitBytes: Int) -> String {
        "Too large to copy to your Mac — over the \(ClipboardPasteLimit.displayLimit(limitBytes)) clipboard transfer limit."
    }

    /// The wording for a finished transfer, or `nil` when it delivered what the
    /// gesture asked for and there is nothing to say.
    ///
    /// A peer-reported failure is composed from the peer's machine-readable code,
    /// never from its message text: the sentence a user reads is written on this
    /// side.
    ///
    /// Every paste-fire refusal says the paste did not finish, not that nothing
    /// was pasted: the pasteboard fires once per item, so an earlier item's file
    /// may already have landed. "Sharing stopped" covers every way the session
    /// ends — the VM stopping, the toggle, a reconnect — where "the VM
    /// disconnected" would name only one.
    static func wording(for finish: ClipboardTransferFinish, vmName: String)
        -> ClipboardTransferWording?
    {
        guard let failure = finish.failure else { return nil }
        let vm = quoted(vmName)

        switch (failure, finish.gesture) {
        case (.diskFull(let needed, let available), let gesture):
            let detail =
                [
                    needed.map { "\(DataFormatters.formatBytes($0)) needed" },
                    available.map { "\(DataFormatters.formatBytes(UInt64(clamping: $0))) free" },
                ]
                .compactMap { $0 }
                .joined(separator: ", ")
            let base = "Not enough disk space to receive the clipboard payload"
            return ClipboardTransferWording(
                headline: headline(for: gesture, vm: vm),
                message: detail.isEmpty ? base : "\(base) (\(detail))",
                menuLine: inboundFailureLine(for: gesture),
                mentionsMacClipboardKept: false)

        case (.tooLarge(let limitBytes), .copy):
            return ClipboardTransferWording(
                headline: "Clipboard not copied from \(vm).",
                message: overCopyBudgetMessage(limitBytes: limitBytes),
                menuLine: "Clipboard: too large to copy to your Mac",
                mentionsMacClipboardKept: true)

        case (.tooLarge(let limitBytes), _):
            return ClipboardTransferWording(
                headline: "Clipboard not pasted into \(vm).",
                message:
                    "Too large to paste into the guest — over the \(ClipboardPasteLimit.displayLimit(limitBytes)) clipboard transfer limit",
                menuLine: "Clipboard: too large to paste into the guest",
                mentionsMacClipboardKept: false)

        case (.peerReported(let code), .drop):
            // The drop did not finish rather than nothing was saved: a batch that
            // fails partway leaves the files it already moved in Downloads, and a
            // message claiming otherwise would send the user looking for
            // something that is there.
            let message: String
            let menuLine: String
            switch code {
            case .dropDiskFull:
                message = "The VM ran out of disk space, so the drop didn't finish."
                menuLine = "Drop: the VM ran out of disk space"
            case .dropDownloadsDenied:
                message =
                    "The guest agent isn't allowed to use the VM's Downloads folder, so the drop didn't finish."
                menuLine = "Drop: the VM's Downloads folder is off limits"
            default:
                message = "The drop didn't finish — some files may not be in the VM's Downloads folder."
                menuLine = "Drop: the files didn't reach the VM"
            }
            return ClipboardTransferWording(
                headline: "Files not copied to \(vm).", message: message, menuLine: menuLine,
                mentionsMacClipboardKept: false)

        case (.peerReported(let code), _):
            let message: String
            switch code {
            case .pasteDiskFull:
                message = "The guest ran out of disk space receiving the clipboard file"
            case .pasteTimeout:
                message = "The clipboard transfer to the guest timed out"
            default:
                message = "Clipboard transfer failed on the guest side"
            }
            return ClipboardTransferWording(
                headline: "Clipboard not pasted into \(vm).", message: message,
                menuLine: "Clipboard: paste into the guest failed",
                mentionsMacClipboardKept: false)

        case (.supersededCopyRetracted(let hasSuccessor), _):
            let removal =
                "The guest clipboard changed, so the earlier copy was removed from the Mac clipboard"
            return ClipboardTransferWording(
                headline: "Clipboard changed in \(vm).",
                message: hasSuccessor
                    ? "\(removal) — use Copy to Mac to bring over the new copy." : "\(removal).",
                menuLine: "Clipboard: earlier copy was removed",
                mentionsMacClipboardKept: false)

        case (.incompleteFileSet, _):
            return ClipboardTransferWording(
                headline: "Clipboard not pasted from \(vm).",
                message:
                    "Clipboard sharing with the VM stopped before every copied file transferred, so the paste didn't finish.",
                menuLine: "Clipboard: paste from the guest failed",
                mentionsMacClipboardKept: false)

        case (.interrupted(let fileCount), .drop):
            let subject = fileCount == 1 ? "The file" : "The files"
            return ClipboardTransferWording(
                headline: "Files not copied to \(vm).",
                message: "\(subject) stopped transferring when the VM disconnected.",
                menuLine: "Drop: the files didn't reach the VM",
                mentionsMacClipboardKept: false)

        case (.interrupted, _):
            return ClipboardTransferWording(
                headline: "Clipboard not pasted from \(vm).",
                message:
                    "Clipboard sharing with the VM stopped mid-transfer, so the paste didn't finish.",
                menuLine: "Clipboard: paste from the guest failed",
                mentionsMacClipboardKept: false)

        case (.timedOut, .preview):
            return ClipboardTransferWording(
                headline: "Clipboard preview from \(vm) failed.",
                message: "The preview from the guest couldn't be loaded.",
                menuLine: "Clipboard: preview from the guest failed",
                mentionsMacClipboardKept: false)

        case (.timedOut, _):
            return ClipboardTransferWording(
                headline: "Clipboard not pasted from \(vm).",
                message: "The transfer from the guest timed out, so the paste didn't finish.",
                menuLine: "Clipboard: paste from the guest timed out",
                mentionsMacClipboardKept: false)

        case (.transferFailed, .preview), (.unpackFailed, .preview), (.stagingFailed, .preview):
            return ClipboardTransferWording(
                headline: "Clipboard preview from \(vm) failed.",
                message: "The preview from the guest couldn't be loaded.",
                menuLine: "Clipboard: preview from the guest failed",
                mentionsMacClipboardKept: false)

        case (.transferFailed, _):
            return ClipboardTransferWording(
                headline: "Clipboard not pasted from \(vm).",
                message: "The transfer from the guest failed, so the paste didn't finish.",
                menuLine: "Clipboard: paste from the guest failed",
                mentionsMacClipboardKept: false)

        case (.unpackFailed, _):
            return ClipboardTransferWording(
                headline: "Clipboard not pasted from \(vm).",
                message: "The copied item couldn't be unpacked, so the paste didn't finish.",
                menuLine: "Clipboard: paste from the guest failed",
                mentionsMacClipboardKept: false)

        case (.stagingFailed, _):
            return ClipboardTransferWording(
                headline: "Clipboard not pasted from \(vm).",
                message: "The copied file couldn't be saved to disk, so the paste didn't finish.",
                menuLine: "Clipboard: paste from the guest failed",
                mentionsMacClipboardKept: false)

        case (.itemsSkipped(let note), _):
            return ClipboardTransferWording(
                headline: "Clipboard not copied to \(vm).", message: note,
                menuLine: "Clipboard: some items weren't forwarded",
                mentionsMacClipboardKept: false)

        case (.itemsUnreadable, _):
            return ClipboardTransferWording(
                headline: "Files not copied to \(vm).",
                message: "Those items couldn't be read, so nothing was sent to the VM.",
                menuLine: "Drop: the files didn't reach the VM",
                mentionsMacClipboardKept: false)

        case (.sendFailed, _):
            return ClipboardTransferWording(
                headline: "Files not copied to \(vm).",
                message: "The connection to the VM dropped, so the files weren't sent.",
                menuLine: "Drop: the files didn't reach the VM",
                mentionsMacClipboardKept: false)
        }
    }

    /// The headline for a failure whose wording is the same whichever gesture
    /// asked for the bytes.
    private static func headline(for gesture: ClipboardTransferGesture, vm: String) -> String {
        switch gesture {
        case .preview: return "Clipboard preview from \(vm) failed."
        case .copy: return "Clipboard not copied from \(vm)."
        case .forward: return "Clipboard not copied to \(vm)."
        case .drop: return "Files not copied to \(vm)."
        case .peerPaste: return "Clipboard not pasted into \(vm)."
        case .paste: return "Clipboard not pasted from \(vm)."
        }
    }

    /// The dropdown line for a failure pulling bytes from the guest.
    private static func inboundFailureLine(for gesture: ClipboardTransferGesture) -> String {
        gesture == .preview
            ? "Clipboard: preview from the guest failed" : "Clipboard: paste from the guest failed"
    }

    private static func quoted(_ name: String) -> String { "\u{201C}\(name)\u{201D}" }
}
