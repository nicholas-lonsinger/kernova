import AVFoundation
import AppKit
import Testing
import Virtualization

@testable import Kernova

/// The Sharing panel's own behavior, drilled into through the shell.
@Suite("VM Settings Sharing Panel Tests", .serialized, .admissionGated)
@MainActor
struct VMSettingsSharingPanelTests {
    /// Isolated, pre-cleaned preferences for this suite's `VMLibraryViewModel`.
    ///
    /// Selection/order persistence never touches the real `.standard` domain.
    private let preferences = makeEphemeralPreferences(suiteName: "test.kernova.vmsettings.sharing")

    private func makeViewModel() -> VMLibraryViewModel {
        makeSettingsViewModel(preferences: preferences)
    }

    private func makeInstance(guestOS: VMGuestOS) -> VMInstance {
        makeSettingsInstance(guestOS: guestOS)
    }

    private func makeController(
        guestOS: VMGuestOS, isReadOnly: Bool, category: VMSettingsCategory? = nil
    ) -> (VMSettingsViewController, VMInstance, VMLibraryViewModel) {
        makeSettingsController(
            guestOS: guestOS, isReadOnly: isReadOnly, category: category,
            preferences: preferences)
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
        #expect(containsLabel("Clipboard sharing", in: macVC.view))
        #expect(!containsLabel("Clipboard", in: macVC.view))

        // Linux: SPICE clipboard keeps its own standalone section header.
        let (linuxVC, _, _) = makeController(guestOS: .linux, isReadOnly: false)
        #expect(containsLabel("Clipboard sharing", in: linuxVC.view))
        #expect(containsLabel("Clipboard", in: linuxVC.view))
    }

    @Test("Agent-dependency caption appears for macOS but not Linux")
    func agentDependencyCaptionMacOSOnly() {
        let caption = VMSettingsSharingPanelViewController.agentDependencyCaption

        let (macVC, _, _) = makeController(guestOS: .macOS, isReadOnly: false)
        #expect(containsLabel(caption, in: macVC.view))

        // Linux clipboard is SPICE-based, so the agent-dependency cue must not appear.
        let (linuxVC, _, _) = makeController(guestOS: .linux, isReadOnly: false)
        #expect(!containsLabel(caption, in: linuxVC.view))
    }

    // MARK: - Clipboard passthrough

    /// Builds a controller over a config with the given clipboard-sharing state,
    /// so passthrough-enablement gating can be exercised.
    private func makeController(guestOS: VMGuestOS, sharingEnabled: Bool) -> (
        VMSettingsViewController, VMInstance
    ) {
        let viewModel = makeViewModel()
        let config = VMConfiguration(
            name: "Test VM", guestOS: guestOS, bootMode: guestOS == .macOS ? .macOS : .efi,
            clipboardSharingEnabled: sharingEnabled)
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(config.id.uuidString, isDirectory: true)
        let instance = VMInstance(configuration: config, bundleURL: bundleURL)
        let vc = VMSettingsViewController(instance: instance, viewModel: viewModel, isReadOnly: false)
        vc.loadViewIfNeeded()
        vc.viewDidAppear()
        return (vc, instance)
    }

    @Test("The passthrough toggle appears for both guest OSes")
    func passthroughTogglePresentByGuestOS() {
        let (macVC, _, _) = makeController(guestOS: .macOS, isReadOnly: false)
        #expect(containsLabel("Automatic clipboard passthrough", in: macVC.view))
        #expect(firstSwitch(action: "clipboardPassthroughToggled", in: macVC.view) != nil)

        let (linuxVC, _, _) = makeController(guestOS: .linux, isReadOnly: false)
        #expect(containsLabel("Automatic clipboard passthrough", in: linuxVC.view))
        #expect(firstSwitch(action: "clipboardPassthroughToggled", in: linuxVC.view) != nil)
    }

    @Test("The passthrough toggle is disabled until sharing is on")
    func passthroughDisabledWithoutSharing() {
        let (offVC, _) = makeController(guestOS: .macOS, sharingEnabled: false)
        #expect(firstSwitch(action: "clipboardPassthroughToggled", in: offVC.view)?.isEnabled == false)

        let (onVC, _) = makeController(guestOS: .macOS, sharingEnabled: true)
        #expect(firstSwitch(action: "clipboardPassthroughToggled", in: onVC.view)?.isEnabled == true)
    }

    /// AppKit draws a disabled `NSSwitch` that is *on* at full accent fill, so
    /// the row reads as live while it is inert; the dim is what says otherwise.
    @Test("A disabled passthrough toggle is dimmed, not just inert")
    func passthroughDimsWhenDisabled() {
        let (offVC, _) = makeController(guestOS: .macOS, sharingEnabled: false)
        let off = firstSwitch(action: "clipboardPassthroughToggled", in: offVC.view)
        #expect(off?.alphaValue ?? 1 < 1)

        let (onVC, _) = makeController(guestOS: .macOS, sharingEnabled: true)
        #expect(firstSwitch(action: "clipboardPassthroughToggled", in: onVC.view)?.alphaValue == 1)
    }

    @Test("Enabling passthrough without a window reverts and does not write")
    func passthroughEnableWithoutWindowReverts() {
        let (vc, instance) = makeController(guestOS: .macOS, sharingEnabled: true)
        guard let toggle = firstSwitch(action: "clipboardPassthroughToggled", in: vc.view) else {
            Issue.record("Expected a passthrough switch")
            return
        }
        // The offscreen test VC has no window to host the confirmation sheet, so
        // the enable path must revert rather than silently enable.
        toggle.state = .on
        toggle.sendAction(toggle.action, to: toggle.target)

        #expect(instance.configuration.clipboardPassthroughEnabled == false)
        #expect(toggle.state == .off)
    }

    @Test("Confirming the security prompt enables passthrough")
    func passthroughConfirmEnables() {
        let (vc, instance) = makeController(guestOS: .macOS, sharingEnabled: true)
        #expect(instance.configuration.clipboardPassthroughEnabled == false)

        vc.confirmPassthroughEnableForTesting()

        #expect(instance.configuration.clipboardPassthroughEnabled == true)
    }

    @Test("Cancelling the security prompt reverts the switch and writes nothing")
    func passthroughCancelReverts() {
        let (vc, instance) = makeController(guestOS: .macOS, sharingEnabled: true)
        guard let toggle = firstSwitch(action: "clipboardPassthroughToggled", in: vc.view) else {
            Issue.record("Expected a passthrough switch")
            return
        }
        toggle.state = .on  // user flipped it; the sheet is up

        vc.cancelPassthroughEnableForTesting()

        #expect(toggle.state == .off)
        #expect(instance.configuration.clipboardPassthroughEnabled == false)
    }

    @Test("Turning passthrough off writes immediately without confirmation")
    func passthroughDisableWritesImmediately() {
        let (vc, instance) = makeController(guestOS: .macOS, sharingEnabled: true)
        vc.confirmPassthroughEnableForTesting()
        #expect(instance.configuration.clipboardPassthroughEnabled == true)

        guard let toggle = firstSwitch(action: "clipboardPassthroughToggled", in: vc.view) else {
            Issue.record("Expected a passthrough switch")
            return
        }
        toggle.state = .off
        toggle.sendAction(toggle.action, to: toggle.target)

        #expect(instance.configuration.clipboardPassthroughEnabled == false)
    }

    @Test("The passthrough confirmation alert fires the right action per button")
    func passthroughConfirmationAlertWiring() {
        var confirmed = false
        var cancelled = false
        let alert = ClipboardPassthroughConfirmation.alert(
            onConfirm: { confirmed = true }, onCancel: { cancelled = true })

        #expect(alert.title == ClipboardPassthroughConfirmation.title)
        #expect(alert.buttons.count == 2)
        #expect(alert.buttons.first?.role == .default)
        #expect(alert.buttons.last?.role == .cancel)

        alert.buttons.first?.action()
        #expect(confirmed && !cancelled)

        confirmed = false
        alert.buttons.last?.action()
        #expect(cancelled && !confirmed)
    }

    // MARK: - Guest agent install reminder

    @Test("The install-reminder switch is live while the prompt is on app-wide")
    func installReminderEnabledByDefault() throws {
        let (vc, instance, _) = makeController(guestOS: .macOS, isReadOnly: false)

        let toggle = try #require(firstSwitch(action: "installReminderToggled", in: vc.view))
        #expect(toggle.isEnabled)
        #expect(!visibleLabel(VMSettingsSharingPanelViewController.installPromptDisabledCaption, in: vc.view))

        toggle.state = .off
        toggle.sendAction(toggle.action, to: toggle.target)
        #expect(instance.configuration.agentInstallNudgeDismissed == true)
    }

    /// The app-wide preference is not overridable per VM, so the switch goes
    /// inert — and says where the preference that made it inert lives, or the
    /// disabled state reads as broken.
    @Test("The app-wide preference disables the install-reminder switch and says why")
    func installReminderDisabledByAppWidePreference() throws {
        let (vc, instance, viewModel) = makeController(
            guestOS: .macOS, isReadOnly: false, category: .sharing)

        viewModel.agentInstallPromptDisabled = true
        // Stands in for the observation pass a Settings-window toggle triggers.
        vc.viewDidAppear()

        let toggle = try #require(firstSwitch(action: "installReminderToggled", in: vc.view))
        #expect(!toggle.isEnabled)
        #expect(visibleLabel(VMSettingsSharingPanelViewController.installPromptDisabledCaption, in: vc.view))
        // Overridden, not rewritten: the row still shows this VM's own choice.
        #expect(instance.configuration.agentInstallNudgeDismissed == false)
        #expect(toggle.state == .on)

        viewModel.agentInstallPromptDisabled = false
        vc.viewDidAppear()

        #expect(toggle.isEnabled)
        #expect(!visibleLabel(VMSettingsSharingPanelViewController.installPromptDisabledCaption, in: vc.view))
    }
}
