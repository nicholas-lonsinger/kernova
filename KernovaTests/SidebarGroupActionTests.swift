import AppKit
import Foundation
import KernovaKit
import KernovaTestSupport
import Testing

@testable import Kernova

/// A group header's Start All, Suspend All and Stop All: what the menu counts
/// and enables, and what a pick does in the app — one account of what was
/// left undone, and nothing selected or focused.
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
            virtualizationService: virtualization,
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

    private func menu() -> SidebarViewMenu {
        SidebarViewMenu(networkTitle: { $0.rawValue }, tags: { [] }, perform: { _ in })
    }

    /// The three group action items of `menu`, by title.
    private func actionItems(of menu: NSMenu) -> [NSMenuItem] {
        let titles = VMGroupAction.allCases.map(SidebarViewMenu.groupActionTitle)
        return menu.items.filter { titles.contains($0.title) }
    }

    // MARK: - Menu

    @Test("A folder's menu counts what each action acts on, badged, and disables an action with none")
    func folderMenuCountsAndEnables() throws {
        let folder = VMFolder(id: UUID(), name: "Lab", members: [])
        let built = menu().menu(folder: folder, actionCounts: [.start: 2, .suspend: 1, .stop: 0])

        let items = actionItems(of: built)
        #expect(items.map(\.title) == ["Start All", "Suspend All", "Stop All"])
        #expect(items.map(\.isEnabled) == [true, true, false])
        #expect(items.map { $0.badge?.itemCount } == [2, 1, nil])
        #expect(built.items[1].title == "Start All")
        #expect(built.items[4].isSeparatorItem)
    }

    @Test("A smart group's menu places the actions between its filter and Rename, all disabled without counts")
    func smartGroupMenuWithoutCounts() throws {
        let group = VMSmartGroup(id: UUID(), name: "Linux", filter: VMLibraryFilter(guestOSes: [.linux]))
        let built = menu().menu(smartGroup: group, values: [], actionCounts: nil)

        let titles = built.items.map(\.title)
        let start = try #require(titles.firstIndex(of: "Start All"))
        #expect(built.items[start - 1].isSeparatorItem)
        #expect(
            titles[start...].prefix(5) == ["Start All", "Suspend All", "Stop All", "", "Rename Smart Group\u{2026}"])
        #expect(actionItems(of: built).allSatisfy { !$0.isEnabled && $0.badge == nil })
    }

    @Test("Picking an action hands its command to the sidebar, naming the group by identifier")
    func pickRunsTheCommand() throws {
        var picked: [SidebarViewMenu.Command] = []
        let viewMenu = SidebarViewMenu(networkTitle: { $0.rawValue }, tags: { [] }, perform: { picked.append($0) })
        let folder = VMFolder(id: UUID(), name: "Lab", members: [])
        let built = viewMenu.menu(folder: folder, actionCounts: [.start: 1, .suspend: 1, .stop: 1])

        built.performActionForItem(at: try #require(built.items.firstIndex { $0.title == "Stop All" }))

        #expect(picked == [.groupAction(.stop, VMGroupReference(.folder, named: folder.id.uuidString))])
    }

    @Test("The sidebar's folder menu reads the counts off the library")
    func sidebarReadsCounts() throws {
        let viewModel = makeViewModel()
        let stopped = viewModel.library.admitFixture(name: "Stopped")
        let running = viewModel.library.admitFixture(name: "Running", phase: .running(sessionID: UUID()))
        let folder = try viewModel.library.createFolder(named: "Lab", members: [stopped.id, running.id])
        let controller = SidebarViewController(viewModel: viewModel)

        let built = try #require(controller.viewMenu(for: .folder(folder.id)))

        #expect(actionItems(of: built).map { $0.badge?.itemCount } == [1, 1, 1])
        #expect(
            viewModel.groupActionCounts(for: VMGroupReference(.folder, named: folder.id.uuidString))
                == [.start: 1, .suspend: 1, .stop: 1])
    }

    // MARK: - Performing

    @Test("A group start in the app selects nothing, focuses no display, and says nothing when all is done")
    func groupStartMovesNothing() async throws {
        let viewModel = makeViewModel()
        let presenter = MockVMLibraryPresenting()
        viewModel.presenter = presenter
        let a = viewModel.library.admitFixture(name: "A")
        let b = viewModel.library.admitFixture(name: "B")
        let folder = try viewModel.library.createFolder(named: "Lab", members: [a.id, b.id])
        let selection = viewModel.selection

        await viewModel.performGroupAction(.start, on: VMGroupReference(.folder, named: folder.id.uuidString))

        #expect(a.status == .running && b.status == .running)
        #expect(viewModel.selection == selection)
        #expect(presenter.focusGuestDisplayInstances.isEmpty)
        #expect(presenter.errors.isEmpty)
    }

    @Test("Whatever a group action leaves undone is one alert naming each VM")
    func undoneIsOneSummary() async throws {
        let virtualization = MockVirtualizationService()
        let viewModel = makeViewModel(virtualization: virtualization)
        let presenter = MockVMLibraryPresenting()
        viewModel.presenter = presenter
        let a = viewModel.library.admitFixture(name: "A")
        let b = viewModel.library.admitFixture(name: "B")
        let c = viewModel.library.admitFixture(name: "C")
        virtualization.startErrors[a.id] = VirtualizationError.noVirtualMachine
        virtualization.startErrors[c.id] = VirtualizationError.noVirtualMachine
        try viewModel.library.createFolder(named: "Lab", members: [a.id, b.id, c.id])

        await viewModel.performGroupAction(.start, on: VMGroupReference(.folder, named: "Lab"))

        #expect(b.status == .running)
        #expect(presenter.errorTitles == ["Couldn\u{2019}t Start Every VM in \u{201C}Lab\u{201D}"])
        let lines = try #require(presenter.errors.first).split(separator: "\n")
        #expect(lines.count == 2)
        #expect(lines[0].hasPrefix("Couldn\u{2019}t start A: "))
        #expect(lines[1].hasPrefix("Couldn\u{2019}t start C: "))
    }

    @Test("A group the library no longer lists is one refusal, and nothing is acted on")
    func unknownGroupIsRefused() async throws {
        let virtualization = MockVirtualizationService()
        let viewModel = makeViewModel(virtualization: virtualization)
        let presenter = MockVMLibraryPresenting()
        viewModel.presenter = presenter
        viewModel.library.admitFixture(name: "A")

        await viewModel.performGroupAction(.start, on: VMGroupReference(.folder, named: UUID().uuidString))

        #expect(presenter.errors.count == 1)
        #expect(virtualization.startCallCount == 0)
    }
}
