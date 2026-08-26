import AppKit
import Testing

@testable import Kernova

@Suite("SnapshotInfoPopover Tests", .admissionGated)
@MainActor
struct SnapshotInfoPopoverContentViewControllerTests {
    /// The controller holds `onCommitNotes` strongly, so the box the caller
    /// reads has to outlive the call — hence a reference type.
    private final class NoteRecorder {
        var committed: [String] = []
    }

    private func makeController(
        kind: VMSnapshotKind, notes: String = "",
        recorder: NoteRecorder = NoteRecorder()
    ) -> SnapshotInfoPopoverContentViewController {
        let snapshot = VMSnapshot(
            name: "Before the update", createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            notes: notes, kind: kind)
        let controller = SnapshotInfoPopoverContentViewController(
            snapshot: snapshot, onDiskText: "2 GB",
            onCommitNotes: { recorder.committed.append($0) })
        controller.loadViewIfNeeded()
        return controller
    }

    private func notesEditor(in controller: NSViewController) -> NotesEditorView? {
        firstSubview(NotesEditorView.self, in: controller.view)
    }

    @Test("The facts grid says what a memory-and-disks snapshot holds")
    func warmNamesMemoryAndDisks() {
        let controller = makeController(kind: .warm)
        #expect(findLabel(withText: "Captured", in: controller.view) != nil)
        #expect(findLabel(withText: "Memory and disks", in: controller.view) != nil)
    }

    @Test("The facts grid says what a disks-only snapshot holds")
    func coldNamesDisksOnly() {
        let controller = makeController(kind: .cold)
        #expect(findLabel(withText: "Disks only", in: controller.view) != nil)
    }

    @Test("An editable popover always offers the Notes box, empty or not")
    func editableAlwaysOffersNotes() {
        let bare = makeController(kind: .warm)
        #expect(findLabel(withText: "Notes", in: bare.view) != nil)
        #expect(notesEditor(in: bare)?.text == "")
        // The empty box says what it is for.
        #expect(findLabel(withText: "Add notes\u{2026}", in: bare.view) != nil)

        let annotated = makeController(kind: .warm, notes: "tools configured")
        #expect(notesEditor(in: annotated)?.text == "tools configured")
    }

    @Test("Dismissing the popover commits what the box holds")
    func dismissCommitsTheNote() {
        let recorder = NoteRecorder()
        let controller = makeController(kind: .warm, recorder: recorder)

        firstSubview(NSTextView.self, in: controller.view)?.string = "tools configured"
        controller.viewWillDisappear()

        #expect(recorder.committed == ["tools configured"])
    }

    @Test("Escape reverts the note, asks for a close, and commits nothing")
    func escapeRevertsAndCloses() {
        let recorder = NoteRecorder()
        let controller = makeController(
            kind: .warm, notes: "tools configured", recorder: recorder)
        var closeRequests = 0
        controller.onRequestClose = { closeRequests += 1 }

        let textView = firstSubview(NSTextView.self, in: controller.view)
        textView?.string = "half-typed replacement"
        textView?.cancelOperation(nil)
        controller.viewWillDisappear()

        #expect(closeRequests == 1)
        #expect(recorder.committed.isEmpty)
        #expect(notesEditor(in: controller)?.text == "tools configured")
    }

    @Test("Dismissing an untouched popover commits nothing")
    func dismissWithoutAnEditCommitsNothing() {
        let recorder = NoteRecorder()
        let controller = makeController(
            kind: .warm, notes: "tools configured", recorder: recorder)

        controller.viewWillDisappear()

        #expect(recorder.committed.isEmpty)
    }
}
