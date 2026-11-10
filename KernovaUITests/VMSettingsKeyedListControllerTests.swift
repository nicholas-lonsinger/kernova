import AppKit
import KernovaTestSupport
import Testing

@testable import KernovaUI

@Suite("VMSettingsKeyedListController Tests", .caseScoped)
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
    }

    /// The list plus the counters its hooks bump, so a test can assert which
    /// path a pass took.
    @MainActor
    private final class Fixture {
        let stack = NSStackView()
        let list: VMSettingsKeyedListController<Model, Row>
        var built: [UUID] = []
        var applied: [UUID] = []

        init(emptyMessage: String? = nil, separator: (() -> NSView)? = nil) {
            stack.orientation = .vertical
            list = VMSettingsKeyedListController(
                listStack: stack, emptyMessage: emptyMessage, separator: separator)
        }

        func update(_ models: [Model]) {
            list.update(
                models,
                makeRow: { model in
                    built.append(model.id)
                    return Row()
                },
                applyRow: { model, row in
                    applied.append(model.id)
                    row.title = model.title
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
