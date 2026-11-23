import AppKit
import Foundation
import KernovaCommandModel
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport
@testable import KernovaUI
@testable import KernovaVirtualization

/// The folder membership the library's lifecycle keeps.
@Suite("Sidebar folders", .serialized, .caseScoped, .scopedWindows)
@MainActor
struct SidebarFolderTests {
    private let preferences = makeTestPreferences()

    private func makeViewModel(
        storage: MockVMStorageService = MockVMStorageService(),
        organization: VMOrganizationDirectory = VMOrganizationDirectory(fileURL: nil)
    ) -> VMLibraryViewModel {
        VMLibraryViewModel(
            storageService: storage,
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
            organization: organization,
            hostNotifications: .isolated(),
            hostPasteboard: FakePasteboard(),
            bundleProducts: .testing
        )
    }

    private func names(in section: SidebarLayout.Section) -> [String] {
        guard case .rows(let rows) = section.content else { return [] }
        return rows.entries.map(\.name)
    }

    private func members(of folder: VMFolder, in viewModel: VMLibraryViewModel) -> [UUID]? {
        viewModel.library.organization.folder(withID: folder.id)?.members
    }

    // MARK: - Lifecycle

    /// Kernova sees a VM leave while it runs — an eviction, a delete — and
    /// doesn't when its bundle goes while Kernova is closed; either way the
    /// folders keep it, so how it left never decides whether it rejoins.
    @Test("A VM leaving the library while Kernova runs keeps its folders, and is listed in them again when it returns")
    func leavingKeepsMembership() async throws {
        let viewModel = makeViewModel()
        let a = viewModel.library.admitFixture(name: "A")
        let b = viewModel.library.admitFixture(name: "B")
        let clients = try viewModel.library.createFolder(named: "Clients", members: [a.id, b.id])
        let demo = try viewModel.library.createFolder(named: "Demo", members: [b.id, a.id])

        viewModel.library.evict(a)
        try await viewModel.commandsLeavingEditsOpen.delete(
            .id(b.id), permanently: false, alsoRemoving: [], consent: Consent([.deleteVM]))

        #expect(viewModel.instances.isEmpty)
        #expect(members(of: clients, in: viewModel) == [a.id, b.id])
        #expect(members(of: demo, in: viewModel) == [b.id, a.id])
        let listed = { (folder: VMFolder) in
            viewModel.sidebarLayout.sections.first { $0.id == .folder(folder.id) }.map(self.names(in:))
        }
        #expect(listed(clients) == [])

        viewModel.library.admitFixture(name: "A") { $0.id = a.id }
        #expect(listed(clients) == ["A"])
        #expect(listed(demo) == ["A"])
    }
}
