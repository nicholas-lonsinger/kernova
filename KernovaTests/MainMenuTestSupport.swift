import AppKit
import Testing

@testable import Kernova

/// Shared fixtures for the ``MainMenuController`` suites — the validation one
/// and the rebuild one.
///
/// Each suite passes its own `suiteName` for preferences: a defaults domain
/// shared across suites running in parallel is a flake source.

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
func makeMenuViewModel(preferences: AppPreferences) -> VMLibraryViewModel {
    VMLibraryViewModel(
        storageService: MockVMStorageService(),
        diskImageService: MockDiskImageService(),
        virtualizationService: MockVirtualizationService(),
        installService: MockMacOSInstallService(),
        ipswService: MockIPSWService(),
        usbDeviceService: MockUSBDeviceService(),
        preferences: preferences
    )
}

@MainActor
func makeMenuInstance(
    guestOS: VMGuestOS = .macOS, name: String = "Menu VM",
    phase: VMLifecyclePhase = .stopped
) -> VMInstance {
    let config = VMConfiguration(
        name: name, guestOS: guestOS, bootMode: guestOS == .macOS ? .macOS : .efi)
    let bundleURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(config.id.uuidString, isDirectory: true)
    return VMInstance(configuration: config, bundleURL: bundleURL, phase: phase)
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
