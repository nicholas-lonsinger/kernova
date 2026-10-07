import Foundation
import Testing

@testable import Kernova

/// The sidebar's projection — ``SidebarLayout``, the ``SidebarTree`` built from
/// it, and the selection and reorder rules over both — on synthetic layouts
/// with several sections, group headers and duplicate rows, which no UI
/// produces yet.
@Suite("Sidebar projection", .caseScoped)
@MainActor
struct SidebarProjectionTests {
    private let running = SidebarSectionID(rawValue: "smart.running")
    private let work = SidebarGroupID(rawValue: "tag.work")
    private let lab = SidebarGroupID(rawValue: "tag.lab")

    private func vm(_ name: String, id: UUID = UUID()) -> LibraryEntry {
        .vm(VMInstanceFixture.make(name: name) { $0.id = id })
    }

    /// The library section listing `library`, then a "Running" section listing
    /// `grouped` under one header per group.
    private func layout(
        library: [LibraryEntry], grouped: [(SidebarGroupID, [LibraryEntry])] = []
    ) -> SidebarLayout {
        var sections = SidebarLayout.project(entries: library).sections
        if !grouped.isEmpty {
            sections.append(
                SidebarLayout.Section(
                    id: running, title: "Running",
                    content: .groups(
                        SidebarLayout.Groups(
                            grouped.map {
                                SidebarLayout.Group(
                                    id: $0.0, title: $0.0.rawValue, rows: SidebarLayout.Rows($0.1))
                            }))))
        }
        return SidebarLayout(sections: sections)
    }

    private func rows(of node: SidebarNode) -> [SidebarRow] {
        node.children.compactMap { $0 as? SidebarRow }
    }

    // MARK: - Projection

    @Test("The library projection is one section listing every entry in manual order")
    func libraryProjection() {
        let entries = [vm("A"), vm("B"), vm("C")]
        let layout = SidebarLayout.project(entries: entries)

        #expect(layout.sections.map(\.id) == [.library])
        #expect(layout.rowKeys == entries.map { SidebarRowKey.library($0.id) })
    }

    @Test("A row list keeps each entry once")
    func rowsDropRepeats() {
        let alpha = vm("A")
        let beta = vm("B")
        #expect(SidebarLayout.Rows([alpha, beta, alpha]).entries.map(\.id) == [alpha.id, beta.id])
    }

    @Test("A layout keeps the first of a repeated section, and of a repeated group in a section")
    func layoutDropsRepeatedSectionsAndGroups() {
        let alpha = vm("A")
        let beta = vm("B")
        let layout = SidebarLayout(sections: [
            SidebarLayout.Section(
                id: .library, title: "Virtual Machines", content: .rows(SidebarLayout.Rows([alpha]))),
            SidebarLayout.Section(
                id: running, title: "Running",
                content: .groups(
                    SidebarLayout.Groups([
                        SidebarLayout.Group(id: work, title: "Work", rows: SidebarLayout.Rows([alpha])),
                        SidebarLayout.Group(id: work, title: "Again", rows: SidebarLayout.Rows([beta])),
                    ]))),
            SidebarLayout.Section(
                id: .library, title: "Again", content: .rows(SidebarLayout.Rows([beta]))),
        ])

        #expect(layout.sections.map(\.id) == [.library, running])
        #expect(
            layout.rowKeys == [
                .library(alpha.id), SidebarRowKey(section: running, group: work, entryID: alpha.id),
            ])
        let tree = SidebarTree()
        _ = tree.update(to: layout)
        #expect(tree.sections.count == 2)
        #expect(tree.sections.last?.children.count == 1)
    }

    // MARK: - Identity

    @Test("Recomputing the projection keeps every row's object")
    func rowIdentitySurvivesRecomputation() throws {
        let entries = [vm("A"), vm("B")]
        let tree = SidebarTree()
        _ = tree.update(to: layout(library: entries, grouped: [(work, entries)]))
        let section = try #require(tree.sections.first)
        let before = rows(of: section)
        let header = try #require(tree.sections.last?.children.first)

        let unchanged = tree.update(to: layout(library: entries, grouped: [(work, entries)]))
        #expect(unchanged.isEmpty)

        let added = vm("C")
        let changes = tree.update(
            to: layout(library: entries + [added], grouped: [(work, entries)]))

        let after = rows(of: section)
        #expect(tree.sections.first === section)
        #expect(tree.sections.last?.children.first === header)
        #expect(zip(before, after).allSatisfy { $0 === $1 })
        #expect(after.count == 3)
        #expect(changes.children.count == 1)
        #expect(changes.children.first?.parent === section)
        #expect(changes.children.first?.removed == [])
        #expect(changes.children.first?.inserted == [2])
        #expect(changes.created.isEmpty)
    }

    @Test("The same VM in two sections, and under two groups of one, yields distinct rows")
    func duplicateEntriesYieldDistinctRows() throws {
        let alpha = vm("A")
        let tree = SidebarTree()
        _ = tree.update(to: layout(library: [alpha], grouped: [(work, [alpha]), (lab, [alpha])]))

        let libraryRow = try #require(tree.row(for: .library(alpha.id)))
        let workRow = try #require(
            tree.row(for: SidebarRowKey(section: running, group: work, entryID: alpha.id)))
        let labRow = try #require(
            tree.row(for: SidebarRowKey(section: running, group: lab, entryID: alpha.id)))

        #expect(libraryRow !== workRow)
        #expect(workRow !== labRow)
        #expect(libraryRow.entry.vm === workRow.entry.vm)
        #expect((workRow.parent as? SidebarGroupHeader)?.id == work)
        #expect((labRow.parent as? SidebarGroupHeader)?.id == lab)
        #expect(tree.sections.last?.children.count == 2)
    }

    @Test("An entry replaced under its identifier reloads its row in place")
    func replacedEntryReloadsInPlace() throws {
        let id = UUID()
        let tree = SidebarTree()
        _ = tree.update(to: layout(library: [vm("Before", id: id)]))
        let row = try #require(tree.row(for: .library(id)))

        let replacement = vm("After", id: id)
        let changes = tree.update(to: layout(library: [replacement]))

        #expect(tree.row(for: .library(id)) === row)
        #expect(row.entry.vm === replacement.vm)
        #expect(changes.children.isEmpty)
        #expect(changes.reloaded.count == 1)
        #expect(changes.reloaded.first === row)
        #expect(changes.detaches(row))
    }

    @Test("A change leaves untouched rows attached and detaches the ones it moves or removes")
    func detachesOnlyRowsItTouches() throws {
        let alpha = vm("A")
        let beta = vm("B")
        let gamma = vm("C")
        let tree = SidebarTree()
        _ = tree.update(to: layout(library: [alpha, beta, gamma], grouped: [(work, [beta])]))
        let alphaRow = try #require(tree.row(for: .library(alpha.id)))
        let betaRow = try #require(tree.row(for: .library(beta.id)))
        let gammaRow = try #require(tree.row(for: .library(gamma.id)))
        let groupedBeta = try #require(
            tree.row(for: SidebarRowKey(section: running, group: work, entryID: beta.id)))

        // Gamma moves to the top; the Running section goes away.
        let changes = tree.update(to: layout(library: [gamma, alpha, beta]))

        #expect(!changes.detaches(alphaRow))
        #expect(!changes.detaches(betaRow))
        #expect(changes.detaches(gammaRow))
        // Through its section, which the root removes.
        #expect(changes.detaches(groupedBeta))
        let root = try #require(changes.children.first { $0.parent == nil })
        #expect(root.removed == [1])
        #expect(root.inserted == [])
    }

    @Test("A section a layout adds is created along with its group headers")
    func addedSectionIsCreated() {
        let alpha = vm("A")
        let tree = SidebarTree()
        _ = tree.update(to: layout(library: [alpha]))

        let changes = tree.update(to: layout(library: [alpha], grouped: [(work, [alpha])]))

        #expect(changes.created.count == 2)
        #expect(changes.created.first === tree.sections.last)
        #expect(changes.children.count == 1)
        #expect(changes.children.first?.parent == nil)
        #expect(changes.children.first?.inserted == [1])
    }

    // MARK: - Selection

    @Test("A selection lands on its row, else the entry's row in its section, else its library row")
    func selectionFallsBack() {
        let alpha = vm("A")
        let beta = vm("B")
        let inWork = SidebarRowKey(section: running, group: work, entryID: alpha.id)
        let inLab = SidebarRowKey(section: running, group: lab, entryID: alpha.id)

        let both = layout(library: [alpha, beta], grouped: [(work, [alpha]), (lab, [alpha])])
        #expect(both.resolve(inLab) == inLab)

        // Its group went away, but the section still lists it.
        let workOnly = layout(library: [alpha, beta], grouped: [(work, [alpha])])
        #expect(workOnly.resolve(inLab) == inWork)

        // The section no longer lists it.
        let elsewhere = layout(library: [alpha, beta], grouped: [(work, [beta])])
        #expect(elsewhere.resolve(inWork) == .library(alpha.id))

        // Programmatic selection names the library row, which lands as itself.
        #expect(elsewhere.resolve(.library(beta.id)) == .library(beta.id))

        // Gone from every section.
        let gone = layout(library: [beta])
        #expect(gone.resolve(inWork) == nil)
    }

    @Test("selectedID is the selection's entry, and setting it targets the library row")
    func selectedIDDerivesFromSelection() {
        let viewModel = makeLibraryViewModel(preferences: makeTestPreferences())
        let library = viewModel.library
        let alpha = library.admitFixture(name: "A")
        let beta = library.admitFixture(name: "B")
        let inWork = SidebarRowKey(section: running, group: work, entryID: alpha.id)

        library.selection = inWork
        #expect(library.selectedID == alpha.id)
        #expect(library.preferences.lastSelectedVMID == alpha.id)

        // Already selected: the row it is selected in stays.
        library.selectedID = alpha.id
        #expect(library.selection == inWork)

        library.selectedID = beta.id
        #expect(library.selection == .library(beta.id))
        #expect(library.preferences.lastSelectedVMID == beta.id)

        library.selectedID = nil
        #expect(library.selection == nil)
    }

    // MARK: - Reorder

    @Test("With every entry visible, a drop maps straight through and its own gap is a no-op")
    func reorderWithEveryEntryVisible() {
        let order = (0..<5).map { _ in UUID() }
        func offset(_ moved: Int, to index: Int) -> Int? {
            SidebarLayout.manualOrderOffset(
                moving: order[moved], toVisibleIndex: index, amongVisible: order, in: order)
        }
        // Move down / up: the proposed gap maps straight through.
        #expect(offset(0, to: 3) == 3)
        #expect(offset(4, to: 1) == 1)
        // Dropped into its own gap (above itself or just below) — no-op.
        #expect(offset(2, to: 2) == nil)
        #expect(offset(2, to: 3) == nil)
        // Past the last row appends.
        #expect(offset(0, to: 5) == 5)
    }

    @Test("Under a projection that hides entries, a drop lands just before its visible neighbor")
    func reorderAmongVisibleRows() {
        let ids = (0..<6).map { _ in UUID() }
        // Manual order a h1 b c h2 d; the section shows a b c d.
        let (a, h1, b, c, h2, d) = (ids[0], ids[1], ids[2], ids[3], ids[4], ids[5])
        let order = [a, h1, b, c, h2, d]
        let visible = [a, b, c, d]
        func offset(_ moved: UUID, to index: Int) -> Int? {
            SidebarLayout.manualOrderOffset(
                moving: moved, toVisibleIndex: index, amongVisible: visible, in: order)
        }
        func moved(_ id: UUID, to index: Int) -> [UUID]? {
            guard let destination = offset(id, to: index), let source = order.firstIndex(of: id)
            else { return nil }
            var result = order
            result.move(fromOffsets: IndexSet(integer: source), toOffset: destination)
            return result
        }

        // d dropped above b: just before b, past the hidden h1 it was not dropped on.
        #expect(moved(d, to: 1) == [a, h1, d, b, c, h2])
        // a dropped above d: just before d, after the hidden h2.
        #expect(moved(a, to: 3) == [h1, b, c, h2, a, d])
        // b dropped past the last visible row: just after d.
        #expect(moved(b, to: 4) == [a, h1, c, h2, d, b])
        // c dropped into its own gap, below b, moves nothing — even though h2
        // sits between c and the d below it.
        #expect(offset(c, to: 2) == nil)
        #expect(offset(c, to: 3) == nil)
    }
}
