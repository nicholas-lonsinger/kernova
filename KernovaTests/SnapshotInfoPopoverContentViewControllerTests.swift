import AppKit
import KernovaTestSupport
import Testing

@testable import Kernova

@Suite("SnapshotInfoPopover Tests", .caseScoped)
@MainActor
struct SnapshotInfoPopoverContentViewControllerTests {
    /// The controller holds `onCommitNotes` strongly, so the box the caller
    /// reads has to outlive the call — hence a reference type.
    private final class NoteRecorder {
        var committed: [String] = []
    }

    private func makeController(
        kind: VMSnapshotKind, name: String = "Before the update", notes: String = "",
        canEditNotes: Bool = true, recorder: NoteRecorder = NoteRecorder()
    ) -> SnapshotInfoPopoverContentViewController {
        let snapshot = VMSnapshot(
            name: name, createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            notes: notes, kind: kind, macAddress: nil)
        let controller = SnapshotInfoPopoverContentViewController(
            snapshot: snapshot, freedText: "2 GB", canEditNotes: canEditNotes,
            onCommitNotes: { recorder.committed.append($0) })
        controller.loadViewIfNeeded()
        return controller
    }

    private func notesEditor(in controller: NSViewController) -> NotesEditorView? {
        firstSubview(NotesEditorView.self, in: controller.view)
    }

    @Test("A note the VM will not take a write to reads as text, with no box to type in")
    func unwritableNoteIsStaticText() {
        let controller = makeController(kind: .warm, notes: "Clean install", canEditNotes: false)

        #expect(notesEditor(in: controller) == nil)
        #expect(findLabel(withText: "Clean install", in: controller.view) != nil)
        #expect(
            findLabel(withText: "Notes", in: makeController(kind: .warm, canEditNotes: false).view)
                == nil)
    }

    @Test("The facts grid says what a running-state snapshot captured")
    func warmNamesWhatItCaptured() {
        let controller = makeController(kind: .warm)
        #expect(findLabel(withText: "Captured", in: controller.view) != nil)
        #expect(
            findLabel(withText: SnapshotKindCopy.capturedContents(.warm), in: controller.view) != nil)
    }

    @Test("The facts grid says what a powered-off snapshot captured")
    func coldNamesWhatItCaptured() {
        let controller = makeController(kind: .cold)
        #expect(
            findLabel(withText: SnapshotKindCopy.capturedContents(.cold), in: controller.view) != nil)
    }

    /// Lays the popover out at the size it asks its host for.
    private func layOut(_ controller: NSViewController) {
        controller.view.setFrameSize(controller.view.fittingSize)
        controller.view.layoutSubtreeIfNeeded()
    }

    @Test("A running-state snapshot's Captured value sits on one line, untruncated")
    func warmCapturedValueFitsOnOneLine() throws {
        let controller = makeController(kind: .warm)
        layOut(controller)

        let value = try #require(
            findLabel(withText: SnapshotKindCopy.capturedContents(.warm), in: controller.view))
        let needed = value.fittingSize
        #expect(value.frame.width >= needed.width)
        #expect(value.frame.height == needed.height)
    }

    @Test("A long snapshot name wraps within the width the facts set")
    func longNameDoesNotWidenThePopover() throws {
        let short = makeController(kind: .warm)
        let long = makeController(
            kind: .warm, name: String(repeating: "A very long snapshot name ", count: 12))
        layOut(short)
        layOut(long)

        #expect(long.view.frame.width == short.view.frame.width)
        #expect(long.view.frame.width >= CalloutStyle.width)
        let headline = try #require(
            allSubviews(NSTextField.self, in: long.view) {
                $0.stringValue.hasPrefix("A very long")
            }.first)
        // Wrapped rather than clipped: the name takes more than one line.
        let lineHeight = try #require(headline.font).boundingRectForFont.height
        #expect(headline.frame.height > lineHeight)
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
