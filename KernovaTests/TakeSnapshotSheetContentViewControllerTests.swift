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
        kind: VMSnapshotKind = .warm
    ) -> (TakeSnapshotSheetContentViewController, Recorder) {
        let recorder = Recorder()
        let sheet = TakeSnapshotSheetContentViewController(
            vmName: vmName, suggestedName: suggestedName, kind: kind)
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
        let notes = firstSubview(NSTextField.self, in: sheet.view) {
            $0.placeholderString == "Optional"
        }
        #expect(notes != nil)
    }

    @Test("Confirming hands back what was typed")
    func confirmSendsTheEnteredValues() {
        let (sheet, recorder) = makeSheet()
        firstSubview(NSTextField.self, in: sheet.view) { $0.placeholderString == "Name" }?
            .stringValue = "Before Xcode"
        firstSubview(NSTextField.self, in: sheet.view) { $0.placeholderString == "Optional" }?
            .stringValue = "tools configured"

        let confirm = findButton(titled: "Take Snapshot", in: sheet.view)
        confirm.map { _ = $0.target?.perform($0.action, with: $0) }

        #expect(recorder.confirmations.count == 1)
        #expect(recorder.confirmations.first?.name == "Before Xcode")
        #expect(recorder.confirmations.first?.notes == "tools configured")
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

    // MARK: - Per-kind copy

    @Test("A memory-and-disks capture says so, and warns about the pause")
    func warmCopyNamesMemoryAndThePause() {
        let (sheet, _) = makeSheet(kind: .warm)
        #expect(sheet.headerBodyText.contains("memory and disks"))
        #expect(sheet.captionText.contains("pauses briefly"))
    }

    @Test("A disks-only capture says the VM comes back powered off, with no pause")
    func coldCopyNamesTheOutcome() {
        let (sheet, _) = makeSheet(kind: .cold)
        #expect(sheet.headerBodyText.contains("disks and settings"))
        #expect(sheet.headerBodyText.contains("powered off"))
        #expect(!sheet.headerBodyText.contains("memory and disks"))
        #expect(!sheet.captionText.contains("pauses briefly"))
        // The shared-blocks note stands either way.
        #expect(sheet.captionText.contains("share their blocks"))
    }
}
