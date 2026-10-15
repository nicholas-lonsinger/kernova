import KernovaKit
import AppKit
import Testing

@testable import Kernova

/// Shared fixtures for the app-level suites: the ``MainMenuController`` ones and
/// every suite that needs a mocked ``VMLibraryViewModel`` to build an app
/// component over.

/// The app's window registry over `viewModel`, saving no window frames.
@MainActor
func makeWindowRegistry(_ viewModel: VMLibraryViewModel) -> AppWindowRegistry {
    let autosave = WindowAutosaveScope.unsaved()
    return AppWindowRegistry(
        viewModel: viewModel,
        displayPlacement: VMDisplayPlacementController(viewModel: viewModel, autosaveScope: autosave),
        autosaveScope: autosave)
}

/// A menu controller over `viewModel` whose working window is the library
/// window, shown for it — so the library's selection is the VM its commands
/// act on, whatever window the shared test host has key.
@MainActor
func makeLibraryMenuController(
    _ viewModel: VMLibraryViewModel, hasBundledGuestAgentDisk: Bool = true
) -> MainMenuController {
    let windows = makeWindowRegistry(viewModel)
    windows.showLibrary(bringToFront: false)
    guard let library = windows.libraryWindow else { preconditionFailure("showLibrary made no window") }
    adoptAppWindow(library)
    return MainMenuController(
        viewModel: viewModel, windows: windows, hasBundledGuestAgentDisk: hasBundledGuestAgentDisk,
        frontWindows: { (library, nil) })
}

@MainActor
func makeLibraryViewModel(
    preferences: AppPreferences,
    usbAccessoryService: (any USBAccessoryProviding)? = nil,
    diskImageService: MockDiskImageService = MockDiskImageService(),
    organization: VMOrganizationDirectory = VMOrganizationDirectory(fileURL: nil)
) -> VMLibraryViewModel {
    VMLibraryViewModel(
        storageService: MockVMStorageService(),
        diskImageService: diskImageService,
        virtualizationService: MockVirtualizationService(),
        installService: MockMacOSInstallService(),
        ipswService: MockIPSWService(),
        removableMediaDeviceService: MockRemovableMediaDeviceService(),
        usbAccessoryService: usbAccessoryService,
        fileSystem: MockFileSystem(),
        downloadsDirectory: nil,
        preferences: preferences,
        vmnetNetworks: VmnetNetworkService.scripted(), arpTable: ScriptedARPTable(), entitlements: .entitled,
        organization: organization
    )
}

/// A VM in `viewModel`'s library, selected in its sidebar, so a menu command
/// acts on it while the library window is the working window
/// (``makeLibraryMenuController(_:hasBundledGuestAgentDisk:)``).
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
