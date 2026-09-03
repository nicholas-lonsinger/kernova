import AppKit
import Testing

@testable import Kernova

@Suite("VMSettingsKeyedListController Tests", .admissionGated)
@MainActor
struct VMSettingsKeyedListControllerTests {
    /// A row's model: an id and the one value a change shows up in.
    private struct Model: Identifiable, Equatable {
        let id: UUID
        var title: String
    }

    /// A row view carrying the title it was last written with, so a test can
    /// tell an in-place update from a rebuilt row.
    @MainActor
    private final class Row: NSView {
        var title = ""
        var subtitleReads = 0
    }

    /// The list plus the counters its hooks bump, so a test can assert which
    /// path a pass took.
    @MainActor
    private final class Fixture {
        let stack = NSStackView()
        let list: VMSettingsKeyedListController<Model, Row>
        var built: [UUID] = []
        var applied: [UUID] = []
        var subtitleReads: [UUID] = []

        init(emptyMessage: String? = nil, separator: (() -> NSView)? = nil) {
            stack.orientation = .vertical
            list = VMSettingsKeyedListController(
                listStack: stack, emptyMessage: emptyMessage, separator: separator)
        }

        func update(_ models: [Model], readsUnchangedRows: Bool = false) {
            list.update(
                models,
                readsUnchangedRows: readsUnchangedRows,
                makeRow: { model in
                    built.append(model.id)
                    return Row()
                },
                applyRow: { model, row in
                    applied.append(model.id)
                    row.title = model.title
                },
                readLiveSubtitle: { model, row in
                    subtitleReads.append(model.id)
                    row.subtitleReads += 1
                })
        }
    }

    private func makeModel(_ title: String) -> Model {
        Model(id: UUID(), title: title)
    }

    // MARK: - Structural rebuild

    @Test("A structural pass builds every row, keys them, and stacks them in order")
    func structuralPassBuildsRows() throws {
        let fixture = Fixture()
        let first = makeModel("One")
        let second = makeModel("Two")

        fixture.update([first, second])

        #expect(fixture.built == [first.id, second.id])
        #expect(fixture.applied == [first.id, second.id])
        #expect(fixture.subtitleReads == [first.id, second.id])
        #expect(fixture.list.row(first.id)?.title == "One")
        #expect(fixture.stack.arrangedSubviews.count == 2)
        #expect(fixture.list.rendered?.map(\.id) == [first.id, second.id])
    }

    @Test("A removed row is rebuilt out of the stack and out of the row table")
    func structuralPassRekeysRows() throws {
        let fixture = Fixture()
        let first = makeModel("One")
        let second = makeModel("Two")
        fixture.update([first, second])
        let firstRow = try #require(fixture.list.row(first.id))

        fixture.update([second])

        #expect(fixture.list.row(first.id) == nil)
        #expect(fixture.stack.arrangedSubviews.count == 1)
        #expect(firstRow.superview == nil)
        // Rebuilt, not reused: the surviving row is a fresh view.
        #expect(fixture.built == [first.id, second.id, second.id])
    }

    // MARK: - In-place update

    @Test("Same ids take the in-place path, applying only what changed")
    func inPlacePassAppliesOnlyChangedRows() throws {
        let fixture = Fixture()
        let first = makeModel("One")
        let second = makeModel("Two")
        fixture.update([first, second])
        let firstRow = try #require(fixture.list.row(first.id))

        var renamed = first
        renamed.title = "Renamed"
        fixture.update([renamed, second])

        // No rebuild: the row views are the ones the first pass made.
        #expect(fixture.built == [first.id, second.id])
        #expect(fixture.list.row(first.id) === firstRow)
        #expect(firstRow.title == "Renamed")
        #expect(fixture.applied == [first.id, second.id, first.id])
        #expect(fixture.subtitleReads == [first.id, second.id, first.id])
    }

    @Test("An unchanged row is re-read only when the caller says its subtitle can move")
    func unchangedRowsAreReReadOnlyWhenAsked() {
        let fixture = Fixture()
        let model = makeModel("One")
        fixture.update([model])

        fixture.update([model])
        #expect(fixture.subtitleReads == [model.id])
        #expect(fixture.applied == [model.id])

        fixture.update([model], readsUnchangedRows: true)
        // Re-read, but not re-applied: nothing about the row changed.
        #expect(fixture.subtitleReads == [model.id, model.id])
        #expect(fixture.applied == [model.id])
    }

    // MARK: - Edit suppression

    @Test("An edit in flight defers a structural rebuild and keeps the prior snapshot")
    func activeEditDefersTheRebuild() {
        let fixture = Fixture()
        let first = makeModel("One")
        fixture.update([first])
        fixture.list.activeEdit = first.id

        let second = makeModel("Two")
        fixture.update([first, second])

        #expect(fixture.stack.arrangedSubviews.count == 1)
        #expect(fixture.list.row(second.id) == nil)
        // Storing the deferred models would leave the next pass diffing against
        // rows that were never built.
        #expect(fixture.list.rendered?.map(\.id) == [first.id])
    }

    @Test("The deferred rebuild lands on the next pass once the edit clears")
    func deferredRebuildLandsAfterTheEdit() {
        let fixture = Fixture()
        let first = makeModel("One")
        fixture.update([first])
        fixture.list.activeEdit = first.id
        let second = makeModel("Two")
        fixture.update([first, second])

        fixture.list.activeEdit = nil
        fixture.update([first, second])

        #expect(fixture.stack.arrangedSubviews.count == 2)
        #expect(fixture.list.row(second.id)?.title == "Two")
    }

    // MARK: - Empty state and separators

    @Test("An empty list renders its message, or nothing when it has none")
    func emptyMessageRendersOnlyWhenGiven() {
        let announced = Fixture(emptyMessage: "No rows")
        announced.update([])
        #expect(findLabel(withText: "No rows", in: announced.stack) != nil)

        let silent = Fixture()
        silent.update([])
        #expect(silent.stack.arrangedSubviews.isEmpty)
    }

    @Test("A separator is placed between adjacent rows and nowhere else")
    func separatorGoesBetweenRows() {
        let fixture = Fixture(separator: { NSBox() })

        fixture.update([makeModel("One"), makeModel("Two"), makeModel("Three")])

        #expect(fixture.stack.arrangedSubviews.count == 5)
        #expect(allSubviews(NSBox.self, in: fixture.stack).count == 2)
    }
}
