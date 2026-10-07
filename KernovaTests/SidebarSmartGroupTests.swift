import AppKit
import Foundation
import KernovaKit
import KernovaTestSupport
import Testing

@testable import Kernova

/// Smart groups as the sidebar lists them: the sections the projection adds,
/// saving the library's filter as one, the header menu editing one, and the
/// selection across sections.
@Suite("Sidebar smart groups", .serialized, .caseScoped, .scopedWindows)
@MainActor
struct SidebarSmartGroupTests {
    private let preferences = makeTestPreferences()

    private let scratch = TestScratchDirectory(prefix: "SidebarSmartGroupTests")

    private func makeViewModel(
        networks: VMNetworkDirectory = VMNetworkDirectory(fileURL: nil),
        organization: VMOrganizationDirectory = VMOrganizationDirectory(fileURL: nil)
    ) -> VMLibraryViewModel {
        VMLibraryViewModel(
            storageService: MockVMStorageService(),
            diskImageService: MockDiskImageService(),
            virtualizationService: MockVirtualizationService(),
            installService: MockMacOSInstallService(),
            ipswService: MockIPSWService(),
            removableMediaDeviceService: MockRemovableMediaDeviceService(),
            fileSystem: MockFileSystem(),
            downloadsDirectory: nil,
            preferences: preferences,
            vmnetNetworks: MockVmnetNetworkProvider(), arpTable: ScriptedARPTable(), entitlements: .entitled,
            networks: networks, organization: organization
        )
    }

    private func vm(_ name: String, guestOS: VMGuestOS = .linux, phase: VMLifecyclePhase = .stopped)
        -> LibraryEntry
    {
        .vm(VMInstanceFixture.make(name: name, guestOS: guestOS, phase: phase))
    }

    private func group(_ name: String, _ filter: VMLibraryFilter) -> VMSmartGroup {
        VMSmartGroup(id: UUID(), name: name, filter: filter)
    }

    private func names(in section: SidebarLayout.Section) -> [String] {
        guard case .rows(let rows) = section.content else { return [] }
        return rows.entries.map(\.name)
    }

    /// A sidebar on screen, its sync pass run.
    private func shownOutline(of controller: SidebarViewController) throws -> NSOutlineView {
        let window = showTestWindow(styleMask: [.titled], contentSize: NSSize(width: 300, height: 600))
        window.contentView = controller.view
        controller.view.layoutSubtreeIfNeeded()
        controller.viewDidAppear()
        return try #require(firstSubview(NSOutlineView.self, in: controller.view))
    }

    private func row(_ key: SidebarRowKey, in outline: NSOutlineView) -> Int {
        (0..<outline.numberOfRows).first { (outline.item(atRow: $0) as? SidebarRow)?.key == key } ?? -1
    }

    // MARK: - Projection

    @Test("Each smart group is a section above the library, listing what its filter admits in the sort's order")
    func projectsSmartGroupSections() {
        let entries = [
            vm("Zed", guestOS: .macOS, phase: .running(sessionID: UUID())),
            vm("Alpha", guestOS: .linux, phase: .running(sessionID: UUID())),
            vm("Mac", guestOS: .macOS),
        ]
        let running = group("Running", VMLibraryFilter(states: [.running]))
        let macs = group("Macs", VMLibraryFilter(guestOSes: [.macOS]))
        let layout = SidebarLayout.project(
            entries: entries, options: SidebarViewOptions(sort: .name), smartGroups: [running, macs],
            context: .testing())

        #expect(layout.sections.map(\.id) == [.smartGroup(running.id), .smartGroup(macs.id), .library])
        #expect(layout.sections.map(\.title) == ["Running", "Macs", "Virtual Machines"])
        #expect(names(in: layout.sections[0]) == ["Alpha", "Zed"])
        #expect(names(in: layout.sections[1]) == ["Mac", "Zed"])
        #expect(names(in: layout.sections[2]) == ["Alpha", "Mac", "Zed"])
        // "Zed" is listed in all three sections, once in each.
        let zed = entries[0].id
        #expect(layout.rowKeys.filter { $0.entryID == zed }.map(\.section) == layout.sections.map(\.id))
        #expect(Set(layout.rowKeys).count == layout.rowKeys.count)

        let tree = SidebarTree()
        _ = tree.update(to: layout)
        #expect(tree.row(for: SidebarRowKey(section: .smartGroup(running.id), group: nil, entryID: zed)) != nil)
        #expect(tree.row(for: .library(zed)) != nil)
    }

    @Test("A group whose filter is empty lists every VM; one matching none lists the no-matches line")
    func emptyFilterListsEveryVM() throws {
        let entries = [vm("A"), vm("B", guestOS: .macOS)]
        let everything = group("Everything", VMLibraryFilter())
        let none = group("Windows-free", VMLibraryFilter(states: [.suspended]))
        let layout = SidebarLayout.project(
            entries: entries, options: SidebarViewOptions(), smartGroups: [everything, none], context: .testing())

        #expect(names(in: layout.sections[0]) == ["A", "B"])
        #expect(names(in: layout.sections[1]).isEmpty)
        #expect(layout.sections[1].emptyText == SidebarLayout.noMatchesText)

        let tree = SidebarTree()
        _ = tree.update(to: layout)
        #expect((tree.sections[1].children.first as? SidebarPlaceholder)?.text == SidebarLayout.noMatchesText)
    }

    @Test("The library's own filter and grouping leave the smart groups alone")
    func libraryOptionsDoNotNarrowSmartGroups() {
        let entries = [vm("Linux"), vm("Mac", guestOS: .macOS)]
        let everything = group("Everything", VMLibraryFilter())
        let layout = SidebarLayout.project(
            entries: entries,
            options: SidebarViewOptions(filter: VMLibraryFilter(guestOSes: [.macOS]), grouping: .guestOS),
            smartGroups: [everything], context: .testing())

        #expect(names(in: layout.sections[0]) == ["Linux", "Mac"])
        guard case .groups = layout.sections[1].content else {
            Issue.record("The library section is not grouped")
            return
        }
    }

    // MARK: - Creating

    @Test("Saving the library's filter makes a group of it and clears the library's filter")
    func saveFromActiveFilter() throws {
        let viewModel = makeViewModel()
        viewModel.library.admitFixture(name: "Linux")
        let mac = viewModel.library.admitFixture(name: "Mac", guestOS: .macOS)
        let filter = VMLibraryFilter(guestOSes: [.macOS])
        viewModel.sidebarOptions = SidebarViewOptions(filter: filter, sort: .name)
        viewModel.selection = .library(mac.id)

        try viewModel.saveSidebarFilterAsSmartGroup(named: "Macs")

        let saved = try #require(viewModel.smartGroups.first)
        #expect(viewModel.smartGroups.count == 1)
        #expect(saved.name == "Macs")
        #expect(saved.filter == filter)
        #expect(viewModel.sidebarOptions == SidebarViewOptions(sort: .name))
        #expect(viewModel.selection == .library(mac.id))
        let layout = viewModel.sidebarLayout
        #expect(layout.sections.map(\.id) == [.smartGroup(saved.id), .library])
        #expect(names(in: layout.sections[0]) == ["Mac"])
        #expect(names(in: layout.sections[1]) == ["Linux", "Mac"])
    }

    @Test("A name another group has is refused, and the library's filter stays")
    func saveRefusesTakenName() throws {
        let viewModel = makeViewModel()
        let filter = VMLibraryFilter(guestOSes: [.macOS])
        viewModel.sidebarOptions.filter = filter
        try viewModel.saveSidebarFilterAsSmartGroup(named: "Macs")
        viewModel.sidebarOptions.filter = filter

        #expect(throws: VMOrganizationDirectory.ChangeError.nameTaken("Macs")) {
            try viewModel.saveSidebarFilterAsSmartGroup(named: "macs")
        }
        #expect(viewModel.sidebarOptions.filter == filter)
        #expect(viewModel.smartGroups.count == 1)
    }

    @Test("The library menu offers saving only while a filter is on")
    func saveItemFollowsTheFilter() throws {
        let viewModel = makeViewModel()
        viewModel.library.admitFixture(name: "Mac", guestOS: .macOS)
        let controller = SidebarViewController(viewModel: viewModel)
        controller.loadViewIfNeeded()
        func saveItem() throws -> NSMenuItem {
            try #require(controller.viewMenu(for: .library)?.items.first { $0.title == "Save as Smart Group\u{2026}" })
        }

        #expect(try saveItem().isEnabled == false)
        viewModel.sidebarOptions.filter = VMLibraryFilter(guestOSes: [.macOS])
        #expect(try saveItem().isEnabled == true)
    }

    @Test("The naming sheet suggests a name from the filter and lists its conditions")
    func namingSheet() throws {
        let menu = SidebarViewMenu(networkTitle: { $0.rawValue }, perform: { _ in })
        let shared = VMLibraryFilter.Network(.shared) { _, _ in true }
        let values = [
            SidebarViewMenu.Value(
                subject: VMLibraryFilter.Subject(
                    guestOS: .macOS, state: .running, network: shared, guestAgent: .upToDate, isEphemeral: true,
                    hasSnapshots: false),
                networkTitle: "Shared Network")
        ]
        let filter = VMLibraryFilter(
            guestOSes: [.macOS], states: [.running], networks: [shared], guestAgents: [.upToDate, .olderVersion],
            ephemeralOnly: true)

        #expect(menu.suggestedName(for: filter, values: values) == "macOS \u{00B7} Running \u{00B7} Shared Network")
        #expect(
            menu.suggestedName(for: VMLibraryFilter(guestAgents: [.upToDate, .olderVersion]), values: values)
                == "Smart Group")
        #expect(
            menu.conditions(of: filter, values: values) == [
                "Guest OS is macOS", "State is Running", "Network is Shared Network",
                "Guest Agent is Up to Date or Older Version", "Ephemeral Mode",
            ])

        var created: String?
        let sheet = SmartGroupNameSheet.newSmartGroup(
            suggestedName: "macOS", conditions: ["Guest OS is macOS"]
        ) { created = $0 }
        #expect(sheet.title == "New Smart Group")
        #expect(sheet.buttons.map(\.title) == ["Create", "Cancel"])
        let accessory = try #require(sheet.accessoryView)
        let field = try #require(sheet.initialFirstResponder as? NSTextField)
        #expect(field.stringValue == "macOS")
        #expect(allSubviews(NSTextField.self, in: accessory).map(\.stringValue).contains("Guest OS is macOS"))
        field.stringValue = "Apple"
        sheet.buttons[0].action()
        #expect(created == "Apple")
    }

    /// `NSAlert` lays its accessory view out at the frame it is handed.
    @Test("The naming sheet's frame holds its caption and every condition, none drawn over another")
    func namingSheetLaysOutItsConditions() throws {
        let conditions = [
            "Guest OS is macOS", "State is Running",
            "Network is Shared Network, Host Only, or Network Not in This Library", "Ephemeral Mode",
        ]
        let sheet = SmartGroupNameSheet.newSmartGroup(suggestedName: "macOS", conditions: conditions) { _ in }
        let accessory = try #require(sheet.accessoryView)
        accessory.layoutSubtreeIfNeeded()
        let labels = allSubviews(NSTextField.self, in: accessory).filter { !$0.isEditable }
        let shown = ["Name:", "Shows VMs where"] + conditions
        let frames = try shown.map { text in
            let label = try #require(labels.first { $0.stringValue == text }, "\(text)")
            // The text's own extent: a field's frame pads its cell past it.
            return try #require(label.superview).convert(label.alignmentRect(forFrame: label.frame), to: accessory)
        }

        for (text, frame) in zip(shown, frames) {
            #expect(frame.height > 0, "\(text)")
            #expect(accessory.bounds.insetBy(dx: -0.5, dy: -0.5).contains(frame), "\(text)")
        }
        for i in frames.indices {
            for j in frames.indices where j > i {
                #expect(!frames[i].intersects(frames[j]), "\(shown[i]) overlaps \(shown[j])")
            }
        }
    }

    @Test("A name the library refuses brings the sheet back with that name typed in it")
    func refusedNameReopensTheSheet() async throws {
        let viewModel = makeViewModel()
        viewModel.library.admitFixture(name: "Mac", guestOS: .macOS)
        viewModel.sidebarOptions.filter = VMLibraryFilter(guestOSes: [.macOS])
        try viewModel.saveSidebarFilterAsSmartGroup(named: "Macs")
        viewModel.sidebarOptions.filter = VMLibraryFilter(guestOSes: [.macOS])
        let controller = SidebarViewController(viewModel: viewModel)
        let outline = try shownOutline(of: controller)
        let window = try #require(outline.window)
        func nameField(in sheet: NSWindow) -> NSTextField? {
            sheet.contentView.flatMap { allSubviews(NSTextField.self, in: $0).first(where: \.isEditable) }
        }
        let menu = try #require(controller.viewMenu(for: .library))
        menu.performActionForItem(at: try #require(menu.items.firstIndex { $0.title == "Save as Smart Group\u{2026}" }))

        let naming = try #require(window.attachedSheet)
        try #require(nameField(in: naming)).stringValue = "macs"
        window.endSheet(naming, returnCode: .alertFirstButtonReturn)
        try await waitUntil { window.attachedSheet != nil && window.attachedSheet !== naming }
        let refusal = try #require(window.attachedSheet)
        #expect(nameField(in: refusal) == nil)
        window.endSheet(refusal, returnCode: .alertFirstButtonReturn)

        try await waitUntil { window.attachedSheet.flatMap(nameField(in:))?.stringValue == "macs" }
        #expect(viewModel.smartGroups.count == 1)
        #expect(viewModel.sidebarOptions.filter == VMLibraryFilter(guestOSes: [.macOS]))
        if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .alertSecondButtonReturn) }
    }

    // MARK: - Header and menu

    @Test("A smart group's header shows its name, its match count and its options button")
    func smartGroupHeader() throws {
        let viewModel = makeViewModel()
        viewModel.library.admitFixture(name: "A")
        viewModel.library.admitFixture(name: "B")
        viewModel.library.admitFixture(name: "Mac", guestOS: .macOS)
        viewModel.sidebarOptions.filter = VMLibraryFilter(guestOSes: [.linux])
        try viewModel.saveSidebarFilterAsSmartGroup(named: "Linux")
        let controller = SidebarViewController(viewModel: viewModel)
        let outline = try shownOutline(of: controller)
        let header = try #require(
            outline.view(atColumn: 0, row: 0, makeIfNecessary: true) as? SidebarGroupHeaderCellView)

        let labels = allSubviews(NSTextField.self, in: header).filter { !$0.isHidden }.map(\.stringValue)
        #expect(labels.contains("Linux"))
        #expect(labels.contains("2"))
        let button = try #require(header.filterButton)
        #expect(button.accessibilityLabel() == "Smart Group Options")
        #expect(button.accessibilityValue() as? String == "Guest OS: Linux")
        #expect(controller.contextMenu(forRow: 0)?.items.first?.title == "Show VMs in \u{201C}Linux\u{201D} where")
    }

    @Test("The header menu edits the group's filter, and the section and its count follow live")
    func headerMenuEditsFilter() async throws {
        let viewModel = makeViewModel()
        viewModel.library.admitFixture(name: "Linux")
        viewModel.library.admitFixture(name: "Mac", guestOS: .macOS)
        viewModel.sidebarOptions.filter = VMLibraryFilter(guestOSes: [.linux])
        let saved = try viewModel.library.saveSidebarFilterAsSmartGroup(named: "Picked")
        let controller = SidebarViewController(viewModel: viewModel)
        let outline = try shownOutline(of: controller)
        let menu = try #require(controller.viewMenu(for: .smartGroup(saved.id)))

        #expect(
            menu.items.map(\.title) == [
                "Show VMs in \u{201C}Picked\u{201D} where", "Guest OS", "State", "Network", "Guest Agent", "Other", "",
                "Rename Smart Group\u{2026}", "Delete Smart Group",
            ])
        #expect(menu.items[0].isSectionHeader)
        #expect(menu.items[1].badge?.stringValue == "Linux")
        let guestOS = try #require(menu.items[1].submenu)
        let macOS = try #require(guestOS.items.firstIndex { $0.title == "macOS" })
        guestOS.performActionForItem(at: macOS)

        #expect(viewModel.smartGroups.first?.filter == VMLibraryFilter(guestOSes: [.linux, .macOS]))
        // The library's own filter is untouched.
        #expect(viewModel.sidebarOptions.filter == VMLibraryFilter())
        try await waitUntil { outline.numberOfRows == 6 }
        let header = try #require(
            outline.view(atColumn: 0, row: 0, makeIfNecessary: true) as? SidebarGroupHeaderCellView)
        #expect(allSubviews(NSTextField.self, in: header).map(\.stringValue).contains("2"))

        // Edited back to empty, the group lists every VM.
        let all = try #require(controller.viewMenu(for: .smartGroup(saved.id))?.items[1].submenu)
        all.performActionForItem(at: 0)
        #expect(viewModel.smartGroups.first?.filter == VMLibraryFilter())
        #expect(names(in: viewModel.sidebarLayout.sections[0]) == ["Linux", "Mac"])
    }

    @Test("Rename retitles the section; Delete removes it")
    func renameAndDelete() async throws {
        let viewModel = makeViewModel()
        viewModel.library.admitFixture(name: "A")
        viewModel.sidebarOptions.filter = VMLibraryFilter(guestOSes: [.linux])
        try viewModel.saveSidebarFilterAsSmartGroup(named: "Old")
        let id = try #require(viewModel.smartGroups.first?.id)
        let controller = SidebarViewController(viewModel: viewModel)
        let outline = try shownOutline(of: controller)

        try viewModel.renameSmartGroup(id, to: "New")
        try await waitUntil { (outline.item(atRow: 0) as? SidebarSection)?.title == "New" }
        #expect(throws: VMOrganizationDirectory.ChangeError.nameRequired) {
            try viewModel.renameSmartGroup(id, to: " ")
        }

        let menu = try #require(controller.viewMenu(for: .smartGroup(id)))
        menu.performActionForItem(at: try #require(menu.items.firstIndex { $0.title == "Delete Smart Group" }))

        #expect(viewModel.smartGroups.isEmpty)
        try await waitUntil { outline.numberOfRows == 2 }
        #expect((outline.item(atRow: 0) as? SidebarSection)?.id == .library)
    }

    @Test("Deleting a named network prunes it from every smart group's filter and the library's")
    func deletingANetworkPrunesIt() throws {
        let viewModel = makeViewModel()
        viewModel.library.admitFixture(name: "A")
        viewModel.library.admitFixture(name: "B", guestOS: .macOS)
        let lab = try viewModel.networks.create(name: "Lab", kind: .shared, verb: .createNetwork)
        let onLab = VMLibraryFilter.Network(.vmnet(.shared, .network(lab.id))) { _, _ in true }
        let shared = VMLibraryFilter.Network(.shared) { _, _ in true }
        viewModel.sidebarOptions.filter = VMLibraryFilter(networks: [onLab])
        try viewModel.saveSidebarFilterAsSmartGroup(named: "Lab")
        viewModel.sidebarOptions.filter = VMLibraryFilter(guestOSes: [.linux], networks: [onLab, .unlisted])
        try viewModel.saveSidebarFilterAsSmartGroup(named: "Linux off the LAN")
        viewModel.sidebarOptions.filter = VMLibraryFilter(networks: [onLab, shared])

        try viewModel.commands.deleteNetwork(lab.id.uuidString)

        #expect(viewModel.networks.networks.isEmpty)
        #expect(
            viewModel.smartGroups.map(\.filter) == [
                VMLibraryFilter(), VMLibraryFilter(guestOSes: [.linux], networks: [.unlisted]),
            ])
        #expect(viewModel.sidebarOptions.filter == VMLibraryFilter(networks: [shared]))
        // Its only condition gone, "Lab" lists every VM.
        #expect(names(in: viewModel.sidebarLayout.sections[0]) == ["A", "B"])
    }

    @Test("A network whose prune the smart groups' file refuses is not deleted")
    func unreadableOrganizationRefusesNetworkDelete() throws {
        try FileManager.default.createDirectory(at: scratch.url, withIntermediateDirectories: true)
        let organizationURL = scratch.url.appendingPathComponent("Organization.json")
        try Data("not json".utf8).write(to: organizationURL)
        let networksURL = scratch.url.appendingPathComponent("Networks.json")
        let viewModel = makeViewModel(
            networks: VMNetworkDirectory(fileURL: networksURL),
            organization: VMOrganizationDirectory(fileURL: organizationURL))
        let lab = try viewModel.networks.create(name: "Lab", kind: .shared, verb: .createNetwork)

        #expect(throws: CommandError.self) { try viewModel.commands.deleteNetwork(lab.id.uuidString) }

        #expect(VMNetworkDirectory(fileURL: networksURL).networks.map(\.id) == [lab.id])
        #expect(try Data(contentsOf: organizationURL) == Data("not json".utf8))
    }

    // MARK: - Selection

    @Test("A row keeps its own section across reloads, and falls back to the library row when it leaves")
    func selectionStaysInItsSectionThenFallsBack() async throws {
        let viewModel = makeViewModel()
        let busy = viewModel.library.admitFixture(name: "Busy", phase: .running(sessionID: UUID()))
        viewModel.sidebarOptions.filter = VMLibraryFilter(states: [.running])
        try viewModel.saveSidebarFilterAsSmartGroup(named: "Running")
        let id = try #require(viewModel.smartGroups.first?.id)
        let inGroup = SidebarRowKey(section: .smartGroup(id), group: nil, entryID: busy.id)
        viewModel.selection = inGroup
        let controller = SidebarViewController(viewModel: viewModel)
        let outline = try shownOutline(of: controller)
        #expect(outline.selectedRow == row(inGroup, in: outline))

        viewModel.library.admitFixture(name: "Other")
        try await waitUntil { outline.numberOfRows == 5 }
        #expect(viewModel.selection == inGroup)
        #expect(outline.selectedRow == row(inGroup, in: outline))

        busy.activity.placeForTesting(.stopped)
        controller.viewDidAppear()

        #expect(viewModel.selection == .library(busy.id))
        #expect(outline.selectedRow == row(.library(busy.id), in: outline))
        #expect(outline.selectedRow > 0)
    }

    @Test("A VM selected in a smart group is not retained by the library section a filter edit hides it from")
    func retentionStaysInTheSelectedSection() throws {
        let viewModel = makeViewModel()
        let mac = viewModel.library.admitFixture(name: "Mac", guestOS: .macOS)
        viewModel.library.admitFixture(name: "Linux")
        viewModel.sidebarOptions.filter = VMLibraryFilter(guestOSes: [.macOS])
        try viewModel.saveSidebarFilterAsSmartGroup(named: "Macs")
        let id = try #require(viewModel.smartGroups.first?.id)
        let inGroup = SidebarRowKey(section: .smartGroup(id), group: nil, entryID: mac.id)
        viewModel.selection = inGroup

        viewModel.sidebarOptions.filter = VMLibraryFilter(guestOSes: [.linux])

        let library = try #require(viewModel.sidebarLayout.sections.last)
        #expect(names(in: library) == ["Linux"])
        #expect(library.filterCounts == SidebarLayout.FilterCounts(shown: 1, total: 2))
        #expect(viewModel.selection == inGroup)
    }

    @Test("Deleting the group holding the selection leaves the VM selected in the library")
    func deleteFallsBackToLibraryRow() throws {
        let viewModel = makeViewModel()
        let a = viewModel.library.admitFixture(name: "A")
        viewModel.sidebarOptions.filter = VMLibraryFilter(guestOSes: [.linux])
        try viewModel.saveSidebarFilterAsSmartGroup(named: "Linux")
        let id = try #require(viewModel.smartGroups.first?.id)
        viewModel.selection = SidebarRowKey(section: .smartGroup(id), group: nil, entryID: a.id)

        try viewModel.deleteSmartGroup(id)

        #expect(viewModel.selection == .library(a.id))
    }

    @Test("Inline rename opens in the selected smart-group row, not the library row")
    func inlineRenameTargetsSelectedRow() async throws {
        let viewModel = makeViewModel()
        let alpha = viewModel.library.admitFixture(name: "Alpha")
        viewModel.sidebarOptions.filter = VMLibraryFilter(guestOSes: [.linux])
        try viewModel.saveSidebarFilterAsSmartGroup(named: "Linux")
        let id = try #require(viewModel.smartGroups.first?.id)
        let inGroup = SidebarRowKey(section: .smartGroup(id), group: nil, entryID: alpha.id)
        viewModel.selection = inGroup
        let controller = SidebarViewController(viewModel: viewModel)
        let outline = try shownOutline(of: controller)
        func cell(_ key: SidebarRowKey) -> SidebarVMRowCellView? {
            outline.view(atColumn: 0, row: row(key, in: outline), makeIfNecessary: false) as? SidebarVMRowCellView
        }

        viewModel.renameVMInSidebar(alpha)

        // The rename reaches the row through the sidebar's own observation
        // loop, which offers no test-facing signal to await.
        try await waitUntil { cell(inGroup)?.isRenaming == true }
        #expect(cell(.library(alpha.id))?.isRenaming != true)
        #expect(viewModel.selection == inGroup)
    }

    // MARK: - Sections

    @Test("A smart group created while the library is saved collapsed opens expanded")
    func newGroupOpensExpanded() throws {
        preferences.collapsedSidebarSections = [SidebarSectionID.library.rawValue]
        let viewModel = makeViewModel()
        viewModel.library.admitFixture(name: "A")
        viewModel.sidebarOptions.filter = VMLibraryFilter(guestOSes: [.linux])
        try viewModel.saveSidebarFilterAsSmartGroup(named: "Linux")
        let controller = SidebarViewController(viewModel: viewModel)
        let outline = try shownOutline(of: controller)

        #expect(outline.isItemExpanded(outline.item(atRow: 0)))
        #expect(outline.numberOfRows == 3)
        #expect(!outline.isItemExpanded(outline.item(atRow: 2)))

        outline.collapseItem(outline.item(atRow: 0))
        let id = try #require(viewModel.smartGroups.first?.id)
        #expect(
            Set(preferences.collapsedSidebarSections) == [
                SidebarSectionID.library.rawValue, SidebarSectionID.smartGroup(id).rawValue,
            ])
    }

    @Test("A selection restored at relaunch leaves a collapsed section collapsed; a reveal opens it")
    func restoredSelectionKeepsSectionCollapsed() throws {
        preferences.collapsedSidebarSections = [SidebarSectionID.library.rawValue]
        let viewModel = makeViewModel()
        let mac = viewModel.library.admitFixture(name: "Mac", guestOS: .macOS)
        viewModel.sidebarOptions.filter = VMLibraryFilter(guestOSes: [.macOS])
        try viewModel.saveSidebarFilterAsSmartGroup(named: "Macs")
        // As a relaunch finds it: the VM last selected — in the group — and
        // nothing selected yet.
        viewModel.selection = nil
        preferences.lastSelectedVMID = mac.id
        let controller = SidebarViewController(viewModel: viewModel)
        let outline = try shownOutline(of: controller)
        let library = try #require(outline.item(atRow: 2) as? SidebarSection)
        #expect(library.id == .library)

        // The library read lands after the sidebar is on screen.
        viewModel.library.restoreSelection()
        controller.viewDidAppear()

        #expect(viewModel.selection == .library(mac.id))
        #expect(!outline.isItemExpanded(library))
        #expect(outline.selectedRow == -1)
        #expect(preferences.collapsedSidebarSections == [SidebarSectionID.library.rawValue])

        viewModel.selectRevealing(mac.id)
        controller.viewDidAppear()

        #expect(outline.isItemExpanded(library))
        #expect(outline.selectedRow == row(.library(mac.id), in: outline))
    }

    @Test("Dragging a smart group's header reorders the smart groups; the library header does not drag")
    func dragReordersSmartGroups() throws {
        let viewModel = makeViewModel()
        for name in ["A", "B", "C"] {
            viewModel.sidebarOptions.filter = VMLibraryFilter(guestOSes: [.linux])
            try viewModel.saveSidebarFilterAsSmartGroup(named: name)
        }
        let controller = SidebarViewController(viewModel: viewModel)
        let outline = try shownOutline(of: controller)
        #expect(controller.outlineView(outline, pasteboardWriterForItem: try #require(outline.item(atRow: 6))) == nil)
        let c = try #require(outline.item(atRow: 4) as? SidebarSection)
        #expect(c.title == "C")
        let writer = try #require(controller.outlineView(outline, pasteboardWriterForItem: c) as? NSPasteboardItem)

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("sidebar-group-drop-\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.writeObjects([writer])
        let drag = FakeDraggingInfo(
            window: outline.window,
            location: outline.convert(NSPoint(x: 100, y: outline.rect(ofRow: 0).minY + 2), to: nil),
            pasteboard: pasteboard, source: outline)

        #expect(outline.draggingEntered(drag) == .move)
        #expect(outline.draggingUpdated(drag) == .move)
        #expect(outline.prepareForDragOperation(drag))
        #expect(outline.performDragOperation(drag))
        outline.concludeDragOperation(drag)

        #expect(viewModel.smartGroups.map(\.name) == ["C", "A", "B"])
        // Appearing runs the sidebar's sync pass synchronously.
        controller.viewDidAppear()
        let sections = (0..<outline.numberOfRows).compactMap { outline.item(atRow: $0) as? SidebarSection }
        #expect(sections.map(\.title) == ["C", "A", "B", "Virtual Machines"])
        // The moved section moved rather than being reinserted, so it is
        // still open — on screen, not only in the saved state.
        #expect(sections.allSatisfy { outline.isItemExpanded($0) })
        #expect(preferences.collapsedSidebarSections.isEmpty)
    }

    @Test("A tree reordering its sections reports moves, never a removal and reinsertion")
    func sectionReorderIsAMove() throws {
        let entries = [vm("A")]
        let groups = ["A", "B", "C"].map { group($0, VMLibraryFilter()) }
        let tree = SidebarTree()
        _ = tree.update(
            to: .project(entries: entries, options: SidebarViewOptions(), smartGroups: groups, context: .testing()))
        let before = tree.sections

        let changes = tree.update(
            to: .project(
                entries: entries, options: SidebarViewOptions(), smartGroups: [groups[2], groups[0], groups[1]],
                context: .testing()))

        let root = try #require(changes.children.first { $0.parent == nil })
        #expect(root.removed.isEmpty)
        #expect(root.inserted.isEmpty)
        #expect(root.moves == [SidebarTree.Changes.Children.Move(from: 2, to: 0)])
        #expect(
            tree.sections.map(ObjectIdentifier.init)
                == [before[2], before[0], before[1], before[3]].map(ObjectIdentifier.init))
    }

    @Test("A collapsed group holding the selection stays collapsed through later changes")
    func collapsedGroupHoldingSelectionStaysCollapsed() async throws {
        let viewModel = makeViewModel()
        let mac = viewModel.library.admitFixture(name: "Mac", guestOS: .macOS)
        viewModel.sidebarOptions.filter = VMLibraryFilter(guestOSes: [.macOS])
        try viewModel.saveSidebarFilterAsSmartGroup(named: "Macs")
        let id = try #require(viewModel.smartGroups.first?.id)
        let inGroup = SidebarRowKey(section: .smartGroup(id), group: nil, entryID: mac.id)
        viewModel.selection = inGroup
        let controller = SidebarViewController(viewModel: viewModel)
        let outline = try shownOutline(of: controller)
        let group = try #require(outline.item(atRow: 0) as? SidebarSection)

        outline.collapseItem(group)
        viewModel.library.admitFixture(name: "Other Mac", guestOS: .macOS)
        controller.viewDidAppear()

        #expect(!outline.isItemExpanded(group))
        #expect(viewModel.selection == inGroup)
        #expect(preferences.collapsedSidebarSections == [SidebarSectionID.smartGroup(id).rawValue])
    }
}
