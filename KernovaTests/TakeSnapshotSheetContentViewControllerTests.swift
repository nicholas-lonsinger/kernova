import AppKit
import Testing

@testable import Kernova

@Suite("TakeSnapshotSheet Tests", .admissionGated)
@MainActor
struct TakeSnapshotSheetContentViewControllerTests {
    private final class Recorder: TakeSnapshotSheetContentViewControllerDelegate {
        var cancels = 0
        var confirmations: [(name: String, notes: String)] = []

        func takeSnapshotSheetDidCancel(_ vc: TakeSnapshotSheetContentViewController) {
            cancels += 1
        }
        func takeSnapshotSheet(
            _ vc: TakeSnapshotSheetContentViewController, didConfirmName name: String,
            notes: String
        ) {
            confirmations.append((name, notes))
        }
    }

    private func makeSheet(
        vmName: String = "Dev Mac", suggestedName: String = "Snapshot",
        mode: VMSnapshotCaptureMode = .live
    ) -> (TakeSnapshotSheetContentViewController, Recorder) {
        let recorder = Recorder()
        let sheet = TakeSnapshotSheetContentViewController(
            vmName: vmName, suggestedName: suggestedName, mode: mode)
        sheet.delegate = recorder
        sheet.loadViewIfNeeded()
        return (sheet, recorder)
    }

    @Test("The title names the VM")
    func titleNamesTheVM() {
        let (sheet, _) = makeSheet(vmName: "Dev Mac")
        #expect(
            findLabel(withText: "Take Snapshot of \u{201C}Dev Mac\u{201D}", in: sheet.view) != nil)
    }

    @Test("The Name field is prefilled with the suggestion and Notes is optional")
    func fieldsStartPrefilled() {
        let (sheet, _) = makeSheet(suggestedName: "Snapshot 3")
        #expect(sheet.enteredName == "Snapshot 3")
        #expect(sheet.enteredNotes.isEmpty)
        #expect(findLabel(withText: "Optional", in: sheet.view) != nil)
    }

    @Test("Confirming hands back what was typed, newlines and all")
    func confirmSendsTheEnteredValues() {
        let (sheet, recorder) = makeSheet()
        firstSubview(NSTextField.self, in: sheet.view) { $0.placeholderString == "Name" }?
            .stringValue = "Before Xcode"
        firstSubview(NSTextView.self, in: sheet.view)?.string = "tools configured\nand licensed"

        let confirm = findButton(titled: "Take Snapshot", in: sheet.view)
        confirm.map { _ = $0.target?.perform($0.action, with: $0) }

        #expect(recorder.confirmations.count == 1)
        #expect(recorder.confirmations.first?.name == "Before Xcode")
        #expect(recorder.confirmations.first?.notes == "tools configured\nand licensed")
    }

    @Test("Cancel is the Escape button and reports a cancel")
    func cancelReportsACancel() {
        let (sheet, recorder) = makeSheet()
        let cancel = findButton(titled: "Cancel", in: sheet.view)

        #expect(cancel?.keyEquivalent == "\u{1B}")
        cancel.map { _ = $0.target?.perform($0.action, with: $0) }

        #expect(recorder.cancels == 1)
    }

    @Test("Take Snapshot is the Return default")
    func confirmIsTheDefaultButton() {
        let (sheet, _) = makeSheet()
        #expect(findButton(titled: "Take Snapshot", in: sheet.view)?.keyEquivalent == "\r")
    }

    // MARK: - Per-mode copy

    @Test("A memory-and-disks capture says so, and warns about the pause")
    func warmCopyNamesMemoryAndThePause() {
        let (sheet, _) = makeSheet(mode: .live)
        #expect(sheet.headerBodyText.contains("memory and disks"))
        #expect(sheet.captionText.contains("pauses briefly"))
    }

    @Test("A suspended-state capture names the suspended session, and says nothing about pausing")
    func suspendedCopyNamesTheSuspendedSession() {
        let (sheet, _) = makeSheet(mode: .suspended)
        #expect(sheet.headerBodyText.contains("suspended"))
        #expect(sheet.captionText.contains("suspended session"))
        #expect(!sheet.captionText.contains("pauses briefly"))
        // The shared-blocks note stands either way.
        #expect(sheet.captionText.contains("share their blocks"))
    }

    @Test("A disks-only capture says the VM comes back powered off, with no pause")
    func coldCopyNamesTheOutcome() {
        let (sheet, _) = makeSheet(mode: .stopped)
        #expect(sheet.headerBodyText.contains("disks and settings"))
        #expect(sheet.headerBodyText.contains("powered off"))
        #expect(!sheet.headerBodyText.contains("memory and disks"))
        #expect(!sheet.captionText.contains("pauses briefly"))
        // The shared-blocks note stands either way.
        #expect(sheet.captionText.contains("share their blocks"))
    }

    @Test("A guest powering off while the sheet is up moves its copy to disks-only")
    func updatingTheModeRewritesTheRenderedCopy() {
        let (sheet, _) = makeSheet(mode: .live)
        let body = findLabel(containing: "memory and disks", in: sheet.view)
        #expect(body != nil)

        sheet.update(mode: .stopped)

        #expect(sheet.mode == .stopped)
        // The same labels, rewritten — not a stale copy left on screen.
        #expect(body?.stringValue.contains("powered off") == true)
        #expect(findLabel(containing: "memory and disks", in: sheet.view) == nil)
        #expect(findLabel(containing: "pauses briefly", in: sheet.view) == nil)
    }
}
