import AppKit
import Foundation
import KernovaCommandModel
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport
@testable import KernovaUI
@testable import KernovaVirtualization

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
            machineFiles: VMBundleMachineFiles(fileSystem: MockFileSystem(), platform: FakePlatformFiles()),
            virtualizationHost: VirtualizationHost(),
            virtualizationService: MockVirtualizationService(),
            installService: MockMacOSInstallService(),
            ipswService: MockIPSWService(),
            localImageInspector: LocalRestoreImageInspector(),
            removableMediaDeviceService: MockRemovableMediaDeviceService(),
            bridgedInterfaces: HostBridgedInterfaceProvider(),
            fileSystem: MockFileSystem(),
            downloadsDirectory: makeTestDownloadsDirectory(),
            preferences: preferences,
            vmnetNetworks: VmnetNetworkService.scripted(),
            arpTable: ScriptedARPTable(),
            entitlements: .entitled,
            networks: networks,
            organization: organization,
            hostNotifications: .isolated(),
            hostPasteboard: FakePasteboard(),
            bundleProducts: .testing
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

    private func row(of section: SidebarSectionID, in outline: NSOutlineView) -> Int {
        (0..<outline.numberOfRows).first { (outline.item(atRow: $0) as? SidebarSection)?.id == section } ?? -1
    }

    // MARK: - Projection

    @Test("Each smart group is a section of its own, listing what its filter admits in the sort's order")
    func projectsSmartGroupSections() {
        let entries = [
            vm("Zed", guestOS: .macOS, phase: .running(sessionID: UUID())),
            vm("Alpha", guestOS: .linux, phase: .running(sessionID: UUID())),
            vm("Mac", guestOS: .macOS),
        ]
        let running = group("Running", VMLibraryFilter(states: [.running]))
        let macs = group("Macs", VMLibraryFilter(guestOSes: [.macOS]))
        let layout = SidebarLayout.project(
            entries: entries, options: SidebarViewOptions(sort: .name),
            organization: .listed([.smartGroup(running), .smartGroup(macs), .library]),
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

    // MARK: - Creating

    @Test("The naming sheet suggests a name from the filter and lists its conditions")
    func namingSheet() throws {
        let menu = SidebarViewMenu(networkTitle: { $0.rawValue }, tags: { [] }, perform: { _ in })
        let shared = VMLibraryFilter.Network(.nat) { _, _ in true }
        let values = [
            SidebarViewMenu.Value(
                subject: VMLibraryFilter.Subject(
                    guestOS: .macOS, state: .running, network: shared, guestAgent: .upToDate, isEphemeral: true,
                    hasSnapshots: false),
                networkTitle: "NAT \u{2013} Common")
        ]
        let filter = VMLibraryFilter(
            guestOSes: [.macOS], states: [.running], networks: [shared], guestAgents: [.upToDate, .olderVersion],
            ephemeralOnly: true)

        #expect(
            menu.suggestedName(for: filter, values: values) == "macOS \u{00B7} Running \u{00B7} NAT \u{2013} Common")
        #expect(
            menu.suggestedName(for: VMLibraryFilter(guestAgents: [.upToDate, .olderVersion]), values: values)
                == "Smart Group")
        #expect(
            menu.conditions(of: filter, values: values) == [
                "Guest OS is macOS", "State is Running", "Network is NAT \u{2013} Common",
                "Guest Agent is Up to Date or Older Version", "Ephemeral Mode",
            ])

        var created: String?
        let sheet = SidebarNameSheet.newSmartGroup(
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

    @Test("A name the library refuses brings the sheet back with that name typed in it")
    func refusedNameReopensTheSheet() async throws {
        let viewModel = makeViewModel()
        viewModel.library.admitFixture(name: "Mac", guestOS: .macOS)
        viewModel.sidebarOptions.filter = VMLibraryFilter(guestOSes: [.macOS])
        try viewModel.library.saveSidebarFilter(viewModel.sidebarOptions.filter, asSmartGroupNamed: "Macs")
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
        #expect(viewModel.library.smartGroups?.count == 1)
        #expect(viewModel.sidebarOptions.filter == VMLibraryFilter(guestOSes: [.macOS]))
        if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .alertSecondButtonReturn) }
    }

    @Test("A new smart group goes after every section, the library included, and scrolls into view past a selected VM")
    func newSmartGroupScrollsIntoView() async throws {
        let viewModel = makeViewModel()
        let first = viewModel.library.admitFixture(name: "Mac 0", guestOS: .macOS)
        for index in 1...60 { viewModel.library.admitFixture(name: "Mac \(index)", guestOS: .macOS) }
        viewModel.sidebarOptions.filter = VMLibraryFilter(guestOSes: [.macOS])
        viewModel.selection = .library(first.id)
        let controller = SidebarViewController(viewModel: viewModel)
        let outline = try shownOutline(of: controller)
        let window = try #require(outline.window)
        #expect(outline.selectedRow == self.row(.library(first.id), in: outline))
        outline.scrollRowToVisible(0)
        #expect(!outline.visibleRect.contains(outline.rect(ofRow: outline.numberOfRows - 1)))
        let menu = try #require(controller.viewMenu(for: .library))

        menu.performActionForItem(at: try #require(menu.items.firstIndex { $0.title == "Save as Smart Group\u{2026}" }))
        window.endSheet(try #require(window.attachedSheet), returnCode: .alertFirstButtonReturn)

        try await waitUntil { viewModel.library.smartGroups?.count == 1 }
        let group = try #require(viewModel.library.smartGroups?.first)
        #expect(viewModel.library.organization.sections?.map(\.id) == [.library, .smartGroup(group.id)])
        // The sync the organization change queued, and any later one, keeps
        // the view where the new section put it.
        controller.viewDidAppear()
        controller.viewDidAppear()
        #expect(viewModel.selection == .library(first.id))
        let header =
            (0..<outline.numberOfRows).first {
                (outline.item(atRow: $0) as? SidebarSection)?.id == .smartGroup(group.id)
            }
        let row = try #require(header)
        #expect(outline.visibleRect.contains(outline.rect(ofRow: row)))
    }

    // MARK: - Header and menu

    @Test("A smart group's header shows its name, its match count and its options button")
    func smartGroupHeader() throws {
        let viewModel = makeViewModel()
        viewModel.library.admitFixture(name: "A")
        viewModel.library.admitFixture(name: "B")
        viewModel.library.admitFixture(name: "Mac", guestOS: .macOS)
        viewModel.sidebarOptions.filter = VMLibraryFilter(guestOSes: [.linux])
        let linux = try viewModel.library.saveSidebarFilter(viewModel.sidebarOptions.filter, asSmartGroupNamed: "Linux")
        let controller = SidebarViewController(viewModel: viewModel)
        let outline = try shownOutline(of: controller)
        let headerRow = row(of: .smartGroup(linux.id), in: outline)
        let header = try #require(
            outline.view(atColumn: 0, row: headerRow, makeIfNecessary: true) as? SidebarGroupHeaderCellView)

        let labels = allSubviews(NSTextField.self, in: header).filter { !$0.isHidden }.map(\.stringValue)
        #expect(labels.contains("Linux"))
        #expect(labels.contains("2"))
        let button = try #require(header.filterButton)
        #expect(button.accessibilityLabel() == "Smart Group Options")
        #expect(button.accessibilityValue() as? String == "Guest OS: Linux")
        #expect(
            controller.contextMenu(forRow: headerRow)?.items.first?.title == "Show VMs in \u{201C}Linux\u{201D} where")
    }

    @Test("The header menu edits the group's filter, and the section and its count follow live")
    func headerMenuEditsFilter() async throws {
        let viewModel = makeViewModel()
        viewModel.library.admitFixture(name: "Linux")
        viewModel.library.admitFixture(name: "Mac", guestOS: .macOS)
        viewModel.sidebarOptions.filter = VMLibraryFilter(guestOSes: [.linux])
        let saved = try viewModel.library.saveSidebarFilter(
            viewModel.sidebarOptions.filter, asSmartGroupNamed: "Picked")
        let controller = SidebarViewController(viewModel: viewModel)
        let outline = try shownOutline(of: controller)
        let menu = try #require(controller.viewMenu(for: .smartGroup(saved.id)))

        #expect(
            menu.items.map(\.title) == [
                "Show VMs in \u{201C}Picked\u{201D} where", "Guest OS", "State", "Network", "Guest Agent", "Other", "",
                "Start All", "Suspend All", "Stop All", "Restart All", "", "Rename Smart Group\u{2026}",
                "Delete Smart Group",
            ])
        #expect(menu.items[0].isSectionHeader)
        #expect(menu.items[1].badge?.stringValue == "Linux")
        let guestOS = try #require(menu.items[1].submenu)
        let macOS = try #require(guestOS.items.firstIndex { $0.title == "macOS" })
        guestOS.performActionForItem(at: macOS)

        #expect(viewModel.library.smartGroups?.first?.filter == VMLibraryFilter(guestOSes: [.linux, .macOS]))
        // The library's own filter is untouched.
        #expect(viewModel.sidebarOptions.filter == VMLibraryFilter())
        try await waitUntil { outline.numberOfRows == 6 }
        let header = try #require(
            outline.view(atColumn: 0, row: row(of: .smartGroup(saved.id), in: outline), makeIfNecessary: true)
                as? SidebarGroupHeaderCellView)
        #expect(allSubviews(NSTextField.self, in: header).map(\.stringValue).contains("2"))

        // Edited back to empty, the group lists every VM.
        let all = try #require(controller.viewMenu(for: .smartGroup(saved.id))?.items[1].submenu)
        all.performActionForItem(at: 0)
        #expect(viewModel.library.smartGroups?.first?.filter == VMLibraryFilter())
        #expect(names(in: viewModel.sidebarLayout.sections[1]) == ["Linux", "Mac"])
    }

    @Test("Rename retitles the section; Delete removes it")
    func renameAndDelete() async throws {
        let viewModel = makeViewModel()
        viewModel.library.admitFixture(name: "A")
        viewModel.sidebarOptions.filter = VMLibraryFilter(guestOSes: [.linux])
        try viewModel.library.saveSidebarFilter(viewModel.sidebarOptions.filter, asSmartGroupNamed: "Old")
        let id = try #require(viewModel.library.smartGroups?.first?.id)
        let controller = SidebarViewController(viewModel: viewModel)
        let outline = try shownOutline(of: controller)

        try viewModel.library.renameSmartGroup(id, to: "New")
        try await waitUntil {
            (outline.item(atRow: row(of: .smartGroup(id), in: outline)) as? SidebarSection)?.title == "New"
        }
        #expect(throws: VMOrganizationDirectory.ChangeError.nameRequired(.smartGroup)) {
            try viewModel.library.renameSmartGroup(id, to: " ")
        }

        let menu = try #require(controller.viewMenu(for: .smartGroup(id)))
        menu.performActionForItem(at: try #require(menu.items.firstIndex { $0.title == "Delete Smart Group" }))

        #expect(viewModel.library.smartGroups == [])
        try await waitUntil { outline.numberOfRows == 2 }
        #expect((outline.item(atRow: 0) as? SidebarSection)?.id == .library)
    }

    @Test("Deleting a named network leaves each filter naming it, which then admits no VM and says so")
    func deletingANetworkKeepsItsCondition() throws {
        let viewModel = makeViewModel()
        let lab = try viewModel.networks.create(name: "Lab", kind: .nat, verb: .createNetwork)
        viewModel.library.admitFixture(name: "A") { $0.networkMembership = .network(lab.id) }
        viewModel.library.admitFixture(name: "B", guestOS: .macOS)
        let onLab = VMLibraryFilter.Network(.vmnet(.nat, .network(lab.id))) { _, _ in true }
        let shared = VMLibraryFilter.Network(.nat) { _, _ in true }
        viewModel.sidebarOptions.filter = VMLibraryFilter(networks: [onLab])
        let labGroup = try viewModel.library.saveSidebarFilter(
            viewModel.sidebarOptions.filter, asSmartGroupNamed: "Lab")
        viewModel.sidebarOptions.filter = VMLibraryFilter(guestOSes: [.linux], networks: [onLab, .unlisted])
        try viewModel.library.saveSidebarFilter(viewModel.sidebarOptions.filter, asSmartGroupNamed: "Linux off the LAN")
        viewModel.sidebarOptions.filter = VMLibraryFilter(networks: [onLab, shared])
        let group = VMGroupReference(.smartGroup, named: labGroup.id.uuidString)
        #expect(names(in: viewModel.sidebarLayout.sections[1]) == ["A"])
        #expect(viewModel.groupActionCounts(for: group)?[.start] == 1)

        try viewModel.deleteNetwork(lab.id)

        #expect(viewModel.networks.state == .listed([]))
        #expect(
            viewModel.library.smartGroups?.map(\.filter) == [
                VMLibraryFilter(networks: [onLab]), VMLibraryFilter(guestOSes: [.linux], networks: [onLab, .unlisted]),
            ])
        #expect(viewModel.sidebarOptions.filter == VMLibraryFilter(networks: [onLab, shared]))
        // Its only condition names a network no VM can be on, so "Lab" lists
        // nothing — and a group action on it acts on nothing.
        #expect(names(in: viewModel.sidebarLayout.sections[1]).isEmpty)
        #expect(viewModel.groupActionCounts(for: group) == [.start: 0, .suspend: 0, .stop: 0, .restart: 0])

        // The menu names the condition it still holds, and clears it.
        let controller = SidebarViewController(viewModel: viewModel)
        let menu = try #require(controller.viewMenu(for: .smartGroup(labGroup.id)))
        let network = try #require(menu.items.first { $0.title == "Network" })
        #expect(network.badge?.stringValue == "Network No Longer in This Library")
        let submenu = try #require(network.submenu)
        let held = try #require(submenu.items.firstIndex { $0.title == "Network No Longer in This Library" })
        #expect(submenu.items[held].state == .on)
        submenu.performActionForItem(at: held)
        #expect(viewModel.library.smartGroups?.first?.filter == VMLibraryFilter())
    }

    @Test("A network is deleted without touching the smart groups' file, readable or not")
    func networkDeleteLeavesTheOrganizationFileAlone() throws {
        try FileManager.default.createDirectory(at: scratch.url, withIntermediateDirectories: true)
        let organizationURL = scratch.url.appendingPathComponent("Organization.json")
        try Data("not json".utf8).write(to: organizationURL)
        let networksURL = scratch.url.appendingPathComponent("Networks.json")
        let viewModel = makeViewModel(
            networks: VMNetworkDirectory(fileURL: networksURL),
            organization: VMOrganizationDirectory(fileURL: organizationURL))
        let lab = try viewModel.networks.create(name: "Lab", kind: .nat, verb: .createNetwork)

        try viewModel.deleteNetwork(lab.id)

        #expect(VMNetworkDirectory(fileURL: networksURL).state == .listed([]))
        #expect(try Data(contentsOf: organizationURL) == Data("not json".utf8))
    }

    // MARK: - Unreadable smart groups

    /// A view model whose smart groups' file holds bytes that aren't JSON.
    private func viewModelWithUnreadableSmartGroups() throws -> (VMLibraryViewModel, URL) {
        try FileManager.default.createDirectory(at: scratch.url, withIntermediateDirectories: true)
        let organizationURL = scratch.url.appendingPathComponent("Organization.json")
        try Data("not json".utf8).write(to: organizationURL)
        return (makeViewModel(organization: VMOrganizationDirectory(fileURL: organizationURL)), organizationURL)
    }

    @Test("Smart groups that can't be read are one disabled row pointing to the config check")
    func unreadableSmartGroupsRow() throws {
        let (viewModel, _) = try viewModelWithUnreadableSmartGroups()
        viewModel.library.admitFixture(name: "Linux")

        let sections = viewModel.sidebarLayout.sections
        #expect(sections.map(\.id) == [.unreadableOrganization, .library])
        #expect(sections[0].title == "Smart Groups and Folders Can\u{2019}t Be Read")
        #expect(sections[0].content.isEmpty)
        #expect(sections[0].emptyText == nil)
        #expect(sections[0].notice?.contains("File > Check Config Files\u{2026}") == true)

        let controller = SidebarViewController(viewModel: viewModel)
        let outline = try shownOutline(of: controller)
        let item = try #require(outline.item(atRow: 0) as? SidebarSection)
        #expect(item.id == .unreadableOrganization)
        #expect(item.children.isEmpty)
        #expect(outline.isExpandable(item) == false)
        #expect(controller.outlineView(outline, shouldSelectItem: item) == false)
        #expect(controller.viewMenu(for: item.id) == nil)
        let cell = try #require(outline.view(atColumn: 0, row: 0, makeIfNecessary: true) as? SidebarGroupHeaderCellView)
        #expect(cell.toolTip == VMOrganizationDirectory.unreadableMessage)
        #expect(cell.textField?.stringValue == "Smart Groups and Folders Can\u{2019}t Be Read")
    }

    @Test("A smart-group change is refused while the file can't be read, and writes nothing")
    func unreadableSmartGroupsRefuseChanges() throws {
        let (viewModel, organizationURL) = try viewModelWithUnreadableSmartGroups()
        viewModel.sidebarOptions.filter = VMLibraryFilter(guestOSes: [.macOS])

        #expect(throws: VMOrganizationDirectory.ChangeError.unreadable) {
            try viewModel.library.saveSidebarFilter(viewModel.sidebarOptions.filter, asSmartGroupNamed: "Macs")
        }
        #expect(throws: VMOrganizationDirectory.ChangeError.unreadable) {
            try viewModel.library.moveSection(.smartGroup(UUID()), before: nil)
        }
        #expect(
            VMOrganizationDirectory.ChangeError.unreadable.errorDescription
                == VMOrganizationDirectory.unreadableMessage)
        // The filter a refused save would have cleared stays on.
        #expect(viewModel.sidebarOptions.filter == VMLibraryFilter(guestOSes: [.macOS]))
        #expect(viewModel.library.organization.state.unreadable != nil)
        #expect(try Data(contentsOf: organizationURL) == Data("not json".utf8))
    }

    @Test("Tags that can't be read show as such in the Tags pane, a row's Tags item, the grouping and the filter")
    func unreadableTagsShowAsUnreadable() throws {
        let (viewModel, organizationURL) = try viewModelWithUnreadableSmartGroups()
        let tagged = UUID()
        let vm = viewModel.library.admitFixture(name: "Desk")
        var checks = 0
        viewModel.onShowConfigCheck = { _ in checks += 1 }

        #expect(viewModel.library.tags == nil)
        #expect(viewModel.library.tags(of: vm).isEmpty)
        #expect(throws: VMOrganizationDirectory.ChangeError.unreadable) {
            try viewModel.library.createTag(named: "Work", color: .red)
        }

        // The pane shows the notice in place of the list, and offers no change.
        let pane = TagsSettingsViewController(viewModel: viewModel)
        pane.loadViewIfNeeded()
        pane.viewWillAppear()
        #expect(pane.isUnreadable)
        #expect(pane.tags.isEmpty)
        func find<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
            ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { find(type, in: $0) }
        }
        let addRemove = try #require(find(NSSegmentedControl.self, in: pane.view).first)
        #expect(!addRemove.isEnabled(forSegment: 0))
        let check = try #require(
            find(NSButton.self, in: pane.view).first { $0.title == "Check Config Files\u{2026}" })
        check.performClick(nil)
        #expect(checks == 1)

        // A row's Tags item points to the check, as Add to Folder does.
        let controller = SidebarViewController(viewModel: viewModel)
        _ = try shownOutline(of: controller)
        let menu = controller.buildContextMenu(for: vm)
        for title in ["Tags", "Add to Folder"] {
            let item = try #require(menu.items.first { $0.title == title })
            #expect(!item.isEnabled, "\(title)")
            #expect(item.submenu == nil, "\(title)")
            #expect(item.toolTip == VMOrganizationDirectory.unreadableMessage, "\(title)")
        }

        // Grouped by tag, every VM is under one group saying the tags can't be
        // read — never "No Tags", which would claim it carries none.
        viewModel.sidebarOptions = SidebarViewOptions(grouping: .tag)
        let library = try #require(viewModel.sidebarLayout.sections.first { $0.id == .library })
        guard case .groups(let groups) = library.content else {
            Issue.record("The library section isn't grouped")
            return
        }
        #expect(groups.groups.map(\.title) == [SidebarLayout.unreadableTagsGroupTitle])

        // A tag the filter holds reads as unreadable, not as deleted, and its
        // one choice clears every tag condition.
        viewModel.sidebarOptions = SidebarViewOptions(filter: VMLibraryFilter(tags: [tagged]))
        let tags = try #require(
            controller.viewMenu(for: .library)?.items.first { $0.title == "Tags" }?.submenu)
        let unread = try #require(tags.items.firstIndex { $0.title == SidebarViewMenu.heldUnreadableTagsTitle })
        #expect(tags.items[unread].state == .on)
        #expect(!tags.items.contains { $0.title == SidebarViewMenu.heldUndefinedTagTitle })
        tags.performActionForItem(at: unread)
        #expect(viewModel.sidebarOptions.filter.tags.isEmpty)
        #expect(try Data(contentsOf: organizationURL) == Data("not json".utf8))
    }

    // MARK: - Sections

    @Test("A selection restored at relaunch leaves a collapsed section collapsed; a reveal opens it")
    func restoredSelectionKeepsSectionCollapsed() throws {
        preferences.collapsedSidebarSections = [SidebarSectionID.library.rawValue]
        let viewModel = makeViewModel()
        let mac = viewModel.library.admitFixture(name: "Mac", guestOS: .macOS)
        viewModel.sidebarOptions.filter = VMLibraryFilter(guestOSes: [.macOS])
        try viewModel.library.saveSidebarFilter(viewModel.sidebarOptions.filter, asSmartGroupNamed: "Macs")
        // As a relaunch finds it: the VM last selected — in the group — and
        // nothing selected yet.
        viewModel.selection = nil
        preferences.sidebarSelection = .library(mac.id)
        let controller = SidebarViewController(viewModel: viewModel)
        let outline = try shownOutline(of: controller)
        let library = try #require(outline.item(atRow: row(of: .library, in: outline)) as? SidebarSection)

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

    @Test("A reveal while the library is grouped opens its collapsed section and selects the VM's grouped row")
    func revealWhileGroupedOpensTheSection() throws {
        preferences.collapsedSidebarSections = [SidebarSectionID.library.rawValue]
        let viewModel = makeViewModel()
        viewModel.library.admitFixture(name: "A")
        let b = viewModel.library.admitFixture(name: "B", guestOS: .macOS)
        viewModel.sidebarOptions.grouping = .guestOS
        let controller = SidebarViewController(viewModel: viewModel)
        let outline = try shownOutline(of: controller)
        let library = try #require(outline.item(atRow: row(of: .library, in: outline)) as? SidebarSection)
        #expect(!outline.isItemExpanded(library))

        viewModel.selectRevealing(b.id)
        controller.viewDidAppear()

        let grouped = SidebarRowKey(section: .library, group: SidebarGroupID(rawValue: "guestOS:macOS"), entryID: b.id)
        #expect(viewModel.selection == grouped)
        #expect(outline.isItemExpanded(library))
        #expect(outline.selectedRow == row(grouped, in: outline))
    }

    @Test("Save as Smart Group saves the filter its sheet showed, though the library's changed while the sheet was up")
    func saveAsSmartGroupSavesTheShownFilter() async throws {
        let viewModel = makeViewModel()
        viewModel.library.admitFixture(name: "Mac", guestOS: .macOS)
        let macs = VMLibraryFilter(guestOSes: [.macOS])
        viewModel.sidebarOptions.filter = macs
        let controller = SidebarViewController(viewModel: viewModel)
        let outline = try shownOutline(of: controller)
        let window = try #require(outline.window)
        let menu = try #require(controller.viewMenu(for: .library))
        menu.performActionForItem(at: try #require(menu.items.firstIndex { $0.title == "Save as Smart Group\u{2026}" }))
        let sheet = try #require(window.attachedSheet)

        // As the View menu's filter items do, which stay enabled under the
        // sheet.
        let linux = VMLibraryFilter(guestOSes: [.linux])
        viewModel.sidebarOptions.filter = linux
        window.endSheet(sheet, returnCode: .alertFirstButtonReturn)

        try await waitUntil { viewModel.library.smartGroups?.count == 1 }
        #expect(viewModel.library.smartGroups?.first?.filter == macs)
        // The filter the user changed to is not the one saved, so it stays.
        #expect(viewModel.sidebarOptions.filter == linux)
    }

    @Test("A collapsed group holding the selection stays collapsed through later changes")
    func collapsedGroupHoldingSelectionStaysCollapsed() async throws {
        let viewModel = makeViewModel()
        let mac = viewModel.library.admitFixture(name: "Mac", guestOS: .macOS)
        viewModel.sidebarOptions.filter = VMLibraryFilter(guestOSes: [.macOS])
        try viewModel.library.saveSidebarFilter(viewModel.sidebarOptions.filter, asSmartGroupNamed: "Macs")
        let id = try #require(viewModel.library.smartGroups?.first?.id)
        let inGroup = SidebarRowKey(section: .smartGroup(id), group: nil, entryID: mac.id)
        viewModel.selection = inGroup
        let controller = SidebarViewController(viewModel: viewModel)
        let outline = try shownOutline(of: controller)
        let group = try #require(outline.item(atRow: row(of: .smartGroup(id), in: outline)) as? SidebarSection)

        outline.collapseItem(group)
        viewModel.library.admitFixture(name: "Other Mac", guestOS: .macOS)
        controller.viewDidAppear()

        #expect(!outline.isItemExpanded(group))
        #expect(viewModel.selection == inGroup)
        #expect(preferences.collapsedSidebarSections == [SidebarSectionID.smartGroup(id).rawValue])
    }
}
