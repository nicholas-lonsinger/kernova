import AppKit
import Foundation
import KernovaKit
import KernovaTestSupport
import Testing

@testable import Kernova

/// The sidebar's name search: how it narrows every sidebar section and what
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

    @Test("A search from outside the app that nothing matches fills the search and clears the selection it hides")
    func showSearchResultsWithNoMatch() {
        let viewModel = makeViewModel()
        let ubuntu = viewModel.library.admitFixture(name: "Ubuntu")
        viewModel.selection = .library(ubuntu.id)

        viewModel.library.showSearchResults(for: "Sequoia")

        #expect(viewModel.library.sidebarSearch == search("Sequoia"))
        #expect(viewModel.selection == nil)
        #expect(viewModel.sidebarLayout.sections.last?.emptyText == SidebarLayout.noMatchesText)
    }

    // MARK: - The sidebar's field and Find VM

    @MainActor
    private struct Window {
        let controller: MainWindowController
        let window: NSWindow
        let sidebar: NSSplitViewItem

        var field: NSSearchField { controller.sidebarViewController.searchField }

        /// Whether the keyboard is in the search field.
        var fieldHasFocus: Bool { (window.firstResponder as? NSText)?.delegate === field }

        /// Whether the field is on screen, checked against the Search button's
        /// selection, which shows it.
        var fieldShown: Bool {
            let shown = controller.sidebarViewController.isSearchShown
            #expect(field.isHidden == !shown)
            #expect((window.toolbar?.selectedItemIdentifier == Self.search) == shown)
            return shown
        }

        static let search = NSToolbarItem.Identifier("search")

        /// Clicks the toolbar's Search button.
        func clickSearchButton() throws {
            let item = try #require(window.toolbar?.items.first { $0.itemIdentifier == Self.search })
            #expect(NSApp.sendAction(try #require(item.action), to: item.target, from: item))
        }
    }

    private func makeWindow(_ viewModel: VMLibraryViewModel) throws -> Window {
        let controller = MainWindowController(viewModel: viewModel, autosaveScope: .unsaved())
        let window = try #require(controller.window)
        adoptAppWindow(window)
        let split = try #require(window.contentViewController as? NSSplitViewController)
        return Window(
            controller: controller, window: window,
            sidebar: try #require(split.splitViewItems.first { $0.behavior == .sidebar }))
    }

    @Test("The sidebar's field writes the library's search and shows one written elsewhere, with the toolbar hidden")
    func fieldMirrorsTheLibrarySearchWithToolbarHidden() async throws {
        let viewModel = makeViewModel()
        let subject = try makeWindow(viewModel)
        subject.window.toolbar?.isVisible = false
        subject.window.makeKeyAndOrderFront(nil)
        let field = subject.field
        #expect(field.window === subject.window)

        subject.controller.focusSearch()
        field.stringValue = "ubu"
        _ = field.sendAction(field.action, to: field.target)
        #expect(viewModel.library.sidebarSearch == search("ubu"))

        viewModel.library.showSearchResults(for: "sonoma")
        // The sidebar's own observation loop writes the field, and offers no
        // test-facing signal to await.
        try await waitUntil { field.stringValue == "sonoma" }
    }

    /// `subject`'s search field holding the keyboard, and its field editor.
    private func editField(of subject: Window) throws -> NSTextView {
        subject.window.makeKeyAndOrderFront(nil)
        subject.controller.sidebarViewController.focusSearchField()
        return try #require(subject.field.currentEditor() as? NSTextView)
    }

    @Test("Text typed but not yet sent survives a sync pass")
    func unsentTextSurvivesSync() throws {
        let viewModel = makeViewModel()
        let subject = try makeWindow(viewModel)
        let editor = try editField(of: subject)

        editor.insertText("ubu", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(!viewModel.library.sidebarSearch.isActive)
        // A pass the search did not cause: a VM arriving.
        viewModel.library.admitFixture(name: "Ubuntu")
        subject.controller.sidebarViewController.viewDidAppear()

        #expect(editor.string == "ubu")
        #expect(subject.field.currentEditor() === editor)
    }

    @Test("Marked text being composed survives a sync pass")
    func markedTextSurvivesSync() throws {
        let viewModel = makeViewModel()
        let subject = try makeWindow(viewModel)
        let editor = try editField(of: subject)

        editor.setMarkedText(
            "う", selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        try #require(editor.hasMarkedText())
        viewModel.library.admitFixture(name: "Ubuntu")
        subject.controller.sidebarViewController.viewDidAppear()

        #expect(editor.hasMarkedText())
        #expect(editor.string == "う")
    }

    @Test("A search written from outside the idle field shows the field and the search on the next sync pass")
    func outsideWriteShowsWhenIdle() throws {
        let viewModel = makeViewModel()
        let subject = try makeWindow(viewModel)
        subject.window.makeKeyAndOrderFront(nil)
        let sidebar = subject.controller.sidebarViewController
        sidebar.viewDidAppear()
        try #require(!subject.fieldShown)

        viewModel.library.showSearchResults(for: "sonoma")
        sidebar.viewDidAppear()
        #expect(subject.field.stringValue == "sonoma")
        #expect(subject.fieldShown)

        // The same text the field already shows is no outside write.
        subject.field.stringValue = "sonoma"
        _ = subject.field.sendAction(subject.field.action, to: subject.field.target)
        viewModel.library.showSearchResults(for: "")
        sidebar.viewDidAppear()
        #expect(subject.field.stringValue == "")
    }

    @Test("A library window opens with the keyboard in the outline, not the search field")
    func libraryOpensWithTheOutlineFocused() throws {
        let viewModel = makeViewModel()
        viewModel.library.admitFixture(name: "Ubuntu")
        let autosave = WindowAutosaveScope.unsaved()
        let registry = AppWindowRegistry(
            viewModel: viewModel,
            displayPlacement: VMDisplayPlacementController(viewModel: viewModel, autosaveScope: autosave),
            autosaveScope: autosave)

        registry.showLibrary(bringToFront: true)

        let window = try #require(registry.libraryWindow)
        adoptAppWindow(window)
        let sidebar = try #require(registry.librarySidebar)
        #expect(window.firstResponder === sidebar.outlineView)
        #expect((window.firstResponder as? NSText)?.delegate !== sidebar.searchField)
    }

    @Test("Find VM expands a collapsed sidebar and puts the keyboard in the search field")
    func findVMWithSidebarCollapsed() async throws {
        let subject = try makeWindow(makeViewModel())
        subject.window.makeKeyAndOrderFront(nil)
        subject.sidebar.isCollapsed = true

        subject.controller.focusSearch()

        try await waitUntil { !subject.sidebar.isCollapsed }
        #expect(subject.fieldShown)
        #expect(subject.fieldHasFocus)
    }

    @Test("A library window opens with the search field hidden")
    func fieldHiddenByDefault() throws {
        let subject = try makeWindow(makeViewModel())
        subject.window.makeKeyAndOrderFront(nil)

        #expect(!subject.fieldShown)
    }

    @Test("The default toolbar puts Search beside New VM, ahead of the sidebar toggle")
    func searchButtonInDefaultToolbar() throws {
        let subject = try makeWindow(makeViewModel())
        let layout = try #require(subject.window.toolbar).items.map(\.itemIdentifier)
        let index = try #require(layout.firstIndex(of: Window.search))

        #expect(
            Array(layout[index...].prefix(3)) == [
                Window.search, NSToolbarItem.Identifier("newVM"), .toggleSidebar,
            ])
    }

    @Test("Show in Finder's toolbar item shows the Finder's symbol, not Search's magnifying glass")
    func showInFinderSymbol() throws {
        let subject = try makeWindow(makeViewModel())
        let toolbar = try #require(subject.window.toolbar)
        func symbol(_ name: String) -> Data? {
            NSImage(systemSymbolName: name, accessibilityDescription: nil)?.tiffRepresentation
        }

        let item = try #require(
            subject.controller.toolbar(
                toolbar, itemForItemIdentifier: NSToolbarItem.Identifier("showInFinder"),
                willBeInsertedIntoToolbar: false))

        #expect(item.image?.tiffRepresentation == symbol("finder"))
        #expect(item.image?.tiffRepresentation != symbol("magnifyingglass"))
    }

    @Test("The Search button shows the field with the keyboard in it, and hides it again, ending its search")
    func searchButtonTogglesTheField() throws {
        let viewModel = makeViewModel()
        let subject = try makeWindow(viewModel)
        subject.window.makeKeyAndOrderFront(nil)

        try subject.clickSearchButton()
        #expect(subject.fieldShown)
        #expect(subject.fieldHasFocus)
        subject.field.stringValue = "ubu"
        _ = subject.field.sendAction(subject.field.action, to: subject.field.target)
        try #require(viewModel.library.sidebarSearch == search("ubu"))

        try subject.clickSearchButton()
        #expect(!subject.fieldShown)
        #expect(!subject.fieldHasFocus)
        #expect(subject.field.stringValue == "")
        #expect(!viewModel.library.sidebarSearch.isActive)
    }

    @Test("The Search button expands a collapsed sidebar with the field shown instead of hiding it")
    func searchButtonWithSidebarCollapsed() async throws {
        let subject = try makeWindow(makeViewModel())
        subject.window.makeKeyAndOrderFront(nil)
        subject.controller.focusSearch()
        subject.sidebar.isCollapsed = true

        try subject.clickSearchButton()

        try await waitUntil { !subject.sidebar.isCollapsed }
        #expect(subject.fieldShown)
        #expect(subject.fieldHasFocus)
    }

    @Test("Escape hides an empty search field and leaves one holding text shown")
    func escapeHidesAnEmptyField() throws {
        let subject = try makeWindow(makeViewModel())
        let editor = try editField(of: subject)
        editor.insertText("ubu", replacementRange: NSRange(location: NSNotFound, length: 0))

        editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        #expect(subject.fieldShown)

        editor.string = ""
        editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        #expect(!subject.fieldShown)
        #expect(!subject.fieldHasFocus)
    }

    @Test("Find VM is ⌘F, enabled with no library window, and opens the window with its field shown and focused")
    func findVMOpensTheLibrary() throws {
        let viewModel = makeViewModel()
        let menuController = MainMenuController(viewModel: viewModel)
        let host = StubMenuHost()
        menuController.host = host
        let edit = try #require(menuController.makeMainMenu().items.first { $0.submenu?.title == "Edit" }?.submenu)
        let find = try #require(edit.items.first { $0.title == "Find VM\u{2026}" })
        #expect(find.keyEquivalent == "f")
        #expect(find.keyEquivalentModifierMask == [.command])
        #expect(find.action == #selector(AppDelegate.findVM(_:)))
        #expect(menuController.validate(find))

        // What `AppDelegate.findVM(_:)` runs.
        let autosave = WindowAutosaveScope.unsaved()
        let registry = AppWindowRegistry(
            viewModel: viewModel,
            displayPlacement: VMDisplayPlacementController(viewModel: viewModel, autosaveScope: autosave),
            autosaveScope: autosave)
        #expect(registry.libraryWindow == nil)

        registry.focusLibrarySearch()

        let window = try #require(registry.libraryWindow)
        adoptAppWindow(window)
        let sidebar = try #require(registry.librarySidebar)
        #expect(sidebar.isSearchShown)
        #expect((window.firstResponder as? NSText)?.delegate === sidebar.searchField)
    }
}
