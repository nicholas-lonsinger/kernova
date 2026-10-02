import AVFoundation
import AppKit
import KernovaTestSupport
import Testing
import Virtualization

@testable import Kernova

/// The Sharing panel's own behavior, drilled into through the shell.
@Suite("VM Settings Sharing Panel Tests", .serialized, .caseScoped, .scopedWindows)
@MainActor
struct VMSettingsSharingPanelTests {
    private let preferences = makeTestPreferences()
    private let scratch = TestScratchDirectory(prefix: "VMSettingsSharingPanelTests")

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

    @Test("The agent dependency is the macOS Guest Agent header's info, never on screen")
    func agentDependencyInfoMacOSOnly() {
        let (macVC, _, _) = makeController(guestOS: .macOS, isReadOnly: false)
        #expect(infoButton(about: "Guest Agent", in: macVC.view) != nil)
        #expect(findLabel(containing: "need the Kernova guest agent", in: macVC.view) == nil)

        // Linux clipboard is SPICE-based, so the agent-dependency cue must not
        // appear; its clipboard row carries its own info instead.
        let (linuxVC, _, _) = makeController(guestOS: .linux, isReadOnly: false)
        #expect(infoButton(about: "Guest Agent", in: linuxVC.view) == nil)
        #expect(infoButton(about: "Clipboard sharing", in: linuxVC.view) != nil)
        #expect(infoButton(about: "Clipboard", in: linuxVC.view) == nil)
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

        vc.confirmPassthroughEnableForTesting(.passthrough(true))

        #expect(instance.configuration.clipboardPassthroughEnabled == true)
    }

    @Test("The passthrough prompt is the verb's, and confirming it re-issues the write consented")
    func passthroughConsentIsTheVerbsPrompt() throws {
        let (vc, instance) = makeController(guestOS: .macOS, sharingEnabled: true)
        let window = makeTestWindow(styleMask: [.titled])
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

        vc.confirmPassthroughEnableForTesting(.passthrough(true))
        #expect(instance.configuration.clipboardPassthroughEnabled)
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

        vc.confirmPassthroughEnableForTesting(.sharing(true))
        #expect(instance.configuration.clipboardPassthroughIsEffective)
    }

    @Test("Turning sharing on with no passthrough flag writes immediately")
    func sharingEnableAloneWritesImmediately() throws {
        let (vc, instance) = makeController(guestOS: .macOS, sharingEnabled: false)

        let toggle = try #require(firstSwitch(action: "clipboardToggled", in: vc.view))
        toggle.state = .on
        toggle.sendAction(toggle.action, to: toggle.target)

        #expect(instance.configuration.clipboardSharingEnabled == true)
    }

    @Test("Turning passthrough off writes immediately without confirmation")
    func passthroughDisableWritesImmediately() {
        let (vc, instance) = makeController(guestOS: .macOS, sharingEnabled: true)
        vc.confirmPassthroughEnableForTesting(.passthrough(true))
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
        let prompt = ClipboardPassthroughConsent.prompt(vmName: "Alpha")
        let alert = ClipboardPassthroughSetting.alert(
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

    @Test("The install-reminder switch is live while the prompt is on app-wide")
    func installReminderEnabledByDefault() throws {
        let (vc, instance, _) = makeController(guestOS: .macOS, isReadOnly: false)

        let toggle = try #require(firstSwitch(action: "installReminderToggled", in: vc.view))
        #expect(toggle.isEnabled)
        #expect(!visibleLabel(VMSettingsSharingPanelViewController.installPromptDisabledCaption, in: vc.view))

        toggle.state = .off
        toggle.sendAction(toggle.action, to: toggle.target)
        #expect(instance.hostState.agentInstallNudgeDismissed == true)
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
        #expect(instance.hostState.agentInstallNudgeDismissed == false)
        #expect(toggle.state == .on)

        viewModel.agentInstallPromptDisabled = false
        vc.viewDidAppear()

        #expect(toggle.isEnabled)
        #expect(!visibleLabel(VMSettingsSharingPanelViewController.installPromptDisabledCaption, in: vc.view))
    }

    // MARK: - Shared directory rows

    /// Builds a pane over a VM carrying `directories`, drilled into Sharing.
    ///
    /// The VM is registered with the library: every share control calls a verb
    /// that addresses it by id, so an unregistered one refuses as not found.
    private func makeSharingController(
        _ directories: [SharedDirectory], phase: VMLifecyclePhase = .stopped,
        guestOS: VMGuestOS = .linux
    ) -> (VMSettingsViewController, VMInstance) {
        let viewModel = makeViewModel()
        let instance = viewModel.library.registerFixture(guestOS: guestOS, phase: phase) {
            $0.sharedDirectories = directories
        }
        let vc = makeSettingsPane(
            instance: instance, viewModel: viewModel, isReadOnly: phase != .stopped)
        vc.loadViewIfNeeded()
        vc.viewDidAppear()
        vc.showCategory(.sharing)
        return (vc, instance)
    }

    /// Seeds the shared file monitor with `paths` and lets the panel repaint
    /// its rows from what the probe found: the repaint is a main-actor task the
    /// monitor's answer enqueues, so it has run once the main queue drains
    /// behind it.
    private func seedMonitor(_ vc: VMSettingsViewController, paths: [String]) async throws {
        let panel = try #require(vc.settingsPanelForTesting(.sharing))
        await panel.context.fileMonitor.setPaths(
            Dictionary(uniqueKeysWithValues: paths.map { ($0, Data?.none) }))
        await drainMainQueue()
    }

    private func sharedRows(in vc: VMSettingsViewController) -> [AttachmentRowView] {
        guard let panel = vc.panelForTesting(.sharing) else { return [] }
        return allSubviews(AttachmentRowView.self, in: panel)
    }

    /// A folder no runner can have, so the probe's answer is not the machine's
    /// to decide.
    private static let missingPath = "/kernova-tests/definitely-not-here/Shared"

    @Test("A share whose folder is gone badges as missing; one that is there does not")
    func missingShareBadgesAfterTheProbeLands() async throws {
        let present = scratch.url.appendingPathComponent(
            "kernova-settings-share", isDirectory: true)
        try FileManager.default.createDirectory(at: present, withIntermediateDirectories: true)
        let presentPath = present.path(percentEncoded: false)

        let (vc, _) = makeSharingController([
            SharedDirectory(path: Self.missingPath), SharedDirectory(path: presentPath),
        ])
        try await seedMonitor(vc, paths: [Self.missingPath, presentPath])

        let panel = try #require(vc.panelForTesting(.sharing))
        #expect(findLabel(containing: "Missing \u{2014} \(Self.missingPath)", in: panel) != nil)
        #expect(findLabel(containing: "Missing \u{2014} \(presentPath)", in: panel) == nil)
        #expect(findLabel(withText: presentPath, in: panel) != nil)
    }

    /// The badge has to follow the folder for the whole session, and the parent
    /// watcher cannot carry that on its own: a Powerbox grant never covers the
    /// parent directory, so `open(parent, O_EVTONLY)` is denied for most shares
    /// and no source is ever installed. Nesting the share under a directory that
    /// does not exist at seed time reproduces that unwatched state here, leaving
    /// the shell's re-ask on drill-in as the only thing that can move the badge.
    @Test("Drilling back into Sharing re-asks about a folder no watcher covers")
    func drillInReprobesAnUnwatchedShare() async throws {
        let base = scratch.url.appendingPathComponent(
            "kernova-settings-share", isDirectory: true)
        let parent = base.appendingPathComponent("parent", isDirectory: true)
        let share = parent.appendingPathComponent("Shared", isDirectory: true)
        let sharePath = share.path(percentEncoded: false)

        let (vc, _) = makeSharingController([SharedDirectory(path: sharePath)])
        try await seedMonitor(vc, paths: [sharePath])

        let panel = try #require(vc.settingsPanelForTesting(.sharing))
        #expect(findLabel(containing: "Missing \u{2014} \(sharePath)", in: panel.view) != nil)
        #expect(panel.context.fileMonitor.watchedParentsForTesting.isEmpty)

        try FileManager.default.createDirectory(at: share, withIntermediateDirectories: true)

        vc.showOverview()
        vc.showCategory(.sharing)

        try await waitForChange { panel.context.fileMonitor.exists(sharePath) }
        await drainMainQueue()
        #expect(findLabel(containing: "Missing \u{2014} \(sharePath)", in: panel.view) == nil)
    }

    @Test("The share row menu reaches the folder, and dims Show in Finder while it is gone")
    func shareRowMenuFollowsTheFolder() async throws {
        let (vc, _) = makeSharingController([SharedDirectory(path: Self.missingPath)])
        try await seedMonitor(vc, paths: [Self.missingPath])

        let row = try #require(sharedRows(in: vc).first)
        let menu = try #require(row.contextMenu?())
        #expect(menu.items.map(\.title) == ["Show in Finder", "Copy Path", "Copy File Name"])
        #expect(menu.items.first { $0.title == "Show in Finder" }?.isEnabled == false)
        #expect(menu.items.first { $0.title == "Copy Path" }?.isEnabled == true)
    }

    @Test("A missing share still takes its read-only toggle and its removal")
    func missingShareKeepsItsControls() async throws {
        let (vc, instance) = makeSharingController([SharedDirectory(path: Self.missingPath)])
        try await seedMonitor(vc, paths: [Self.missingPath])
        let panel = try #require(vc.panelForTesting(.sharing))

        let toggle = try #require(firstSwitch(action: "sharedReadOnlyToggled:", in: panel))
        toggle.state = .on
        toggle.sendAction(toggle.action, to: toggle.target)
        #expect(instance.configuration.sharedDirectories?.first?.readOnly == true)

        let remove = try #require(
            firstSubview(NSButton.self, in: panel) {
                $0.action.map(NSStringFromSelector) == "sharedDeleteTapped:"
            })
        remove.sendAction(remove.action, to: remove.target)
        #expect(instance.configuration.sharedDirectories == nil)
    }

    @Test("A running macOS guest takes another share and keeps its last, saying why")
    func runningMacOSGuestOffersAddButNotTheLastRemoval() async throws {
        let caption = VMSettingsSharingPanelViewController.sharingDeviceCaption
        let (vc, instance) = makeSharingController(
            [SharedDirectory(path: Self.missingPath)], phase: .running(sessionID: UUID()),
            guestOS: .macOS)
        try await seedMonitor(vc, paths: [Self.missingPath])
        let panel = try #require(vc.panelForTesting(.sharing))

        let add = try #require(
            firstSubview(NSButton.self, in: panel) { $0.title == "Add Shared Directory…" })
        #expect(add.isEnabled)
        let toggle = try #require(firstSwitch(action: "sharedReadOnlyToggled:", in: panel))
        #expect(toggle.isEnabled)
        let remove = try #require(
            firstSubview(NSButton.self, in: panel) {
                $0.action.map(NSStringFromSelector) == "sharedDeleteTapped:"
            })
        #expect(!remove.isEnabled)
        #expect(visibleLabel(caption, in: panel))
        #expect(settingsLockHints(in: panel).allSatisfy { $0.isHidden })
        remove.sendAction(remove.action, to: remove.target)
        #expect(instance.configuration.sharedDirectories?.count == 1)

        // With no share, the first is what the rule holds.
        let (emptyVC, _) = makeSharingController(
            [], phase: .running(sessionID: UUID()), guestOS: .macOS)
        let emptyPanel = try #require(emptyVC.panelForTesting(.sharing))
        let emptyAdd = try #require(
            firstSubview(NSButton.self, in: emptyPanel) { $0.title == "Add Shared Directory…" })
        #expect(!emptyAdd.isEnabled)
        #expect(visibleLabel(caption, in: emptyPanel))
    }

    @Test("A live read-only change the folder refuses is presented, and the switch shows what is committed")
    func refusedLiveReadOnlyChangeIsPresentedAndReverted() throws {
        let folder = scratch.url.appendingPathComponent(UUID().uuidString).path(percentEncoded: false)
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder)
        }
        let share = SharedDirectory(path: folder, readOnly: true)
        let presenter = MockVMLibraryPresenting()
        let viewModel = makeViewModel()
        viewModel.presenter = presenter
        let instance = viewModel.library.registerFixture(
            guestOS: .macOS, phase: .running(sessionID: UUID())
        ) { $0.sharedDirectories = [share] }
        instance.beginSessionContextForTesting().directoryShare =
            try ConfigurationBuilder.macOSDirectoryShare(for: [share])
        let vc = makeSettingsPane(instance: instance, viewModel: viewModel, isReadOnly: true)
        vc.loadViewIfNeeded()
        vc.viewDidAppear()
        vc.showCategory(.sharing)
        let panel = try #require(vc.panelForTesting(.sharing))
        let toggle = try #require(firstSwitch(action: "sharedReadOnlyToggled:", in: panel))
        #expect(toggle.isEnabled)

        toggle.state = .off
        toggle.sendAction(toggle.action, to: toggle.target)

        #expect(presenter.errors == ["Shared directory is not writable: \(folder)."])
        #expect(toggle.state == .on)
        #expect(instance.configuration.sharedDirectories?.first?.readOnly == true)
    }

    @Test("A stopped VM states no share rule")
    func stoppedVMStatesNoShareRule() throws {
        let (vc, _) = makeSharingController(
            [SharedDirectory(path: Self.missingPath)], guestOS: .macOS)
        let panel = try #require(vc.panelForTesting(.sharing))
        #expect(!visibleLabel(VMSettingsSharingPanelViewController.sharingDeviceCaption, in: panel))
    }

    /// A running Linux guest's shares each ride a device fixed at boot, so the
    /// share controls go inert — and the verb behind each refuses if one is
    /// driven anyway.
    @Test("A running VM's share rows and its Add button are inert")
    func runningVMLocksTheShareControls() async throws {
        let (vc, instance) = makeSharingController(
            [SharedDirectory(path: Self.missingPath)], phase: .running(sessionID: UUID()))
        try await seedMonitor(vc, paths: [Self.missingPath])
        let panel = try #require(vc.panelForTesting(.sharing))

        let toggle = try #require(firstSwitch(action: "sharedReadOnlyToggled:", in: panel))
        #expect(!toggle.isEnabled)
        let add = try #require(
            firstSubview(NSButton.self, in: panel) { $0.title == "Add Shared Directory…" })
        #expect(!add.isEnabled)

        let remove = try #require(
            firstSubview(NSButton.self, in: panel) {
                $0.action.map(NSStringFromSelector) == "sharedDeleteTapped:"
            })
        #expect(!remove.isEnabled)
        remove.sendAction(remove.action, to: remove.target)
        #expect(instance.configuration.sharedDirectories?.count == 1)
    }

    // MARK: - Shared Directories info

    @Test(
        "The resume note joins the Shared Directories info only for a guest known to run macOS 13",
        arguments: [
            (VMGuestOS.macOS, "Version 13.7.8 (Build 22H730)" as String?, true),
            (VMGuestOS.macOS, "Version 14.8.9 (Build 23J100)", false),
            (VMGuestOS.macOS, "Version 27.0 (Build 26A428)", false),
            (VMGuestOS.macOS, nil, false),
            (VMGuestOS.linux, "13.7.8", false),
        ])
    func resumeNoteOnlyForMacOS13(guestOS: VMGuestOS, reported: String?, noted: Bool) {
        let configuration = VMConfiguration(
            name: "Shares", guestOS: guestOS, bootMode: guestOS == .macOS ? .macOS : .efi,
            lastSeenGuestOSVersion: reported)
        let paragraphs = VMSettingsSharingPanelViewController.sharedDirectoriesInfoParagraphs(
            for: configuration)
        let mentionsResume = paragraphs.contains {
            if case .body(let text) = $0 { return text.contains("resumes from Suspend") }
            return false
        }
        #expect(mentionsResume == noted)
    }
}
