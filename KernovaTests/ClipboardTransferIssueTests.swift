import Foundation
import KernovaKit
import Testing

@testable import Kernova

/// Unit tests for the display copy on `ClipboardTransferIssue`.
///
/// One source of wording for the clipboard window's banner, the status-item
/// notice popover, and the dropdown's per-VM line.
@Suite("Clipboard Transfer Issue Copy Tests")
struct ClipboardTransferIssueTests {
    private let limit = ClipboardPasteLimit.defaultBytes

    private func peerError(_ code: ClipboardErrorCode) -> ClipboardTransferIssue {
        ClipboardTransferIssue(
            kind: .peerReportedError(code: code.rawValue, message: "wire text"), date: Date())
    }

    // MARK: - displayMessage

    @Test("A guest-reported failure reads as its own explanation, not the wire text")
    func peerReportedMessages() {
        let expected: [(ClipboardErrorCode, String)] = [
            (
                .pasteTooLarge,
                "Too large to paste into the guest — over the \(ClipboardPasteLimit.displayLimit(limit)) clipboard transfer limit"
            ),
            (.pasteDiskFull, "The guest ran out of disk space receiving the clipboard file"),
            (.pasteTimeout, "The clipboard transfer to the guest timed out"),
            (.pasteFailed, "Clipboard transfer failed on the guest side"),
        ]
        for (code, message) in expected {
            #expect(peerError(code).displayMessage(pasteLimitBytes: limit) == message)
        }
    }

    @Test("An over-cap guest paste names the ceiling passed in, not the default")
    func peerReportedTooLargeNamesTheGivenCeiling() {
        let lowered = 512 * 1024 * 1024
        #expect(
            peerError(.pasteTooLarge).displayMessage(pasteLimitBytes: lowered)
                == "Too large to paste into the guest — over the \(ClipboardPasteLimit.displayLimit(lowered)) clipboard transfer limit"
        )
    }

    @Test("A disk-full notice appends whichever figures the abort knew")
    func diskFullDetail() {
        #expect(
            ClipboardTransferIssue(kind: .diskFull(needed: nil, available: nil), date: Date())
                .displayMessage(pasteLimitBytes: limit)
                == "Not enough disk space to receive the clipboard payload")
        let sized = ClipboardTransferIssue(
            kind: .diskFull(needed: 4096, available: 1024), date: Date())
        #expect(
            sized.displayMessage(pasteLimitBytes: limit)
                == "Not enough disk space to receive the clipboard payload (\(DataFormatters.formatBytes(4096)) needed, \(DataFormatters.formatBytes(1024)) free)"
        )
    }

    @Test("An outcome produced on this side shows the message it already carries")
    func localAndRetractedCarryTheirOwnMessage() {
        #expect(
            ClipboardTransferIssue.overCopyBudget(limitBytes: limit)
                .displayMessage(pasteLimitBytes: limit)
                == ClipboardTransferIssue.overCopyBudgetMessage(limitBytes: limit))
        let retracted = ClipboardTransferIssue.staleCopyRetracted()
        guard case .staleCopyRetracted(let message) = retracted.kind else {
            Issue.record("Expected a staleCopyRetracted issue, got \(retracted.kind)")
            return
        }
        #expect(retracted.displayMessage(pasteLimitBytes: limit) == message)
    }

    // MARK: - noticeHeadline

    @Test("The headline names the VM and the direction the clipboard didn't move")
    func headlinesByKind() {
        let vm = "Build VM"
        #expect(
            ClipboardTransferIssue.overCopyBudget(limitBytes: limit).noticeHeadline(vmName: vm)
                == "Clipboard not copied from \u{201C}Build VM\u{201D}.")
        #expect(
            ClipboardTransferIssue.folderSkippedForOutdatedGuest().noticeHeadline(vmName: vm)
                == "Clipboard not copied to \u{201C}Build VM\u{201D}.")
        #expect(
            ClipboardTransferIssue.forwardSkippedItems(note: "skipped").noticeHeadline(vmName: vm)
                == "Clipboard not copied to \u{201C}Build VM\u{201D}.")
        for issue in [
            ClipboardTransferIssue.partialFileSetUnservable(),
            .pasteTimedOut(),
            .pasteTransferFailed(),
            .pasteFolderUnpackFailed(),
            .pasteFileStagingFailed(),
            ClipboardTransferIssue(kind: .diskFull(needed: 1, available: 0), date: Date()),
        ] {
            #expect(
                issue.noticeHeadline(vmName: vm) == "Clipboard not pasted from \u{201C}Build VM\u{201D}.")
        }
        #expect(
            peerError(.pasteFailed).noticeHeadline(vmName: vm)
                == "Clipboard not pasted into \u{201C}Build VM\u{201D}.")
        #expect(
            ClipboardTransferIssue.staleCopyRetracted().noticeHeadline(vmName: vm)
                == "Clipboard changed in \u{201C}Build VM\u{201D}.")
    }

    @Test("A local failure carrying an unrecognized code falls back to a neutral headline")
    func unknownLocalCodeHeadline() {
        let issue = ClipboardTransferIssue(
            kind: .localFailure(code: "clipboard.unheard.of", message: "…"), date: Date())
        #expect(issue.noticeHeadline(vmName: "VM") == "Clipboard issue with \u{201C}VM\u{201D}.")
    }

    // MARK: - includesStaleClipboardContext

    @Test("Only the over-cap copy refusal may say the Mac clipboard is unchanged")
    func staleContextIsCopyRefusalOnly() {
        #expect(
            ClipboardTransferIssue.overCopyBudget(limitBytes: limit).includesStaleClipboardContext)
        for issue in [
            ClipboardTransferIssue.partialFileSetUnservable(),
            .pasteTimedOut(),
            .pasteTransferFailed(),
            .folderSkippedForOutdatedGuest(),
            .forwardSkippedItems(note: "skipped"),
            .staleCopyRetracted(),
            ClipboardTransferIssue(kind: .diskFull(needed: 1, available: 0), date: Date()),
            peerError(.pasteTooLarge),
        ] {
            #expect(!issue.includesStaleClipboardContext, "\(issue.kind) must not claim it")
        }
    }

    // MARK: - warrantsInterruptingNotice

    @Test("Only a refusal of a gesture made on this Mac interrupts on this side")
    func interruptingNoticeIsHostSideOnly() {
        for issue in [
            ClipboardTransferIssue.overCopyBudget(limitBytes: limit),
            .partialFileSetUnservable(),
            .pasteTimedOut(),
            .pasteTransferFailed(),
            .folderSkippedForOutdatedGuest(),
            .forwardSkippedItems(note: "skipped"),
            .staleCopyRetracted(),
            ClipboardTransferIssue(kind: .diskFull(needed: 1, available: 0), date: Date()),
        ] {
            #expect(issue.warrantsInterruptingNotice, "\(issue.kind) must interrupt here")
        }
        for code in [
            ClipboardErrorCode.pasteTooLarge, .pasteDiskFull, .pasteTimeout, .pasteFailed,
        ] {
            #expect(
                !peerError(code).warrantsInterruptingNotice,
                "\(code.rawValue) is the guest's own refusal to report")
        }
    }

    // MARK: - menuLineText

    @Test("The dropdown line is a compact fragment per outcome")
    func menuLines() {
        #expect(
            ClipboardTransferIssue.overCopyBudget(limitBytes: limit).menuLineText
                == "Clipboard: too large to copy to your Mac")
        #expect(
            ClipboardTransferIssue.pasteTimedOut().menuLineText
                == "Clipboard: paste from the guest timed out")
        #expect(
            ClipboardTransferIssue.pasteTransferFailed().menuLineText
                == "Clipboard: paste from the guest failed")
        #expect(
            ClipboardTransferIssue.partialFileSetUnservable().menuLineText
                == "Clipboard: paste from the guest failed")
        #expect(
            ClipboardTransferIssue(kind: .diskFull(needed: 1, available: 0), date: Date())
                .menuLineText == "Clipboard: paste from the guest failed")
        #expect(peerError(.pasteFailed).menuLineText == "Clipboard: paste into the guest failed")
        #expect(
            peerError(.pasteTooLarge).menuLineText == "Clipboard: too large to paste into the guest")
        #expect(
            ClipboardTransferIssue.staleCopyRetracted().menuLineText
                == "Clipboard: earlier copy was removed")
        #expect(
            ClipboardTransferIssue.folderSkippedForOutdatedGuest().menuLineText
                == "Clipboard: folder copy needs a guest agent update")
        #expect(
            ClipboardTransferIssue.forwardSkippedItems(note: "skipped").menuLineText
                == "Clipboard: some items weren't forwarded")
    }

    @Test("No dropdown line ends in a period — they read as menu rows, not prose")
    func menuLinesAreFragments() {
        for issue in [
            ClipboardTransferIssue.overCopyBudget(limitBytes: limit),
            .pasteTimedOut(),
            .pasteTransferFailed(),
            .staleCopyRetracted(),
            .folderSkippedForOutdatedGuest(),
            peerError(.pasteFailed),
        ] {
            #expect(!issue.menuLineText.hasSuffix("."))
        }
    }
}
