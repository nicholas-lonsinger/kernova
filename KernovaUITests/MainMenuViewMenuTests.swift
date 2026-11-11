import AppKit
import KernovaCommandModel
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport
@testable import KernovaUI

/// The View menu's sidebar items: that they stay and set the library's
/// options without a library window, match their shortcuts through the menu
/// bar, and expand and collapse every section.
@Suite("View menu sidebar items", .serialized, .caseScoped, .scopedWindows)
@MainActor
struct MainMenuViewMenuTests {
    private let preferences = makeTestPreferences()

    @MainActor
    private struct Fixture {
        let controller: MainMenuController
        let viewModel: VMLibraryViewModel
        let windows: AppWindowRegistry
        let mainMenu: NSMenu
        let viewMenu: NSMenu

        /// The View menu as it reads once opened.
        func opened() -> NSMenu {
            viewMenu.delegate?.menuNeedsUpdate?(viewMenu)
            viewMenu.update()
            return viewMenu
        }

        /// Puts the library window on screen, as the app shows it, so its
        /// sidebar is the one the View menu reads and acts on.
        func openLibraryWindow() throws {
            windows.showLibrary(bringToFront: false)
        }

        /// The on-screen library window's sidebar.
        func sidebar() throws -> SidebarViewController {
            try #require(windows.librarySidebar)
        }
    }

    private func makeFixture(
        sidebarAttached: Bool = true, populate: (VMLibraryViewModel) throws -> Void = { _ in }
    ) throws -> Fixture {
        let viewModel = makeLibraryViewModel(preferences: preferences)
        try populate(viewModel)
        let windows = makeWindowRegistry(viewModel)
        let controller = MainMenuController(
            viewModel: viewModel, windows: windows)
        let mainMenu = controller.makeMainMenu()
        let fixture = Fixture(
            controller: controller, viewModel: viewModel, windows: windows, mainMenu: mainMenu,
            viewMenu: try #require(submenu(titled: "View", in: mainMenu)))
        if sidebarAttached { try fixture.openLibraryWindow() }
        return fixture
    }

    private func item(_ title: String, in menu: NSMenu?) throws -> NSMenuItem {
        try #require(menu?.items.first { $0.title == title })
    }

    private func pick(_ title: String, in menu: NSMenu?) throws {
        let menu = try #require(menu)
        menu.performActionForItem(at: try #require(menu.items.firstIndex { $0.title == title }))
    }

    private static let sidebarTitles = [
        "Sort By", "Group By", "Filter", "Clear Filters", "", "Show Details", "", "Expand All Sections",
        "Collapse All Sections", "", "Smart Group", "Folder", "",
    ]

    // MARK: - Mirror

    @Test("Without a library window on screen the options stay and set the library's; the sections' items are disabled")
    func withoutSidebar() throws {
        var vm: VMInstance?
        let fixture = try makeFixture(sidebarAttached: false) { viewModel in
            let admitted = viewModel.library.admitFixture(name: "A")
            vm = admitted
            _ = try viewModel.library.createFolder(named: "Lab", members: [admitted.id])
        }
        let folder = try #require(fixture.viewModel.library.folders?.first)
        fixture.viewModel.selection = SidebarRowKey(
            section: .folder(folder.id), group: nil, entryID: try #require(vm).id)
        let menu = fixture.opened()

        #expect(Array(menu.items.map(\.title).prefix(Self.sidebarTitles.count)) == Self.sidebarTitles)
        for title in ["Expand All Sections", "Collapse All Sections", "Smart Group", "Folder"] {
            #expect(try item(title, in: menu).isEnabled == false, "\(title)")
        }
        try pick("Show Details", in: menu)
        #expect(fixture.viewModel.sidebarOptions.showsDetails)

        try fixture.openLibraryWindow()
        #expect(try item("Folder", in: fixture.opened()).isEnabled)
    }

    // MARK: - Shortcuts

    /// A key-down producing `characters` under `modifiers`, whatever the
    /// keyboard layout.
    private func keyDown(_ characters: String, _ modifiers: NSEvent.ModifierFlags) throws -> NSEvent {
        try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0,
                context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false,
                keyCode: 0))
    }

    @Test("A Sort By shortcut sets the sort through the menu bar's own key matching")
    func shortcutMatches() throws {
        let fixture = try makeFixture(sidebarAttached: false) { $0.library.admitFixture(name: "A") }
        // As at launch: the menu bar is built before any library window, and
        // the options change after it, with the View menu never opened.
        try fixture.openLibraryWindow()
        fixture.viewModel.sidebarOptions.filter = VMLibraryFilter(guestOSes: [.linux])

        #expect(fixture.mainMenu.performKeyEquivalent(with: try keyDown("1", [.control, .option, .command])))

        #expect(fixture.viewModel.sidebarOptions.sort == SidebarViewMenu.sortChoices.first)
        #expect(fixture.viewModel.sidebarOptions.filter == VMLibraryFilter(guestOSes: [.linux]))
    }

    // MARK: - Expansion

    @Test("Collapse All and Expand All change every section, saved, each enabled while it would change one")
    func expandAndCollapseAll() throws {
        let fixture = try makeFixture { viewModel in
            viewModel.library.admitFixture(name: "A")
            _ = try viewModel.library.createFolder(named: "Lab")
            viewModel.sidebarOptions.filter = VMLibraryFilter(guestOSes: [.linux])
            _ = try viewModel.library.saveSidebarFilter(viewModel.sidebarOptions.filter, asSmartGroupNamed: "Linux")
        }
        let outline = try fixture.sidebar().outlineView
        let sections = try fixture.sidebar().tree.sections
        #expect(sections.count == 3)

        try pick("Collapse All Sections", in: fixture.opened())
        #expect(sections.allSatisfy { !outline.isItemExpanded($0) })
        #expect(Set(preferences.collapsedSidebarSections) == Set(sections.map(\.id.rawValue)))
        #expect(try item("Collapse All Sections", in: fixture.opened()).isEnabled == false)
        #expect(try item("Expand All Sections", in: fixture.opened()).isEnabled)

        try pick("Expand All Sections", in: fixture.opened())
        #expect(sections.allSatisfy { outline.isItemExpanded($0) })
        #expect(preferences.collapsedSidebarSections.isEmpty)
        #expect(try item("Expand All Sections", in: fixture.opened()).isEnabled == false)
    }
}
