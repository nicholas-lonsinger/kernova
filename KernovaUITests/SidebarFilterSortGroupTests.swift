import AppKit
import Foundation
import KernovaCommandModel
import KernovaTestSupport
import Synchronization
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport
@testable import KernovaUI
@testable import KernovaVirtualization

/// The state bucket the library's grouping and the Shortcuts entity read.
@Suite("Sidebar filter, sort and group", .serialized, .caseScoped, .scopedWindows)
@MainActor
struct SidebarFilterSortGroupTests {
    private let preferences = makeTestPreferences()

    private func makeViewModel() -> VMLibraryViewModel {
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
            hostNotifications: .isolated(),
            hostPasteboard: FakePasteboard(),
            bundleProducts: .testing
        )
    }

    // MARK: - Sidebar

    @Test("VMInfo reports the state bucket by liveness, and the Shortcuts entity reads it")
    func infoCarriesStateBucket() throws {
        let viewModel = makeViewModel()
        let capturing = viewModel.library.admitFixture(name: "Capturing", phase: .stopped)
        capturing.activity.placeForTesting(.operating(.capturingSnapshot(.stopped), from: .stopped))

        let info = try viewModel.commandsLeavingEditsOpen.info(.id(capturing.id))

        #expect(info.status == VMStatus.snapshotting.rawValue)
        #expect(info.stateBucket == .stopped)
        #expect(VMEntity(info).stateGroup == "stopped")
    }
}
