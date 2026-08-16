import Foundation
import KernovaKit
import Testing

@testable import Kernova

/// Unit tests for `ClipboardTransferIssue` — the classification an aborted
/// inbound pull lands on, and the display copy each outcome reads as.
///
/// One source of wording for the clipboard window's banner, the status-item
/// notice popover, and the dropdown's per-VM line.
@Suite("Clipboard Transfer Issue Tests")
struct ClipboardTransferIssueTests {
    private let limit = ClipboardPasteLimit.defaultBytes

    private func peerError(_ code: ClipboardErrorCode) -> ClipboardTransferIssue {
        ClipboardTransferIssue(
            kind: .peerReportedError(code: code.rawValue, message: "wire text"), date: Date())
    }

    private func abortInfo(_ code: ClipboardStreamAbortCode) -> ClipboardStreamAbortInfo {
        ClipboardStreamAbortInfo(
            transferID: 1, code: code, message: "aborted", neededBytes: nil, availableBytes: nil)
    }

    // MARK: - inboundPullAborted

    @Test(
        "An abort that retires the transfer classifies to no issue",
        arguments: Array(ClipboardStreamAbortCode.retiring))
    func retiringAbortsClassifyToNothing(code: ClipboardStreamAbortCode) {
        #expect(ClipboardTransferIssue.inboundPullAborted(abortInfo(code)) == nil)
    }

    /// Runs over `allCases` and spells every one of them, with no `default:`, so
    /// a code added to `ClipboardStreamAbortCode` fails to compile here until
    /// someone states what it classifies to. The implementation's own `default:`
    /// keeps an unstated code reported rather than swallowed; this is what makes
    /// falling into it a decision rather than an oversight.
    @Test(
        "Every abort that is not a retirement classifies to a reportable issue",
        arguments: ClipboardStreamAbortCode.allCases.filter {
            !ClipboardStreamAbortCode.retiring.contains($0)
        })
    func failedAbortsClassifyToAnIssue(code: ClipboardStreamAbortCode) {
        let kind = ClipboardTransferIssue.inboundPullAborted(abortInfo(code))?.kind
        switch code {
        case .diskFull:
            guard case .diskFull = kind else {
                Issue.record("\(code.rawValue) should report the disk, got \(String(describing: kind))")
                return
            }
        case .extractError:
            #expect(kind == ClipboardTransferIssue.pasteUnpackFailed().kind)
        case .requestRange, .requestUTI, .requestCancelled, .readError, .sendFailed, .ackTimeout,
            .offsetGap, .chunkEmpty, .chunkTooLarge, .sizeOverrun, .flowOverrun, .sizeMismatch,
            .digestMismatch, .payloadUnsupported, .payloadUnexpected, .payloadInvalid, .writeError,
            .stageError, .mapError, .stallTimeout, .pasteTimeout:
            #expect(kind == ClipboardTransferIssue.pasteTransferFailed().kind)
        case .cancelled, .superseded, .requestStale, .userCancelled:
            Issue.record("\(code.rawValue) retires the transfer and is covered by the case above")
        }
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
        let retracted = ClipboardTransferIssue.staleCopyRetracted(hasSuccessor: true)
        guard case .staleCopyRetracted(let message) = retracted.kind else {
            Issue.record("Expected a staleCopyRetracted issue, got \(retracted.kind)")
            return
        }
        #expect(retracted.displayMessage(pasteLimitBytes: limit) == message)
    }

    @Test("A retraction points at Copy to Mac only when an offer replaced the one it removed")
    func retractionNamesCopyToMacOnlyWithASuccessor() {
        let replaced = ClipboardTransferIssue.staleCopyRetracted(hasSuccessor: true)
            .displayMessage(pasteLimitBytes: limit)
        let unreplaced = ClipboardTransferIssue.staleCopyRetracted(hasSuccessor: false)
            .displayMessage(pasteLimitBytes: limit)
        #expect(replaced.contains("use Copy to Mac"))
        // Without a successor the click has nothing to fetch, so the sentence
        // stops at what happened.
        #expect(!unreplaced.contains("use Copy to Mac"))
        #expect(unreplaced.hasSuffix("removed from the Mac clipboard."))
    }

    @Test("A paste the VM's disconnect cut short says it did not finish, not that nothing landed")
    func interruptedPastesClaimOnlyWhatIsKnown() {
        // Neither refusal can tell a fresh paste from the tail of one whose
        // earlier files already landed, so neither says nothing was pasted.
        for issue in [
            ClipboardTransferIssue.partialFileSetUnservable(), .pasteInterrupted(),
        ] {
            let message = issue.displayMessage(pasteLimitBytes: limit)
            #expect(message.hasPrefix("The VM disconnected"), "\(issue.kind)")
            #expect(message.hasSuffix("so the paste didn't finish."), "\(issue.kind)")
            #expect(!message.contains("nothing was pasted"), "\(issue.kind)")
        }
        #expect(
            ClipboardTransferIssue.pasteInterrupted().kind
                == .localFailure(
                    code: ClipboardErrorCode.pasteFailed.rawValue,
                    message: ClipboardTransferIssue.pasteInterrupted()
                        .displayMessage(pasteLimitBytes: limit)))
    }

    // MARK: - noticeHeadline

    @Test("The headline names the VM and the direction the clipboard didn't move")
    func headlinesByKind() {
        let vm = "Build VM"
        #expect(
            ClipboardTransferIssue.overCopyBudget(limitBytes: limit).noticeHeadline(vmName: vm)
                == "Clipboard not copied from \u{201C}Build VM\u{201D}.")
        #expect(
            ClipboardTransferIssue.forwardSkippedItems(note: "skipped").noticeHeadline(vmName: vm)
                == "Clipboard not copied to \u{201C}Build VM\u{201D}.")
        for issue in [
            ClipboardTransferIssue.partialFileSetUnservable(),
            .pasteTimedOut(),
            .pasteInterrupted(),
            .pasteTransferFailed(),
            .pasteUnpackFailed(),
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
            ClipboardTransferIssue.staleCopyRetracted(hasSuccessor: true).noticeHeadline(vmName: vm)
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
            .pasteInterrupted(),
            .pasteTransferFailed(),
            .forwardSkippedItems(note: "skipped"),
            .staleCopyRetracted(hasSuccessor: true),
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
            .pasteInterrupted(),
            .pasteTransferFailed(),
            .forwardSkippedItems(note: "skipped"),
            .staleCopyRetracted(hasSuccessor: true),
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
            ClipboardTransferIssue.staleCopyRetracted(hasSuccessor: true).menuLineText
                == "Clipboard: earlier copy was removed")
        #expect(
            ClipboardTransferIssue.forwardSkippedItems(note: "skipped").menuLineText
                == "Clipboard: some items weren't forwarded")
    }

    @Test("No dropdown line ends in a period — they read as menu rows, not prose")
    func menuLinesAreFragments() {
        for issue in [
            ClipboardTransferIssue.overCopyBudget(limitBytes: limit),
            .pasteTimedOut(),
            .pasteInterrupted(),
            .pasteTransferFailed(),
            .staleCopyRetracted(hasSuccessor: true),
            peerError(.pasteFailed),
        ] {
            #expect(!issue.menuLineText.hasSuffix("."))
        }
    }
}
