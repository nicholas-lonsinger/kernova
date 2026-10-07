import AppKit
import Foundation
import KernovaKit
import KernovaTestSupport
import Testing

@testable import Kernova

/// The toolbar's name search: how it narrows every sidebar section and what
/// their headers count, how it stays apart from the filter, what a search from
/// outside the app makes of it, and Find VM.
@Suite("Sidebar name search", .serialized, .caseScoped, .scopedWindows)
@MainActor
struct SidebarNameSearchTests {
    private let preferences = makeTestPreferences()

    private func makeViewModel() -> VMLibraryViewModel {
        makeLibraryViewModel(preferences: preferences)
    }

    private func vm(_ name: String, guestOS: VMGuestOS = .linux) -> LibraryEntry {
        .vm(VMInstanceFixture.make(name: name, guestOS: guestOS))
    }

    private func names(in section: SidebarLayout.Section) -> [String] {
        switch section.content {
        case .rows(let rows): rows.entries.map(\.name)
        case .groups(let groups): groups.groups.flatMap { $0.rows.entries.map(\.name) }
        }
    }

    private func search(_ text: String) -> SidebarNameSearch { SidebarNameSearch(text: text) }

    // MARK: - Matching

    @Test("A name matches when it contains the trimmed term, ignoring case and diacritics")
    func matching() {
        #expect(search("ubu").admits("Ubuntu Server"))
        #expect(search("  server ").admits("Ubuntu Server"))
        #expect(search("cafe").admits("Café Lab"))
        #expect(!search("sonoma").admits("Ubuntu Server"))
        #expect(search("   ").admits("Anything"))
        #expect(!search("   ").isActive)
    }

    @Test("The best match is the name equal to the term, then one it begins, then the first that contains it")
    func bestMatch() {
        let names = ["Old Ubuntu", "Ubuntu Server", "ubuntu"]
        #expect(search("Ubuntu").bestMatch(in: names, name: { $0 }) == "ubuntu")
        #expect(search("Ubuntu S").bestMatch(in: names, name: { $0 }) == "Ubuntu Server")
        #expect(search("buntu").bestMatch(in: names, name: { $0 }) == "Old Ubuntu")
        #expect(search("Sequoia").bestMatch(in: names, name: { $0 }) == nil)
        #expect(search("").bestMatch(in: names, name: { $0 }) == nil)
    }

    // MARK: - Projection

    @Test("The search narrows every section — smart groups, folders and the library — on top of each one's own rule")
    func narrowsEverySection() {
        let entries = [
            vm("Ubuntu", guestOS: .linux), vm("Ubuntu Mac", guestOS: .macOS), vm("Sonoma", guestOS: .macOS),
        ]
        let macs = VMSmartGroup(id: UUID(), name: "Macs", filter: VMLibraryFilter(guestOSes: [.macOS]))
        let folder = VMFolder(id: UUID(), name: "Lab", members: entries.map(\.id))
        let layout = SidebarLayout.project(
            entries: entries, options: SidebarViewOptions(sort: .name), search: search("ubuntu"),
            smartGroups: [macs], folders: [folder], context: .testing())

        #expect(names(in: layout.sections[0]) == ["Ubuntu Mac"])
        #expect(names(in: layout.sections[1]) == ["Ubuntu", "Ubuntu Mac"])
        #expect(names(in: layout.sections[2]) == ["Ubuntu", "Ubuntu Mac"])
    }

    @Test("The search and the library's filter both narrow the library: a VM is listed only when both admit it")
    func andsWithTheFilter() {
        let entries = [vm("Ubuntu", guestOS: .linux), vm("Ubuntu Mac", guestOS: .macOS), vm("Sonoma", guestOS: .macOS)]
        let layout = SidebarLayout.project(
            entries: entries, options: SidebarViewOptions(filter: VMLibraryFilter(guestOSes: [.macOS])),
            search: search("ubuntu"), context: .testing())

        #expect(names(in: layout.sections[0]) == ["Ubuntu Mac"])
        #expect(layout.sections[0].count == .narrowed(shown: 1, of: 3))
    }

    @Test("While a search is on, each header counts what it lists of what it holds")
    func countsUnderSearch() {
        let entries = [vm("Ubuntu", guestOS: .linux), vm("Ubuntu Mac", guestOS: .macOS), vm("Sonoma", guestOS: .macOS)]
        let macs = VMSmartGroup(id: UUID(), name: "Macs", filter: VMLibraryFilter(guestOSes: [.macOS]))
        let folder = VMFolder(id: UUID(), name: "Lab", members: [entries[0].id, entries[2].id])
        let project = { (text: String) in
            SidebarLayout.project(
                entries: entries, options: SidebarViewOptions(), search: search(text), smartGroups: [macs],
                folders: [folder], context: .testing())
        }

        let searched = project("ubuntu")
        #expect(
            searched.sections.map(\.count) == [
                .narrowed(shown: 1, of: 2), .narrowed(shown: 1, of: 2), .narrowed(shown: 2, of: 3),
            ])
        #expect(searched.sections.map { $0.count?.text } == ["1 of 2", "1 of 2", "2 of 3"])

        let unsearched = project("")
        #expect(unsearched.sections.map(\.count) == [.members(2), .members(2), nil])
    }

    @Test("A section the search empties says no VMs match; a folder with no members still asks for some")
    func emptyTextUnderSearch() {
        let entries = [vm("Ubuntu")]
        let full = VMFolder(id: UUID(), name: "Full", members: [entries[0].id])
        let empty = VMFolder(id: UUID(), name: "Empty", members: [])
        let layout = SidebarLayout.project(
            entries: entries, options: SidebarViewOptions(), search: search("sonoma"), folders: [full, empty],
            context: .testing())

        #expect(
            layout.sections.map(\.emptyText) == [
                SidebarLayout.noMatchesText, SidebarLayout.emptyFolderText, SidebarLayout.noMatchesText,
            ])
    }

    @Test("The library section's header counts under the search alone, its filter button left inactive")
    func libraryHeaderUnderSearchAlone() throws {
        let viewModel = makeViewModel()
        viewModel.library.admitFixture(name: "Ubuntu")
        viewModel.library.admitFixture(name: "Sonoma")
        let controller = SidebarViewController(viewModel: viewModel)
        let window = showTestWindow(styleMask: [.titled], contentSize: NSSize(width: 300, height: 600))
        window.contentView = controller.view
        controller.viewDidAppear()

        viewModel.library.sidebarSearch = search("sonoma")
        controller.viewDidAppear()

        let section = try #require(controller.tree.sections.last)
        #expect(
            controller.filtering(for: section)
                == SidebarGroupHeaderCellView.Filtering(countText: "1 of 2", isActive: false, activeDescription: nil))
    }

    // MARK: - Apart from the filter

    @Test("Clear Filters clears the filter and keeps the search")
    func clearFiltersKeepsTheSearch() throws {
        let viewModel = makeViewModel()
        viewModel.library.admitFixture(name: "Ubuntu", guestOS: .linux)
        viewModel.library.admitFixture(name: "Ubuntu Mac", guestOS: .macOS)
        viewModel.sidebarOptions.filter = VMLibraryFilter(guestOSes: [.macOS])
        viewModel.library.sidebarSearch = search("ubuntu")
        let controller = SidebarViewController(viewModel: viewModel)

        let menu = try #require(controller.viewMenu(for: .library))
        let clear = try #require(menu.items.first { $0.title == "Clear Filters" })
        let command = try #require((clear.representedObject as? SidebarViewMenu.Pick)?.command)
        controller.perform(command)

        #expect(!viewModel.sidebarOptions.filter.isActive)
        #expect(viewModel.library.sidebarSearch == search("ubuntu"))
        #expect(names(in: try #require(viewModel.sidebarLayout.sections.last)) == ["Ubuntu", "Ubuntu Mac"])
    }

    @Test("Saving the filter as a smart group saves the filter alone, and the search stays on")
    func saveAsSmartGroupLeavesTheSearch() throws {
        let viewModel = makeViewModel()
        viewModel.library.admitFixture(name: "Ubuntu Mac", guestOS: .macOS)
        viewModel.library.admitFixture(name: "Sonoma", guestOS: .macOS)
        viewModel.sidebarOptions.filter = VMLibraryFilter(guestOSes: [.macOS])
        viewModel.library.sidebarSearch = search("ubuntu")

        let group = try viewModel.library.saveSidebarFilterAsSmartGroup(named: "Macs")

        #expect(group.filter == VMLibraryFilter(guestOSes: [.macOS]))
        #expect(viewModel.library.sidebarSearch == search("ubuntu"))
        // The group holds both Macs; the search lists one of them.
        #expect(viewModel.sidebarLayout.sections.first?.count == .narrowed(shown: 1, of: 2))
    }

    // MARK: - Selection

    @Test("A search that hides the selected VM clears the selection, as a filter edit does")
    func searchHidingSelectionClearsIt() {
        let viewModel = makeViewModel()
        let ubuntu = viewModel.library.admitFixture(name: "Ubuntu")
        viewModel.library.admitFixture(name: "Sonoma")
        viewModel.selection = .library(ubuntu.id)

        viewModel.library.sidebarSearch = search("sonoma")

        #expect(viewModel.selection == nil)
    }

    @Test("Renaming the selected VM out of the search keeps it listed until the selection moves off it")
    func renameKeepsSelectedVMListed() throws {
        let viewModel = makeViewModel()
        let ubuntu = viewModel.library.admitFixture(name: "Ubuntu")
        let other = viewModel.library.admitFixture(name: "Ubuntu Two")
        viewModel.library.sidebarSearch = search("ubuntu")
        viewModel.selection = .library(ubuntu.id)

        try viewModel.commands.rename(.id(ubuntu.id), to: "Renamed")

        let library = try #require(viewModel.sidebarLayout.sections.last)
        #expect(names(in: library) == ["Renamed", "Ubuntu Two"])
        #expect(viewModel.selection == .library(ubuntu.id))

        viewModel.selection = .library(other.id)
        #expect(names(in: try #require(viewModel.sidebarLayout.sections.last)) == ["Ubuntu Two"])
    }

    @Test("Revealing a VM the search hides clears the search")
    func revealClearsAHidingSearch() {
        let viewModel = makeViewModel()
        let ubuntu = viewModel.library.admitFixture(name: "Ubuntu")
        let sonoma = viewModel.library.admitFixture(name: "Sonoma")
        viewModel.library.sidebarSearch = search("sonoma")

        viewModel.selectRevealing(sonoma.id)
        #expect(viewModel.library.sidebarSearch == search("sonoma"))

        viewModel.selectRevealing(ubuntu.id)
        #expect(!viewModel.library.sidebarSearch.isActive)
        #expect(viewModel.selection == .library(ubuntu.id))
    }

    // MARK: - A search from outside the app

    @Test("A search from outside the app fills the search and selects the VM the term most likely names")
    func showSearchResultsFillsTheSearch() {
        let viewModel = makeViewModel()
        viewModel.library.admitFixture(name: "Old Ubuntu")
        viewModel.library.admitFixture(name: "Ubuntu Server")
        let exact = viewModel.library.admitFixture(name: "ubuntu")

        viewModel.library.showSearchResults(for: "Ubuntu")

        #expect(viewModel.library.sidebarSearch == search("Ubuntu"))
        #expect(viewModel.selectedID == exact.id)
    }

    @Test("A search from outside the app that nothing matches fills the search and leaves the selection")
    func showSearchResultsWithNoMatch() {
        let viewModel = makeViewModel()
        let ubuntu = viewModel.library.admitFixture(name: "Ubuntu")
        viewModel.selection = .library(ubuntu.id)

        viewModel.library.showSearchResults(for: "Sequoia")

        #expect(viewModel.library.sidebarSearch == search("Sequoia"))
        #expect(viewModel.sidebarLayout.sections.last?.emptyText == SidebarLayout.noMatchesText)
    }

    // MARK: - Toolbar field and Find VM

    @MainActor
    private struct Window {
        let controller: MainWindowController
        let window: NSWindow
        let toolbar: NSToolbar
        let sidebar: NSSplitViewItem

        var searchItem: NSSearchToolbarItem? {
            toolbar.items.first { $0.itemIdentifier == MainWindowController.toolbarSearch } as? NSSearchToolbarItem
        }
    }

    private func makeWindow(_ viewModel: VMLibraryViewModel) throws -> Window {
        let controller = MainWindowController(viewModel: viewModel, autosaveScope: .unsaved())
        let window = try #require(controller.window)
        adoptAppWindow(window)
        let split = try #require(window.contentViewController as? NSSplitViewController)
        return Window(
            controller: controller, window: window, toolbar: try #require(window.toolbar),
            sidebar: try #require(split.splitViewItems.first { $0.behavior == .sidebar }))
    }

    @Test("The toolbar's search field writes the library's search, and shows one written elsewhere")
    func fieldMirrorsTheLibrarySearch() async throws {
        let viewModel = makeViewModel()
        let subject = try makeWindow(viewModel)
        let field = try #require(subject.searchItem?.searchField)

        field.stringValue = "ubu"
        _ = field.sendAction(field.action, to: field.target)
        #expect(viewModel.library.sidebarSearch == search("ubu"))

        viewModel.library.showSearchResults(for: "sonoma")
        try await waitUntil { field.stringValue == "sonoma" }
    }

    @Test("Find VM expands a collapsed sidebar and puts the keyboard in the search field")
    func findVMWithSidebarCollapsed() async throws {
        let subject = try makeWindow(makeViewModel())
        subject.window.makeKeyAndOrderFront(nil)
        subject.sidebar.isCollapsed = true
        let field = try #require(subject.searchItem?.searchField)

        subject.controller.focusSearch()

        try await waitUntil { !subject.sidebar.isCollapsed }
        #expect((subject.window.firstResponder as? NSText)?.delegate === field)
    }

    @Test("Find VM is offered while the toolbar holds the search item, and disabled once it is customized out")
    func findVMDisabledWithoutTheItem() throws {
        let viewModel = makeViewModel()
        let subject = try makeWindow(viewModel)
        let host = StubMenuHost()
        let menuController = MainMenuController(viewModel: viewModel)
        menuController.host = host
        let edit = try #require(menuController.makeMainMenu().items.first { $0.submenu?.title == "Edit" }?.submenu)
        let find = try #require(edit.items.first { $0.title == "Find VM\u{2026}" })
        #expect(find.keyEquivalent == "f")
        #expect(find.keyEquivalentModifierMask == [.command])

        host.offersLibrarySearch = subject.controller.offersSearch
        #expect(menuController.validate(find))

        let index = try #require(
            subject.toolbar.items.firstIndex { $0.itemIdentifier == MainWindowController.toolbarSearch })
        subject.toolbar.removeItem(at: index)
        host.offersLibrarySearch = subject.controller.offersSearch
        #expect(!menuController.validate(find))
    }
}
