import AppKit
import KernovaLogging
import Testing

@testable import Kernova

/// The Settings list editor's inline rename against a list that changes
/// under it.
@Suite("Settings named list editor", .serialized, .caseScoped, .scopedWindows)
@MainActor
struct SettingsNamedListEditorTests {
    private static let nameColumn = NSUserInterfaceItemIdentifier("name")

    @MainActor
    private final class Source: SettingsNamedListSource {
        var order: [UUID]
        var names: [UUID: String]

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
        func rename(_ id: UUID, to name: String) throws { names[id] = name }
        var canCreate: Bool { true }
        func presentCreate() {}
        func deleteConfirmation(for id: UUID, delete: @escaping () -> Void) -> AlertConfiguration? { nil }
        func delete(_ id: UUID) throws { order.removeAll { $0 == id } }
    }

    /// An editor over `source` in a window on screen, listing it.
    private func makeEditor(_ source: Source) -> (SettingsNamedListEditor, NSWindow) {
        let editor = SettingsNamedListEditor(
            noun: "Tag", columns: [.init(id: Self.nameColumn, title: "Name", width: 150)],
            nameColumn: Self.nameColumn, logger: KernovaLogger(subsystem: "app.kernova", category: "Test"),
            source: source)
        let window = showTestWindow(styleMask: [.titled], contentSize: NSSize(width: 500, height: 400))
        window.contentView = editor.makePaneView(header: "Tags", caption: "")
        editor.reload()
        window.layoutIfNeeded()
        return (editor, window)
    }

    /// Opens the name editor of `row`, as a double-click does, and types
    /// `typed` into it.
    private func openNameEditor(
        _ editor: SettingsNamedListEditor, in window: NSWindow, row: Int, typing typed: String
    ) throws -> NSTextField {
        let cell = try #require(
            editor.tableView.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView)
        let field = try #require(cell.textField)
        #expect(window.makeFirstResponder(field))
        let fieldEditor = try #require(field.currentEditor())
        fieldEditor.string = typed
        return field
    }

    @Test("A change arriving after a name's editor opens, before anything is typed, waits for the edit to end")
    func reloadWaitsForAnOpenEditor() throws {
        let first = UUID()
        let source = Source([(first, "Work")])
        let (editor, window) = makeEditor(source)
        let cell = try #require(editor.tableView.view(atColumn: 0, row: 0, makeIfNecessary: true) as? NSTableCellView)
        let field = try #require(cell.textField)

        // As a double-click leaves it: the field editor open, nothing typed.
        #expect(window.makeFirstResponder(field))
        #expect(field.currentEditor() != nil)

        source.order.append(UUID())
        editor.reload()

        #expect(field.currentEditor() != nil)
        #expect(editor.tableView.numberOfRows == 1)

        #expect(window.makeFirstResponder(nil))
        #expect(editor.tableView.numberOfRows == 2)
        #expect(source.names[first] == "Work")
    }

    @Test("The pane's own create and delete commit an open name edit, then list their change")
    func ownChangesCommitAnOpenEdit() throws {
        let first = UUID()
        let created = UUID()
        let source = Source([(first, "Work")])
        let (editor, window) = makeEditor(source)

        let field = try openNameEditor(editor, in: window, row: 0, typing: "Home")
        editor.attempt("Couldn\u{2019}t Create the Tag") {
            source.order.append(created)
            source.names[created] = "Lab"
            editor.reload()
            editor.select(created)
        }

        #expect(field.currentEditor() == nil)
        #expect(source.names[first] == "Home")
        #expect(editor.tableView.numberOfRows == 2)
        #expect(editor.selectedID == created)

        _ = try openNameEditor(editor, in: window, row: 1, typing: "Bench")
        editor.attempt("Couldn\u{2019}t Delete the Tag") { try source.delete(first) }

        #expect(source.names[created] == "Bench")
        #expect(editor.ids == [created])
        #expect(editor.tableView.numberOfRows == 1)
    }
}
