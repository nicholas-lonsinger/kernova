import AppKit
import Foundation
import KernovaKit
import KernovaTestSupport
import Testing

@testable import Kernova

/// What the sidebar keeps across a relaunch: its options, its selected row,
/// and which sections are collapsed — and what it never keeps, the search.
///
/// A relaunch is a second view model over the same preferences and library
/// file, its VMs admitted under the identifiers the first one's carried.
@Suite("Sidebar view persistence", .serialized, .caseScoped, .scopedWindows)
@MainActor
struct SidebarViewPersistenceTests {
    private let preferences = makeTestPreferences()
    /// The library file both launches read: smart groups, folders and tags.
    private let organization = VMOrganizationDirectory(fileURL: nil)

    private let macID = UUID()
    private let linuxID = UUID()

    /// One launch: a view model over the shared preferences and library file,
    /// holding a Mac and a Linux VM under the same identifiers every launch.
    private func launch() -> VMLibraryViewModel {
        let viewModel = VMLibraryViewModel(
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
            networks: VMNetworkDirectory(fileURL: nil), organization: organization)
        let (macID, linuxID) = (macID, linuxID)
        viewModel.library.admitFixture(name: "Mac", guestOS: .macOS) { $0.id = macID }
        viewModel.library.admitFixture(name: "Linux", guestOS: .linux) { $0.id = linuxID }
        return viewModel
    }

    /// `viewModel`'s sidebar on screen, its sync pass run.
    private func shownOutline(of viewModel: VMLibraryViewModel) throws -> (SidebarViewController, NSOutlineView) {
        let controller = SidebarViewController(viewModel: viewModel)
        let window = showTestWindow(styleMask: [.titled], contentSize: NSSize(width: 300, height: 600))
        window.contentView = controller.view
        controller.view.layoutSubtreeIfNeeded()
        controller.viewDidAppear()
        return (controller, try #require(firstSubview(NSOutlineView.self, in: controller.view)))
    }

    // MARK: - Options

    @Test("Options edited with no window open are what the next launch starts with")
    func optionsPersistWithoutAWindow() {
        let first = launch()
        first.library.editSidebarOptions(.sort(.name))
        first.library.editSidebarOptions(.grouping(.guestOS))
        first.library.editSidebarOptions(.showsDetails(true))
        first.library.editSidebarOptions(.filter(VMLibraryFilter(guestOSes: [.macOS])))

        let relaunched = launch()

        #expect(
            relaunched.sidebarOptions
                == SidebarViewOptions(
                    filter: VMLibraryFilter(guestOSes: [.macOS]), sort: .name, grouping: .guestOS, showsDetails: true))
        #expect(preferences.sidebarViewOptions == relaunched.sidebarOptions)
    }

    @Test("The search is never kept: the next launch starts with none")
    func searchIsNotPersisted() {
        let first = launch()
        first.library.sidebarSearch = SidebarNameSearch(text: "mac")
        first.library.editSidebarOptions(.sort(.name))

        let relaunched = launch()

        #expect(!relaunched.library.sidebarSearch.isActive)
        #expect(relaunched.sidebarOptions.sort == .name)
    }

    @Test("A filter value the library no longer lists — a deleted tag, a deleted named network — survives a relaunch")
    func staleFilterValuesSurviveRelaunch() throws {
        let first = launch()
        let tag = try first.library.createTag(named: "Work", color: .blue)
        let deletedNetwork = VMLibraryFilter.Network(.vmnet(.nat, .network(UUID()))) { _, _ in true }
        let filter = VMLibraryFilter(networks: [deletedNetwork], tags: [tag.id])
        first.library.editSidebarOptions(.filter(filter))
        try first.library.deleteTag(tag.id)
        #expect(first.sidebarOptions.filter == filter)

        let relaunched = launch()
        relaunched.library.restoreSelection()

        #expect(relaunched.sidebarOptions.filter == filter)
        let library = try #require(relaunched.sidebarLayout.sections.last)
        #expect(library.content.isEmpty)
        #expect(library.emptyText == SidebarLayout.noMatchesText)
    }

    // MARK: - Selection

    @Test("A relaunch restores the selected row in its own section, leaving that section collapsed")
    func selectionRestoresIntoACollapsedSection() throws {
        let first = launch()
        let group = try organization.createSmartGroup(named: "Macs", filter: VMLibraryFilter(guestOSes: [.macOS]))
        let row = SidebarRowKey(section: .smartGroup(group.id), group: nil, entryID: macID)
        first.selection = row
        #expect(preferences.sidebarSelection == row)
        preferences.collapsedSidebarSections = [SidebarSectionID.smartGroup(group.id).rawValue]

        let relaunched = launch()
        let (controller, outline) = try shownOutline(of: relaunched)
        relaunched.library.restoreSelection()
        controller.viewDidAppear()

        #expect(relaunched.selection == row)
        let section = try #require(
            (0..<outline.numberOfRows).lazy.compactMap { outline.item(atRow: $0) as? SidebarSection }
                .first { $0.id == .smartGroup(group.id) })
        #expect(!outline.isItemExpanded(section))
        #expect(outline.selectedRow == -1)
        #expect(preferences.collapsedSidebarSections == [SidebarSectionID.smartGroup(group.id).rawValue])
    }

    @Test("A saved row whose section is gone restores to the VM's library row")
    func selectionFallsBackToTheLibraryRow() throws {
        let first = launch()
        let group = try organization.createSmartGroup(named: "Macs", filter: VMLibraryFilter(guestOSes: [.macOS]))
        first.selection = SidebarRowKey(section: .smartGroup(group.id), group: nil, entryID: macID)
        try organization.removeSmartGroup(group.id)

        let relaunched = launch()
        relaunched.library.restoreSelection()

        #expect(relaunched.selection == .library(macID))
    }

    // MARK: - Collapsed sections

    @Test("Deleting a smart group or a folder forgets its collapsed state, and leaves the rest")
    func deleteForgetsCollapsedState() throws {
        let viewModel = launch()
        let group = try organization.createSmartGroup(named: "Macs", filter: VMLibraryFilter(guestOSes: [.macOS]))
        let folder = try viewModel.library.createFolder(named: "Lab")
        let library = SidebarSectionID.library.rawValue
        preferences.collapsedSidebarSections = [
            SidebarSectionID.smartGroup(group.id).rawValue, SidebarSectionID.folder(folder.id).rawValue, library,
        ]

        try viewModel.library.deleteSmartGroup(group.id)
        #expect(preferences.collapsedSidebarSections == [SidebarSectionID.folder(folder.id).rawValue, library])

        try viewModel.library.deleteFolder(folder.id)
        #expect(preferences.collapsedSidebarSections == [library])
    }

    @Test("A collapsed library section stays collapsed across a relaunch")
    func collapsedLibrarySurvivesRelaunch() throws {
        let first = launch()
        let (_, outline) = try shownOutline(of: first)
        let section = try #require(outline.item(atRow: 0) as? SidebarSection)
        outline.collapseItem(section)
        #expect(preferences.collapsedSidebarSections == [SidebarSectionID.library.rawValue])

        let (_, relaunchedOutline) = try shownOutline(of: launch())

        let relaunchedSection = try #require(relaunchedOutline.item(atRow: 0) as? SidebarSection)
        #expect(relaunchedSection.id == .library)
        #expect(!relaunchedOutline.isItemExpanded(relaunchedSection))
    }
}
