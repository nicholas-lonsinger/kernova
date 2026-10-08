import AppKit
import KernovaKit
import Testing

@testable import Kernova

/// The View menu's sidebar items: that they mirror the library section's
/// header menu, set the same options, carry shortcuts nothing else in the
/// menu bar uses, expand and collapse every section, and route to the
/// selected row's section.
@Suite("View menu sidebar items", .serialized, .caseScoped)
@MainActor
struct MainMenuViewMenuTests {
    private let preferences = makeTestPreferences()
    private let scratch = TestScratchDirectory(prefix: "MainMenuViewMenuTests")

    @MainActor
    private struct Fixture {
        let controller: MainMenuController
        let host: StubMenuHost
        let viewModel: VMLibraryViewModel
        let sidebar: SidebarViewController
        let mainMenu: NSMenu
        let viewMenu: NSMenu

        /// The View menu as it reads once opened.
        func opened() -> NSMenu {
            viewMenu.delegate?.menuNeedsUpdate?(viewMenu)
            viewMenu.update()
            return viewMenu
        }
    }

    private func makeFixture(
        sidebarAttached: Bool = true, organization: VMOrganizationDirectory = VMOrganizationDirectory(fileURL: nil),
        populate: (VMLibraryViewModel) throws -> Void = { _ in }
    ) throws -> Fixture {
        let viewModel = makeLibraryViewModel(preferences: preferences, organization: organization)
        try populate(viewModel)
        let sidebar = SidebarViewController(viewModel: viewModel)
        sidebar.loadViewIfNeeded()
        let controller = MainMenuController(viewModel: viewModel, hasBundledGuestAgentDisk: true)
        let host = StubMenuHost(librarySidebar: sidebarAttached ? sidebar : nil)
        controller.host = host
        let mainMenu = controller.makeMainMenu()
        return Fixture(
            controller: controller, host: host, viewModel: viewModel, sidebar: sidebar, mainMenu: mainMenu,
            viewMenu: try #require(submenu(titled: "View", in: mainMenu)))
    }

    private func item(_ title: String, in menu: NSMenu?) throws -> NSMenuItem {
        try #require(menu?.items.first { $0.title == title })
    }

    private func pick(_ title: String, in menu: NSMenu?) throws {
        let menu = try #require(menu)
        menu.performActionForItem(at: try #require(menu.items.firstIndex { $0.title == title }))
    }

    /// Everything an item shows and does, its submenu's items included.
    private struct Rendering: Equatable {
        let isSeparator: Bool
        let title: String
        let state: NSControl.StateValue
        let isEnabled: Bool
        let badge: String?
        let badgeCount: Int?
        let keyEquivalent: String
        let modifiers: NSEvent.ModifierFlags.RawValue
        let command: SidebarViewMenu.Command?
        let submenu: [Rendering]?
    }

    private func rendering(_ item: NSMenuItem) -> Rendering {
        Rendering(
            isSeparator: item.isSeparatorItem, title: item.title, state: item.state, isEnabled: item.isEnabled,
            badge: item.badge?.stringValue, badgeCount: item.badge?.itemCount, keyEquivalent: item.keyEquivalent,
            modifiers: item.keyEquivalent.isEmpty ? 0 : item.keyEquivalentModifierMask.rawValue,
            command: (item.representedObject as? SidebarViewMenu.Pick)?.command,
            submenu: item.submenu?.items.map(rendering))
    }

    /// Records each item of `built` that renders unlike its counterpart in
    /// `expected`.
    private func expectRenderedAlike(
        _ built: [NSMenuItem]?, _ expected: [NSMenuItem], sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let built = built ?? []
        #expect(built.count == expected.count, sourceLocation: sourceLocation)
        for (lhs, rhs) in zip(built, expected) {
            #expect(rendering(lhs) == rendering(rhs), sourceLocation: sourceLocation)
        }
    }

    private static let sidebarTitles = [
        "Sort By", "Group By", "Filter", "Clear Filters", "", "Show Details", "", "Expand All Sections",
        "Collapse All Sections", "", "Smart Group", "Folder", "",
    ]

    // MARK: - Mirror

    @Test("The sidebar items lead the View menu, before the toolbar items")
    func structure() throws {
        let fixture = try makeFixture { $0.library.admitFixture(name: "A") }
        let titles = fixture.opened().items.map(\.title)
        #expect(Array(titles.prefix(Self.sidebarTitles.count)) == Self.sidebarTitles)
        #expect(Array(titles.dropFirst(Self.sidebarTitles.count)) == ["Show Toolbar", "Customize Toolbar\u{2026}"])
    }

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

        fixture.host.librarySidebar = fixture.sidebar
        #expect(try item("Folder", in: fixture.opened()).isEnabled)
    }

    @Test("Sort By, Group By, the filter rows, Show Details and Clear Filters render as the header menu's do")
    func mirrorsHeaderMenu() throws {
        let fixture = try makeFixture { viewModel in
            viewModel.library.admitFixture(name: "Mac", guestOS: .macOS)
            viewModel.library.admitFixture(name: "Linux", guestOS: .linux)
            viewModel.sidebarOptions = SidebarViewOptions(
                filter: VMLibraryFilter(guestOSes: [.macOS]), sort: .name, grouping: .state, showsDetails: true)
        }
        let header = try #require(fixture.sidebar.viewMenu(for: .library))
        let menu = fixture.opened()

        for title in ["Sort By", "Group By", "Show Details", "Clear Filters"] {
            #expect(rendering(try item(title, in: menu)) == rendering(try item(title, in: header)))
        }
        let headerFilterRows = header.items.prefix { !$0.isSeparatorItem }
        let filterRows = try #require(try item("Filter", in: menu).submenu).items
        expectRenderedAlike(filterRows, Array(headerFilterRows))
        #expect(try item("Sort By", in: menu).badge?.stringValue == "Name")
        #expect(try item("Show Details", in: menu).state == .on)
        #expect(try item("Clear Filters", in: menu).isEnabled)
    }

    @Test("The View menu's validation keeps each item's built enablement")
    func validationKeepsEnablement() throws {
        let fixture = try makeFixture { $0.library.admitFixture(name: "A") }
        let menu = fixture.opened()
        #expect(menu.autoenablesItems)
        #expect(try item("Clear Filters", in: menu).isEnabled == false)
        #expect(try item("Expand All Sections", in: menu).isEnabled == false)
        #expect(try item("Collapse All Sections", in: menu).isEnabled)
    }

    // MARK: - Picks

    @Test("Each pick sets the library section's options")
    func picksSetOptions() throws {
        let fixture = try makeFixture { $0.library.admitFixture(name: "Mac", guestOS: .macOS) }
        let viewModel = fixture.viewModel

        try pick("Name", in: try item("Sort By", in: fixture.opened()).submenu)
        #expect(viewModel.sidebarOptions.sort == .name)
        try pick("State", in: try item("Group By", in: fixture.opened()).submenu)
        #expect(viewModel.sidebarOptions.grouping == .state)
        let guestOS = try item("Guest OS", in: try item("Filter", in: fixture.opened()).submenu).submenu
        try pick("macOS", in: guestOS)
        #expect(viewModel.sidebarOptions.filter == VMLibraryFilter(guestOSes: [.macOS]))
        try pick("Show Details", in: fixture.opened())
        #expect(viewModel.sidebarOptions.showsDetails)
        try pick("Clear Filters", in: fixture.opened())
        #expect(viewModel.sidebarOptions.filter == VMLibraryFilter())
        #expect(viewModel.sidebarOptions.sort == .name && viewModel.sidebarOptions.grouping == .state)
        #expect(try item("Name", in: try item("Sort By", in: fixture.opened()).submenu).state == .on)
    }

    @Test("A Sort By item built before another option changed sets only the sort")
    func staleSortKeepsOtherOptions() throws {
        let fixture = try makeFixture { $0.library.admitFixture(name: "Mac", guestOS: .macOS) }
        let sort = try item("Sort By", in: fixture.opened()).submenu
        fixture.viewModel.sidebarOptions.filter = VMLibraryFilter(guestOSes: [.linux])

        try pick("Date Created", in: sort)

        #expect(fixture.viewModel.sidebarOptions.sort == .dateCreated)
        #expect(fixture.viewModel.sidebarOptions.filter == VMLibraryFilter(guestOSes: [.linux]))
    }

    // MARK: - Shortcuts

    /// Every key equivalent in `menu` and its submenus, as typed: an
    /// uppercase letter carries Shift.
    private func shortcuts(in menu: NSMenu) -> [(item: NSMenuItem, key: String, modifiers: UInt)] {
        menu.items.flatMap { item -> [(item: NSMenuItem, key: String, modifiers: UInt)] in
            var found: [(item: NSMenuItem, key: String, modifiers: UInt)] = []
            if !item.keyEquivalent.isEmpty {
                var modifiers = item.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask)
                let key = item.keyEquivalent
                if key.lowercased() != key { modifiers.insert(.shift) }
                found.append((item, key.lowercased(), modifiers.rawValue))
            }
            return found + (item.submenu.map(shortcuts(in:)) ?? [])
        }
    }

    @Test("Sort By carries ⌃⌥⌘ digit shortcuts, Manual 0, in the header menu too")
    func sortShortcutsAssigned() throws {
        let fixture = try makeFixture { $0.library.admitFixture(name: "A") }
        let sort = try #require(try item("Sort By", in: fixture.opened()).submenu)
        let shortcutItems = sort.items.filter { !$0.isSeparatorItem }

        #expect(shortcutItems.count == VMLibrarySort.allCases.count)
        for (index, choice) in SidebarViewMenu.sortChoices.enumerated() {
            let sortItem = try item(choice.title, in: sort)
            #expect(sortItem.keyEquivalent == "\(index + 1)")
            #expect(sortItem.keyEquivalentModifierMask == [.control, .option, .command])
        }
        #expect(try item(VMLibrarySort.manual.title, in: sort).keyEquivalent == "0")
        #expect(
            shortcutItems.map { "\($0.title) \($0.keyEquivalent)" } == [
                "Name 1", "Date Created 2", "Last Run 3", "Manual 0",
            ])
        let headerSort = try item("Sort By", in: fixture.sidebar.viewMenu(for: .library))
        #expect(rendering(headerSort) == rendering(try item("Sort By", in: fixture.opened())))
    }

    @Test("No sidebar shortcut is any other menu bar item's")
    func shortcutsDoNotCollide() throws {
        let fixture = try makeFixture { $0.library.admitFixture(name: "A") }
        _ = fixture.opened()
        let all = shortcuts(in: fixture.mainMenu)
        let sidebarItems = Set(
            shortcuts(in: try #require(try item("Sort By", in: fixture.viewMenu).submenu)).map {
                ObjectIdentifier($0.item)
            })
        #expect(sidebarItems.count == VMLibrarySort.allCases.count)
        for shortcut in all where sidebarItems.contains(ObjectIdentifier(shortcut.item)) {
            let sharing = all.filter { $0.key == shortcut.key && $0.modifiers == shortcut.modifiers }
            #expect(sharing.count == 1, "\(shortcut.item.title) shares \(shortcut.key)")
        }
    }

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
        fixture.host.librarySidebar = fixture.sidebar
        fixture.viewModel.sidebarOptions.filter = VMLibraryFilter(guestOSes: [.linux])

        #expect(fixture.mainMenu.performKeyEquivalent(with: try keyDown("1", [.control, .option, .command])))

        #expect(fixture.viewModel.sidebarOptions.sort == SidebarViewMenu.sortChoices.first)
        #expect(fixture.viewModel.sidebarOptions.filter == VMLibraryFilter(guestOSes: [.linux]))
    }

    /// AppKit populates the View menu while it matches any key equivalent
    /// against the menu bar, so its rebuild reads only what the app holds.
    @Test("Rebuilding the View menu with a folder or smart group selected reloads no organization file")
    func rebuildReadsNoOrganizationFile() throws {
        try FileManager.default.createDirectory(at: scratch.url, withIntermediateDirectories: true)
        let organizationURL = scratch.url.appendingPathComponent("Organization.json")
        var vm: VMInstance?
        let fixture = try makeFixture(organization: VMOrganizationDirectory(fileURL: organizationURL)) { viewModel in
            let admitted = viewModel.library.admitFixture(name: "A", guestOS: .linux)
            vm = admitted
            _ = try viewModel.library.createFolder(named: "Lab", members: [admitted.id])
            viewModel.sidebarOptions.filter = VMLibraryFilter(guestOSes: [.linux])
            _ = try viewModel.library.saveSidebarFilter(viewModel.sidebarOptions.filter, asSmartGroupNamed: "Linux")
        }
        let library = fixture.viewModel.library
        let sections: [SidebarSectionID] = [
            .folder(try #require(library.folders?.first).id),
            .smartGroup(try #require(library.smartGroups?.first).id),
        ]
        // What a reload would find, and read as no groups at all.
        try Data("not json".utf8).write(to: organizationURL)

        for section in sections {
            fixture.viewModel.selection = SidebarRowKey(section: section, group: nil, entryID: try #require(vm).id)
            let route = section.folderID != nil ? "Folder" : "Smart Group"
            let start = try #require(
                try item(route, in: fixture.opened()).submenu?.items.first { $0.title.hasPrefix("Start All") })
            #expect(start.isEnabled, "\(route)")
            #expect(library.organization.state.listed != nil, "\(route)")
        }
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
        let outline = fixture.sidebar.outlineView
        let sections = fixture.sidebar.tree.sections
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

    // MARK: - Section routes

    @Test("A library row's selection offers neither route")
    func libraryRowOffersNoRoute() throws {
        var vm: VMInstance?
        let fixture = try makeFixture { viewModel in
            vm = viewModel.library.admitFixture(name: "A")
            _ = try viewModel.library.createFolder(named: "Lab")
        }
        fixture.viewModel.selection = .library(try #require(vm).id)
        let menu = fixture.opened()
        for kind in VMGroupKind.allCases {
            let route = try item(SidebarViewMenu.groupKindTitle(kind), in: menu)
            #expect(route.submenu == nil && !route.isEnabled)
        }
    }

    @Test("A folder row's selection opens the folder's own menu under Folder")
    func folderRoute() throws {
        var vm: VMInstance?
        var folder: VMFolder?
        let fixture = try makeFixture { viewModel in
            let admitted = viewModel.library.admitFixture(name: "A")
            vm = admitted
            folder = try viewModel.library.createFolder(named: "Lab", members: [admitted.id])
        }
        let id = try #require(folder).id
        fixture.viewModel.selection = SidebarRowKey(section: .folder(id), group: nil, entryID: try #require(vm).id)
        let menu = fixture.opened()

        let route = try item("Folder", in: menu)
        #expect(route.isEnabled)
        let header = try #require(fixture.sidebar.viewMenu(for: .folder(id)))
        expectRenderedAlike(route.submenu?.items, header.items)
        #expect(route.submenu?.items.map(\.title).contains("Rename Folder\u{2026}") == true)
        #expect(try item("Smart Group", in: menu).isEnabled == false)
    }

    @Test("A smart group row's selection opens the group's rules and actions under Smart Group, and they act")
    func smartGroupRoute() throws {
        var vm: VMInstance?
        let fixture = try makeFixture { viewModel in
            vm = viewModel.library.admitFixture(name: "A", guestOS: .linux)
            viewModel.sidebarOptions.filter = VMLibraryFilter(guestOSes: [.linux])
            _ = try viewModel.library.saveSidebarFilter(viewModel.sidebarOptions.filter, asSmartGroupNamed: "Linux")
        }
        let group = try #require(fixture.viewModel.library.smartGroups?.first)
        fixture.viewModel.selection = SidebarRowKey(
            section: .smartGroup(group.id), group: nil, entryID: try #require(vm).id)
        let menu = fixture.opened()

        let route = try item("Smart Group", in: menu)
        let header = try #require(fixture.sidebar.viewMenu(for: .smartGroup(group.id)))
        expectRenderedAlike(route.submenu?.items, header.items)
        #expect(try item("Folder", in: menu).isEnabled == false)
        for title in ["Guest OS", "Start All", "Suspend All", "Stop All", "Rename Smart Group\u{2026}"] {
            #expect(route.submenu?.items.contains { $0.title == title } == true)
        }

        try pick("Delete Smart Group", in: route.submenu)
        #expect(fixture.viewModel.library.smartGroups == [])
    }
}
