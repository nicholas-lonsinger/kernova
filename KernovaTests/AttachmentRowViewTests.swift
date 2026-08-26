import AppKit
import Testing

@testable import Kernova

@Suite("AttachmentRowView Tests", .admissionGated)
@MainActor
struct AttachmentRowViewTests {
    private func makeRow(
        title: String = "Data Disk", notes: String = "", controlsEnabled: Bool = true
    ) -> AttachmentRowView {
        AttachmentRowView(
            itemID: UUID(),
            title: title,
            notes: notes,
            controlsEnabled: controlsEnabled,
            icon: AttachmentIconButton(),
            subtitle: makeAttachmentSubtitleLabel(path: "", isMissing: false),
            readOnlyToggle: NSSwitch(),
            readOnlyCaption: NSView())
    }

    @Test("A note trails the name in the row")
    func notesTrailTheName() {
        let row = makeRow(title: "Data Disk", notes: "holds the build cache")

        let note = findLabel(withText: "holds the build cache", in: row)
        #expect(note != nil)
        #expect(note.map { isVisible($0, within: row) } == true)
    }

    @Test("A row with no note shows no note field")
    func noNoteShowsNoField() {
        let row = makeRow(title: "Data Disk", notes: "")

        #expect(
            allSubviews(InlineEditableLabel.self, in: row) {
                $0.stringValue.isEmpty && isVisible($0, within: row)
            }.isEmpty)
    }

    @Test("update(title:notes:...) replaces both the name and the note in place")
    func updateReplacesNameAndNotes() {
        let row = makeRow(title: "Data Disk", notes: "before")

        row.update(
            title: "Renamed Disk", notes: "after", iconSystemName: "externaldrive",
            missingPath: nil, readOnly: false, controlsEnabled: true)

        #expect(findLabel(withText: "Renamed Disk", in: row) != nil)
        #expect(findLabel(withText: "after", in: row) != nil)
        #expect(findLabel(withText: "before", in: row) == nil)
    }

    @Test("A note holding a newline raises the overflow callback instead of editing inline")
    func multilineNoteRoutesToOverflow() {
        let row = makeRow(title: "Data Disk", notes: "line one\nline two")
        let window = showInTestWindow(row, size: NSSize(width: 480, height: 80))
        defer { window.close() }

        var overflowIDs: [UUID] = []
        var editBegan = false
        row.onNotesOverflowActivated = { overflowIDs.append($0) }
        row.onEditBegan = { _ in editBegan = true }

        row.beginNotesEditing()

        #expect(overflowIDs == [row.itemID])
        #expect(editBegan == false)
        // Flattened for the row; the newline survives in the callback's caller.
        #expect(findLabel(withText: "line one line two", in: row) != nil)
    }

    @Test("A single-line note begins inline editing rather than overflowing")
    func singleLineNoteEditsInline() {
        let row = makeRow(title: "Data Disk", notes: "before")
        let window = showInTestWindow(row, size: NSSize(width: 480, height: 80))
        defer { window.close() }

        var overflowIDs: [UUID] = []
        var editBegan = false
        row.onNotesOverflowActivated = { overflowIDs.append($0) }
        row.onEditBegan = { _ in editBegan = true }

        row.beginNotesEditing()

        #expect(overflowIDs.isEmpty)
        #expect(editBegan == true)
    }

    @Test("Committing a note fires onNotesCommitted with the row's id")
    func commitForwardsToOwner() {
        let row = makeRow(title: "Data Disk", notes: "before")
        let window = showInTestWindow(row, size: NSSize(width: 480, height: 80))
        defer { window.close() }
        var committed: [(UUID, String)] = []
        row.onNotesCommitted = { committed.append(($0, $1)) }

        row.beginNotesEditing()
        let field = allSubviews(InlineEditableLabel.self, in: row) { $0.isEditable }.first
        field?.stringValue = "after"
        field.map { $0.controlTextDidEndEditing(Notification(name: .init("test"), object: $0)) }

        #expect(committed.count == 1)
        #expect(committed.first?.0 == row.itemID)
        #expect(committed.first?.1 == "after")
    }
}
