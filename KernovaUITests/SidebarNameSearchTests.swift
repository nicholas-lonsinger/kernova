import AppKit
import Foundation
import KernovaCommandModel
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport
@testable import KernovaUI

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

    // MARK: - Projection

    @Test("While a search is on, each header counts what it lists of what it holds")
    func countsUnderSearch() {
        let entries = [vm("Ubuntu", guestOS: .linux), vm("Ubuntu Mac", guestOS: .macOS), vm("Sonoma", guestOS: .macOS)]
        let macs = VMSmartGroup(id: UUID(), name: "Macs", filter: VMLibraryFilter(guestOSes: [.macOS]))
        let folder = VMFolder(id: UUID(), name: "Lab", members: [entries[0].id, entries[2].id])
        let project = { (text: String) in
            SidebarLayout.project(
                entries: entries, options: SidebarViewOptions(), search: search(text),
                organization: .listed([.smartGroup(macs), .folder(folder), .library]), context: .testing())
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
            entries: entries, options: SidebarViewOptions(), search: search("sonoma"),
            organization: .listed([.folder(full), .folder(empty), .library]), context: .testing())

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

    // MARK: - The sidebar's field and Find VM

    @MainActor
    private struct Window {
        let controller: MainWindowController
        let window: NSWindow
        let sidebar: NSSplitViewItem

        var field: NSSearchField { controller.sidebarViewController.searchField }

        /// Whether the keyboard is in the search field.
        var fieldHasFocus: Bool { (window.firstResponder as? NSText)?.delegate === field }

        /// Whether the field is on screen.
        var fieldShown: Bool {
            let shown = controller.sidebarViewController.isSearchShown
            #expect(field.isHidden == !shown)
            return shown
        }

        static let search = NSToolbarItem.Identifier("search")

        /// Clicks the toolbar's Search button.
        func clickSearchButton() throws {
            let item = try #require(window.toolbar?.items.first { $0.itemIdentifier == Self.search })
            #expect(NSApp.sendAction(try #require(item.action), to: item.target, from: item))
        }

        /// The on-screen control AppKit drew for the toolbar item sending `action`.
        func toolbarControl(sending action: Selector) throws -> NSControl {
            window.layoutIfNeeded()
            func controls(in view: NSView) -> [NSControl] {
                ((view as? NSControl).map { [$0] } ?? []) + view.subviews.flatMap(controls(in:))
            }
            let frame = try #require(window.contentView?.superview)
            return try #require(controls(in: frame).first { $0.action == action })
        }
    }

    private func makeWindow(_ viewModel: VMLibraryViewModel) throws -> Window {
        let controller = MainWindowController(viewModel: viewModel, stage: .offDesktop())
        let window = try #require(controller.window)
        let split = try #require(window.contentViewController as? NSSplitViewController)
        return Window(
            controller: controller, window: window,
            sidebar: try #require(split.splitViewItems.first { $0.behavior == .sidebar }))
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

    @Test("New VM and Search share one glass capsule")
    func searchSharesNewVMGlass() throws {
        let subject = try makeWindow(makeViewModel())
        subject.window.makeKeyAndOrderFront(nil)
        func glass(behind action: Selector) throws -> NSGlassEffectView {
            let control: NSView = try subject.toolbarControl(sending: action)
            return try #require(
                sequence(first: control, next: \.superview).lazy.compactMap { $0 as? NSGlassEffectView }.first)
        }

        // AppKit lays a selectable toolbar item out on a platter of its own
        // (measured macOS 27.2 26B118), so Search's shown state cannot be
        // toolbar selection.
        #expect(
            try glass(behind: #selector(AppDelegate.newVM(_:)))
                === glass(behind: #selector(MainWindowController.toggleSearch(_:))))
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
        #expect(subject.window.firstResponder === subject.controller.sidebarViewController.outlineView)
        #expect(subject.field.stringValue == "")
        #expect(!viewModel.library.sidebarSearch.isActive)
    }

    @Test("Escape clears a search field holding text and keeps it shown, then hides the empty field")
    func escapeHidesAnEmptyField() throws {
        let subject = try makeWindow(makeViewModel())
        let editor = try editField(of: subject)
        editor.insertText("ubu", replacementRange: NSRange(location: NSNotFound, length: 0))

        editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        #expect(subject.fieldShown)
        #expect(subject.field.stringValue == "")
        #expect(editor.string == "")

        editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        #expect(!subject.fieldShown)
        #expect(!subject.fieldHasFocus)
    }
}
