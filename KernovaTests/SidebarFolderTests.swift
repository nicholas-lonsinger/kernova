import AppKit
import Foundation
import KernovaKit
import KernovaTestSupport
import Testing

@testable import Kernova

/// Folders as the sidebar lists them: the sections the projection adds, the
/// menus that make and change them, the drags that fill and order them, and
/// the membership the library's lifecycle keeps.
@Suite("Sidebar folders", .serialized, .caseScoped, .scopedWindows)
@MainActor
struct SidebarFolderTests {
    private let preferences = makeTestPreferences()

    private let scratch = TestScratchDirectory(prefix: "SidebarFolderTests")

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

    private func vm(_ name: String, guestOS: VMGuestOS = .linux) -> LibraryEntry {
        .vm(VMInstanceFixture.make(name: name, guestOS: guestOS))
    }

    private func names(in section: SidebarLayout.Section) -> [String] {
        guard case .rows(let rows) = section.content else { return [] }
        return rows.entries.map(\.name)
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

    private func row(of section: SidebarSectionID, in outline: NSOutlineView) -> Int {
        (0..<outline.numberOfRows).first { (outline.item(atRow: $0) as? SidebarSection)?.id == section } ?? -1
    }

    private func inFolder(_ folder: VMFolder, _ entry: UUID) -> SidebarRowKey {
        SidebarRowKey(section: .folder(folder.id), group: nil, entryID: entry)
    }

    private func members(of folder: VMFolder, in viewModel: VMLibraryViewModel) -> [UUID]? {
        viewModel.library.organization.folder(withID: folder.id)?.members
    }

    // MARK: - Drags

    /// The point in the middle of `row`, which AppKit proposes as a drop on it.
    private func middle(of row: Int, in outline: NSOutlineView) -> NSPoint {
        NSPoint(x: 100, y: outline.rect(ofRow: row).midY)
    }

    /// The point just inside `row`'s top edge, which AppKit proposes as the
    /// gap above it.
    private func top(of row: Int, in outline: NSOutlineView) -> NSPoint {
        NSPoint(x: 100, y: outline.rect(ofRow: row).minY + 2)
    }

    /// Drags `items` to `point` through the outline view's own drag
    /// destination, from the outline itself unless `fromFinder`, dropping
    /// them there unless the outline refuses; answers the operation it
    /// offered.
    @discardableResult
    private func drag(
        _ items: [NSPasteboardWriting], to point: NSPoint, in outline: NSOutlineView, fromFinder: Bool = false
    ) -> NSDragOperation {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("sidebar-folder-drop-\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.writeObjects(items)
        let drag = FakeDraggingInfo(
            window: outline.window, location: outline.convert(point, to: nil), pasteboard: pasteboard,
            source: fromFinder ? nil : outline)
        _ = outline.draggingEntered(drag)
        let operation = outline.draggingUpdated(drag)
        guard operation != [] else {
            outline.draggingExited(drag)
            return operation
        }
        #expect(outline.prepareForDragOperation(drag))
        #expect(outline.performDragOperation(drag))
        outline.concludeDragOperation(drag)
        return operation
    }

    /// What the sidebar's own drag source writes for the item at `row`.
    private func writer(
        ofRow row: Int, in outline: NSOutlineView, controller: SidebarViewController
    ) throws -> NSPasteboardWriting {
        let item = try #require(outline.item(atRow: row))
        return try #require(controller.outlineView(outline, pasteboardWriterForItem: item))
    }

    // MARK: - Projection

    @Test("Folder sections sit between the smart groups and the library, each listing its members in its own order")
    func projectsFolderSections() {
        let entries = [vm("Alpha"), vm("Bravo"), vm("Charlie", guestOS: .macOS)]
        let alpha = entries[0].id
        let bravo = entries[1].id
        let charlie = entries[2].id
        let gone = UUID()
        let macs = VMSmartGroup(id: UUID(), name: "Macs", filter: VMLibraryFilter(guestOSes: [.macOS]))
        let clients = VMFolder(id: UUID(), name: "Clients", members: [charlie, gone, alpha])
        let demo = VMFolder(id: UUID(), name: "Demo", members: [charlie])
        let empty = VMFolder(id: UUID(), name: "Empty", members: [])

        let layout = SidebarLayout.project(
            entries: entries, options: SidebarViewOptions(), smartGroups: [macs], folders: [clients, demo, empty],
            context: .testing())

        #expect(
            layout.sections.map(\.id) == [
                .smartGroup(macs.id), .folder(clients.id), .folder(demo.id), .folder(empty.id), .library,
            ])
        #expect(layout.sections.map(\.title) == ["Macs", "Clients", "Demo", "Empty", "Virtual Machines"])
        // The folder's own order under the manual sort; a member the library
        // does not list is not listed.
        #expect(names(in: layout.sections[1]) == ["Charlie", "Alpha"])
        #expect(layout.sections[1].count == .members(2))
        #expect(names(in: layout.sections[3]).isEmpty)
        #expect(layout.sections[3].emptyText == SidebarLayout.emptyFolderText)
        // Charlie is listed in four sections, once in each.
        #expect(
            layout.rowKeys.filter { $0.entryID == charlie }.map(\.section) == [
                .smartGroup(macs.id), .folder(clients.id), .folder(demo.id), .library,
            ])
        #expect(!layout.rowKeys.contains { $0.entryID == bravo && $0.section.folderID != nil })

        let byName = SidebarLayout.project(
            entries: entries, options: SidebarViewOptions(sort: .name), folders: [clients], context: .testing())
        #expect(names(in: byName.sections[0]) == ["Alpha", "Charlie"])

        let tree = SidebarTree()
        _ = tree.update(to: layout)
        #expect((tree.sections[3].children.first as? SidebarPlaceholder)?.text == SidebarLayout.emptyFolderText)
    }

    // MARK: - Membership

    @Test("Add to Folder toggles membership, checked where a folder holds the VM, and a VM can be in several")
    func addToFolderToggles() throws {
        let viewModel = makeViewModel()
        let a = viewModel.library.admitFixture(name: "A")
        let clients = try viewModel.library.createFolder(named: "Clients")
        let demo = try viewModel.library.createFolder(named: "Demo")
        let controller = SidebarViewController(viewModel: viewModel)
        controller.loadViewIfNeeded()
        func submenu() throws -> NSMenu {
            let menu = controller.buildContextMenu(for: a)
            return try #require(menu.items.first { $0.title == "Add to Folder" }?.submenu)
        }

        #expect(try submenu().items.map(\.title) == ["Clients", "Demo", "", "New Folder\u{2026}"])
        #expect(try submenu().items.prefix(2).map(\.state) == [.off, .off])
        try submenu().performActionForItem(at: 0)
        try submenu().performActionForItem(at: 1)

        #expect(members(of: clients, in: viewModel) == [a.id])
        #expect(members(of: demo, in: viewModel) == [a.id])
        #expect(try submenu().items.prefix(2).map(\.state) == [.on, .on])
        #expect(
            viewModel.sidebarLayout.rowKeys.filter { $0.entryID == a.id }.map(\.section) == [
                .folder(clients.id), .folder(demo.id), .library,
            ])

        try submenu().performActionForItem(at: 0)
        #expect(members(of: clients, in: viewModel) == [])
        #expect(members(of: demo, in: viewModel) == [a.id])
    }

    @Test("Remove from Folder is offered on a folder's rows only, and the selection falls back to the library row")
    func removeFromFolder() throws {
        let viewModel = makeViewModel()
        let a = viewModel.library.admitFixture(name: "A")
        let clients = try viewModel.library.createFolder(named: "Clients", members: [a.id])
        let controller = SidebarViewController(viewModel: viewModel)
        let outline = try shownOutline(of: controller)

        let libraryMenu = try #require(controller.contextMenu(forRow: row(.library(a.id), in: outline)))
        #expect(!libraryMenu.items.contains { $0.title == "Remove from Folder" })
        let folderRow = row(inFolder(clients, a.id), in: outline)
        let menu = try #require(controller.contextMenu(forRow: folderRow))
        #expect(viewModel.selection == inFolder(clients, a.id))
        let remove = try #require(menu.items.firstIndex { $0.title == "Remove from Folder" })
        #expect(menu.items[remove - 1].title == "Add to Folder")

        menu.performActionForItem(at: remove)

        #expect(members(of: clients, in: viewModel) == [])
        #expect(viewModel.selection == .library(a.id))
        // The VM is only out of the folder.
        #expect(viewModel.instances.map(\.id) == [a.id])
    }

    @Test("Command-Delete stays Move to Trash on a folder's row")
    func commandDeleteStaysMoveToTrash() throws {
        let viewModel = makeViewModel()
        let a = viewModel.library.admitFixture(name: "A")
        let clients = try viewModel.library.createFolder(named: "Clients", members: [a.id])
        let controller = SidebarViewController(viewModel: viewModel)
        let outline = try shownOutline(of: controller)
        let menu = try #require(controller.contextMenu(forRow: row(inFolder(clients, a.id), in: outline)))

        // No folder item takes a key equivalent, and the sidebar takes no
        // Command-Delete: the menu bar's Move to Trash… gets it, and acts on
        // the selected VM.
        #expect(
            menu.items.filter { ["Add to Folder", "Remove from Folder"].contains($0.title) }
                .allSatisfy { $0.keyEquivalent.isEmpty })
        #expect(menu.items.contains { $0.title == "Move to Trash\u{2026}" && $0.isEnabled })
        let commandDelete = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                windowNumber: outline.window?.windowNumber ?? 0, context: nil, characters: "\u{08}",
                charactersIgnoringModifiers: "\u{08}", isARepeat: false, keyCode: 51))
        #expect(!outline.performKeyEquivalent(with: commandDelete))
        #expect(viewModel.selectedInstance === a)
    }

    // MARK: - Header and menu

    @Test("A folder's header shows its name, its member count and its options button")
    func folderHeader() throws {
        let viewModel = makeViewModel()
        let a = viewModel.library.admitFixture(name: "A")
        let b = viewModel.library.admitFixture(name: "B")
        viewModel.library.admitFixture(name: "C")
        let clients = try viewModel.library.createFolder(named: "Clients", members: [a.id, b.id])
        let controller = SidebarViewController(viewModel: viewModel)
        let outline = try shownOutline(of: controller)
        let header = try #require(
            outline.view(atColumn: 0, row: row(of: .folder(clients.id), in: outline), makeIfNecessary: true)
                as? SidebarGroupHeaderCellView)

        let labels = allSubviews(NSTextField.self, in: header).filter { !$0.isHidden }.map(\.stringValue)
        #expect(labels.contains("Clients"))
        #expect(labels.contains("2"))
        #expect(try #require(header.filterButton).accessibilityLabel() == "Folder Options")

        let menu = try #require(controller.viewMenu(for: .folder(clients.id)))
        #expect(
            menu.items.map(\.title) == [
                "\u{201C}Clients\u{201D} \u{2014} drag VMs here to add them", "Start All", "Suspend All",
                "Stop All", "", "Rename Folder\u{2026}", "Delete Folder",
            ])
        #expect(menu.items[0].isSectionHeader)
        #expect(
            controller.contextMenu(forRow: row(of: .folder(clients.id), in: outline))?.items.map(\.title)
                == menu.items.map(\.title))
    }

    @Test("New Folder… in the library menu names a new, empty folder through a sheet")
    func newFolderFromLibraryMenu() async throws {
        let viewModel = makeViewModel()
        viewModel.library.admitFixture(name: "A")
        let controller = SidebarViewController(viewModel: viewModel)
        let outline = try shownOutline(of: controller)
        let window = try #require(outline.window)
        let menu = try #require(controller.viewMenu(for: .library))
        let item = try #require(menu.items.firstIndex { $0.title == "New Folder\u{2026}" })
        #expect(menu.items[item - 1].title == "Save as Smart Group\u{2026}")
        #expect(menu.items[item].isEnabled)

        menu.performActionForItem(at: item)
        let sheet = try #require(window.attachedSheet)
        let field = try #require(
            sheet.contentView.flatMap { allSubviews(NSTextField.self, in: $0).first(where: \.isEditable) })
        #expect(field.stringValue == "Untitled Folder")
        field.stringValue = "Clients"
        window.endSheet(sheet, returnCode: .alertFirstButtonReturn)

        try await waitUntil { viewModel.library.folders.map(\.name) == ["Clients"] }
        #expect(viewModel.library.folders.first?.members == [])
        try await waitUntil { (outline.item(atRow: 0) as? SidebarSection)?.title == "Clients" }
    }

    @Test("New Folder… under Add to Folder makes a folder holding that VM")
    func newFolderFromRowMenu() async throws {
        let viewModel = makeViewModel()
        let a = viewModel.library.admitFixture(name: "A")
        try viewModel.library.createFolder(named: "Untitled Folder")
        let controller = SidebarViewController(viewModel: viewModel)
        let outline = try shownOutline(of: controller)
        let window = try #require(outline.window)
        let submenu = try #require(
            controller.buildContextMenu(for: a).items.first { $0.title == "Add to Folder" }?.submenu)

        submenu.performActionForItem(at: try #require(submenu.items.firstIndex { $0.title == "New Folder\u{2026}" }))
        let sheet = try #require(window.attachedSheet)
        let field = try #require(
            sheet.contentView.flatMap { allSubviews(NSTextField.self, in: $0).first(where: \.isEditable) })
        #expect(field.stringValue == "Untitled Folder 2")
        window.endSheet(sheet, returnCode: .alertFirstButtonReturn)

        try await waitUntil { viewModel.library.folders.count == 2 }
        #expect(viewModel.library.folders.last?.name == "Untitled Folder 2")
        #expect(viewModel.library.folders.last?.members == [a.id])
    }

    @Test("Rename retitles the folder; Delete asks first, then removes it, keeps its VMs, and moves its selection")
    func renameAndDelete() async throws {
        let viewModel = makeViewModel()
        let a = viewModel.library.admitFixture(name: "A")
        let folder = try viewModel.library.createFolder(named: "Old", members: [a.id])
        viewModel.selection = inFolder(folder, a.id)
        let controller = SidebarViewController(viewModel: viewModel)
        let outline = try shownOutline(of: controller)
        let window = try #require(outline.window)

        try viewModel.library.renameFolder(folder.id, to: "New")
        try await waitUntil { (outline.item(atRow: 0) as? SidebarSection)?.title == "New" }
        #expect(viewModel.selection == inFolder(folder, a.id))

        func pickDelete() throws -> NSWindow {
            let menu = try #require(controller.viewMenu(for: .folder(folder.id)))
            menu.performActionForItem(at: try #require(menu.items.firstIndex { $0.title == "Delete Folder" }))
            return try #require(window.attachedSheet)
        }
        let declined = try pickDelete()
        let texts = allSubviews(NSTextField.self, in: try #require(declined.contentView)).map(\.stringValue)
        #expect(texts.contains("Delete the Folder \u{201C}New\u{201D}?"))
        #expect(texts.contains("\u{201C}New\u{201D} holds 1 VM. Deleting the folder keeps it in the library."))
        window.endSheet(declined, returnCode: .alertSecondButtonReturn)
        try await waitUntil { window.attachedSheet == nil }
        #expect(viewModel.library.folders.map(\.id) == [folder.id])

        window.endSheet(try pickDelete(), returnCode: .alertFirstButtonReturn)
        try await waitUntil { viewModel.library.folders.isEmpty }
        #expect(viewModel.instances.map(\.id) == [a.id])
        #expect(viewModel.selection == .library(a.id))
        try await waitUntil { outline.numberOfRows == 2 }
        #expect(outline.selectedRow == row(.library(a.id), in: outline))
    }

    @Test("Folder names are non-empty and unique among folders ignoring case")
    func folderNamesAreUnique() throws {
        let viewModel = makeViewModel()
        let library = viewModel.library
        let clients = try library.createFolder(named: " Clients ")
        let demo = try library.createFolder(named: "Demo")
        #expect(clients.name == "Clients")

        #expect(throws: VMOrganizationDirectory.ChangeError.nameTaken("Clients", .folder)) {
            try library.createFolder(named: "CLIENTS")
        }
        #expect(throws: VMOrganizationDirectory.ChangeError.nameTaken("Clients", .folder)) {
            try library.renameFolder(demo.id, to: "clients")
        }
        #expect(throws: VMOrganizationDirectory.ChangeError.nameRequired(.folder)) {
            try library.renameFolder(demo.id, to: "  ")
        }
        // A folder's own name, recased, is a rename; a smart group's name is
        // its own kind's.
        try library.renameFolder(clients.id, to: "CLIENTS")
        try library.organization.createSmartGroup(named: "Demo", filter: VMLibraryFilter())
        #expect(library.folders.map(\.name) == ["CLIENTS", "Demo"])
    }

    // MARK: - Drag and drop

    @Test("A row dropped on a folder's header joins the folder, as a copy")
    func dropOnFolderHeaderJoins() throws {
        let viewModel = makeViewModel()
        let a = viewModel.library.admitFixture(name: "A")
        let b = viewModel.library.admitFixture(name: "B")
        let clients = try viewModel.library.createFolder(named: "Clients")
        let controller = SidebarViewController(viewModel: viewModel)
        let outline = try shownOutline(of: controller)

        let operation = drag(
            [try writer(ofRow: row(.library(b.id), in: outline), in: outline, controller: controller)],
            to: middle(of: row(of: .folder(clients.id), in: outline), in: outline), in: outline)

        #expect(operation == .copy)
        #expect(members(of: clients, in: viewModel) == [b.id])
        #expect(viewModel.entries.map(\.id) == [a.id, b.id])
    }

    @Test("A row dropped on another folder's rows joins it and stays in its own")
    func dropOnFolderRowsJoins() throws {
        let viewModel = makeViewModel()
        let a = viewModel.library.admitFixture(name: "A")
        let b = viewModel.library.admitFixture(name: "B")
        let clients = try viewModel.library.createFolder(named: "Clients", members: [a.id])
        let demo = try viewModel.library.createFolder(named: "Demo", members: [b.id])
        let controller = SidebarViewController(viewModel: viewModel)
        let outline = try shownOutline(of: controller)

        let operation = drag(
            [try writer(ofRow: row(inFolder(clients, a.id), in: outline), in: outline, controller: controller)],
            to: middle(of: row(inFolder(demo, b.id), in: outline), in: outline), in: outline)

        #expect(operation == .copy)
        #expect(members(of: demo, in: viewModel) == [b.id, a.id])
        #expect(members(of: clients, in: viewModel) == [a.id])
    }

    @Test("A drop on a smart group is refused, and so is one on a folder already holding the VM")
    func refusedDrops() throws {
        let viewModel = makeViewModel()
        let a = viewModel.library.admitFixture(name: "A")
        let b = viewModel.library.admitFixture(name: "B")
        let everything = try viewModel.library.organization.createSmartGroup(
            named: "Everything", filter: VMLibraryFilter())
        let clients = try viewModel.library.createFolder(named: "Clients", members: [a.id])
        let controller = SidebarViewController(viewModel: viewModel)
        let outline = try shownOutline(of: controller)
        func dragged() throws -> NSPasteboardWriting {
            try writer(ofRow: row(.library(a.id), in: outline), in: outline, controller: controller)
        }

        let group = SidebarRowKey(section: .smartGroup(everything.id), group: nil, entryID: b.id)
        #expect(
            drag(
                [try dragged()], to: middle(of: row(of: .smartGroup(everything.id), in: outline), in: outline),
                in: outline)
                == [])
        #expect(drag([try dragged()], to: middle(of: row(group, in: outline), in: outline), in: outline) == [])
        #expect(
            drag([try dragged()], to: middle(of: row(of: .folder(clients.id), in: outline), in: outline), in: outline)
                == [])
        // Within a smart group, too: it lists by its filter and has no order.
        let inGroup = try writer(
            ofRow: row(SidebarRowKey(section: .smartGroup(everything.id), group: nil, entryID: b.id), in: outline),
            in: outline, controller: controller)
        let first = SidebarRowKey(section: .smartGroup(everything.id), group: nil, entryID: a.id)
        #expect(drag([inGroup], to: top(of: row(first, in: outline), in: outline), in: outline) == [])

        #expect(members(of: clients, in: viewModel) == [a.id])
        #expect(viewModel.entries.map(\.id) == [a.id, b.id])
    }

    @Test("A drag within a folder reorders the folder's own order and leaves the library's")
    func dragWithinFolderReordersIt() throws {
        let viewModel = makeViewModel()
        let a = viewModel.library.admitFixture(name: "A")
        let b = viewModel.library.admitFixture(name: "B")
        let c = viewModel.library.admitFixture(name: "C")
        let clients = try viewModel.library.createFolder(named: "Clients", members: [a.id, b.id, c.id])
        let controller = SidebarViewController(viewModel: viewModel)
        let outline = try shownOutline(of: controller)

        let operation = drag(
            [try writer(ofRow: row(inFolder(clients, c.id), in: outline), in: outline, controller: controller)],
            to: top(of: row(inFolder(clients, a.id), in: outline), in: outline), in: outline)

        #expect(operation == .move)
        #expect(members(of: clients, in: viewModel) == [c.id, a.id, b.id])
        #expect(viewModel.entries.map(\.id) == [a.id, b.id, c.id])
        controller.viewDidAppear()
        let listed = (0..<outline.numberOfRows).compactMap { outline.item(atRow: $0) as? SidebarRow }
            .filter { $0.key.section == .folder(clients.id) }.map(\.key.entryID)
        #expect(listed == [c.id, a.id, b.id])
    }

    @Test("Under a sort other than Manual a row still joins a folder, but reorders nothing")
    func sortedRowsJoinButDoNotReorder() throws {
        let viewModel = makeViewModel()
        let a = viewModel.library.admitFixture(name: "A")
        let b = viewModel.library.admitFixture(name: "B")
        let clients = try viewModel.library.createFolder(named: "Clients", members: [a.id, b.id])
        let demo = try viewModel.library.createFolder(named: "Demo")
        viewModel.sidebarOptions.sort = .name
        let controller = SidebarViewController(viewModel: viewModel)
        let outline = try shownOutline(of: controller)

        let inClients = try writer(
            ofRow: row(inFolder(clients, b.id), in: outline), in: outline, controller: controller)
        #expect(
            drag([inClients], to: top(of: row(inFolder(clients, a.id), in: outline), in: outline), in: outline) == [])
        func inLibrary() throws -> NSPasteboardWriting {
            try writer(ofRow: row(.library(b.id), in: outline), in: outline, controller: controller)
        }
        #expect(drag([try inLibrary()], to: top(of: row(.library(a.id), in: outline), in: outline), in: outline) == [])
        #expect(members(of: clients, in: viewModel) == [a.id, b.id])
        #expect(viewModel.entries.map(\.id) == [a.id, b.id])

        #expect(
            drag([try inLibrary()], to: middle(of: row(of: .folder(demo.id), in: outline), in: outline), in: outline)
                == .copy)
        #expect(members(of: demo, in: viewModel) == [b.id])
    }

    /// AppKit can propose the section above while the pointer is over the
    /// next section's header, or the section below while it is over the last
    /// row above; the pointer decides.
    @Test("At the boundary between two folders, the row under the pointer decides which one a drop joins")
    func boundaryDropFollowsThePointer() throws {
        let viewModel = makeViewModel()
        let a = viewModel.library.admitFixture(name: "A")
        let b = viewModel.library.admitFixture(name: "B")
        let x = viewModel.library.admitFixture(name: "X")
        let y = viewModel.library.admitFixture(name: "Y")
        let first = try viewModel.library.createFolder(named: "First", members: [a.id])
        let second = try viewModel.library.createFolder(named: "Second", members: [b.id])
        let controller = SidebarViewController(viewModel: viewModel)
        let outline = try shownOutline(of: controller)
        let lastOfFirst = row(inFolder(first, a.id), in: outline)
        let secondHeader = row(of: .folder(second.id), in: outline)
        #expect(secondHeader == lastOfFirst + 1)

        let topOfHeader = NSPoint(x: 100, y: outline.rect(ofRow: secondHeader).minY + 1)
        #expect(
            drag(
                [try writer(ofRow: row(.library(x.id), in: outline), in: outline, controller: controller)],
                to: topOfHeader, in: outline) == .copy)
        let bottomOfLastRow = NSPoint(x: 100, y: outline.rect(ofRow: lastOfFirst).maxY - 1)
        #expect(
            drag(
                [try writer(ofRow: row(.library(y.id), in: outline), in: outline, controller: controller)],
                to: bottomOfLastRow, in: outline) == .copy)

        #expect(members(of: second, in: viewModel) == [b.id, x.id])
        #expect(members(of: first, in: viewModel) == [a.id, y.id])
    }

    @Test("Dragging a folder's header reorders the folders, among the folders only")
    func dragReordersFolders() throws {
        let viewModel = makeViewModel()
        viewModel.library.admitFixture(name: "A")
        let group = try viewModel.library.organization.createSmartGroup(named: "Everything", filter: VMLibraryFilter())
        for name in ["X", "Y", "Z"] { try viewModel.library.createFolder(named: name) }
        let controller = SidebarViewController(viewModel: viewModel)
        let outline = try shownOutline(of: controller)
        let z = try #require(viewModel.library.folders.last)
        let dragged = try writer(ofRow: row(of: .folder(z.id), in: outline), in: outline, controller: controller)

        // Above the smart group, it lands at the top of the folders.
        #expect(
            drag([dragged], to: top(of: row(of: .smartGroup(group.id), in: outline), in: outline), in: outline) == .move
        )

        #expect(viewModel.library.folders.map(\.name) == ["Z", "X", "Y"])
        #expect(viewModel.library.smartGroups.map(\.id) == [group.id])
        controller.viewDidAppear()
        let sections = (0..<outline.numberOfRows).compactMap { outline.item(atRow: $0) as? SidebarSection }
        #expect(sections.map(\.title) == ["Everything", "Z", "X", "Y", "Virtual Machines"])
    }

    @Test("A Finder bundle dropped on a folder is imported, then joins it; dropped elsewhere it joins none")
    func finderBundleDroppedOnFolderJoinsIt() async throws {
        let viewModel = makeViewModel()
        let a = viewModel.library.admitFixture(name: "A")
        let clients = try viewModel.library.createFolder(named: "Clients", members: [a.id])
        let controller = SidebarViewController(viewModel: viewModel)
        let outline = try shownOutline(of: controller)
        let dropped = try scratch.importSource(name: "Dropped")
        let elsewhere = try scratch.importSource(name: "Elsewhere")

        #expect(
            drag(
                [dropped.url as NSURL], to: middle(of: row(inFolder(clients, a.id), in: outline), in: outline),
                in: outline, fromFinder: true) == .copy)
        #expect(
            drag(
                [elsewhere.url as NSURL], to: middle(of: row(.library(a.id), in: outline), in: outline),
                in: outline, fromFinder: true) == .copy)
        await viewModel.awaitArrivalsForTesting()

        #expect(Set(viewModel.instances.map(\.id)) == [a.id, dropped.config.id, elsewhere.config.id])
        #expect(members(of: clients, in: viewModel) == [a.id, dropped.config.id])
    }

    // MARK: - Lifecycle

    @Test("A clone joins none of its source's folders")
    func cloneJoinsNoFolder() async throws {
        let storage = MockVMStorageService()
        let viewModel = makeViewModel(storage: storage)
        let original = viewModel.library.admitFixture(name: "Original")
        storage.bundles[original.bundleURL] = original.configuration
        let clients = try viewModel.library.createFolder(named: "Clients", members: [original.id])

        viewModel.cloneVM(original)
        await viewModel.awaitArrivalsForTesting()

        let clone = try #require(viewModel.instances.first { $0.id != original.id })
        #expect(members(of: clients, in: viewModel) == [original.id])
        #expect(!viewModel.sidebarLayout.rowKeys.contains { $0.entryID == clone.id && $0.section.folderID != nil })
    }

    /// A VM trashed while Kernova was closed leaves its identifier in its
    /// folders, unseen; it comes back by an import, or by a load or the
    /// directory watcher adopting its bundle after Finder's Put Back.
    @Test("A VM returning under an identifier its folders still hold is listed in them again, whichever way it returns")
    func returningIdentityRejoinsOnEveryPath() async throws {
        let viewModel = makeViewModel()
        let imported = try scratch.importSource(name: "Imported")
        let putBack = UUID()
        let clients = try viewModel.library.organization.createFolder(
            named: "Clients", members: [imported.config.id, putBack])
        #expect(names(in: try #require(viewModel.sidebarLayout.sections.first)).isEmpty)

        _ = viewModel.importVMs(fromDroppedURLs: [imported.url])
        await viewModel.awaitArrivalsForTesting()
        viewModel.library.admitFixture(name: "Put Back") { $0.id = putBack }

        let folder = try #require(viewModel.sidebarLayout.sections.first)
        #expect(folder.id == .folder(clients.id))
        #expect(names(in: folder) == ["Imported", "Put Back"])
        #expect(members(of: clients, in: viewModel) == [imported.config.id, putBack])
    }

    @Test("A VM leaving the library leaves every folder")
    func evictionPrunesMembership() async throws {
        let viewModel = makeViewModel()
        let a = viewModel.library.admitFixture(name: "A")
        let b = viewModel.library.admitFixture(name: "B")
        let clients = try viewModel.library.createFolder(named: "Clients", members: [a.id, b.id])
        let demo = try viewModel.library.createFolder(named: "Demo", members: [b.id, a.id])

        viewModel.library.evict(a)
        #expect(members(of: clients, in: viewModel) == [b.id])
        #expect(members(of: demo, in: viewModel) == [b.id])

        try await viewModel.commands.delete(
            .id(b.id), permanently: false, alsoRemoving: [], consent: Consent([.deleteVM]))
        #expect(viewModel.instances.isEmpty)
        #expect(members(of: clients, in: viewModel) == [])
        #expect(members(of: demo, in: viewModel) == [])
        #expect(viewModel.library.folders.count == 2)
    }

    @Test("An import that becomes no VM leaves the folder it was dropped into")
    func failedImportLeavesTheFolder() async throws {
        let storage = MockVMStorageService()
        let viewModel = makeViewModel(storage: storage)
        let clients = try viewModel.library.createFolder(named: "Clients")
        let source = try scratch.importSource(name: "Never Copied", onDisk: false)
        storage.bundles[source.url] = source.config

        _ = viewModel.importVMs(fromDroppedURLs: [source.url], intoFolder: clients.id)
        #expect(members(of: clients, in: viewModel) == [source.config.id])
        await viewModel.awaitArrivalsForTesting()

        #expect(viewModel.entries.isEmpty)
        #expect(members(of: clients, in: viewModel) == [])
    }

    // MARK: - Selection

    @Test("A row selected in a folder keeps its section across reloads")
    func selectionKeepsItsFolder() throws {
        let viewModel = makeViewModel()
        let a = viewModel.library.admitFixture(name: "A")
        let clients = try viewModel.library.createFolder(named: "Clients", members: [a.id])
        let controller = SidebarViewController(viewModel: viewModel)
        let outline = try shownOutline(of: controller)
        outline.selectRowIndexes([row(inFolder(clients, a.id), in: outline)], byExtendingSelection: false)
        #expect(viewModel.selection == inFolder(clients, a.id))

        viewModel.library.admitFixture(name: "B")
        controller.viewDidAppear()

        #expect(viewModel.selection == inFolder(clients, a.id))
        #expect(outline.selectedRow == row(inFolder(clients, a.id), in: outline))
    }
}
