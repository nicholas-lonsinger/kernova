import AppKit
import Foundation
import KernovaKit
import KernovaTestSupport
import Testing

@testable import Kernova

/// Color tags: their definitions in the library file, each VM's assignments in
/// its host state, and every surface that shows, filters, groups or edits
/// them.
@Suite("Sidebar tags", .serialized, .caseScoped, .scopedWindows)
@MainActor
struct SidebarTagTests {
    private let preferences = makeTestPreferences()

    private let scratch = TestScratchDirectory(prefix: "SidebarTagTests")

    private var fileURL: URL { scratch.url.appendingPathComponent("Organization.json") }

    private func makeViewModel(storage: MockVMStorageService = MockVMStorageService()) -> VMLibraryViewModel {
        VMLibraryViewModel(
            storageService: storage,
            diskImageService: MockDiskImageService(),
            virtualizationService: MockVirtualizationService(),
            installService: MockMacOSInstallService(),
            ipswService: MockIPSWService(),
            removableMediaDeviceService: MockRemovableMediaDeviceService(),
            fileSystem: MockFileSystem(),
            downloadsDirectory: nil,
            preferences: preferences,
            vmnetNetworks: MockVmnetNetworkProvider(), arpTable: ScriptedARPTable(), entitlements: .entitled,
            organization: VMOrganizationDirectory(fileURL: nil)
        )
    }

    /// A sidebar on screen, its sync pass run.
    private func shownOutline(of controller: SidebarViewController) throws -> NSOutlineView {
        let window = showTestWindow(styleMask: [.titled], contentSize: NSSize(width: 300, height: 700))
        window.contentView = controller.view
        controller.view.layoutSubtreeIfNeeded()
        controller.viewDidAppear()
        return try #require(firstSubview(NSOutlineView.self, in: controller.view))
    }

    private func row(_ key: SidebarRowKey, in outline: NSOutlineView) -> Int {
        (0..<outline.numberOfRows).first { (outline.item(atRow: $0) as? SidebarRow)?.key == key } ?? -1
    }

    // MARK: - Store

    @Test("Tags persist in their order with their colors; a rename and a recolor keep the identifier")
    func tagsRoundTrip() throws {
        let directory = VMOrganizationDirectory(fileURL: fileURL)
        let work = try directory.createTag(named: " Work ", color: .blue)
        let lab = try directory.createTag(named: "Lab", color: .green)
        #expect(work.name == "Work")

        try directory.renameTag(lab.id, to: "Bench")
        try directory.setColor(.red, ofTag: work.id)

        let reread = VMOrganizationDirectory(fileURL: fileURL)
        #expect(
            reread.tags == [
                VMTag(id: work.id, name: "Work", color: .red), VMTag(id: lab.id, name: "Bench", color: .green),
            ])
        #expect(reread.tag(named: "bench")?.id == lab.id)
        #expect(reread.tag(named: work.id.uuidString.lowercased())?.id == work.id)
        #expect(reread.tag(named: "Home") == nil)
        #expect(reread.unusedName(from: "Work", for: .tag) == "Work 2")
    }

    @Test("A tag's name is non-empty, no identifier, and unique among tags ignoring case")
    func tagNamesAreValidated() throws {
        let directory = VMOrganizationDirectory(fileURL: nil)
        let work = try directory.createTag(named: "Work", color: .blue)
        // A smart group's name does not take a tag's.
        try directory.createSmartGroup(named: "Lab", filter: VMLibraryFilter())
        let lab = try directory.createTag(named: "Lab", color: .green)

        #expect(throws: VMOrganizationDirectory.ChangeError.nameRequired(.tag)) {
            try directory.createTag(named: " ", color: .red)
        }
        #expect(throws: VMOrganizationDirectory.ChangeError.nameTaken("Work", .tag)) {
            try directory.renameTag(lab.id, to: "WORK")
        }
        let identifier = UUID().uuidString
        #expect(throws: VMOrganizationDirectory.ChangeError.nameIsIdentifier(identifier, .tag)) {
            try directory.createTag(named: identifier, color: .red)
        }
        #expect(directory.tags.map(\.id) == [work.id, lab.id])
    }

    @Test("A library file written before tags reads with none, and keeps its groups as a tag is added")
    func fileWithoutTagsReadsWithNone() throws {
        try FileManager.default.createDirectory(at: scratch.url, withIntermediateDirectories: true)
        try Data(#"{"smartGroups":[],"folders":[]}"#.utf8).write(to: fileURL)
        let directory = VMOrganizationDirectory(fileURL: fileURL)
        #expect(directory.readFailure == nil)
        #expect(directory.tags.isEmpty)

        let work = try directory.createTag(named: "Work", color: .blue)

        #expect(VMOrganizationDirectory(fileURL: fileURL).tags == [work])
    }

    @Test("Removing a tag drops it from every smart group's filter in the same write")
    func removingATagPrunesSmartGroups() throws {
        let directory = VMOrganizationDirectory(fileURL: fileURL)
        let work = try directory.createTag(named: "Work", color: .blue)
        let lab = try directory.createTag(named: "Lab", color: .green)
        let group = try directory.createSmartGroup(
            named: "Tagged", filter: VMLibraryFilter(guestOSes: [.linux], tags: [work.id, lab.id]))

        try directory.removeTag(work.id)

        let reread = VMOrganizationDirectory(fileURL: fileURL)
        #expect(reread.tags.map(\.id) == [lab.id])
        #expect(reread.smartGroup(withID: group.id)?.filter == VMLibraryFilter(guestOSes: [.linux], tags: [lab.id]))
    }

    // MARK: - Assignments

    @Test("An assignment the library does not define shows nowhere and filters as none")
    func undefinedAssignmentsReadAsNone() throws {
        let viewModel = makeViewModel()
        let library = viewModel.library
        let work = try library.createTag(named: "Work", color: .blue)
        let vm = library.admitFixture(name: "A", hostState: VMHostState(tags: [work.id, UUID()]))

        #expect(library.tags(of: vm) == [work])
        #expect(library.sidebarContext.subject(of: .vm(vm)).tags == [work.id])
    }

    @Test("Clones keep their source's tags, both a New Machine and an Exact Copy")
    func clonesKeepTags() async throws {
        for outcome in [CloneOutcome.newMachine, .exactCopy] {
            let storage = MockVMStorageService()
            let viewModel = makeViewModel(storage: storage)
            let library = viewModel.library
            let work = try library.createTag(named: "Work", color: .blue)
            let original = library.admitFixture(name: "Original", hostState: VMHostState(tags: [work.id]))
            storage.bundles[original.bundleURL] = original.configuration
            storage.hostStates[original.bundleURL] = original.hostState

            viewModel.cloneVM(original, as: outcome)
            await viewModel.awaitArrivalsForTesting()

            let clone = try #require(viewModel.instances.first { $0.id != original.id }, "\(outcome)")
            #expect(library.tags(of: clone) == [work], "\(outcome)")
            #expect(storage.hostStates[clone.bundleURL]?.tags == [work.id], "\(outcome)")
        }
    }

    @Test("An import keeps the tags this library defines and drops the rest on arrival")
    func importDropsUnknownTags() async throws {
        let storage = MockVMStorageService()
        let viewModel = makeViewModel(storage: storage)
        let work = try viewModel.library.createTag(named: "Work", color: .blue)
        let foreign = UUID()
        let source = try scratch.importSource(name: "Arriving")
        try VMConfiguration.makeJSONEncoder().encode(VMHostState(tags: [work.id, foreign]))
            .write(to: source.url.appendingPathComponent(VMBundleLayout.hostStateRelativePath))

        #expect(viewModel.importVMs(fromDroppedURLs: [source.url]))
        await viewModel.awaitArrivalsForTesting()

        let imported = try #require(viewModel.instances.first { $0.id == source.config.id })
        #expect(imported.hostState.tags == [work.id])
    }

    // MARK: - Grouping

    @Test("Group by Tag lists a VM under every tag it carries, in the tags' order, the untagged last")
    func groupByTagListsDuplicates() throws {
        let work = VMTag(id: UUID(), name: "Work", color: .blue)
        let lab = VMTag(id: UUID(), name: "Lab", color: .green)
        let both = VMInstanceFixture.make(name: "Both", hostState: VMHostState(tags: [work.id, lab.id]))
        let desk = VMInstanceFixture.make(name: "Desk", hostState: VMHostState(tags: [work.id]))
        let plain = VMInstanceFixture.make(name: "Plain")
        var options = SidebarViewOptions()
        options.grouping = .tag

        let layout = SidebarLayout.project(
            entries: [.vm(plain), .vm(both), .vm(desk)], options: options,
            context: .testing(tags: [lab, work]))

        guard case .groups(let groups)? = layout.sections.last?.content else {
            Issue.record("expected groups")
            return
        }
        #expect(groups.groups.map(\.title) == ["Lab", "Work", SidebarLayout.untaggedGroupTitle])
        #expect(groups.groups.map { $0.rows.entries.map(\.name) } == [["Both"], ["Both", "Desk"], ["Plain"]])
        let bothRows = layout.rowKeys.filter { $0.entryID == both.id }
        #expect(bothRows.count == 2)
        #expect(Set(bothRows).count == 2)
    }

    // MARK: - Rows

    @Test("A row shows its tags' dots, names them as its accessibility value, and the snap fits them")
    func rowShowsTags() async throws {
        let viewModel = makeViewModel()
        let library = viewModel.library
        let work = try library.createTag(named: "Work", color: .blue)
        let lab = try library.createTag(named: "Lab", color: .green)
        let vm = library.admitFixture(name: "Tagged")
        let controller = SidebarViewController(viewModel: viewModel)
        let outline = try shownOutline(of: controller)
        func cell() throws -> SidebarVMRowCellView {
            try #require(
                outline.view(atColumn: 0, row: row(.library(vm.id), in: outline), makeIfNecessary: true)
                    as? SidebarVMRowCellView)
        }
        #expect(try cell().accessibilityValue() == nil)
        let untagged = try #require(controller.widthToFitLongestRow())

        try library.setTag(lab.id, assigned: true, on: vm)
        try library.setTag(work.id, assigned: true, on: vm)
        // The row repaints from its observation loop's apply, already queued.
        await drainMainQueue()
        #expect(try cell().accessibilityValue() as? String == "Work, Lab")

        let tagged = try #require(controller.widthToFitLongestRow())
        #expect(tagged - untagged == Spacing.small + SidebarTagDotsView.width(forCount: 2))
        let dots = try #require(firstSubview(SidebarTagDotsView.self, in: try cell()))
        #expect(dots.colors == [.blue, .green])
        #expect(!dots.isHidden)
    }

    // MARK: - Menus

    @Test("Tags in a VM's menu toggles each tag, checked where the VM carries it, then Edit Tags…")
    func contextMenuToggles() throws {
        let viewModel = makeViewModel()
        let library = viewModel.library
        let work = try library.createTag(named: "Work", color: .blue)
        let lab = try library.createTag(named: "Lab", color: .green)
        let vm = library.admitFixture(name: "A")
        let controller = SidebarViewController(viewModel: viewModel)
        controller.loadViewIfNeeded()
        func submenu() throws -> NSMenu {
            let menu = controller.buildContextMenu(for: vm)
            return try #require(menu.items.first { $0.title == "Tags" }?.submenu)
        }

        #expect(try submenu().items.map(\.title) == ["Work", "Lab", "", "Edit Tags\u{2026}"])
        #expect(try submenu().items.prefix(2).map(\.state) == [.off, .off])
        #expect(try submenu().items.prefix(2).allSatisfy { $0.image != nil && $0.isEnabled })
        try submenu().performActionForItem(at: 1)
        #expect(library.tags(of: vm) == [lab])
        try submenu().performActionForItem(at: 0)
        #expect(library.tags(of: vm) == [work, lab])
        #expect(try submenu().items.prefix(2).map(\.state) == [.on, .on])

        try submenu().performActionForItem(at: 1)
        #expect(library.tags(of: vm) == [work])
        #expect(vm.hostState.tags == [work.id])
    }

    @Test("With no tags, a VM's Tags menu offers only Edit Tags…")
    func contextMenuWithoutTags() throws {
        let viewModel = makeViewModel()
        let vm = viewModel.library.admitFixture(name: "A")
        let controller = SidebarViewController(viewModel: viewModel)
        controller.loadViewIfNeeded()

        let submenu = try #require(controller.buildContextMenu(for: vm).items.first { $0.title == "Tags" }?.submenu)
        #expect(submenu.items.map(\.title) == ["Edit Tags\u{2026}"])
    }

    @Test("The filter menu's Tags row lists each tag with its count; a pick widens the set")
    func filterMenuTags() throws {
        let viewModel = makeViewModel()
        let library = viewModel.library
        let work = try library.createTag(named: "Work", color: .blue)
        let lab = try library.createTag(named: "Lab", color: .green)
        library.admitFixture(name: "Both", hostState: VMHostState(tags: [work.id, lab.id]))
        library.admitFixture(name: "Desk", hostState: VMHostState(tags: [work.id]))
        library.admitFixture(name: "Plain")
        let controller = SidebarViewController(viewModel: viewModel)
        controller.loadViewIfNeeded()
        func tagsRow() throws -> NSMenuItem {
            try #require(controller.viewMenu(for: .library)?.items.first { $0.title == "Tags" })
        }

        let submenu = try #require(try tagsRow().submenu)
        #expect(submenu.items.map(\.title) == ["All Tags", "", "Work", "Lab"])
        #expect(submenu.items.suffix(2).map { $0.badge?.itemCount } == [2, 1])
        submenu.performActionForItem(at: 3)
        #expect(viewModel.sidebarOptions.filter == VMLibraryFilter(tags: [lab.id]))
        try #require(try tagsRow().submenu).performActionForItem(at: 2)
        #expect(viewModel.sidebarOptions.filter == VMLibraryFilter(tags: [work.id, lab.id]))
        #expect(try tagsRow().badge?.stringValue == "2 Selected")
        #expect(
            controller.viewMenu.conditions(of: VMLibraryFilter(tags: [lab.id]), values: [])
                == ["Tag is Lab"])

        let groupBy = try #require(controller.viewMenu(for: .library)?.items.first { $0.title == "Group By" })
        #expect(groupBy.submenu?.items.map(\.title).contains("Tag") == true)
    }

    // MARK: - Settings pane

    @Test("The Tags pane creates, renames and recolors tags, and lists the VMs carrying each")
    func settingsPaneEdits() throws {
        let viewModel = makeViewModel()
        let library = viewModel.library
        let vm = library.admitFixture(name: "Desk")
        let pane = TagsSettingsViewController(viewModel: viewModel)
        pane.loadViewIfNeeded()

        #expect(pane.suggestedColor() == .red)
        try pane.create(name: "Work", color: pane.suggestedColor())
        #expect(pane.suggestedColor() == .orange)
        let work = try #require(library.tags.first)
        try library.setTag(work.id, assigned: true, on: vm)
        try pane.rename(work.id, to: "Office")
        try pane.recolor(work.id, to: .purple)

        #expect(library.tags == [VMTag(id: work.id, name: "Office", color: .purple)])
        #expect(pane.tags == library.tags)
        #expect(TagsSettingsViewController.membersText(pane.members(of: library.tags[0])) == "Desk")
        #expect(throws: VMOrganizationDirectory.ChangeError.nameTaken("Office", .tag)) {
            try pane.create(name: "office", color: .blue)
        }
    }

    @Test("Deleting a tag takes it off every VM, out of every smart group's filter and the library's")
    func settingsPaneDeletes() throws {
        let viewModel = makeViewModel()
        let library = viewModel.library
        let work = try library.createTag(named: "Work", color: .blue)
        let lab = try library.createTag(named: "Lab", color: .green)
        let a = library.admitFixture(name: "A", hostState: VMHostState(tags: [work.id, lab.id]))
        let b = library.admitFixture(name: "B", hostState: VMHostState(tags: [work.id]))
        let group = try library.organization.createSmartGroup(
            named: "Work", filter: VMLibraryFilter(tags: [work.id]))
        library.sidebarOptions.filter = VMLibraryFilter(tags: [work.id, lab.id])
        let pane = TagsSettingsViewController(viewModel: viewModel)
        pane.loadViewIfNeeded()
        let confirmation = TagsSettingsViewController.deleteConfirmation(
            for: work, members: pane.members(of: work), delete: {})
        #expect(confirmation.message == "Deleting it takes it off \u{201C}A\u{201D} and \u{201C}B\u{201D}.")

        try pane.delete(work.id)

        #expect(library.tags == [lab])
        #expect(a.hostState.tags == [lab.id])
        #expect(b.hostState.tags.isEmpty)
        #expect(library.organization.smartGroup(withID: group.id)?.filter == VMLibraryFilter())
        #expect(library.sidebarOptions.filter == VMLibraryFilter(tags: [lab.id]))
        #expect(pane.tags == [lab])
    }

    @Test("Edit Tags… opens Settings on the Tags pane")
    func settingsOpensOnTags() throws {
        let tabs = SettingsTabViewController(viewModel: makeViewModel())
        tabs.loadViewIfNeeded()

        tabs.select(.tags)

        #expect(tabs.tabViewItems[tabs.selectedTabViewItemIndex].viewController is TagsSettingsViewController)
    }
}
