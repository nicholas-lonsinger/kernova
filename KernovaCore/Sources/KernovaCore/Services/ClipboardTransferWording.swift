import Foundation
import KernovaKit
import KernovaTransferProgress

/// The sentences one refused clipboard or drop transfer is rendered with,
/// derived once from the failure and the gesture that produced it.
///
/// Every surface reads the same value: the status-item notice takes `headline`
/// and `message`, and the dropdown's per-VM line takes `menuLine`.
package struct ClipboardTransferWording: Equatable {
    /// The notice's bold first line, naming the VM and which direction the
    /// clipboard failed to move in.
    package let headline: String
    /// The full sentence — the notice's body.
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

    /// Shown for a copy to the Mac refused over the deadline-safe cap: a copy
    /// command's and a passthrough publish's are the same refusal.
    /// What a copy written without its `count` files over `limitBytes` says.
    private static func filesLeftOutMessage(count: Int, limitBytes: Int) -> String {
        let files = count == 1 ? "Its file was" : "Its \(count) files were"
        return "\(files) left out — over the \(ClipboardPasteLimit.displayLimit(limitBytes)) clipboard transfer limit."
    }

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
        case (_, .dragOut):
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

        case (.tooLarge(let limitBytes), .send):
            return ClipboardTransferWording(
                headline: "Clipboard not copied to \(vm).",
                message:
                    "Too large to copy to the guest — over the \(ClipboardPasteLimit.displayLimit(limitBytes)) clipboard transfer limit.",
                menuLine: "Clipboard: too large to copy to the guest",
                mentionsMacClipboardKept: false)

        case (.clipboardChanged, .copy):
            return ClipboardTransferWording(
                headline: "Clipboard not copied from \(vm).",
                message:
                    "The Mac clipboard changed before the guest\u{2019}s clipboard arrived, so it was left as it is.",
                menuLine: "Clipboard: the Mac clipboard changed first",
                mentionsMacClipboardKept: false)

        case (.clipboardChanged, _):
            return ClipboardTransferWording(
                headline: "Clipboard not copied to \(vm).",
                message:
                    "The guest\u{2019}s clipboard changed before the Mac\u{2019}s arrived, so it was left as it is.",
                menuLine: "Clipboard: the guest\u{2019}s clipboard changed first",
                mentionsMacClipboardKept: false)

        case (.nothingToCopy, .copy):
            return ClipboardTransferWording(
                headline: "Clipboard not copied from \(vm).",
                message: "The guest\u{2019}s clipboard holds nothing that can be copied.",
                menuLine: "Clipboard: nothing to copy from the guest",
                mentionsMacClipboardKept: false)

        case (.nothingToCopy, _):
            return ClipboardTransferWording(
                headline: "Clipboard not copied to \(vm).",
                message: "The Mac clipboard holds nothing that can be copied.",
                menuLine: "Clipboard: nothing to copy to the guest",
                mentionsMacClipboardKept: false)

        case (.noTextToCopy, _):
            return ClipboardTransferWording(
                headline: "Clipboard not copied to \(vm).",
                message: "The Mac clipboard holds no text, and text is all this VM\u{2019}s clipboard sharing carries.",
                menuLine: "Clipboard: no text to copy to the guest",
                mentionsMacClipboardKept: false)

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

        case (.peerReported, _):
            return ClipboardTransferWording(
                headline: "Clipboard not pasted into \(vm).", message: "Clipboard transfer failed on the guest side",
                menuLine: "Clipboard: paste into the guest failed",
                mentionsMacClipboardKept: false)

        case (.disconnectedCopyRetracted, _):
            return ClipboardTransferWording(
                headline: "Clipboard sharing stopped in \(vm).",
                message:
                    "Clipboard sharing with the VM stopped, so the earlier copy was removed from the Mac clipboard.",
                menuLine: "Clipboard: earlier copy was removed",
                mentionsMacClipboardKept: false)

        case (.disconnectedFilesRetracted, _):
            return ClipboardTransferWording(
                headline: "Clipboard sharing stopped in \(vm).",
                message:
                    "Clipboard sharing with the VM stopped, so the copied files were removed from the Mac clipboard. The rest of the copy is still there.",
                menuLine: "Clipboard: copied files were removed",
                mentionsMacClipboardKept: false)

        case (.withdrawnCopyRetracted, _):
            return ClipboardTransferWording(
                headline: "Clipboard copy withdrawn by \(vm).",
                message: "The VM withdrew the earlier copy, so it was removed from the Mac clipboard.",
                menuLine: "Clipboard: earlier copy was withdrawn",
                mentionsMacClipboardKept: false)

        case (.withdrawnFilesRetracted, _):
            return ClipboardTransferWording(
                headline: "Clipboard copy withdrawn by \(vm).",
                message:
                    "The VM withdrew the earlier copy, so its files were removed from the Mac clipboard. The rest of the copy is still there.",
                menuLine: "Clipboard: copied files were withdrawn",
                mentionsMacClipboardKept: false)

        case (.filesLeftOut(let count, let limitBytes), .copy):
            return ClipboardTransferWording(
                headline: "Clipboard copied from \(vm) without its files.",
                message: filesLeftOutMessage(count: count, limitBytes: limitBytes),
                menuLine: "Clipboard: files left out, too large to copy to your Mac",
                mentionsMacClipboardKept: false)

        case (.filesLeftOut(let count, let limitBytes), _):
            return ClipboardTransferWording(
                headline: "Clipboard copied to \(vm) without its files.",
                message: filesLeftOutMessage(count: count, limitBytes: limitBytes),
                menuLine: "Clipboard: files left out, too large to copy to the guest",
                mentionsMacClipboardKept: false)

        case (.partsGone, .copy):
            return ClipboardTransferWording(
                headline: "Clipboard copied from \(vm) without some of it.",
                message:
                    "Part of the guest\u{2019}s clipboard was what the Mac sent it, and the Mac no longer has it, so it was left out.",
                menuLine: "Clipboard: part of the copy was no longer on the Mac",
                mentionsMacClipboardKept: false)

        case (.partsGone, _):
            return ClipboardTransferWording(
                headline: "Clipboard copied to \(vm) without some of it.",
                message:
                    "Part of the Mac clipboard was what the guest sent it, and the guest no longer has it, so it was left out.",
                menuLine: "Clipboard: part of the copy was no longer in the guest",
                mentionsMacClipboardKept: false)

        case (.interrupted(let fileCount), .drop):
            // The connection ending is all a drop observes: the VM stopping, the
            // agent quitting and the host letting go each end it the same way.
            let subject = fileCount == 1 ? "The file" : "The files"
            return ClipboardTransferWording(
                headline: "Files not copied to \(vm).",
                message: "\(subject) stopped transferring when the connection to the VM ended.",
                menuLine: "Drop: the files didn't reach the VM",
                mentionsMacClipboardKept: false)

        case (.dropStopped(let stop), _):
            let message: String
            let menuLine: String
            switch stop {
            case .turnedOff:
                message = "\u{201C}Drag and drop files\u{201D} was off in the VM's settings, so the drop didn't finish."
                menuLine = "Drop: \u{201C}Drag and drop files\u{201D} was off"
            case .noAgent:
                message = "No guest agent in the VM was taking drops, so the drop didn't finish."
                menuLine = "Drop: no guest agent was taking drops"
            case .movedToAnotherAgent:
                message = "Another guest agent in the VM took over drops, so the drop didn't finish."
                menuLine = "Drop: another guest agent took over drops"
            }
            return ClipboardTransferWording(
                headline: "Files not copied to \(vm).", message: message, menuLine: menuLine,
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

        case (.transferFailed, .preview), (.stagingFailed, .preview), (.sourceUnreadable, .preview):
            return ClipboardTransferWording(
                headline: "Clipboard preview from \(vm) failed.",
                message: "The preview from the guest couldn't be loaded.",
                menuLine: "Clipboard: preview from the guest failed",
                mentionsMacClipboardKept: false)

        case (.transferFailed, .copy):
            return ClipboardTransferWording(
                headline: "Clipboard not copied from \(vm).",
                message: "The guest\u{2019}s clipboard couldn\u{2019}t be copied to the Mac.",
                menuLine: "Clipboard: copy from the guest failed",
                mentionsMacClipboardKept: false)

        case (.transferFailed, .send):
            return ClipboardTransferWording(
                headline: "Clipboard not copied to \(vm).",
                message: "The Mac clipboard couldn\u{2019}t be copied to the guest.",
                menuLine: "Clipboard: copy to the guest failed",
                mentionsMacClipboardKept: false)

        case (.transferFailed, _):
            return ClipboardTransferWording(
                headline: "Clipboard not pasted from \(vm).",
                message: "The transfer from the guest failed, so the paste didn't finish.",
                menuLine: "Clipboard: paste from the guest failed",
                mentionsMacClipboardKept: false)

        case (.sourceUnreadable, let gesture):
            let reader = gesture.readsOnThisMac ? "This Mac" : "The VM"
            let prefix = gesture == .drop ? "Drop" : "Clipboard"
            return ClipboardTransferWording(
                headline: headline(for: gesture, vm: vm),
                message: "\(reader) couldn't read one of the items, so \(unfinished(gesture)) didn't finish.",
                menuLine: "\(prefix): \(reader.lowercasedFirst) couldn't read an item",
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
                message: count == 1
                    ? "One item couldn't be read, so it wasn't sent to the VM. The rest were."
                    : "\(count) items couldn't be read, so they weren't sent to the VM. The rest were.",
                menuLine: "Drop: some files weren't sent",
                mentionsMacClipboardKept: false)

        // A snapshot leaves a file out of an item when it cannot open it or it is gone, and a representation
        // when it cannot read or pull it, the item dropped once nothing of it is left; the count alone crosses,
        // so neither command names what of an item was left out.
        case (.itemsSkipped(let count), .copy):
            return ClipboardTransferWording(
                headline: "Clipboard partly copied from \(vm).",
                message: count == 1
                    ? "One item on the guest\u{2019}s clipboard wasn\u{2019}t copied to the Mac in full. The rest were."
                    : "\(count) items on the guest\u{2019}s clipboard weren\u{2019}t copied to the Mac in full. The rest were.",
                menuLine: "Clipboard: some items weren't copied in full from the guest",
                mentionsMacClipboardKept: false)

        case (.itemsSkipped(let count), .send):
            return ClipboardTransferWording(
                headline: "Clipboard partly copied to \(vm).",
                message: count == 1
                    ? "One item on the Mac clipboard wasn\u{2019}t copied to the guest in full. The rest were."
                    : "\(count) items on the Mac clipboard weren\u{2019}t copied to the guest in full. The rest were.",
                menuLine: "Clipboard: some items weren't copied in full to the guest",
                mentionsMacClipboardKept: false)

        // Passthrough's offer leaves out only a file it cannot open or that is gone, the rest of its item offered.
        case (.itemsSkipped(let count), _):
            return ClipboardTransferWording(
                headline: "Clipboard partly copied to \(vm).",
                message: count == 1
                    ? "One copied file couldn't be read, so it wasn't sent to the VM. Everything else was."
                    : "\(count) copied files couldn't be read, so they weren't sent to the VM. Everything else was.",
                menuLine: "Clipboard: some files weren't forwarded",
                mentionsMacClipboardKept: false)

        case (.itemsUnreadable, .drop):
            return ClipboardTransferWording(
                headline: "Files not copied to \(vm).",
                message: "Those items couldn't be read, so nothing was sent to the VM.",
                menuLine: "Drop: the files didn't reach the VM",
                mentionsMacClipboardKept: false)

        case (.itemsUnreadable, .copy):
            return ClipboardTransferWording(
                headline: "Clipboard not copied from \(vm).",
                message: "The guest couldn\u{2019}t read the copied files, so nothing was copied to the Mac.",
                menuLine: "Clipboard: the guest's copy couldn't be read",
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
                message: "The files couldn't be offered to the VM, so none were sent.",
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
        case .forward, .send: return "Clipboard not copied to \(vm)."
        case .drop: return "Files not copied to \(vm)."
        case .dragOut: return "Files not copied from \(vm)."
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
        case .stagingFailed:
            message = "The files couldn't be saved where you dropped them, so the drag didn't finish."
            menuLine = "Drag: the files couldn't be saved"
        case .peerReported(.dragItemUnavailable):
            message = "An app in the VM didn't write a dragged item, so the drag didn't finish."
            menuLine = "Drag: an app in the VM didn't write an item"
        case .peerReported:
            message = "The VM couldn't send the files, so the drag didn't finish."
            menuLine = "Drag: the files didn't reach your Mac"
        case .sourceUnreadable:
            message = "The VM couldn't read one of the items, so the drag didn't finish."
            menuLine = "Drag: the VM couldn't read an item"
        case .tooLarge, .disconnectedCopyRetracted, .disconnectedFilesRetracted, .withdrawnCopyRetracted,
            .withdrawnFilesRetracted, .transferFailed, .itemsSkipped, .itemsUnreadable, .sendFailed, .dropStopped,
            .clipboardChanged, .nothingToCopy, .filesLeftOut, .partsGone, .noTextToCopy:
            message = "The transfer from the VM failed, so the drag didn't finish."
            menuLine = "Drag: the files didn't reach your Mac"
        }
        return ClipboardTransferWording(
            headline: headline(for: .dragOut, vm: vm), message: message, menuLine: menuLine,
            mentionsMacClipboardKept: false)
    }

    /// What the gesture that did not finish is called in the sentence saying so.
    private static func unfinished(_ gesture: ClipboardTransferGesture) -> String {
        switch gesture {
        case .drop: "the drop"
        case .dragOut: "the drag"
        case .copy, .forward, .send: "the copy"
        case .paste, .preview: "the paste"
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
    private static func quoted(_ name: String) -> String { "\u{201C}\(name)\u{201D}" }
}

extension ClipboardTransferGesture {
    /// Whether the bytes this gesture moves are read on this Mac — it sends
    /// them — rather than in the VM.
    fileprivate var readsOnThisMac: Bool {
        switch self {
        case .drop, .forward, .send: true
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
