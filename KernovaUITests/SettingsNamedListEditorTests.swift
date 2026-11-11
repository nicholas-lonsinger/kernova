import AppKit
import KernovaLogging
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaUI

/// The Settings list editor's in-place rename: the clicks that open it, how
/// it ends, and a list that changes under it.
@Suite("Settings named list editor", .serialized, .caseScoped, .scopedWindows)
@MainActor
struct SettingsNamedListEditorTests {
    private static let nameColumn = NSUserInterfaceItemIdentifier("name")

    private struct Refusal: Error {}

    @MainActor
    private final class Source: SettingsNamedListSource {
        var order: [UUID]
        var names: [UUID: String]
        /// Names `rename` refuses.
        var refusedNames: Set<String> = []
        private(set) var renameCount = 0

        init(_ names: [(UUID, String)]) {
            order = names.map(\.0)
            self.names = Dictionary(uniqueKeysWithValues: names)
        }

        func listedIDs() -> [UUID]? { order }
        var unreadableText: String { "" }
        func showConfigCheck() {}
        func name(of id: UUID) -> String { names[id] ?? "" }
        func text(for column: NSUserInterfaceItemIdentifier, of id: UUID) -> String { "" }
        func control(for column: NSUserInterfaceItemIdentifier, of id: UUID) -> NSView? { nil }
        func readListedValues() {}
        func rename(_ id: UUID, to name: String) throws {
            renameCount += 1
            guard !refusedNames.contains(name) else { throw Refusal() }
            names[id] = name
        }
        var canCreate: Bool { true }
        func presentCreate() {}
        func deleteConfirmation(for id: UUID, delete: @escaping () -> Void) -> AlertConfiguration? { nil }
        func delete(_ id: UUID) throws { order.removeAll { $0 == id } }
    }

    /// Holds each slow second click's rename until the test lets it fire, in
    /// place of the double-click interval.
    @MainActor
    private final class Deferrals {
        private var pending: [UUID: @MainActor () -> Void] = [:]

        func deferral(_ fire: @escaping @MainActor () -> Void) -> @MainActor () -> Void {
            let id = UUID()
            pending[id] = fire
            return { [weak self] in self?.pending[id] = nil }
        }

        /// Fires every rename waiting out the interval.
        func elapse() {
            let due = pending.values
            pending = [:]
            for fire in due { fire() }
        }
    }

    /// An editor over `source` in a window on screen, listing it.
    private func makeEditor(
        _ source: Source, _ deferrals: Deferrals = Deferrals()
    ) -> (SettingsNamedListEditor, NSWindow) {
        let editor = SettingsNamedListEditor(
            noun: "Tag", columns: [.init(id: Self.nameColumn, title: "Name", width: 150)],
            nameColumn: Self.nameColumn, logger: KernovaLogger(subsystem: "app.kernova", category: "Test"),
            source: source, renameDeferral: deferrals.deferral)
        let window = showTestWindow(styleMask: [.titled], contentSize: NSSize(width: 500, height: 400))
        window.contentView = editor.makePaneView(header: "Tags", caption: "")
        editor.reload()
        window.layoutIfNeeded()
        return (editor, window)
    }

    /// Presses on the name of `row` and releases `drag` points to the right,
    /// with AppKit's own tracking of the press — selecting the row — faked.
    private func click(
        _ editor: SettingsNamedListEditor, row: Int, count: Int = 1, drag: CGFloat = 0
    ) throws {
        let table = editor.tableView
        let rect = table.frameOfCell(atColumn: 0, row: row)
        let point = table.convert(NSPoint(x: rect.minX + 30, y: rect.midY), to: nil)
        let event = try #require(
            NSEvent.mouseEvent(
                with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: table.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: count,
                pressure: 1))
        try #require(table.renameClicks).mouseDown(with: event) { _ in
            table.selectRowIndexes([row], byExtendingSelection: false)
            return NSPoint(x: point.x + drag, y: point.y)
        }
    }

    /// The field editor of the rename open on `row`'s name, `nil` while none
    /// is.
    private func renameEditor(_ editor: SettingsNamedListEditor, row: Int) -> NSTextView? {
        let cell = editor.tableView.view(atColumn: 0, row: row, makeIfNecessary: false)
        return cell.flatMap { firstSubview(InlineEditableLabel.self, in: $0)?.currentEditor() as? NSTextView }
    }

    /// The name `row` shows, once the table has laid out what it last
    /// loaded.
    private func shownName(_ editor: SettingsNamedListEditor, row: Int) -> String? {
        editor.tableView.window?.layoutIfNeeded()
        return (editor.tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? NSTableCellView)?
            .textField?.stringValue
    }

    @Test("A slow second click on the selected row's name opens its rename once the double-click interval passes")
    func slowSecondClickOpensTheRename() throws {
        let source = Source([(UUID(), "Work"), (UUID(), "Home")])
        let deferrals = Deferrals()
        let (editor, _) = makeEditor(source, deferrals)

        // The first click only selects.
        try click(editor, row: 1)
        deferrals.elapse()
        #expect(editor.tableView.selectedRow == 1)
        #expect(renameEditor(editor, row: 1) == nil)

        try click(editor, row: 1)
        #expect(renameEditor(editor, row: 1) == nil)
        deferrals.elapse()
        #expect(renameEditor(editor, row: 1)?.string == "Home")
    }

    @Test("A press on the selected row that becomes a drag opens no rename")
    func dragOpensNoRename() throws {
        let source = Source([(UUID(), "Work")])
        let deferrals = Deferrals()
        let (editor, _) = makeEditor(source, deferrals)
        try click(editor, row: 0)

        try click(editor, row: 0, drag: 20)
        deferrals.elapse()

        #expect(renameEditor(editor, row: 0) == nil)
    }

    @Test("A double-click opens the rename at once, selecting the row")
    func doubleClickOpensTheRename() throws {
        let source = Source([(UUID(), "Work"), (UUID(), "Home")])
        let (editor, _) = makeEditor(source)

        try click(editor, row: 1, count: 2)

        #expect(editor.tableView.selectedRow == 1)
        #expect(renameEditor(editor, row: 1)?.string == "Home")
    }

    @Test("A double-click while a slow second click waits drops the waiting rename")
    func doubleClickDropsAWaitingSlowClickRename() throws {
        let source = Source([(UUID(), "Work")])
        let deferrals = Deferrals()
        let (editor, _) = makeEditor(source, deferrals)
        try click(editor, row: 0)
        try click(editor, row: 0)

        try click(editor, row: 0, count: 2)
        try #require(renameEditor(editor, row: 0)).doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        deferrals.elapse()

        #expect(renameEditor(editor, row: 0) == nil)
    }

    @Test("Return renames through the source; Escape puts the name back and renames nothing")
    func returnCommitsAndEscapeReverts() throws {
        let id = UUID()
        let source = Source([(id, "Work")])
        let (editor, _) = makeEditor(source)

        try click(editor, row: 0, count: 2)
        let escaping = try #require(renameEditor(editor, row: 0))
        escaping.string = "Home"
        escaping.doCommand(by: #selector(NSResponder.cancelOperation(_:)))

        #expect(renameEditor(editor, row: 0) == nil)
        #expect(source.renameCount == 0)
        #expect(shownName(editor, row: 0) == "Work")

        try click(editor, row: 0, count: 2)
        typeAndReturn("Home", in: try #require(renameEditor(editor, row: 0)))

        #expect(renameEditor(editor, row: 0) == nil)
        #expect(source.names[id] == "Home")
        #expect(shownName(editor, row: 0) == "Home")
    }

    @Test("A refused name shows the refusal, then opens the rename again holding it, and Escape puts the name back")
    func refusedNameReopensTheRename() async throws {
        let id = UUID()
        let source = Source([(id, "Work")])
        source.refusedNames = ["Lab"]
        let (editor, window) = makeEditor(source)

        try click(editor, row: 0, count: 2)
        typeAndReturn("Lab", in: try #require(renameEditor(editor, row: 0)))
        try await waitUntil { window.attachedSheet != nil }
        #expect(renameEditor(editor, row: 0) == nil)
        window.endSheet(try #require(window.attachedSheet), returnCode: .alertFirstButtonReturn)

        try await waitUntil { renameEditor(editor, row: 0) != nil }
        let reopened = try #require(renameEditor(editor, row: 0))
        #expect(reopened.string == "Lab")
        reopened.doCommand(by: #selector(NSResponder.cancelOperation(_:)))

        #expect(source.renameCount == 1)
        #expect(source.names[id] == "Work")
        #expect(shownName(editor, row: 0) == "Work")
    }

    @Test("A change arriving after a rename opens, before anything is typed, waits for the edit to end")
    func reloadWaitsForAnOpenRename() throws {
        let first = UUID()
        let source = Source([(first, "Work")])
        let (editor, _) = makeEditor(source)
        try click(editor, row: 0, count: 2)
        let open = try #require(renameEditor(editor, row: 0))

        source.order.append(UUID())
        editor.reload()

        #expect(renameEditor(editor, row: 0) === open)
        #expect(editor.tableView.numberOfRows == 1)

        open.insertNewline(nil)
        #expect(editor.tableView.numberOfRows == 2)
        #expect(source.names[first] == "Work")
    }

    @Test("The pane's own create and delete commit an open rename, then list their change")
    func ownChangesCommitAnOpenRename() throws {
        let first = UUID()
        let created = UUID()
        let source = Source([(first, "Work")])
        let (editor, _) = makeEditor(source)

        try click(editor, row: 0, count: 2)
        try #require(renameEditor(editor, row: 0)).string = "Home"
        editor.attempt("Couldn\u{2019}t Create the Tag") {
            source.order.append(created)
            source.names[created] = "Lab"
            editor.reload()
            editor.select(created)
        }

        #expect(renameEditor(editor, row: 0) == nil)
        #expect(source.names[first] == "Home")
        #expect(editor.tableView.numberOfRows == 2)
        #expect(editor.selectedID == created)

        try click(editor, row: 1, count: 2)
        try #require(renameEditor(editor, row: 1)).string = "Bench"
        editor.attempt("Couldn\u{2019}t Delete the Tag") { try source.delete(first) }

        #expect(source.names[created] == "Bench")
        #expect(editor.ids == [created])
        #expect(editor.tableView.numberOfRows == 1)
    }
}
