import KernovaKit
import AppKit
import Testing

@testable import Kernova
@testable import KernovaCore

/// Shared fixtures for the app-level suites: the ``MainMenuController`` ones and
/// every suite that needs a mocked ``VMLibraryViewModel`` to build an app
/// component over.

/// The app's window registry over `viewModel`, its windows off the desktop
/// and its activation requests going to `presence`.
@MainActor
func makeWindowRegistry(
    _ viewModel: VMLibraryViewModel, presence: TestAppPresence = TestAppPresence()
) -> AppWindowRegistry {
    let stage = WindowStage.offDesktop()
    return AppWindowRegistry(
        viewModel: viewModel,
        displayPlacement: VMDisplayPlacementController(viewModel: viewModel, stage: stage),
        stage: stage, presence: presence)
}

@MainActor
func makeLibraryViewModel(
    preferences: AppPreferences,
    storageService: MockVMStorageService = MockVMStorageService(),
    fileSystem: MockFileSystem = MockFileSystem(),
    usbAccessoryService: (any USBAccessoryProviding)? = nil,
    diskImageService: MockDiskImageService = MockDiskImageService(),
    organization: VMOrganizationDirectory = VMOrganizationDirectory(fileURL: nil)
) -> VMLibraryViewModel {
    VMLibraryViewModel(
        storageService: storageService,
        diskImageService: diskImageService,
        machineFiles: VMBundleMachineFiles(fileSystem: fileSystem, platform: FakePlatformFiles()),
        virtualizationHost: VirtualizationHost(),
        virtualizationService: MockVirtualizationService(),
        installService: MockMacOSInstallService(),
        ipswService: MockIPSWService(),
        localImageInspector: LocalRestoreImageInspector(),
        removableMediaDeviceService: MockRemovableMediaDeviceService(),
        bridgedInterfaces: HostBridgedInterfaceProvider(),
        usbAccessoryService: usbAccessoryService,
        fileSystem: fileSystem,
        downloadsDirectory: nil,
        preferences: preferences,
        vmnetNetworks: VmnetNetworkService.scripted(),
        arpTable: ScriptedARPTable(),
        entitlements: .entitled,
        organization: organization,
        hostNotifications: .isolated(),
        hostPasteboard: FakePasteboard(),
        guestAgent: .testing
    )
}

/// A VM in `viewModel`'s library, selected in its sidebar — the VM the library
/// window shows while it is the working window.
@MainActor
@discardableResult
func makeMenuInstance(
    in viewModel: VMLibraryViewModel,
    guestOS: VMGuestOS = .macOS, name: String = "Menu VM",
    phase: VMLifecyclePhase = .stopped, mutate: (inout VMConfiguration) -> Void = { _ in }
) -> VMInstance {
    let instance = viewModel.library.admitFixture(
        name: name, guestOS: guestOS, phase: phase, mutate: mutate)
    viewModel.library.selection = .library(instance.id)
    return instance
}

/// One menu item carrying `action`, as the menu bar builds it.
@MainActor
func makeMenuItem(_ action: Selector) -> NSMenuItem {
    NSMenuItem(title: "placeholder", action: action, keyEquivalent: "")
}

/// The submenu of the top-level menu titled `title`.
@MainActor
func submenu(titled title: String, in mainMenu: NSMenu) -> NSMenu? {
    mainMenu.items.compactMap(\.submenu).first { $0.title == title }
}
