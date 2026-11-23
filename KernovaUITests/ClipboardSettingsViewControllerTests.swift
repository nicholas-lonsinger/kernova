import AppKit
import Foundation
import KernovaKit
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport
@testable import KernovaUI
@testable import KernovaVirtualization

/// The Clipboard settings pane's paste ceiling, written as the popup selects it.
@Suite("Clipboard Settings Tests", .serialized, .caseScoped)
@MainActor
struct ClipboardSettingsViewControllerTests {
    private let preferences: AppPreferences

    init() {
        self.preferences = makeTestPreferences()
    }

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

    /// Builds the pane and runs the appear-time layout the way
    /// NSTabViewController does at tab-switch time.
    private func makeLaidOutController() -> ClipboardSettingsViewController {
        let controller = ClipboardSettingsViewController(viewModel: makeViewModel())
        _ = controller.view
        controller.refreshContent()
        controller.view.setFrameSize(controller.preferredContentSize)
        controller.view.layoutSubtreeIfNeeded()
        return controller
    }

    private func popUp(in controller: ClipboardSettingsViewController) throws -> NSPopUpButton {
        try #require(findPopUpButton(in: controller.view))
    }

    // MARK: - The ladder

    @Test("selecting a ceiling writes it to preferences")
    func selectingWritesThePreference() throws {
        let controller = makeLaidOutController()
        let popUp = try popUp(in: controller)

        let lowered = 512 * 1024 * 1024
        popUp.selectItem(at: try #require(ClipboardPasteLimit.choices.firstIndex(of: lowered)))
        popUp.sendAction(popUp.action, to: popUp.target)

        #expect(preferences.clipboardMaxPasteBytes == lowered)
    }
}

/// Searches the view subtree depth-first for its first pop-up button.
@MainActor
private func findPopUpButton(in root: NSView) -> NSPopUpButton? {
    if let popUp = root as? NSPopUpButton { return popUp }
    for subview in root.subviews {
        if let found = findPopUpButton(in: subview) { return found }
    }
    return nil
}
