import AppKit
import Testing

@testable import Kernova

@Suite("AttachmentInfoPopover Tests", .admissionGated)
@MainActor
struct AttachmentInfoPopoverContentViewControllerTests {
    /// The controller holds `onCommitNotes` strongly, so the box the caller
    /// reads has to outlive the call — hence a reference type.
    private final class NoteRecorder {
        var committed: [String] = []
    }

    private func makeController(
        notes: String = "", canEdit: Bool = true, recorder: NoteRecorder = NoteRecorder()
    ) -> AttachmentInfoPopoverContentViewController {
        let controller = AttachmentInfoPopoverContentViewController(
            label: "Data Disk",
            fileName: "data.asif",
            fullPath: "/Users/test/data.asif",
            onDiskText: "2 GB",
            allocatedText: "20 GB",
            readOnly: false,
            busText: "Virtio block",
            createdText: "Jan 1, 2025",
            notes: notes,
            canEdit: canEdit,
            onCommitNotes: { recorder.committed.append($0) })
        controller.loadViewIfNeeded()
        return controller
    }

    private func notesEditor(in controller: NSViewController) -> NotesEditorView? {
        firstSubview(NotesEditorView.self, in: controller.view)
    }

    @Test("The facts grid names the attachment's file, bus, and read-only state")
    func factsGridNamesTheAttachment() {
        let controller = makeController()
        #expect(findLabel(withText: "File", in: controller.view) != nil)
        #expect(findLabel(withText: "data.asif", in: controller.view) != nil)
        #expect(findLabel(withText: "Virtio block", in: controller.view) != nil)
    }

    @Test("An editable popover always offers the Notes box, empty or not")
    func editableAlwaysOffersNotes() {
        let bare = makeController()
        #expect(findLabel(withText: "Notes", in: bare.view) != nil)
        #expect(notesEditor(in: bare)?.text == "")
        // The empty box says what it is for.
        #expect(findLabel(withText: "Add notes\u{2026}", in: bare.view) != nil)

        let annotated = makeController(notes: "holds the build cache")
        #expect(notesEditor(in: annotated)?.text == "holds the build cache")
    }

    @Test("A popover that can't be edited shows the note as text, and omits it when empty")
    func readOnlyKeepsStaticNotes() {
        let bare = makeController(canEdit: false)
        #expect(findLabel(withText: "Notes", in: bare.view) == nil)
        #expect(notesEditor(in: bare) == nil)

        let annotated = makeController(notes: "holds the build cache", canEdit: false)
        #expect(findLabel(withText: "holds the build cache", in: annotated.view) != nil)
        #expect(notesEditor(in: annotated) == nil)
    }

    @Test("Dismissing the popover commits what the box holds")
    func dismissCommitsTheNote() {
        let recorder = NoteRecorder()
        let controller = makeController(recorder: recorder)

        firstSubview(NSTextView.self, in: controller.view)?.string = "holds the build cache"
        controller.viewWillDisappear()

        #expect(recorder.committed == ["holds the build cache"])
    }

    @Test("Escape reverts the note, asks for a close, and commits nothing")
    func escapeRevertsAndCloses() {
        let recorder = NoteRecorder()
        let controller = makeController(notes: "holds the build cache", recorder: recorder)
        var closeRequests = 0
        controller.onRequestClose = { closeRequests += 1 }

        let textView = firstSubview(NSTextView.self, in: controller.view)
        textView?.string = "half-typed replacement"
        textView?.cancelOperation(nil)
        controller.viewWillDisappear()

        #expect(closeRequests == 1)
        #expect(recorder.committed.isEmpty)
        #expect(notesEditor(in: controller)?.text == "holds the build cache")
    }

    @Test("Dismissing an untouched popover commits nothing")
    func dismissWithoutAnEditCommitsNothing() {
        let recorder = NoteRecorder()
        let controller = makeController(notes: "holds the build cache", recorder: recorder)

        controller.viewWillDisappear()

        #expect(recorder.committed.isEmpty)
    }
}
