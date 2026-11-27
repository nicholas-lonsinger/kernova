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

    /// What a copy written without its `count` files over `limitBytes` says.
    private static func filesLeftOutMessage(count: Int, limitBytes: Int) -> String {
        let files = count == 1 ? "Its file was" : "Its \(count) files were"
        return "\(files) left out — over the \(ClipboardPasteLimit.displayLimit(limitBytes)) clipboard transfer limit."
    }

    /// What a copy to the Mac refused whole over `limitBytes` says.
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
                menuLine: "Clipboard: paste from the guest failed")

        case (.tooLarge(let limitBytes), .copy):
            return ClipboardTransferWording(
                headline: "Clipboard not copied from \(vm).",
                message: overCopyBudgetMessage(limitBytes: limitBytes),
                menuLine: "Clipboard: too large to copy to your Mac")

        case (.nothingToCopy, .copy):
            return ClipboardTransferWording(
                headline: "Clipboard not copied from \(vm).",
                message: "The guest\u{2019}s clipboard holds nothing that can be copied.",
                menuLine: "Clipboard: nothing to copy from the guest")

        case (.nothingToCopy, _):
            return ClipboardTransferWording(
                headline: "Clipboard not copied to \(vm).",
                message: "The Mac clipboard holds nothing that can be copied.",
                menuLine: "Clipboard: nothing to copy to the guest")

        case (.tooLarge, .drop):
            return ClipboardTransferWording(
                headline: "Files not copied to \(vm).",
                message: "The drop holds more items than can be dropped on the VM at once.",
                menuLine: "Drop: too many items to drop at once")

        case (.tooLarge(let limitBytes), _):
            return ClipboardTransferWording(
                headline: "Clipboard not pasted into \(vm).",
                message:
                    "Too large to paste into the guest — over the \(ClipboardPasteLimit.displayLimit(limitBytes)) clipboard transfer limit",
                menuLine: "Clipboard: too large to paste into the guest")

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
                headline: "Files not copied to \(vm).", message: message, menuLine: menuLine)

        case (.peerReported, _):
            return ClipboardTransferWording(
                headline: "Clipboard not pasted into \(vm).", message: "Clipboard transfer failed on the guest side",
                menuLine: "Clipboard: paste into the guest failed")

        case (.filesLeftOut(let count, let limitBytes), .copy):
            return ClipboardTransferWording(
                headline: "Clipboard copied from \(vm) without its files.",
                message: filesLeftOutMessage(count: count, limitBytes: limitBytes),
                menuLine: "Clipboard: files left out, too large to copy to your Mac")

        case (.filesLeftOut(let count, let limitBytes), _):
            return ClipboardTransferWording(
                headline: "Clipboard copied to \(vm) without its files.",
                message: filesLeftOutMessage(count: count, limitBytes: limitBytes),
                menuLine: "Clipboard: files left out, too large to copy to the guest")

        case (.interrupted(let fileCount), .drop):
            // The connection ending is all a drop observes: the VM stopping, the
            // agent quitting and the host letting go each end it the same way.
            let subject = fileCount == 1 ? "The file" : "The files"
            return ClipboardTransferWording(
                headline: "Files not copied to \(vm).",
                message: "\(subject) stopped transferring when the connection to the VM ended.",
                menuLine: "Drop: the files didn't reach the VM")

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
                headline: "Files not copied to \(vm).", message: message, menuLine: menuLine)

        case (.interrupted, _):
            return ClipboardTransferWording(
                headline: "Clipboard not pasted from \(vm).",
                message:
                    "Clipboard sharing with the VM stopped mid-transfer, so the paste didn't finish.",
                menuLine: "Clipboard: paste from the guest failed")

        case (.timedOut, .drop):
            return ClipboardTransferWording(
                headline: "Files not copied to \(vm).",
                message: "The VM stopped taking the files, so the drop was called off.",
                menuLine: "Drop: the VM stopped taking the files")

        case (.timedOut, _):
            return ClipboardTransferWording(
                headline: "Clipboard not pasted from \(vm).",
                message: "The transfer from the guest timed out, so the paste didn't finish.",
                menuLine: "Clipboard: paste from the guest timed out")

        case (.transferFailed, .copy):
            return ClipboardTransferWording(
                headline: "Clipboard not copied from \(vm).",
                message: "The guest\u{2019}s clipboard couldn\u{2019}t be copied to the Mac.",
                menuLine: "Clipboard: copy from the guest failed")

        case (.transferFailed, _):
            return ClipboardTransferWording(
                headline: "Clipboard not pasted from \(vm).",
                message: "The transfer from the guest failed, so the paste didn't finish.",
                menuLine: "Clipboard: paste from the guest failed")

        case (.sourceUnreadable, let gesture):
            let reader = gesture.readsOnThisMac ? "This Mac" : "The VM"
            let prefix = gesture == .drop ? "Drop" : "Clipboard"
            return ClipboardTransferWording(
                headline: headline(for: gesture, vm: vm),
                message: "\(reader) couldn't read one of the items, so \(unfinished(gesture)) didn't finish.",
                menuLine: "\(prefix): \(reader.lowercasedFirst) couldn't read an item")

        // Only a drag out raises a shortfall account.
        case (.stagingFailed, _), (.dragOutShortfall, _):
            return ClipboardTransferWording(
                headline: "Clipboard not pasted from \(vm).",
                message: "The copied file couldn't be saved to disk, so the paste didn't finish.",
                menuLine: "Clipboard: paste from the guest failed")

        case (.itemsSkipped(let count), .drop):
            return ClipboardTransferWording(
                headline: "Some files not copied to \(vm).",
                message:
                    "\(itemCount(count).capitalizedFirst) couldn't be read, so \(count == 1 ? "it wasn't" : "they weren't") sent to the VM. The rest were.",
                menuLine: "Drop: some files weren't sent")

        // A read of the Mac's clipboard leaves out only a file it cannot open or that is gone, the rest of its
        // item offered.
        case (.itemsSkipped(let count), _):
            return ClipboardTransferWording(
                headline: "Clipboard partly copied to \(vm).",
                message: count == 1
                    ? "One copied file couldn't be read, so it wasn't sent to the VM. Everything else was."
                    : "\(count) copied files couldn't be read, so they weren't sent to the VM. Everything else was.",
                menuLine: "Clipboard: some files weren't forwarded")

        case (.itemsUnreadable, .drop):
            return ClipboardTransferWording(
                headline: "Files not copied to \(vm).",
                message: "Those items couldn't be read, so nothing was sent to the VM.",
                menuLine: "Drop: the files didn't reach the VM")

        case (.itemsUnreadable, .copy):
            return ClipboardTransferWording(
                headline: "Clipboard not copied from \(vm).",
                message: "The guest couldn\u{2019}t read the copied files, so nothing was copied to the Mac.",
                menuLine: "Clipboard: the guest's copy couldn't be read")

        case (.itemsUnreadable, _):
            return ClipboardTransferWording(
                headline: "Clipboard not copied to \(vm).",
                message: "The copy couldn't be read, so nothing was sent to the VM.",
                menuLine: "Clipboard: the copy couldn't be read")

        case (.sendFailed, _):
            return ClipboardTransferWording(
                headline: "Files not copied to \(vm).",
                message: "The files couldn't be offered to the VM, so none were sent.",
                menuLine: "Drop: the files didn't reach the VM")
        }
    }

    /// The headline for a failure whose wording is the same whichever gesture
    /// asked for the bytes.
    private static func headline(for gesture: ClipboardTransferGesture, vm: String) -> String {
        switch gesture {
        case .copy: return "Clipboard not copied from \(vm)."
        case .forward: return "Clipboard not copied to \(vm)."
        case .drop: return "Files not copied to \(vm)."
        case .dragOut: return "Files not copied from \(vm)."
        case .peerPaste: return "Clipboard not pasted into \(vm)."
        case .paste: return "Clipboard not pasted from \(vm)."
        }
    }

    /// The wording for files dragged out of the VM display that did not reach
    /// where they were dropped on this Mac, or that could not leave the guest.
    ///
    /// Says the drag did not finish rather than that nothing arrived: a
    /// destination asks for each item in turn, so other items may be there.
    private static func dragOutWording(
        for failure: ClipboardTransferFailure, vm: String
    ) -> ClipboardTransferWording {
        let message: String
        let menuLine: String
        switch failure {
        case .dragOutShortfall(let account):
            return shortfallWording(account, vm: vm)
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
        case .tooLarge:
            message = "The drag holds more items than can be dragged out of the VM at once."
            menuLine = "Drag: too many items to drag out at once"
        case .transferFailed, .peerReported, .sourceUnreadable, .stagingFailed, .itemsSkipped, .itemsUnreadable,
            .sendFailed, .dropStopped, .nothingToCopy, .filesLeftOut:
            message = "The transfer from the VM failed, so the drag didn't finish."
            menuLine = "Drag: the files didn't reach your Mac"
        }
        return ClipboardTransferWording(
            headline: headline(for: .dragOut, vm: vm), message: message, menuLine: menuLine)
    }

    /// The wording for a drag out whose items each landed or failed on their
    /// own: how many landed of how many, how many failed for each reason, and
    /// what helps when that is known.
    ///
    /// A refused write names a step only when another item of the drag
    /// landed in the folder it was refused in: that folder takes Kernova's
    /// writes, so the refusal was of those paths alone, and a drag of fewer
    /// items asks this Mac for fewer of them. A folder in the VM holds only
    /// items that are not promises, so a refused promise leaves out that hint.
    private static func shortfallWording(_ account: DragOutAccount, vm: String) -> ClipboardTransferWording {
        let lead: String
        if account.landed > 0 {
            let verb = account.landed == 1 ? "was" : "were"
            lead = "\(account.landed.formatted()) of the \(account.items.formatted()) items \(verb) copied."
        } else {
            lead =
                account.items == 1
                ? "The item wasn't copied." : "None of the \(account.items.formatted()) items were copied."
        }
        var sentences = [lead]
        let refused = account.refused == 1 ? "it" : "them"
        if account.refused > 0 {
            sentences.append(
                "This Mac didn't allow Kernova to save \(itemCount(account.refused)) where you dropped \(refused).")
        }
        if account.unreadable > 0 {
            sentences.append("\(itemCount(account.unreadable).capitalizedFirst) couldn't be read in the VM.")
        }
        if account.unwritable > 0 {
            sentences.append("\(itemCount(account.unwritable).capitalizedFirst) couldn't be written on this Mac.")
        }
        if account.unsupplied > 0 {
            sentences.append("An app in the VM didn't supply \(itemCount(account.unsupplied)).")
        }
        if account.failed > 0 {
            sentences.append("\(itemCount(account.failed).capitalizedFirst) failed to transfer.")
        }
        let stepHolds = account.refused > 0 && account.refusedBesideLanded
        if stepHolds {
            sentences.append(
                account.refusedPromise
                    ? "Drag fewer at a time."
                    : "Drag fewer at a time, or drag a folder that holds \(refused) \u{2014} a folder goes as one item."
            )
        }
        let noun = account.items == 1 ? "item" : "items"
        return ClipboardTransferWording(
            headline: account.landed > 0 ? "Some files not copied from \(vm)." : headline(for: .dragOut, vm: vm),
            message: sentences.joined(separator: " "),
            menuLine: "Drag: \(account.landed.formatted()) of \(account.items.formatted()) \(noun) copied"
                + (stepHolds ? "; drag fewer at a time" : ""))
    }

    /// `count` items, for the middle of a sentence: "one item", or the count.
    private static func itemCount(_ count: Int) -> String {
        count == 1 ? "one item" : "\(count.formatted()) items"
    }

    /// What the gesture that did not finish is called in the sentence saying so.
    private static func unfinished(_ gesture: ClipboardTransferGesture) -> String {
        switch gesture {
        case .drop: "the drop"
        case .dragOut: "the drag"
        case .copy, .forward: "the copy"
        case .paste, .peerPaste: "the paste"
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

    private static func quoted(_ name: String) -> String { "\u{201C}\(name)\u{201D}" }
}

extension ClipboardTransferGesture {
    /// Whether the bytes this gesture moves are read on this Mac — it sends
    /// them — rather than in the VM.
    fileprivate var readsOnThisMac: Bool {
        switch self {
        case .drop, .forward, .peerPaste: true
        case .paste, .copy, .dragOut: false
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

    /// The string with its first character uppercased, for a phrase that
    /// begins a sentence.
    fileprivate var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}
