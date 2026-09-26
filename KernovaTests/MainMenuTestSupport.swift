import AppKit
import Testing

@testable import Kernova

/// Shared fixtures for the app-level suites: the ``MainMenuController`` ones and
/// every suite that needs a mocked ``VMLibraryViewModel`` to build an app
/// component over.

/// Stands in for `AppDelegate` as the menu's host, answering with one fixed VM.
///
/// The sender is ignored: the `representedObject` rule that makes a sidebar
/// context-menu item name its own row lives with the actions on `AppDelegate`.
@MainActor
final class StubMenuHost: MainMenuHosting {
    var instance: VMInstance?

    init(instance: VMInstance? = nil) {
        self.instance = instance
    }

    func menuCommandTarget(of sender: Any?) -> VMInstance? { instance }
}

@MainActor
func makeLibraryViewModel(
    preferences: AppPreferences,
    usbAccessoryService: (any USBAccessoryProviding)? = nil,
    diskImageService: MockDiskImageService = MockDiskImageService()
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
        vmnetNetworks: MockVmnetNetworkProvider(), arpTable: ScriptedARPTable(), entitlements: .entitled
    )
}

@MainActor
func makeMenuInstance(
    guestOS: VMGuestOS = .macOS, name: String = "Menu VM",
    phase: VMLifecyclePhase = .stopped, mutate: (inout VMConfiguration) -> Void = { _ in }
) -> VMInstance {
    VMInstanceFixture.make(name: name, guestOS: guestOS, phase: phase, mutate: mutate)
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
