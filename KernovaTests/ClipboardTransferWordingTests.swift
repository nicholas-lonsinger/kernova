import Foundation
import KernovaKit
import Testing

@testable import Kernova

/// Unit tests for the one derivation of clipboard refusal copy — the clipboard
/// window's banner, the status-item notice popover, and the dropdown's per-VM
/// line all read from it.
@Suite("Clipboard Transfer Wording Tests", .admissionGated)
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
            (.diskFull(needed: nil, available: nil), .preview),
            (.tooLarge(limitBytes: limit), .copy),
            (.tooLarge(limitBytes: limit), .peerPaste),
            (.peerReported(.pasteDiskFull), .peerPaste),
            (.peerReported(.pasteTimeout), .peerPaste),
            (.peerReported(.pasteFailed), .peerPaste),
            (.peerReported(nil), .peerPaste),
            (.peerReported(.dropDiskFull), .drop),
            (.peerReported(.dropDownloadsDenied), .drop),
            (.peerReported(.dropFailed), .drop),
            (.supersededCopyRetracted(hasSuccessor: true), .copy),
            (.supersededCopyRetracted(hasSuccessor: false), .copy),
            (.incompleteFileSet, .paste),
            (.interrupted(fileCount: nil), .paste),
            (.interrupted(fileCount: 1), .drop),
            (.interrupted(fileCount: 3), .drop),
            (.timedOut, .paste),
            (.timedOut, .preview),
            (.timedOut, .drop),
            (.transferFailed, .paste),
            (.transferFailed, .preview),
            (.unpackFailed, .paste),
            (.unpackFailed, .preview),
            (.stagingFailed, .paste),
            (.itemsSkipped(note: "Some items couldn't be read."), .forward),
            (.itemsSkipped(note: "One item couldn't be read."), .drop),
            (.itemsUnreadable, .drop),
            (.sendFailed, .drop),
            (.unclaimed, .drop),
        ]
    }

    // MARK: - Outcomes with nothing to say

    @Test("an operation that delivered what was asked for has no wording")
    func successHasNoWording() {
        let snapshot = ClipboardProgressSnapshot(
            direction: .inbound, peerName: vm, currentItemName: nil, filesCompleted: 1,
            fileCount: 1, bytesTransferred: 10, totalBytes: 10, bytesPerSecond: nil,
            secondsRemaining: nil, gesture: .paste, elapsedSeconds: 1)
        for outcome in [
            ClipboardTransferOutcome.completed(final: snapshot), .cancelled(final: snapshot),
        ] {
            let finish = ClipboardTransferFinish(
                gesture: .paste, outcome: outcome, peerName: vm)
            #expect(ClipboardTransferWording.wording(for: finish, vmName: vm) == nil)
        }
    }

    // MARK: - Headlines

    @Test("the headline names the VM and the direction the clipboard didn't move")
    func headlinesByGesture() throws {
        #expect(
            try #require(wording(.tooLarge(limitBytes: limit), .copy)).headline
                == "Clipboard not copied from \(quotedVM).")
        #expect(
            try #require(wording(.itemsSkipped(note: "n"), .forward)).headline
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
        #expect(
            try #require(wording(.transferFailed, .preview)).headline
                == "Clipboard preview from \(quotedVM) failed.")
        #expect(
            try #require(wording(.supersededCopyRetracted(hasSuccessor: true), .copy)).headline
                == "Clipboard changed in \(quotedVM).")
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

    @Test("a guest-reported failure reads as its own explanation, not the wire text")
    func peerReportedMessages() throws {
        let expected: [(ClipboardErrorCode?, String)] = [
            (.pasteDiskFull, "The guest ran out of disk space receiving the clipboard file"),
            (.pasteTimeout, "The clipboard transfer to the guest timed out"),
            (.pasteFailed, "Clipboard transfer failed on the guest side"),
            (nil, "Clipboard transfer failed on the guest side"),
        ]
        for (code, message) in expected {
            #expect(
                try #require(wording(.peerReported(code), .peerPaste)).message == message,
                "\(String(describing: code))")
        }
        #expect(
            try #require(wording(.tooLarge(limitBytes: limit), .peerPaste)).message
                == "Too large to paste into the guest — over the \(ClipboardPasteLimit.displayLimit(limit)) clipboard transfer limit"
        )
    }

    @Test("an over-cap refusal names the ceiling in force when it was raised")
    func tooLargeNamesTheGivenCeiling() throws {
        let lowered = 512 * 1024 * 1024
        #expect(
            try #require(wording(.tooLarge(limitBytes: lowered), .peerPaste)).message
                .contains(ClipboardPasteLimit.displayLimit(lowered)))
        #expect(
            try #require(wording(.tooLarge(limitBytes: lowered), .copy)).message
                == ClipboardTransferWording.overCopyBudgetMessage(limitBytes: lowered))
    }

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

    @Test("a retraction points at Copy to Mac only when an offer replaced what it removed")
    func retractionNamesCopyToMacOnlyWithASuccessor() throws {
        let replaced = try #require(wording(.supersededCopyRetracted(hasSuccessor: true), .copy))
        let unreplaced = try #require(wording(.supersededCopyRetracted(hasSuccessor: false), .copy))
        #expect(replaced.message.contains("use Copy to Mac"))
        // Without a successor the click has nothing to fetch, so the sentence
        // stops at what happened.
        #expect(!unreplaced.message.contains("use Copy to Mac"))
        #expect(unreplaced.message.hasSuffix("removed from the Mac clipboard."))
    }

    @Test("a paste-fire refusal says the paste did not finish, not that nothing landed")
    func pasteRefusalsClaimOnlyWhatIsKnown() throws {
        // The pasteboard fires once per item, so no refusal can tell a fresh
        // paste from the tail of one whose earlier files already landed.
        for failure in [
            ClipboardTransferFailure.incompleteFileSet, .interrupted(fileCount: nil), .timedOut,
            .transferFailed, .unpackFailed, .stagingFailed,
        ] {
            let message = try #require(wording(failure, .paste)).message
            #expect(message.hasSuffix("so the paste didn't finish."), "\(failure)")
            #expect(!message.contains("nothing was pasted"), "\(failure)")
        }
        // Neither session-end refusal names the VM disconnecting: the sharing
        // toggle and a reconnect end the session the same way.
        for failure in [
            ClipboardTransferFailure.incompleteFileSet, .interrupted(fileCount: nil),
        ] {
            #expect(
                try #require(wording(failure, .paste)).message
                    .hasPrefix("Clipboard sharing with the VM stopped"), "\(failure)")
        }
    }

    @Test("a failed preview never claims a paste happened")
    func previewNeverSpeaksOfAPaste() throws {
        for failure in [
            ClipboardTransferFailure.timedOut, .transferFailed, .unpackFailed,
        ] {
            let copy = try #require(wording(failure, .preview))
            #expect(copy.message == "The preview from the guest couldn't be loaded.", "\(failure)")
            #expect(!copy.message.contains("paste"), "\(failure)")
            #expect(!copy.menuLine.contains("paste"), "\(failure)")
        }
    }

    @Test("an interrupted drop counts the files it was carrying")
    func interruptedDropCountsItsFiles() throws {
        #expect(
            try #require(wording(.interrupted(fileCount: 1), .drop)).message
                == "The file stopped transferring when the VM disconnected.")
        #expect(
            try #require(wording(.interrupted(fileCount: 3), .drop)).message
                == "The files stopped transferring when the VM disconnected.")
    }

    @Test("a guest drop failure says the drop didn't finish, not that nothing was saved")
    func dropFailureWording() throws {
        #expect(
            try #require(wording(.peerReported(.dropDiskFull), .drop)).message
                == "The VM ran out of disk space, so the drop didn't finish.")
        #expect(
            try #require(wording(.peerReported(.dropDownloadsDenied), .drop)).message
                == "The guest agent isn't allowed to use the VM's Downloads folder, so the drop didn't finish."
        )
        #expect(
            try #require(wording(.peerReported(.dropFailed), .drop)).message
                == "The drop didn't finish — some files may not be in the VM's Downloads folder.")
    }

    @Test("a passthrough forward shows the intake's own note")
    func forwardShowsTheIntakeNote() throws {
        let note = "Some items couldn't be read."
        #expect(try #require(wording(.itemsSkipped(note: note), .forward)).message == note)
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
            (.incompleteFileSet, .paste, "Clipboard: paste from the guest failed"),
            (.diskFull(needed: 1, available: 0), .paste, "Clipboard: paste from the guest failed"),
            (.transferFailed, .preview, "Clipboard: preview from the guest failed"),
            (
                .supersededCopyRetracted(hasSuccessor: true), .copy,
                "Clipboard: earlier copy was removed"
            ),
            (.itemsSkipped(note: "n"), .forward, "Clipboard: some items weren't forwarded"),
            (.peerReported(.dropDiskFull), .drop, "Drop: the VM ran out of disk space"),
            (
                .peerReported(.dropDownloadsDenied), .drop,
                "Drop: the VM's Downloads folder is off limits"
            ),
            (.peerReported(.dropFailed), .drop, "Drop: the files didn't reach the VM"),
            (.sendFailed, .drop, "Drop: the files didn't reach the VM"),
            (.itemsSkipped(note: "n"), .drop, "Drop: some files weren't sent"),
            (.unclaimed, .drop, "Drop: the VM never took the files"),
            (.timedOut, .drop, "Drop: the VM stopped taking the files"),
        ]
        for (failure, gesture, line) in expected {
            #expect(
                try #require(wording(failure, gesture)).menuLine == line, "\(failure) / \(gesture)")
        }
    }

    @Test("no dropdown line ends in a period — they read as menu rows, not prose")
    func menuLinesAreFragments() throws {
        for (failure, gesture) in everyArm {
            #expect(
                !(try #require(wording(failure, gesture)).menuLine.hasSuffix(".")),
                "\(failure) / \(gesture)")
        }
    }

    // MARK: - The Mac-clipboard aside

    @Test("only the over-cap copy refusal may say the Mac clipboard is unchanged")
    func staleContextIsCopyRefusalOnly() throws {
        #expect(try #require(wording(.tooLarge(limitBytes: limit), .copy)).mentionsMacClipboardKept)
        for (failure, gesture) in everyArm where !(gesture == .copy && isTooLarge(failure)) {
            #expect(
                !(try #require(wording(failure, gesture)).mentionsMacClipboardKept),
                "\(failure) / \(gesture) must not claim it")
        }
    }

    private func isTooLarge(_ failure: ClipboardTransferFailure) -> Bool {
        guard case .tooLarge = failure else { return false }
        return true
    }
}
