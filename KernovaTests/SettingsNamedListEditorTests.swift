import AppKit
import KernovaLogging
import KernovaTestSupport
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
        func delete(_ id: UUID) throws {}
    }

    @Test("A change arriving after a name's editor opens, before anything is typed, waits for the edit to end")
    func reloadWaitsForAnOpenEditor() throws {
        let first = UUID()
        let source = Source([(first, "Work")])
        let editor = SettingsNamedListEditor(
            noun: "Tag", columns: [.init(id: Self.nameColumn, title: "Name", width: 150)],
            nameColumn: Self.nameColumn, logger: KernovaLogger(subsystem: "app.kernova", category: "Test"),
            source: source)
        let window = showTestWindow(styleMask: [.titled], contentSize: NSSize(width: 500, height: 400))
        window.contentView = editor.makePaneView(header: "Tags", caption: "")
        editor.reload()
        window.layoutIfNeeded()
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
}
