import AppKit
import Testing

@testable import Kernova

@Suite("VMSettingsViewController Tests")
@MainActor
struct VMSettingsViewControllerTests {
    // MARK: - Fixtures

    /// Isolated, pre-cleaned preferences for this suite's `VMLibraryViewModel`.
    ///
    /// Selection/order persistence never touches the real `.standard` domain.
    private let preferences = makeEphemeralPreferences(suiteName: "test.kernova.vmsettings")

    private func makeViewModel() -> VMLibraryViewModel {
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

    private func makeInstance(guestOS: VMGuestOS) -> VMInstance {
        let config = VMConfiguration(
            name: "Test VM", guestOS: guestOS, bootMode: guestOS == .macOS ? .macOS : .efi)
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(config.id.uuidString, isDirectory: true)
        return VMInstance(configuration: config, bundleURL: bundleURL)
    }

    /// Builds the controller and runs its appearance lifecycle so `apply()` has
    /// populated control values and enabled state.
    private func makeController(guestOS: VMGuestOS, isReadOnly: Bool) -> (
        VMSettingsViewController, VMInstance, VMLibraryViewModel
    ) {
        let viewModel = makeViewModel()
        let instance = makeInstance(guestOS: guestOS)
        let vc = VMSettingsViewController(
            instance: instance, viewModel: viewModel, isReadOnly: isReadOnly)
        vc.loadViewIfNeeded()
        vc.viewDidAppear()
        return (vc, instance, viewModel)
    }

    // MARK: - Per-row delete confirmation prompt

    @Test("Internal disk delete offers Move-to-Trash only (no keep-file)")
    func deletePromptInternalDisk() {
        let prompt = VMSettingsViewController.attachmentDeletePrompt(
            label: "Extra Disk", isInternal: true, isMainDisk: false,
            isGuestAgent: false, sharedVMNames: [])
        #expect(prompt.actions == [.moveToTrash])
        #expect(prompt.title.contains("Extra Disk"))
    }

    @Test("Main disk delete warns it's the startup disk")
    func deletePromptMainDisk() {
        let prompt = VMSettingsViewController.attachmentDeletePrompt(
            label: "Main Disk", isInternal: true, isMainDisk: true,
            isGuestAgent: false, sharedVMNames: [])
        #expect(prompt.actions == [.moveToTrash])
        #expect(prompt.message.contains("startup disk"))
    }

    @Test("Private external delete offers both Move-to-Trash and Remove-from-VM")
    func deletePromptPrivateExternal() {
        let prompt = VMSettingsViewController.attachmentDeletePrompt(
            label: "Scratch", isInternal: false, isMainDisk: false,
            isGuestAgent: false, sharedVMNames: [])
        #expect(prompt.actions == [.moveToTrash, .removeFromVM])
    }

    @Test("Shared external delete hard-blocks trashing (Remove-from-VM only) and names the VMs")
    func deletePromptSharedExternal() {
        let prompt = VMSettingsViewController.attachmentDeletePrompt(
            label: "Installer", isInternal: false, isMainDisk: false,
            isGuestAgent: false, sharedVMNames: ["macOS Copy", "Linux"])
        #expect(prompt.actions == [.removeFromVM])
        #expect(prompt.message.contains("macOS Copy"))
        #expect(prompt.message.contains("Linux"))
    }

    @Test("Guest Agent delete only detaches and says the installer isn't deleted")
    func deletePromptGuestAgent() {
        let prompt = VMSettingsViewController.attachmentDeletePrompt(
            label: "Kernova Guest Agent", isInternal: false, isMainDisk: false,
            isGuestAgent: true, sharedVMNames: [])
        #expect(prompt.actions == [.removeFromVM])
        #expect(prompt.message.contains("isn't deleted"))
    }

    // MARK: - Guest Agent visibility

    @Test("Guest Agent section is present for macOS guests")
    func guestAgentPresentForMacOS() {
        let (vc, _, _) = makeController(guestOS: .macOS, isReadOnly: false)
        #expect(containsLabel("Forward guest logs", in: vc.view))
    }

    @Test("Guest Agent section is absent for Linux guests")
    func guestAgentAbsentForLinux() {
        let (vc, _, _) = makeController(guestOS: .linux, isReadOnly: false)
        #expect(!containsLabel("Forward guest logs", in: vc.view))
    }

    // MARK: - Agent-dependent grouping (#398)

    @Test("Clipboard Sharing nests in the agent group on macOS, standalone on Linux")
    func clipboardGroupingByGuestOS() {
        // macOS: the row is nested in the Guest Agent group, with no standalone
        // "Clipboard" section header (guards against re-adding the sibling section).
        let (macVC, _, _) = makeController(guestOS: .macOS, isReadOnly: false)
        #expect(containsLabel("Clipboard Sharing", in: macVC.view))
        #expect(!containsLabel("Clipboard", in: macVC.view))

        // Linux: SPICE clipboard keeps its own standalone section header.
        let (linuxVC, _, _) = makeController(guestOS: .linux, isReadOnly: false)
        #expect(containsLabel("Clipboard Sharing", in: linuxVC.view))
        #expect(containsLabel("Clipboard", in: linuxVC.view))
    }

    @Test("Agent-dependency caption appears for macOS but not Linux")
    func agentDependencyCaptionMacOSOnly() {
        let caption = VMSettingsViewController.agentDependencyCaption

        let (macVC, _, _) = makeController(guestOS: .macOS, isReadOnly: false)
        #expect(containsLabel(caption, in: macVC.view))

        // Linux clipboard is SPICE-based, so the agent-dependency cue must not appear.
        let (linuxVC, _, _) = makeController(guestOS: .linux, isReadOnly: false)
        #expect(!containsLabel(caption, in: linuxVC.view))
    }

    // MARK: - Read-only lock behavior

    @Test("Read-only disables lockable controls but not hot-toggleable ones")
    func readOnlyDisablesLockableControls() {
        let (vc, _, _) = makeController(guestOS: .macOS, isReadOnly: true)

        // Networking is lockable → disabled while read-only.
        let network = firstSwitch(action: "networkToggled", in: vc.view)
        #expect(network?.isEnabled == false)

        // Clipboard is hot-toggleable → stays enabled.
        let clipboard = firstSwitch(action: "clipboardToggled", in: vc.view)
        #expect(clipboard?.isEnabled == true)
    }

    @Test("Lockable controls are enabled when editable")
    func editableEnablesLockableControls() {
        let (vc, _, _) = makeController(guestOS: .macOS, isReadOnly: false)
        let network = firstSwitch(action: "networkToggled", in: vc.view)
        #expect(network?.isEnabled == true)
    }

    @Test("Lock icons are visible only while read-only")
    func lockIconsVisibilityTracksReadOnly() {
        let (readOnlyVC, _, _) = makeController(guestOS: .macOS, isReadOnly: true)
        let shownIcons = lockIcons(in: readOnlyVC.view)
        #expect(!shownIcons.isEmpty)
        #expect(shownIcons.allSatisfy { !$0.isHidden })

        let (editableVC, _, _) = makeController(guestOS: .macOS, isReadOnly: false)
        let hiddenIcons = lockIcons(in: editableVC.view)
        #expect(!hiddenIcons.isEmpty)
        #expect(hiddenIcons.allSatisfy { $0.isHidden })
    }

    // MARK: - Config write-back

    @Test("Toggling Clipboard Sharing writes back to the configuration")
    func clipboardToggleWritesConfig() {
        let (vc, instance, _) = makeController(guestOS: .linux, isReadOnly: false)
        #expect(instance.configuration.clipboardSharingEnabled == false)

        guard let clipboard = firstSwitch(action: "clipboardToggled", in: vc.view) else {
            Issue.record("Expected a clipboard switch")
            return
        }
        clipboard.state = .on
        clipboard.sendAction(clipboard.action, to: clipboard.target)

        #expect(instance.configuration.clipboardSharingEnabled == true)
    }

    @Test("Toggling Networking writes back to the configuration")
    func networkToggleWritesConfig() {
        let (vc, instance, _) = makeController(guestOS: .linux, isReadOnly: false)
        let initial = instance.configuration.networkEnabled

        guard let network = firstSwitch(action: "networkToggled", in: vc.view) else {
            Issue.record("Expected a networking switch")
            return
        }
        network.state = initial ? .off : .on
        network.sendAction(network.action, to: network.target)

        #expect(instance.configuration.networkEnabled == !initial)
    }

    // MARK: - Helpers (recursive view-tree introspection)

    private func allSwitches(in view: NSView) -> [NSSwitch] {
        var result: [NSSwitch] = []
        if let toggle = view as? NSSwitch { result.append(toggle) }
        for subview in view.subviews { result.append(contentsOf: allSwitches(in: subview)) }
        return result
    }

    private func firstSwitch(action name: String, in view: NSView) -> NSSwitch? {
        allSwitches(in: view).first { toggle in
            toggle.action.map(NSStringFromSelector) == name
        }
    }

    private func lockIcons(in view: NSView) -> [NSImageView] {
        var result: [NSImageView] = []
        if let image = view as? NSImageView, image.toolTip == "Locked while the VM is running" {
            result.append(image)
        }
        for subview in view.subviews { result.append(contentsOf: lockIcons(in: subview)) }
        return result
    }

    private func containsLabel(_ text: String, in view: NSView) -> Bool {
        if let field = view as? NSTextField, field.stringValue == text { return true }
        return view.subviews.contains { containsLabel(text, in: $0) }
    }
}
