import AppKit
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport
@testable import KernovaUI

/// How wide the in-place name and note edits are drawn on the rows built on
/// ``EditableRowTitleView``: the full value while the row has room, and never
/// past the row's edge.
@Suite("Inline Edit Sizing Tests", .serialized, .caseScoped, .scopedWindows)
@MainActor
struct InlineEditSizingTests {
    enum RowKind: CaseIterable, Sendable, CustomTestStringConvertible {
        case snapshot, attachment
        var testDescription: String { self == .snapshot ? "snapshot" : "attachment" }
    }

    /// A row showing `name` and `notes`, whose `apply` feeds a stored value
    /// back the way the row's owner does after a commit.
    private struct HostedRow {
        let view: NSView
        let title: EditableRowTitleView
        let apply: (_ name: String, _ notes: String) -> Void
    }

    private func makeRow(_ kind: RowKind, name: String, notes: String) -> HostedRow {
        switch kind {
        case .snapshot:
            let row = SnapshotRowView(
                snapshotID: UUID(), target: NSObject(),
                revertAction: #selector(NSObject.description),
                moreAction: #selector(NSObject.description))
            let apply = { (name: String, notes: String) in
                let snapshot = VMSnapshot(
                    name: name, createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                    notes: notes, macAddress: nil)
                row.update(
                    SnapshotRowModel(
                        snapshot: snapshot, isCurrent: true, isBaseline: false, canRevert: true,
                        canRename: true, canSetNotes: true, canDelete: true),
                    subtitle: "Today")
            }
            apply(name, notes)
            return HostedRow(view: row, title: row.titleView, apply: apply)
        case .attachment:
            let row = AttachmentRowView(
                itemID: UUID(), title: name, notes: notes, controlsEnabled: true,
                icon: AttachmentIconButton(),
                subtitle: makeAttachmentSubtitleLabel(path: "", isMissing: false),
                readOnlyToggle: NSSwitch(), readOnlyCaption: NSView())
            let title = firstSubview(EditableRowTitleView.self, in: row)!
            let apply = { (name: String, notes: String) in
                row.update(
                    title: name, notes: notes, subtitle: "", iconSystemName: "externaldrive",
                    missingPath: nil, readOnly: false, controlsEnabled: true, ejectEnabled: true)
            }
            return HostedRow(view: row, title: title, apply: apply)
        }
    }

    /// The title line's name label, then its note label.
    private func labels(of row: HostedRow) -> (name: InlineEditableLabel, notes: InlineEditableLabel) {
        let all = allSubviews(InlineEditableLabel.self, in: row.title)
        return (all[0], all[1])
    }

    /// The width `text` takes in `label`'s font, measured by AppKit's own
    /// string metrics rather than the code under test.
    private func textWidth(_ text: String, in label: NSTextField) -> CGFloat {
        ceil(NSAttributedString(string: text, attributes: [.font: label.font!]).size().width)
    }

    private func layOut(_ row: HostedRow) {
        row.view.window?.contentView?.layoutSubtreeIfNeeded()
    }

    /// Types `text` into an open edit, the way the field editor reports it.
    private func type(_ text: String, into label: InlineEditableLabel) {
        label.currentEditor()?.string = text
        label.controlTextDidChange(
            Notification(name: NSControl.textDidChangeNotification, object: label))
    }

    nonisolated private static let names = ["A", "Before installing the Xcode beta"]
    nonisolated private static let notes = ["", "x", "Clean install with Homebrew and the command line tools"]

    @Test(
        "The name shows in full on display, through an edit as typed, and after it commits",
        arguments: RowKind.allCases, names)
    func nameFitsThroughAnEdit(kind: RowKind, name: String) throws {
        let row = makeRow(kind, name: name, notes: "A note")
        showInTestWindow(row.view, size: NSSize(width: 900, height: 60))
        let label = labels(of: row).name
        layOut(row)
        #expect(label.frame.width >= textWidth(name, in: label))

        row.title.beginRename()
        layOut(row)
        try #require(label.isEditing)
        #expect(label.frame.width >= textWidth(name, in: label))

        let typed = name + " and then some more words"
        type(typed, into: label)
        layOut(row)
        #expect(label.frame.width >= textWidth(typed, in: label))

        label.endEditing()
        row.apply(typed, "A note")
        layOut(row)
        #expect(label.frame.width >= textWidth(typed, in: label))
    }

    @Test(
        "The note shows in full on display, through an edit as typed, and after it commits",
        arguments: RowKind.allCases, notes)
    func noteFitsThroughAnEdit(kind: RowKind, notes: String) throws {
        let row = makeRow(kind, name: "Data", notes: notes)
        showInTestWindow(row.view, size: NSSize(width: 900, height: 60))
        let label = labels(of: row).notes
        layOut(row)
        #expect(label.isHidden == notes.isEmpty)
        if !notes.isEmpty { #expect(label.frame.width >= textWidth(notes, in: label)) }

        row.title.beginNotesEditing()
        layOut(row)
        try #require(label.isEditing)
        // An empty box still shows its placeholder in full.
        let shown = notes.isEmpty ? label.placeholderString ?? "" : notes
        #expect(label.frame.width >= textWidth(shown, in: label))

        let typed = notes + " and a second clause that lengthens it"
        type(typed, into: label)
        layOut(row)
        #expect(label.frame.width >= textWidth(typed, in: label))

        label.endEditing()
        row.apply("Data", typed)
        layOut(row)
        #expect(label.frame.width >= textWidth(typed, in: label))
    }

    @Test("A value longer than the row truncates at the row's edge", arguments: RowKind.allCases)
    func longValuesStayInsideTheRow(kind: RowKind) throws {
        let long = String(repeating: "A very long value ", count: 12)
        let row = makeRow(kind, name: long, notes: long)
        showInTestWindow(row.view, size: NSSize(width: 480, height: 60))
        let (name, notes) = labels(of: row)

        func expectInsideTitleLine() {
            layOut(row)
            let line = row.title.bounds
            for label in [name, notes] where !label.isHidden {
                let frame = label.convert(label.bounds, to: row.title)
                #expect(frame.maxX <= line.maxX + 0.5)
            }
            // The name is what keeps its room; the note gives way first.
            #expect(name.frame.width > 0)
        }

        expectInsideTitleLine()
        row.title.beginRename()
        expectInsideTitleLine()
        name.endEditing()
        row.title.beginNotesEditing()
        expectInsideTitleLine()
    }
}
