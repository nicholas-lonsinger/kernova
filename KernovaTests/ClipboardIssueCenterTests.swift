import Foundation
import KernovaKit
import Testing

@testable import Kernova

/// Unit tests for `ClipboardIssueCenter` — the app-level aggregate that lets a
/// clipboard refusal reach a surface when no clipboard window is open.
///
/// The interesting behavior is the split between the per-VM record the dropdown
/// renders and the one-shot notice the popover presents, and that a watched VM's
/// window suppresses the second without losing the first.
@Suite("Clipboard Issue Center Tests")
@MainActor
struct ClipboardIssueCenterTests {
    private let vmID = UUID()

    private func report(
        _ issue: ClipboardTransferIssue, to center: ClipboardIssueCenter, id: UUID? = nil,
        vmName: String = "Build VM"
    ) {
        center.report(
            issue, instanceID: id ?? vmID, vmName: vmName,
            pasteLimitBytes: ClipboardPasteLimit.defaultBytes)
    }

    @Test("A fresh center holds nothing")
    func emptyCenter() {
        let center = ClipboardIssueCenter()
        #expect(center.latestByInstance.isEmpty)
        #expect(center.pendingNotice == nil)
    }

    @Test("An unwatched VM's issue is both recorded and queued for the notice")
    func reportRecordsAndQueues() {
        let center = ClipboardIssueCenter()
        let issue = ClipboardTransferIssue.overCopyBudget(limitBytes: ClipboardPasteLimit.defaultBytes)

        report(issue, to: center)

        #expect(center.latestByInstance[vmID]?.issue == issue)
        #expect(center.latestByInstance[vmID]?.vmName == "Build VM")
        #expect(center.latestByInstance[vmID]?.pasteLimitBytes == ClipboardPasteLimit.defaultBytes)
        #expect(center.pendingNotice == center.latestByInstance[vmID])
    }

    @Test("A watched VM's issue is recorded but never queued — its window shows it")
    func watchedVMSuppressesTheNotice() {
        let center = ClipboardIssueCenter()
        center.beginWatching(instanceID: vmID)

        report(.pasteTimedOut(), to: center)

        #expect(center.latestByInstance[vmID]?.issue.kind == ClipboardTransferIssue.pasteTimedOut().kind)
        #expect(center.pendingNotice == nil)
    }

    @Test("A guest-side refusal is recorded but never interrupts here")
    func peerReportedErrorIsRecordedWithoutQueueing() {
        let center = ClipboardIssueCenter()
        let peerIssue = ClipboardTransferIssue(
            kind: .peerReportedError(
                code: ClipboardErrorCode.pasteTooLarge.rawValue, message: "wire text"),
            date: Date())

        report(peerIssue, to: center)

        // The dropdown still explains why the guest's clipboard is short —
        // only the popover, which interrupts the wrong user, stands down.
        #expect(center.latestByInstance[vmID]?.issue == peerIssue)
        #expect(center.pendingNotice == nil)
    }

    @Test("A host-side refusal after a guest-side one still queues")
    func hostSideIssueQueuesAfterAPeerReportedOne() {
        let center = ClipboardIssueCenter()
        report(
            ClipboardTransferIssue(
                kind: .peerReportedError(
                    code: ClipboardErrorCode.pasteFailed.rawValue, message: "wire text"),
                date: Date()), to: center)

        report(.pasteTimedOut(), to: center)

        #expect(center.pendingNotice?.issue.kind == ClipboardTransferIssue.pasteTimedOut().kind)
    }

    @Test("Opening the window retires a notice already queued for that VM")
    func beginWatchingDropsThePendingNotice() {
        let center = ClipboardIssueCenter()
        report(.pasteTimedOut(), to: center)
        #expect(center.pendingNotice != nil)

        center.beginWatching(instanceID: vmID)

        #expect(center.pendingNotice == nil)
        // The dropdown line survives the window taking over the interruption.
        #expect(center.latestByInstance[vmID] != nil)
    }

    @Test("Another VM's notice survives one VM starting to be watched")
    func beginWatchingLeavesOtherVMsAlone() {
        let center = ClipboardIssueCenter()
        let other = UUID()
        report(.pasteTimedOut(), to: center, id: other, vmName: "CI VM")

        center.beginWatching(instanceID: vmID)

        #expect(center.pendingNotice?.instanceID == other)
    }

    @Test("Closing the window replays nothing — only a later issue queues again")
    func endWatchingRestoresNothing() {
        let center = ClipboardIssueCenter()
        center.beginWatching(instanceID: vmID)
        report(.pasteTimedOut(), to: center)

        center.endWatching(instanceID: vmID)

        #expect(center.pendingNotice == nil)

        report(.partialFileSetUnservable(), to: center)
        #expect(
            center.pendingNotice?.issue.kind
                == ClipboardTransferIssue.partialFileSetUnservable().kind)
    }

    @Test("A newer issue supersedes the one the VM was carrying")
    func newerReportSupersedes() {
        let center = ClipboardIssueCenter()
        report(.pasteTimedOut(), to: center)

        report(.staleCopyRetracted(), to: center)

        #expect(center.latestByInstance.count == 1)
        #expect(
            center.latestByInstance[vmID]?.issue.kind
                == ClipboardTransferIssue.staleCopyRetracted().kind)
        #expect(center.pendingNotice?.issue.kind == ClipboardTransferIssue.staleCopyRetracted().kind)
    }

    @Test("Consuming the pending notice leaves the dropdown's record standing")
    func consumeKeepsTheRecord() {
        let center = ClipboardIssueCenter()
        report(.pasteTimedOut(), to: center)

        center.consumePendingNotice()

        #expect(center.pendingNotice == nil)
        #expect(center.latestByInstance[vmID] != nil)
    }

    @Test("Clearing a VM removes both its record and its queued notice")
    func clearRemovesBoth() {
        let center = ClipboardIssueCenter()
        report(.pasteTimedOut(), to: center)

        center.clear(instanceID: vmID)

        #expect(center.latestByInstance.isEmpty)
        #expect(center.pendingNotice == nil)
    }

    @Test("Clearing one VM leaves another VM's queued notice alone")
    func clearLeavesOtherVMsAlone() {
        let center = ClipboardIssueCenter()
        let other = UUID()
        report(.pasteTimedOut(), to: center, id: other, vmName: "CI VM")

        center.clear(instanceID: vmID)

        #expect(center.pendingNotice?.instanceID == other)
        #expect(center.latestByInstance[other] != nil)
    }
}
