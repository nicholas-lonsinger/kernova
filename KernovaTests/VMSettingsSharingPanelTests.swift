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

    // MARK: - Shared directory rows

    /// Builds a pane over a VM carrying `directories`, drilled into Sharing.
    ///
    /// The VM is registered with the library: every share control calls a verb
    /// that addresses it by id, so an unregistered one refuses as not found.
    private func makeSharingController(
        _ directories: [SharedDirectory], phase: VMLifecyclePhase = .stopped
    ) -> (VMSettingsViewController, VMInstance) {
        let viewModel = makeViewModel()
        let instance = makeSettingsInstance(guestOS: .linux, phase: phase)
        instance.configuration.sharedDirectories = directories
        registerSettingsInstance(instance, in: viewModel)
        let vc = VMSettingsViewController(
            instance: instance, viewModel: viewModel, isReadOnly: phase != .stopped)
        vc.loadViewIfNeeded()
        vc.viewDidAppear()
        vc.showCategory(.sharing)
        return (vc, instance)
    }

    /// Seeds the shared file monitor with `paths` and repaints the rows from
    /// what it found — the two steps the panel takes on its own, awaited here so
    /// the assertion doesn't race the probe.
    private func seedMonitor(_ vc: VMSettingsViewController, paths: [String]) async throws {
        let panel = try #require(vc.settingsPanelForTesting(.sharing))
        await panel.context.fileMonitor.setPaths(
            Dictionary(uniqueKeysWithValues: paths.map { ($0, Data?.none) }))
        panel.refresh()
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
        let present = FileManager.default.temporaryDirectory
            .appendingPathComponent("kernova-settings-share-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: present, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: present) }
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
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("kernova-settings-share-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
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

        try await waitForChange {
            panel.context.fileMonitor.exists(sharePath)
        }
        panel.refresh()
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

    /// A running VM's virtiofs device set is fixed at boot, so the share
    /// controls go inert — and the verb behind each refuses if one is driven
    /// anyway.
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
}
