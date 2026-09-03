import AppKit
import Testing

@testable import Kernova

/// Shared fixtures and view-tree lookups for the settings pane's suites — the
/// shell's own and the six per-panel ones.
///
/// Each suite passes its own `suiteName` for preferences: a defaults domain
/// shared across suites running in parallel is a flake source.

/// The library the pane reads through. `vmnetNetworks` and `entitled` reach the
/// slot registry, which is what answers every surface's IP address row.
@MainActor
func makeSettingsViewModel(
    preferences: AppPreferences,
    vmnetNetworks: MockVmnetNetworkProvider = MockVmnetNetworkProvider(),
    entitled: Bool = true
) -> VMLibraryViewModel {
    VMLibraryViewModel(
        storageService: MockVMStorageService(),
        diskImageService: MockDiskImageService(),
        virtualizationService: MockVirtualizationService(),
        installService: MockMacOSInstallService(),
        ipswService: MockIPSWService(),
        usbDeviceService: MockUSBDeviceService(),
        preferences: preferences,
        vmnetNetworks: vmnetNetworks,
        isVMNetworkingEntitled: entitled
    )
}

@MainActor
func makeSettingsInstance(guestOS: VMGuestOS, phase: VMLifecyclePhase = .stopped) -> VMInstance {
    let config = VMConfiguration(
        name: "Test VM", guestOS: guestOS, bootMode: guestOS == .macOS ? .macOS : .efi)
    let bundleURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(config.id.uuidString, isDirectory: true)
    return VMInstance(configuration: config, bundleURL: bundleURL, phase: phase)
}

/// Puts `instance` in the view model's library, which is what lets the command
/// verbs a panel's controls call resolve it by id.
@MainActor
func registerSettingsInstance(_ instance: VMInstance, in viewModel: VMLibraryViewModel) {
    (viewModel.storageService as? MockVMStorageService)?.bundles[instance.bundleURL] =
        instance.configuration
    viewModel.library.wirePersistence(for: instance)
    viewModel.library.instances.append(instance)
}

/// Builds the settings pane and runs its appearance lifecycle so `apply()` has
/// populated control values and enabled state.
///
/// `category` opens that panel, which is what puts its rows on screen — the
/// pane starts on the overview, where every panel is hidden.
@MainActor
func makeSettingsController(
    guestOS: VMGuestOS, isReadOnly: Bool, category: VMSettingsCategory? = nil,
    phase: VMLifecyclePhase = .stopped, preferences: AppPreferences
) -> (VMSettingsViewController, VMInstance, VMLibraryViewModel) {
    let viewModel = makeSettingsViewModel(preferences: preferences)
    let instance = makeSettingsInstance(guestOS: guestOS, phase: phase)
    let vc = VMSettingsViewController(
        instance: instance, viewModel: viewModel, isReadOnly: isReadOnly)
    vc.loadViewIfNeeded()
    vc.viewDidAppear()
    if let category { vc.showCategory(category) }
    return (vc, instance, viewModel)
}

// MARK: - View-tree lookups

@MainActor
func settingsNetworkModePopUp(in view: NSView) -> NSPopUpButton? {
    firstSubview(NSPopUpButton.self, in: view) {
        $0.action.map(NSStringFromSelector) == "networkModeChanged"
    }
}

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

@MainActor
func settingsLockHints(in view: NSView) -> [NSView] {
    allSubviews(NSStackView.self, in: view) { $0.toolTip == groupedFormLockHintText }
}

/// An overview card's scoped lock hint, found by the claim it carries.
@MainActor
func cardLockHint(_ category: VMSettingsCategory, in card: NSView) -> NSView? {
    guard let hint = category.lockHint else { return nil }
    return firstSubview(NSStackView.self, in: card) { $0.toolTip == hint }
}

/// The lock hints on the pinned header, which is where a single-section
/// category's hint lives while that category is open.
@MainActor
func panelHeaderLockHints(in vc: VMSettingsViewController) -> [NSView] {
    guard let header = firstSubview(VMIdentityHeaderView.self, in: vc.view) else { return [] }
    return settingsLockHints(in: header)
}

/// The grouped-form row whose leading label reads `label`.
@MainActor
func settingsRow(labeled label: String, in view: NSView) -> NSView? {
    firstSubview(NSStackView.self, in: view) { stack in
        stack.arrangedSubviews.contains { ($0 as? NSTextField)?.stringValue == label }
    }
}

@MainActor
func containsLabel(_ text: String, in view: NSView) -> Bool {
    findLabel(withText: text, in: view) != nil
}

/// Like ``containsLabel(_:in:)``, but only counts a label that is actually
/// shown (no hidden label or hidden ancestor).
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

/// Ends editing through the field's own delegate, so the assertion covers the
/// wiring as well as the commit.
@MainActor
func commitEdit(_ field: NSTextField) {
    field.delegate?.controlTextDidEndEditing?(Notification(name: .init("test"), object: field))
}
