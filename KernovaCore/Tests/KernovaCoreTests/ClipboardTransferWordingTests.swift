import Foundation
import KernovaKit
import KernovaTestSupport
import Testing

@testable import KernovaCore

/// Unit tests for the one derivation of clipboard refusal copy — the clipboard
/// window's banner, the status-item notice popover, and the dropdown's per-VM
/// line all read from it.
@Suite("Clipboard Transfer Wording Tests", .caseScoped)
struct ClipboardTransferWordingTests {
    private let limit = ClipboardPasteLimit.defaultBytes
    private let vm = "Build VM"
    private let quotedVM = "\u{201C}Build VM\u{201D}"

    private func wording(
        _ failure: ClipboardTransferFailure, _ gesture: ClipboardTransferGesture
    ) -> ClipboardTransferWording? {
        ClipboardTransferWording.wording(
            for: ClipboardTransferFinish(
                gesture: gesture, outcome: .failed(failure), peerName: vm),
            vmName: vm)
    }

    /// Every (failure, gesture) pair a producer can raise.
    private var everyArm: [(ClipboardTransferFailure, ClipboardTransferGesture)] {
        [
            (.diskFull(needed: 4096, available: 1024), .paste),
            (.tooLarge(limitBytes: limit), .copy),
            (.tooLarge(limitBytes: limit), .peerPaste),
            (.peerReported(.pasteFailed), .peerPaste),
            (.peerReported(.dropDiskFull), .drop),
            (.peerReported(.dropDownloadsDenied), .drop),
            (.peerReported(.dropFailed), .drop),
            (.filesLeftOut(count: 1, limitBytes: limit), .copy),
            (.nothingToCopy, .copy),
            (.nothingToCopy, .forward),
            (.interrupted(fileCount: nil), .paste),
            (.interrupted(fileCount: 1), .drop),
            (.interrupted(fileCount: 3), .drop),
            (.timedOut, .paste),
            (.timedOut, .drop),
            (.transferFailed, .paste),
            (.transferFailed, .copy),
            (.stagingFailed, .paste),
            (.itemsSkipped(count: 2), .forward),
            (.itemsSkipped(count: 1), .drop),
            (.itemsUnreadable, .forward),
            (.itemsUnreadable, .drop),
            (.itemsUnreadable, .copy),
            (.sendFailed, .drop),
            (.tooLarge(limitBytes: 16_777_216), .drop),
            (.dropStopped(.turnedOff), .drop),
            (.dropStopped(.noAgent), .drop),
            (.dropStopped(.movedToAnotherAgent), .drop),
            (.diskFull(needed: 4096, available: 1024), .dragOut),
            (.interrupted(fileCount: nil), .dragOut),
            (.timedOut, .dragOut),
            (.transferFailed, .dragOut),
            (.stagingFailed, .dragOut),
            (.peerReported(.pasteFailed), .dragOut),
            (.peerReported(.dragItemUnavailable), .dragOut),
            (.sourceUnreadable, .dragOut),
            (.tooLarge(limitBytes: 65_536), .dragOut),
            (.sourceUnreadable, .paste),
            (.sourceUnreadable, .drop),
        ]
    }

    // MARK: - Outcomes with nothing to say

    // MARK: - Headlines

    @Test("the headline names the VM and the direction the clipboard didn't move")
    func headlinesByGesture() throws {
        #expect(
            try #require(wording(.tooLarge(limitBytes: limit), .copy)).headline
                == "Clipboard not copied from \(quotedVM).")
        #expect(
            try #require(wording(.itemsSkipped(count: 1), .forward)).headline
                == "Clipboard partly copied to \(quotedVM).")
        #expect(
            try #require(wording(.itemsUnreadable, .forward)).headline
                == "Clipboard not copied to \(quotedVM).")
        #expect(
            try #require(wording(.timedOut, .paste)).headline
                == "Clipboard not pasted from \(quotedVM).")
        #expect(
            try #require(wording(.peerReported(.pasteFailed), .peerPaste)).headline
                == "Clipboard not pasted into \(quotedVM).")
        #expect(
            try #require(wording(.sendFailed, .drop)).headline
                == "Files not copied to \(quotedVM).")
    }

    @Test("every arm names the VM in its headline")
    func everyHeadlineNamesTheVM() throws {
        for (failure, gesture) in everyArm {
            let copy = try #require(wording(failure, gesture), "\(failure) / \(gesture)")
            #expect(copy.headline.contains(quotedVM), "\(failure) / \(gesture)")
            #expect(copy.headline.hasSuffix("."), "\(failure) / \(gesture)")
        }
    }

    // MARK: - Messages

    @Test("a disk-full message appends whichever figures the failure knew")
    func diskFullDetail() throws {
        #expect(
            try #require(wording(.diskFull(needed: nil, available: nil), .paste)).message
                == "Not enough disk space to receive the clipboard payload")
        #expect(
            try #require(wording(.diskFull(needed: 4096, available: 1024), .paste)).message
                == "Not enough disk space to receive the clipboard payload (\(DataFormatters.formatBytes(4096)) needed, \(DataFormatters.formatBytes(1024)) free)"
        )
    }

    @Test("a paste-fire refusal says the paste did not finish, not that nothing landed")
    func pasteRefusalsClaimOnlyWhatIsKnown() throws {
        // The pasteboard fires once per item, so no refusal can tell a fresh
        // paste from the tail of one whose earlier files already landed.
        for failure in [
            ClipboardTransferFailure.interrupted(fileCount: nil), .timedOut, .transferFailed, .stagingFailed,
            .sourceUnreadable,
        ] {
            let message = try #require(wording(failure, .paste)).message
            #expect(message.hasSuffix("so the paste didn't finish."), "\(failure)")
            #expect(!message.contains("nothing was pasted"), "\(failure)")
        }
        // The session-end refusal names no VM disconnecting: the sharing
        // toggle and a reconnect end the session the same way.
        #expect(
            try #require(wording(.interrupted(fileCount: nil), .paste)).message
                .hasPrefix("Clipboard sharing with the VM stopped"))
    }

    @Test("an interrupted drop counts the files it was carrying, and names only the connection ending")
    func interruptedDropCountsItsFiles() throws {
        #expect(
            try #require(wording(.interrupted(fileCount: 1), .drop)).message
                == "The file stopped transferring when the connection to the VM ended.")
        #expect(
            try #require(wording(.interrupted(fileCount: 3), .drop)).message
                == "The files stopped transferring when the connection to the VM ended.")
    }

    @Test("a drop the VM refuses as too large reads as a drop, never as a clipboard paste")
    func tooLargeDropReadsAsADrop() throws {
        let copy = try #require(wording(.tooLarge(limitBytes: 16_777_216), .drop))
        #expect(copy.headline == "Files not copied to \(quotedVM).")
        #expect(copy.menuLine.hasPrefix("Drop: "))
        #expect(!copy.message.lowercased().contains("clipboard"))
        #expect(!copy.message.contains("paste"))
    }

    @Test("a drag out reads as files not copied from the VM, never as a paste or a drop")
    func dragOutWording() throws {
        for (failure, gesture) in everyArm where gesture == .dragOut {
            let copy = try #require(wording(failure, gesture), "\(failure)")
            #expect(copy.headline == "Files not copied from \(quotedVM).", "\(failure)")
            #expect(copy.menuLine.hasPrefix("Drag: "), "\(failure)")
            #expect(!copy.message.contains("paste"), "\(failure)")
            #expect(!copy.message.contains("clipboard"), "\(failure)")
        }
        #expect(
            try #require(wording(.diskFull(needed: nil, available: nil), .dragOut)).message
                == "This Mac ran out of disk space receiving the files, so the drag didn't finish.")
        #expect(
            try #require(wording(.stagingFailed, .dragOut)).message
                == "The files couldn't be saved where you dropped them, so the drag didn't finish.")
        #expect(
            try #require(wording(.peerReported(.dragItemUnavailable), .dragOut)).message
                == "An app in the VM didn't write a dragged item, so the drag didn't finish.")
    }

    @Test("an item that couldn't be read is worded by the side that read it")
    func unreadableItemWording() throws {
        let dragOut = try #require(wording(.sourceUnreadable, .dragOut))
        #expect(dragOut.headline == "Files not copied from \(quotedVM).")
        #expect(dragOut.message == "The VM couldn't read one of the items, so the drag didn't finish.")
        #expect(dragOut.menuLine == "Drag: the VM couldn't read an item")

        let paste = try #require(wording(.sourceUnreadable, .paste))
        #expect(paste.headline == "Clipboard not pasted from \(quotedVM).")
        #expect(paste.message == "The VM couldn't read one of the items, so the paste didn't finish.")
        #expect(paste.menuLine == "Clipboard: the VM couldn't read an item")

        let drop = try #require(wording(.sourceUnreadable, .drop))
        #expect(drop.message == "This Mac couldn't read one of the items, so the drop didn't finish.")
        #expect(drop.menuLine == "Drop: this Mac couldn't read an item")
    }

    @Test(
        "a drop or a forward that left unreadable files out counts them and says the rest crossed",
        arguments: [
            (
                ClipboardTransferGesture.drop, 1,
                "One item couldn't be read, so it wasn't sent to the VM. The rest were."
            ),
            (.drop, 3, "3 items couldn't be read, so they weren't sent to the VM. The rest were."),
            (
                .forward, 1,
                "One copied file couldn't be read, so it wasn't sent to the VM. Everything else was."
            ),
            (
                .forward, 3,
                "3 copied files couldn't be read, so they weren't sent to the VM. Everything else was."
            ),
        ])
    func skippedItemsMessage(gesture: ClipboardTransferGesture, count: Int, message: String) throws {
        #expect(try #require(wording(.itemsSkipped(count: count), gesture)).message == message)
    }

    // MARK: - Menu lines

    @Test("the dropdown line is a compact fragment per outcome")
    func menuLines() throws {
        let expected: [(ClipboardTransferFailure, ClipboardTransferGesture, String)] = [
            (.tooLarge(limitBytes: limit), .copy, "Clipboard: too large to copy to your Mac"),
            (
                .tooLarge(limitBytes: limit), .peerPaste,
                "Clipboard: too large to paste into the guest"
            ),
            (.peerReported(.pasteFailed), .peerPaste, "Clipboard: paste into the guest failed"),
            (.timedOut, .paste, "Clipboard: paste from the guest timed out"),
            (.transferFailed, .paste, "Clipboard: paste from the guest failed"),
            (.diskFull(needed: 1, available: 0), .paste, "Clipboard: paste from the guest failed"),
            (.itemsSkipped(count: 1), .forward, "Clipboard: some files weren't forwarded"),
            (.itemsUnreadable, .forward, "Clipboard: the copy couldn't be read"),
            (.itemsUnreadable, .copy, "Clipboard: the guest's copy couldn't be read"),
            (.peerReported(.dropDiskFull), .drop, "Drop: the VM ran out of disk space"),
            (
                .peerReported(.dropDownloadsDenied), .drop,
                "Drop: the VM's Downloads folder is off limits"
            ),
            (.peerReported(.dropFailed), .drop, "Drop: the files didn't reach the VM"),
            (.sendFailed, .drop, "Drop: the files didn't reach the VM"),
            (.dropStopped(.turnedOff), .drop, "Drop: \u{201C}Drag and drop files\u{201D} was off"),
            (.dropStopped(.noAgent), .drop, "Drop: no guest agent was taking drops"),
            (.dropStopped(.movedToAnotherAgent), .drop, "Drop: another guest agent took over drops"),
            (.itemsSkipped(count: 1), .drop, "Drop: some files weren't sent"),
            (.timedOut, .drop, "Drop: the VM stopped taking the files"),
        ]
        for (failure, gesture, line) in expected {
            #expect(
                try #require(wording(failure, gesture)).menuLine == line, "\(failure) / \(gesture)")
        }
    }
}
