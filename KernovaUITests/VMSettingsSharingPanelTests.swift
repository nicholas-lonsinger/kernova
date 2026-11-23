import AVFoundation
import AppKit
import KernovaCommandModel
import KernovaTestSupport
import Testing
import Virtualization

@testable import KernovaCore
@testable import KernovaCoreTestSupport
@testable import KernovaUI

/// The Sharing panel's own behavior, drilled into through the shell.
@Suite("VM Settings Sharing Panel Tests", .serialized, .caseScoped, .scopedWindows)
@MainActor
struct VMSettingsSharingPanelTests {
    private let preferences = makeTestPreferences()
    private func makeViewModel() -> VMLibraryViewModel {
        makeSettingsViewModel(preferences: preferences)
    }

    private func makeController(
        guestOS: VMGuestOS, isReadOnly: Bool, category: VMSettingsCategory? = .sharing
    ) -> (VMSettingsViewController, VMInstance, VMLibraryViewModel) {
        makeSettingsController(
            guestOS: guestOS, isReadOnly: isReadOnly, category: category,
            preferences: preferences)
    }

    // MARK: - Clipboard passthrough

    /// Builds a controller over a config with the given clipboard-sharing state,
    /// so passthrough-enablement gating can be exercised.
    private func makeController(
        guestOS: VMGuestOS, sharingEnabled: Bool,
        mutate: (inout VMConfiguration) -> Void = { _ in }
    ) -> (VMSettingsViewController, VMInstance) {
        let viewModel = makeViewModel()
        let instance = viewModel.library.registerFixture(guestOS: guestOS) {
            $0.clipboardSharingEnabled = sharingEnabled
            mutate(&$0)
        }
        let vc = makeSettingsPane(instance: instance, viewModel: viewModel, isReadOnly: false)
        vc.loadViewIfNeeded()
        vc.viewDidAppear()
        vc.showCategory(.sharing)
        return (vc, instance)
    }

    @Test("The passthrough prompt is the verb's")
    func passthroughConsentIsTheVerbsPrompt() throws {
        let (vc, instance) = makeController(guestOS: .macOS, sharingEnabled: true)
        let window = showTestWindow(styleMask: [.titled])
        window.contentView = vc.view
        let toggle = try #require(firstSwitch(action: "clipboardPassthroughToggled", in: vc.view))

        toggle.state = .on
        toggle.sendAction(toggle.action, to: toggle.target)

        // The verb refused for want of consent, so nothing landed; the sheet
        // asks in the words that refusal carried.
        #expect(!instance.configuration.clipboardPassthroughEnabled)
        let sheet = try #require(window.attachedSheet)
        let prompt = ClipboardPassthroughConsent.prompt(vmName: instance.name)
        #expect(findLabel(withText: prompt.title, in: try #require(sheet.contentView)) != nil)
    }

    @Test("Turning sharing on over a passthrough flag already set confirms first")
    func sharingEnableOverAStalePassthroughFlagConfirms() throws {
        // Sharing off with the passthrough flag still set is what turning
        // sharing off leaves behind, and turning it back on starts passthrough
        // running — so it asks the same question the passthrough switch does.
        let (vc, instance) = makeController(guestOS: .macOS, sharingEnabled: false) {
            $0.clipboardPassthroughEnabled = true
        }

        let toggle = try #require(firstSwitch(action: "clipboardToggled", in: vc.view))
        toggle.state = .on
        toggle.sendAction(toggle.action, to: toggle.target)

        // No window to host the sheet in, so the enable reverts rather than
        // granting the guest a continuous read without being asked.
        #expect(instance.configuration.clipboardSharingEnabled == false)
        #expect(!instance.configuration.clipboardPassthroughIsEffective)
    }

    @Test("The passthrough confirmation alert fires the right action per button")
    func passthroughConfirmationAlertWiring() {
        var confirmed = false
        var cancelled = false
        let prompt = ClipboardPassthroughConsent.prompt(vmName: "Alpha")
        let alert = ConsentedSettingWrite.alert(
            prompt: prompt, onConfirm: { confirmed = true }, onCancel: { cancelled = true })

        #expect(alert.title == prompt.title)
        #expect(alert.message == prompt.message)
        // Turning the setting on destroys nothing, so Turn On takes Return here
        // and reaches Shortcuts as a non-destructive confirmation.
        #expect(!prompt.confirmIsDestructive)
        #expect(alert.buttons.count == 2)
        #expect(alert.buttons.first?.title == prompt.confirmTitle)
        #expect(alert.buttons.first?.role == .default)
        #expect(alert.buttons.last?.role == .cancel)

        alert.buttons.first?.action()
        #expect(confirmed && !cancelled)

        confirmed = false
        alert.buttons.last?.action()
        #expect(cancelled && !confirmed)
    }

    // MARK: - Guest agent install reminder

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
        #expect(instance.hostState.agentInstallNudgeDismissed == false)
        #expect(toggle.state == .on)

        viewModel.agentInstallPromptDisabled = false
        vc.viewDidAppear()

        #expect(toggle.isEnabled)
        #expect(!visibleLabel(VMSettingsSharingPanelViewController.installPromptDisabledCaption, in: vc.view))
    }
}
