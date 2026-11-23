import AppKit
import Foundation
import KernovaCommandModel
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport
@testable import KernovaUI
@testable import KernovaVirtualization

/// A smart group's filter across a change to what it names.
@Suite("Sidebar smart groups", .serialized, .caseScoped, .scopedWindows)
@MainActor
struct SidebarSmartGroupTests {
    private let preferences = makeTestPreferences()

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

    private func group(_ name: String, _ filter: VMLibraryFilter) -> VMSmartGroup {
        VMSmartGroup(id: UUID(), name: name, filter: filter)
    }

    private func names(in section: SidebarLayout.Section) -> [String] {
        guard case .rows(let rows) = section.content else { return [] }
        return rows.entries.map(\.name)
    }

    private func row(_ key: SidebarRowKey, in outline: NSOutlineView) -> Int {
        (0..<outline.numberOfRows).first { (outline.item(atRow: $0) as? SidebarRow)?.key == key } ?? -1
    }

    private func row(of section: SidebarSectionID, in outline: NSOutlineView) -> Int {
        (0..<outline.numberOfRows).first { (outline.item(atRow: $0) as? SidebarSection)?.id == section } ?? -1
    }

    // MARK: - Header and menu

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
}
