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
        #expect(reread.state.listed?.tag(named: "bench")?.id == lab.id)
        #expect(reread.state.listed?.tag(named: work.id.uuidString.lowercased())?.id == work.id)
        #expect(reread.state.listed?.tag(named: "Home") == nil)
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
        #expect(directory.tags?.map(\.id) == [work.id, lab.id])
    }

    @Test("A library file written before tags reads with none, and keeps its groups as a tag is added")
    func fileWithoutTagsReadsWithNone() throws {
        try FileManager.default.createDirectory(at: scratch.url, withIntermediateDirectories: true)
        try Data(#"{"smartGroups":[],"folders":[]}"#.utf8).write(to: fileURL)
        let directory = VMOrganizationDirectory(fileURL: fileURL)
        #expect(directory.state.unreadable == nil)
        #expect(directory.tags == [])

        let work = try directory.createTag(named: "Work", color: .blue)

        #expect(VMOrganizationDirectory(fileURL: fileURL).tags == [work])
    }

    @Test("Deleting a tag keeps a smart group's condition on it, which then lists no VM through it")
    func deletingATagNeverWidensASmartGroup() throws {
        let viewModel = makeViewModel()
        let library = viewModel.library
        let work = try library.createTag(named: "Work", color: .blue)
        library.admitFixture(name: "Tagged", hostState: VMHostState(tags: [work.id]))
        library.admitFixture(name: "Plain")
        let group = try library.organization.createSmartGroup(named: "Work", filter: VMLibraryFilter(tags: [work.id]))
        func listed() -> [String] {
            guard
                case .rows(let rows)? = library.sidebarLayout.sections.first(where: { $0.id == .smartGroup(group.id) })?
                    .content
            else { return [] }
            return rows.entries.map(\.name)
        }
        #expect(listed() == ["Tagged"])

        try library.deleteTag(work.id)

        #expect(library.organization.smartGroup(withID: group.id)?.filter == VMLibraryFilter(tags: [work.id]))
        #expect(listed() == [])
    }

    // MARK: - Assignments

    @Test("An assignment the library does not define shows nowhere and filters as none")
    func undefinedAssignmentsReadAsNone() throws {
        let viewModel = makeViewModel()
        let library = viewModel.library
        let work = try library.createTag(named: "Work", color: .blue)
        let vm = library.admitFixture(name: "A", hostState: VMHostState(tags: [work.id, UUID()]))

        #expect(library.tags(of: vm) == [work])
        #expect(library.sidebarContext.subject(of: .vm(vm))?.tags == [work.id])
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

    @Test(
        "A clone's arrival reads as the clone it becomes, tags, Ephemeral Mode and snapshots"
    )
    func cloneArrivalReadsAsTheClone() async throws {
        for outcome in [CloneOutcome.newMachine, .exactCopy] {
            let storage = MockVMStorageService()
            let viewModel = makeViewModel(storage: storage)
            let library = viewModel.library
            let work = try library.createTag(named: "Work", color: .blue)
            let baseline = VMSnapshot(name: "Baseline", macAddress: nil)
            let original = library.admitFixture(
                name: "Original",
                hostState: VMHostState(
                    ephemeralModeEnabled: true, ephemeralBaselineSnapshotID: baseline.id, tags: [work.id]),
                snapshots: VMSnapshotManifest(snapshots: [baseline]))
            storage.bundles[original.bundleURL] = original.configuration
            storage.hostStates[original.bundleURL] = original.hostState
            viewModel.sidebarOptions.filter = VMLibraryFilter(tags: [work.id])

            viewModel.cloneVM(original, as: outcome)

            let arrival = try #require(library.arrivals.first, "\(outcome)")
            let subject = try #require(library.sidebarContext.subject(of: .arriving(arrival)), "\(outcome)")
            #expect(subject.tags == [work.id], "\(outcome)")
            #expect(subject.isEphemeral == (outcome == .exactCopy), "\(outcome)")
            #expect(subject.hasSnapshots == (outcome == .exactCopy), "\(outcome)")
            // The tag filter lists it, so registering it selects it.
            #expect(viewModel.selectedID == arrival.id, "\(outcome)")
            await viewModel.awaitArrivalsForTesting()
        }
    }

    @Test("An import's arrival reads as its source does: its tags and Ephemeral Mode")
    func importArrivalReadsAsItsSource() async throws {
        let storage = MockVMStorageService()
        let viewModel = makeViewModel(storage: storage)
        let work = try viewModel.library.createTag(named: "Work", color: .blue)
        let source = try scratch.importSource(name: "Arriving")
        var hostState = VMHostState(tags: [work.id])
        hostState.applyEphemeralMode(enabled: true, baseline: nil)
        try VMConfiguration.makeJSONEncoder().encode(hostState)
            .write(to: source.url.appendingPathComponent(VMBundleLayout.hostStateRelativePath))
        viewModel.sidebarOptions.filter = VMLibraryFilter(tags: [work.id])

        #expect(viewModel.importVMs(fromDroppedURLs: [source.url]))

        let arrival = try #require(viewModel.library.arrivals.first)
        let subject = try #require(viewModel.library.sidebarContext.subject(of: .arriving(arrival)))
        #expect(subject.tags == [work.id])
        #expect(subject.isEphemeral)
        // The tag filter lists it, so the import selects it.
        #expect(viewModel.selectedID == arrival.id)
        await viewModel.awaitArrivalsForTesting()
    }

    @Test("An import keeps every assignment, one this library does not define inert")
    func importKeepsAssignments() async throws {
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
        #expect(imported.hostState.tags == [work.id, foreign])
        #expect(viewModel.library.tags(of: imported) == [work])
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

    /// The labels of every accessibility element VoiceOver reaches under
    /// `element`, depth first.
    private func accessibilityLabels(under element: NSAccessibilityProtocol, depth: Int = 4) -> [(
        String, NSAccessibility.Role?
    )] {
        let children = NSAccessibility.unignoredChildren(from: element.accessibilityChildren() ?? [])
            .compactMap { $0 as? NSAccessibilityProtocol }
        return children.flatMap { child in
            (child.accessibilityLabel().map { [($0, child.accessibilityRole())] } ?? [])
                + (depth > 0 ? accessibilityLabels(under: child, depth: depth - 1) : [])
        }
    }

    @Test("A row shows its tags' dots, names them to VoiceOver from inside its cell, and the snap fits them")
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
        func rowLabels() throws -> [(String, NSAccessibility.Role?)] {
            let rowView = try #require(outline.rowView(atRow: row(.library(vm.id), in: outline), makeIfNecessary: true))
            return accessibilityLabels(under: rowView)
        }
        #expect(try !rowLabels().contains { $0.0.hasPrefix("Tags:") })
        let untagged = try #require(controller.widthToFitLongestRow())

        try library.setTag(lab.id, assigned: true, on: vm)
        try library.setTag(work.id, assigned: true, on: vm)
        // The row repaints from its observation loop's apply, already queued.
        await drainMainQueue()
        // Row → cell → the dots, an image VoiceOver reads by its label.
        let tagLabels = try rowLabels().filter { $0.0.hasPrefix("Tags:") }
        #expect(tagLabels.map(\.0) == ["Tags: Work, Lab"])
        #expect(tagLabels.map(\.1) == [.image])

        let tagged = try #require(controller.widthToFitLongestRow())
        #expect(tagged - untagged == Spacing.small + SidebarTagDotsView.width(forCount: 2))
        let dots = try #require(firstSubview(SidebarTagDotsView.self, in: try cell()))
        #expect(dots.tags == [work, lab])
        #expect(!dots.isHidden)
    }

    @Test("A selected row's dots are drawn inside a contrasting ring")
    func selectedRowRingsTheDots() throws {
        let viewModel = makeViewModel()
        let library = viewModel.library
        let work = try library.createTag(named: "Work", color: .blue)
        let vm = library.admitFixture(name: "Tagged", hostState: VMHostState(tags: [work.id]))
        let controller = SidebarViewController(viewModel: viewModel)
        let outline = try shownOutline(of: controller)
        let cell = try #require(
            outline.view(atColumn: 0, row: row(.library(vm.id), in: outline), makeIfNecessary: true)
                as? SidebarVMRowCellView)
        let dots = try #require(firstSubview(SidebarTagDotsView.self, in: cell))
        #expect(dots.ringColor == nil)

        cell.backgroundStyle = .emphasized

        #expect(dots.backgroundStyle == .emphasized)
        #expect(dots.ringColor == .alternateSelectedControlTextColor)
        cell.backgroundStyle = .normal
        #expect(dots.ringColor == nil)
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

    @Test("A tag's item shows the same swatch, opted in to showing, in a VM's Tags menu and the filter's Tags row")
    func tagItemsShareTheSwatch() throws {
        let viewModel = makeViewModel()
        let library = viewModel.library
        let work = try library.createTag(named: "Work", color: .blue)
        let lab = try library.createTag(named: "Lab", color: .green)
        let vm = library.admitFixture(name: "A", hostState: VMHostState(tags: [work.id]))
        let controller = SidebarViewController(viewModel: viewModel)
        controller.loadViewIfNeeded()
        let vmMenu = try #require(controller.buildContextMenu(for: vm).items.first { $0.title == "Tags" }?.submenu)
        let filterMenu = try #require(
            controller.viewMenu(for: .library)?.items.first { $0.title == "Tags" }?.submenu)

        for tag in [work, lab] {
            let fromVM = try #require(vmMenu.items.first { $0.title == tag.name })
            let fromFilter = try #require(filterMenu.items.first { $0.title == tag.name })
            let expected = tag.color.dotImage()
            for item in [fromVM, fromFilter] {
                let image = try #require(item.image, "\(tag.name)")
                #expect(image.size == expected.size, "\(tag.name)")
                #expect(image.accessibilityDescription == tag.color.title, "\(tag.name)")
                #expect(image.tiffRepresentation == expected.tiffRepresentation, "\(tag.name)")
                if #available(macOS 27, *) {
                    #expect(item.preferredImageVisibility == .visible, "\(tag.name)")
                }
            }
        }
        // The swatches tell the colors apart, so the comparison is not vacuous.
        #expect(work.color.dotImage().tiffRepresentation != lab.color.dotImage().tiffRepresentation)
    }

    @Test("The Settings color pop-up lists every color with its swatch, opted in to showing")
    func colorPopUpShowsSwatches() throws {
        let popUp = TagsSettingsViewController.colorPopUp(selecting: .green)
        #expect(popUp.itemArray.map(\.title) == VMTagColor.allCases.map(\.title))
        #expect(popUp.titleOfSelectedItem == VMTagColor.green.title)
        for item in popUp.itemArray {
            let image = try #require(item.image, "\(item.title)")
            #expect(image.accessibilityDescription == item.title)
            if #available(macOS 27, *) {
                #expect(item.preferredImageVisibility == .visible, "\(item.title)")
            }
        }
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

    @Test("With no tags, neither the Tags filter row nor Group By ▸ Tag is offered")
    func noTagsOffersNoTagRows() throws {
        let viewModel = makeViewModel()
        viewModel.library.admitFixture(name: "Plain")
        let controller = SidebarViewController(viewModel: viewModel)
        controller.loadViewIfNeeded()

        let menu = try #require(controller.viewMenu(for: .library))
        #expect(!menu.items.contains { $0.title == "Tags" })
        let groupBy = try #require(menu.items.first { $0.title == "Group By" })
        #expect(groupBy.submenu?.items.map(\.title) == ["Guest OS", "State", "Network", "", "None"])
    }

    @Test("A condition on a deleted tag stays listed and checked in the library's and a group's menu")
    func deletedTagConditionShows() throws {
        let viewModel = makeViewModel()
        let library = viewModel.library
        let work = try library.createTag(named: "Work", color: .blue)
        let lab = try library.createTag(named: "Lab", color: .green)
        library.admitFixture(name: "Tagged", hostState: VMHostState(tags: [work.id]))
        let group = try library.organization.createSmartGroup(named: "Work", filter: VMLibraryFilter(tags: [work.id]))
        library.sidebarOptions.filter = VMLibraryFilter(tags: [work.id])
        let controller = SidebarViewController(viewModel: viewModel)
        controller.loadViewIfNeeded()

        try library.deleteTag(work.id)
        try library.deleteTag(lab.id)

        for section in [SidebarSectionID.library, .smartGroup(group.id)] {
            let menu = try #require(controller.viewMenu(for: section))
            let row = try #require(menu.items.first { $0.title == "Tags" }, "\(section)")
            #expect(row.badge?.stringValue == SidebarViewMenu.heldUndefinedTagTitle, "\(section)")
            let submenu = try #require(row.submenu)
            #expect(
                submenu.items.map(\.title) == ["All Tags", "", SidebarViewMenu.heldUndefinedTagTitle], "\(section)")
            #expect(submenu.items.last?.state == .on, "\(section)")
        }
        #expect(
            controller.viewMenu.activeFilterDescription(filter: VMLibraryFilter(tags: [work.id]), values: [])
                == "Tags: \(SidebarViewMenu.heldUndefinedTagTitle)")
        // Picking it clears the condition.
        let libraryRow = try #require(controller.viewMenu(for: .library)?.items.first { $0.title == "Tags" })
        libraryRow.submenu?.performActionForItem(at: 2)
        #expect(viewModel.sidebarOptions.filter == VMLibraryFilter())
        let groupRow = try #require(controller.viewMenu(for: .smartGroup(group.id))?.items.first { $0.title == "Tags" })
        groupRow.submenu?.performActionForItem(at: 2)
        #expect(library.organization.smartGroup(withID: group.id)?.filter == VMLibraryFilter())
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
        let work = try #require(library.tags?.first)
        try library.setTag(work.id, assigned: true, on: vm)
        try pane.rename(work.id, to: "Office")
        try pane.recolor(work.id, to: .purple)

        #expect(library.tags == [VMTag(id: work.id, name: "Office", color: .purple)])
        #expect(pane.tags == library.tags)
        #expect(TagsSettingsViewController.membersText(pane.members(of: try #require(library.tags?.first))) == "Desk")
        #expect(throws: VMOrganizationDirectory.ChangeError.nameTaken("Office", .tag)) {
            try pane.create(name: "office", color: .blue)
        }
    }

    @Test("Deleting a tag takes it off every VM and keeps every filter's condition on it, as its question says")
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
        #expect(pane.smartGroups(filteringOn: work).map(\.id) == [group.id])
        let confirmation = TagsSettingsViewController.deleteConfirmation(
            for: work, members: pane.members(of: work), smartGroups: pane.smartGroups(filteringOn: work),
            delete: {})
        #expect(
            confirmation.message
                == "Deleting it takes it off \u{201C}A\u{201D} and \u{201C}B\u{201D}. The smart group "
                + "\u{201C}Work\u{201D} filters on it; that condition will match no virtual machine.")
        let unused = TagsSettingsViewController.deleteConfirmation(for: lab, members: [], smartGroups: [], delete: {})
        #expect(unused.message == "No virtual machine carries this tag.")

        try pane.delete(work.id)

        #expect(library.tags == [lab])
        #expect(a.hostState.tags == [lab.id])
        #expect(b.hostState.tags.isEmpty)
        #expect(library.organization.smartGroup(withID: group.id)?.filter == VMLibraryFilter(tags: [work.id]))
        #expect(library.sidebarOptions.filter == VMLibraryFilter(tags: [work.id, lab.id]))
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
