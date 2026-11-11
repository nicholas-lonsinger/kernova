import AppKit
import Foundation
import KernovaCommandModel
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport
@testable import KernovaUI
@testable import KernovaVirtualization

/// A group header's Start All, Suspend All, Stop All and Restart All: what
/// the menu counts and enables, and what a pick does in the app — one account
/// of what was left undone, and nothing selected or focused.
@Suite("Sidebar group actions", .serialized, .caseScoped)
@MainActor
struct SidebarGroupActionTests {
    private let preferences = makeTestPreferences()

    private func makeViewModel(
        virtualization: MockVirtualizationService = MockVirtualizationService()
    ) -> VMLibraryViewModel {
        VMLibraryViewModel(
            storageService: MockVMStorageService(),
            diskImageService: MockDiskImageService(),
            machineFiles: VMBundleMachineFiles(fileSystem: MockFileSystem(), platform: FakePlatformFiles()),
            virtualizationHost: VirtualizationHost(),
            virtualizationService: virtualization,
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
            organization: VMOrganizationDirectory(fileURL: nil),
            hostNotifications: .isolated(),
            hostPasteboard: FakePasteboard(),
            bundleProducts: .testing
        )
    }

    private func menu() -> SidebarViewMenu {
        SidebarViewMenu(networkTitle: { $0.rawValue }, tags: { [] }, perform: { _ in })
    }

    /// The group action items of `menu`, by title.
    private func actionItems(of menu: NSMenu) -> [NSMenuItem] {
        let titles = VMGroupAction.allCases.map(SidebarViewMenu.groupActionTitle)
        return menu.items.filter { titles.contains($0.title) }
    }

    // MARK: - Menu

    @Test("A smart group's menu places the actions between its filter and Rename, all disabled without counts")
    func smartGroupMenuWithoutCounts() throws {
        let group = VMSmartGroup(id: UUID(), name: "Linux", filter: VMLibraryFilter(guestOSes: [.linux]))
        let built = menu().menu(smartGroup: group, values: [], actionCounts: nil)

        let titles = built.items.map(\.title)
        let start = try #require(titles.firstIndex(of: "Start All"))
        #expect(built.items[start - 1].isSeparatorItem)
        #expect(
            titles[start...].prefix(6) == [
                "Start All", "Suspend All", "Stop All", "Restart All", "", "Rename Smart Group",
            ])
        #expect(actionItems(of: built).allSatisfy { !$0.isEnabled && $0.badge == nil })
    }

    @Test("Picking an action hands its command to the sidebar, naming the group by identifier")
    func pickRunsTheCommand() throws {
        var picked: [SidebarViewMenu.Command] = []
        let viewMenu = SidebarViewMenu(networkTitle: { $0.rawValue }, tags: { [] }, perform: { picked.append($0) })
        let folder = VMFolder(id: UUID(), name: "Lab", members: [])
        let built = viewMenu.menu(folder: folder, actionCounts: [.start: 1, .suspend: 1, .stop: 1, .restart: 1])

        built.performActionForItem(at: try #require(built.items.firstIndex { $0.title == "Stop All" }))
        built.performActionForItem(at: try #require(built.items.firstIndex { $0.title == "Restart All" }))

        let group = VMGroupReference(.folder, named: folder.id.uuidString)
        #expect(picked == [.groupAction(.stop, group), .groupAction(.restart, group)])
    }

    @Test("The sidebar's folder menu reads the counts off the library")
    func sidebarReadsCounts() throws {
        let viewModel = makeViewModel()
        let stopped = viewModel.library.admitFixture(name: "Stopped")
        let running = viewModel.library.admitFixture(name: "Running", phase: .running(sessionID: UUID()))
        let folder = try viewModel.library.createFolder(named: "Lab", members: [stopped.id, running.id])
        let controller = SidebarViewController(viewModel: viewModel)

        let built = try #require(controller.viewMenu(for: .folder(folder.id)))

        #expect(actionItems(of: built).map { $0.badge?.itemCount } == [1, 1, 1, 1])
        #expect(
            viewModel.groupActionCounts(for: VMGroupReference(.folder, named: folder.id.uuidString))
                == [.start: 1, .suspend: 1, .stop: 1, .restart: 1])
    }
}
