import Foundation
import KernovaKit

/// The sentences one refused clipboard or drop transfer is rendered with,
/// derived once from the failure and the gesture that produced it.
///
/// Every surface reads the same value: the status-item notice takes `headline`
/// and `message`, the clipboard window's banner takes `message`, and the
/// dropdown's per-VM line takes `menuLine`.
package struct ClipboardTransferWording: Equatable {
    /// The notice's bold first line, naming the VM and which direction the
    /// clipboard failed to move in.
    package let headline: String
    /// The full sentence — the window's banner and the notice's body.
    package let message: String
    /// The compact fragment under the VM's dropdown row, with no trailing period
    /// since it reads as a menu line rather than prose.
    package let menuLine: String
    /// Whether a surface may add that the Mac clipboard still holds what it held
    /// before.
    ///
    /// True only for the over-cap copy refusal, the one outcome that refuses the
    /// publish whole and so leaves the previous contents in place; after any
    /// other failure the sentence would be a guess.
    package let mentionsMacClipboardKept: Bool

    /// Shown for a Copy to Mac refused over the deadline-safe cap, wherever it
    /// surfaces: the click's own inline outcome and the report an automatic
    /// passthrough publish raises are the same refusal.
    package static func overCopyBudgetMessage(limitBytes: Int) -> String {
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
    package static func wording(for finish: ClipboardTransferFinish, vmName: String)
        -> ClipboardTransferWording?
    {
        guard let failure = finish.failure else { return nil }
        let vm = quoted(vmName)

        switch (failure, finish.gesture) {
        case (_, .dragOut), (.dragItemUnnamed, _):
            return dragOutWording(for: failure, vm: vm)

        case (.diskFull(let needed, let available), let gesture):
            let detail = diskFullDetail(needed: needed, available: available)
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

        case (.timedOut, .drop):
            return ClipboardTransferWording(
                headline: "Files not copied to \(vm).",
                message: "The VM stopped taking the files, so the drop was called off.",
                menuLine: "Drop: the VM stopped taking the files",
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

        case (.transferFailed, .preview), (.unpackFailed, .preview), (.stagingFailed, .preview),
            (.sourceUnreadable, .preview):
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

        case (.sourceUnreadable(let readFailure), let gesture):
            let reader = gesture.readsOnThisMac ? "This Mac" : "The VM"
            let unfinished: String
            switch gesture {
            case .drop: unfinished = "the drop"
            case .copy, .forward: unfinished = "the copy"
            case .paste, .peerPaste, .preview, .dragOut: unfinished = "the paste"
            }
            return ClipboardTransferWording(
                headline: headline(for: gesture, vm: vm),
                message: "\(unreadableClause(readFailure, reader: reader)), so \(unfinished) didn't finish.",
                menuLine: unreadableMenuLine(
                    readFailure, prefix: gesture == .drop ? "Drop" : "Clipboard", reader: reader),
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

        case (.itemsSkipped(let count), .drop):
            return ClipboardTransferWording(
                headline: "Some files not copied to \(vm).",
                message: skippedMessage(count: count, item: "item"),
                menuLine: "Drop: some files weren't sent",
                mentionsMacClipboardKept: false)

        case (.itemsSkipped(let count), _):
            return ClipboardTransferWording(
                headline: "Clipboard partly copied to \(vm).",
                message: skippedMessage(count: count, item: "copied item"),
                menuLine: "Clipboard: some items weren't forwarded",
                mentionsMacClipboardKept: false)

        case (.itemsUnreadable, .drop):
            return ClipboardTransferWording(
                headline: "Files not copied to \(vm).",
                message: "Those items couldn't be read, so nothing was sent to the VM.",
                menuLine: "Drop: the files didn't reach the VM",
                mentionsMacClipboardKept: false)

        case (.itemsUnreadable, _):
            return ClipboardTransferWording(
                headline: "Clipboard not copied to \(vm).",
                message: "The copy couldn't be read, so nothing was sent to the VM.",
                menuLine: "Clipboard: the copy couldn't be read",
                mentionsMacClipboardKept: false)

        case (.sendFailed, _):
            return ClipboardTransferWording(
                headline: "Files not copied to \(vm).",
                message: "The connection to the VM dropped, so the files weren't sent.",
                menuLine: "Drop: the files didn't reach the VM",
                mentionsMacClipboardKept: false)

        case (.unclaimed, _):
            return ClipboardTransferWording(
                headline: "Files not copied to \(vm).",
                message: "The VM never started taking the files, so the drop was called off.",
                menuLine: "Drop: the VM never took the files",
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
        case .dragOut: return "Files not copied from \(vm)."
        case .peerPaste: return "Clipboard not pasted into \(vm)."
        case .paste: return "Clipboard not pasted from \(vm)."
        }
    }

    /// The wording for files dragged out of the VM display that did not reach
    /// where they were dropped on this Mac.
    ///
    /// Says the drag did not finish rather than that nothing arrived: a
    /// destination asks for each item in turn, so the items before the failure
    /// may already be there.
    private static func dragOutWording(
        for failure: ClipboardTransferFailure, vm: String
    ) -> ClipboardTransferWording {
        let message: String
        let menuLine: String
        switch failure {
        case .diskFull(let needed, let available):
            let detail = diskFullDetail(needed: needed, available: available)
            let base = "This Mac ran out of disk space receiving the files, so the drag didn't finish"
            message = detail.isEmpty ? "\(base)." : "\(base) (\(detail))."
            menuLine = "Drag: not enough disk space on this Mac"
        case .interrupted:
            message = "The files stopped transferring when the VM disconnected."
            menuLine = "Drag: the files didn't reach your Mac"
        case .timedOut:
            message = "The VM stopped sending the files, so the drag was called off."
            menuLine = "Drag: the VM stopped sending the files"
        case .unpackFailed:
            message = "A dragged folder couldn't be unpacked, so the drag didn't finish."
            menuLine = "Drag: the files didn't reach your Mac"
        case .stagingFailed:
            message = "The files couldn't be saved where you dropped them, so the drag didn't finish."
            menuLine = "Drag: the files couldn't be saved"
        case .peerReported(.dragItemUnavailable):
            message = "An app in the VM didn't write a dragged item, so the drag didn't finish."
            menuLine = "Drag: an app in the VM didn't write an item"
        case .peerReported:
            message = "The VM couldn't send the files, so the drag didn't finish."
            menuLine = "Drag: the files didn't reach your Mac"
        case .dragItemUnnamed:
            message = "The VM didn't name a dragged item, so the drag didn't finish."
            menuLine = "Drag: the VM didn't name an item"
        case .sourceUnreadable(let readFailure):
            message = "\(unreadableClause(readFailure, reader: "The VM")), so the drag didn't finish."
            menuLine = unreadableMenuLine(readFailure, prefix: "Drag", reader: "The VM")
        case .tooLarge, .supersededCopyRetracted, .incompleteFileSet, .transferFailed,
            .itemsSkipped, .itemsUnreadable, .sendFailed, .unclaimed:
            message = "The transfer from the VM failed, so the drag didn't finish."
            menuLine = "Drag: the files didn't reach your Mac"
        }
        return ClipboardTransferWording(
            headline: headline(for: .dragOut, vm: vm), message: message, menuLine: menuLine,
            mentionsMacClipboardKept: false)
    }

    /// The clause naming an item `reader` could not read: the item's own name —
    /// the one the read failed on, which may sit deep inside what the user
    /// dragged — and the reason the read gave, if it gave one.
    private static func unreadableClause(
        _ failure: ClipboardItemFailure?, reader: String
    ) -> String {
        guard let failure, !failure.itemName.isEmpty else {
            return "\(reader) couldn't read one of the items"
        }
        let clause = "\(reader) couldn't read \(quoted(failure.itemName))"
        guard let reason = reasonPhrase(failure.reason) else { return clause }
        return "\(clause) (\(reason))"
    }

    /// The dropdown line for an item `reader` could not read.
    private static func unreadableMenuLine(
        _ failure: ClipboardItemFailure?, prefix: String, reader: String
    ) -> String {
        guard let failure, !failure.itemName.isEmpty else {
            return "\(prefix): \(reader.lowercasedFirst) couldn't read an item"
        }
        return "\(prefix): \(reader.lowercasedFirst) couldn't read \(quoted(failure.itemName))"
    }

    /// The reason a read gave, at the strength its error code carries, or `nil`
    /// when it gave none.
    ///
    /// `EPERM` and `EACCES` both mean the reader was refused the item; neither
    /// says what refused it.
    private static func reasonPhrase(_ reason: ClipboardItemFailure.Reason) -> String? {
        switch reason {
        case .posix(EPERM), .posix(EACCES):
            return "permission denied"
        case .posix(ENOENT):
            return "it no longer exists"
        case .posix(let code):
            return String(cString: strerror(code)).lowercasedFirst
        case .endedEarly:
            return "it changed size"
        case .unknown:
            return nil
        }
    }

    /// The needed and free byte counts a disk-full refusal knows, joined, or
    /// empty when it knows neither.
    private static func diskFullDetail(needed: UInt64?, available: Int64?) -> String {
        [
            needed.map { "\(DataFormatters.formatBytes($0)) needed" },
            available.map { "\(DataFormatters.formatBytes(UInt64(clamping: $0))) free" },
        ]
        .compactMap { $0 }
        .joined(separator: ", ")
    }

    /// The dropdown line for a failure pulling bytes from the guest.
    private static func inboundFailureLine(for gesture: ClipboardTransferGesture) -> String {
        gesture == .preview
            ? "Clipboard: preview from the guest failed" : "Clipboard: paste from the guest failed"
    }

    /// The sentence for `count` unreadable items left out of a send whose rest
    /// crossed; `item` names one of them.
    private static func skippedMessage(count: Int, item: String) -> String {
        count == 1
            ? "One \(item) couldn't be read, so it wasn't sent to the VM. The rest were."
            : "\(count) \(item)s couldn't be read, so they weren't sent to the VM. The rest were."
    }

    private static func quoted(_ name: String) -> String { "\u{201C}\(name)\u{201D}" }
}

extension ClipboardTransferGesture {
    /// Whether the bytes this gesture moves are read on this Mac — it sends
    /// them — rather than in the VM.
    fileprivate var readsOnThisMac: Bool {
        switch self {
        case .drop, .forward, .peerPaste: true
        case .paste, .preview, .copy, .dragOut: false
        }
    }
}

extension String {
    /// The string with its first character lowercased, for a phrase that
    /// continues a sentence.
    fileprivate var lowercasedFirst: String {
        guard let first else { return self }
        return first.lowercased() + dropFirst()
    }
}
