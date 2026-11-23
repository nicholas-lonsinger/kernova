import AVFoundation
import AppKit
import KernovaCommandModel
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport
@testable import KernovaUI
@testable import KernovaVirtualization

/// Shared fixtures and view-tree lookups for the settings pane's suites — the
/// shell's own and the six per-panel ones.

/// The library the pane reads through, entitlements included.
/// `vmnetNetworks`, `arpTable` and `entitled` reach the guest-address observer,
/// which is what answers every surface's IP address row.
@MainActor
func makeSettingsViewModel(
    preferences: AppPreferences,
    storage: MockVMStorageService = MockVMStorageService(),
    vmnetNetworks: VmnetNetworkService = .scripted(),
    arpTable: ScriptedARPTable = ScriptedARPTable(),
    entitled: Bool = true,
    machineFiles: (any VMBundleMachineFileWorking)? = nil,
    networks: VMNetworkDirectory = VMNetworkDirectory(fileURL: nil),
    hostNotifications: HostNotifications = .isolated()
) -> VMLibraryViewModel {
    VMLibraryViewModel(
        storageService: storage,
        diskImageService: MockDiskImageService(),
        machineFiles: machineFiles ?? VMBundleMachineFiles(fileSystem: MockFileSystem(), platform: FakePlatformFiles()),
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
        vmnetNetworks: vmnetNetworks,
        arpTable: arpTable,
        entitlements: entitled ? .entitled : .unentitled,
        networks: networks,
        hostNotifications: hostNotifications,
        hostPasteboard: FakePasteboard(),
        bundleProducts: .testing
    )
}

/// The test target's one construction site for the settings pane, which is what
/// keeps every fixture off the app-wide activation center.
///
/// `NSApplication.didBecomeActiveNotification` is posted process-wide, and a
/// pane subscribes to it in `viewDidAppear()` — which every fixture runs, while
/// almost none run the `viewWillDisappear()` that unsubscribes. Defaulting to a
/// fresh center per pane means an activation of the test host reaches no
/// controller a suite is still holding. A test that drives activation itself
/// passes a center it holds.
@MainActor
func makeSettingsPane(
    instance: VMInstance,
    viewModel: VMLibraryViewModel,
    isReadOnly: Bool,
    bridgedInterfaces: any BridgedInterfaceProviding = HostBridgedInterfaceProvider(),
    micPermissionStatus: @escaping @MainActor () -> AVAuthorizationStatus = {
        AVCaptureDevice.authorizationStatus(for: .audio)
    },
    systemSettings: SystemSettingsLink = SystemSettingsLink()
) -> VMSettingsViewController {
    VMSettingsViewController(
        instance: instance, viewModel: viewModel, isReadOnly: isReadOnly,
        bridgedInterfaces: bridgedInterfaces,
        micPermissionStatus: micPermissionStatus, systemSettings: systemSettings)
}

/// Builds the settings pane and runs its appearance lifecycle so `apply()` has
/// populated control values and enabled state.
///
/// `category` opens that panel, which is what puts its rows on screen — the
/// pane starts on the overview, where every panel is hidden.
/// `holdsSavedState` puts a suspend slot in the VM's bundle before the pane is
/// built, which is what pins the settings a saved state pins.
@MainActor
func makeSettingsController(
    guestOS: VMGuestOS, isReadOnly: Bool, category: VMSettingsCategory? = nil,
    phase: VMLifecyclePhase = .stopped, holdsSavedState: Bool = false,
    preferences: AppPreferences
) -> (VMSettingsViewController, VMInstance, VMLibraryViewModel) {
    let viewModel = makeSettingsViewModel(preferences: preferences)
    // In the library, which is what lets the command verbs a panel's controls
    // call resolve it by id.
    let instance = viewModel.library.registerFixture(guestOS: guestOS, phase: phase)
    if holdsSavedState { try? VMInstanceFixture.writeSaveFile(for: instance) }
    let vc = makeSettingsPane(
        instance: instance, viewModel: viewModel, isReadOnly: isReadOnly)
    vc.loadViewIfNeeded()
    vc.viewDidAppear()
    if let category { vc.showCategory(category) }
    return (vc, instance, viewModel)
}

// MARK: - View-tree lookups

@MainActor
func firstSwitch(action name: String, in view: NSView) -> NSSwitch? {
    firstSubview(NSSwitch.self, in: view) { $0.action.map(NSStringFromSelector) == name }
}

/// The form holds several popups, so each is found by the action it sends
/// rather than by position in the view tree.
@MainActor
func firstPopUp(action name: String, in view: NSView) -> NSPopUpButton? {
    firstSubview(NSPopUpButton.self, in: view) { $0.action.map(NSStringFromSelector) == name }
}

/// The grouped-form row whose leading label reads `label`: the
/// ``GroupedFormControlRow`` titled `label`, or else the stack holding that
/// label directly.
@MainActor
func settingsRow(labeled label: String, in view: NSView) -> NSView? {
    firstSubview(GroupedFormControlRow.self, in: view) { $0.titleLabel.stringValue == label }
        ?? firstSubview(NSStackView.self, in: view) { stack in
            stack.arrangedSubviews.contains { ($0 as? NSTextField)?.stringValue == label }
        }
}

/// Whether `view` shows a label reading `text`: one neither hidden itself nor
/// under a hidden ancestor.
@MainActor
func visibleLabel(_ text: String, in view: NSView) -> Bool {
    firstSubview(NSTextField.self, in: view) {
        $0.stringValue == text && isVisible($0, within: view)
    } != nil
}

/// The editable field in the grouped-form card row titled `label`, however
/// deeply the row nests it (the MAC row pairs its field with a button).
@MainActor
func editableField(_ label: String, in view: NSView) -> NSTextField? {
    guard let row = settingsRow(labeled: label, in: view) else { return nil }
    return findEditableField(in: row)
}
