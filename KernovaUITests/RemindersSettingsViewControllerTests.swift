import AppKit
import Foundation
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport
@testable import KernovaUI
@testable import KernovaVirtualization

/// Layout tests for the Reminders settings pane.
///
/// The pane hugs its content when short and scrolls past a height cap. The
/// regression risk is the capped state: the pane's frame is fixed by the tab
/// controller, and a hug constraint that outranks the text's compression
/// resistance resolves the shortfall by collapsing every section header and
/// caption to zero height instead of scrolling.
@Suite("Reminders Settings Tests", .serialized, .caseScoped, .scopedWindows)
@MainActor
struct RemindersSettingsViewControllerTests {
    private let preferences: AppPreferences

    init() {
        self.preferences = makeTestPreferences()
    }

    private func makeViewModel(
        virtualization: MockVirtualizationService = MockVirtualizationService()
    ) -> VMLibraryViewModel {
        VMLibraryViewModel(
            storageService: MockVMStorageService(),
            diskImageService: MockDiskImageService(),
            machineFiles: VMBundleMachineFiles(fileSystem: MockFileSystem(), platform: FakePlatformFiles()),
            virtualizationHost: VirtualizationHost(),
            virtualizationService: virtualization,
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

    /// Builds the pane with `vmCount` VMs and runs the appear-time layout the
    /// way NSTabViewController does: it reads `preferredContentSize` at switch
    /// time and sizes the pane's view to exactly that.
    private func makeLaidOutController(vmCount: Int) -> RemindersSettingsViewController {
        makeLaidOutPane(vmCount: vmCount).controller
    }

    /// As ``makeLaidOutController(vmCount:)``, also handing back the view model
    /// so a test can drive the app-wide install-prompt preference.
    private func makeLaidOutPane(vmCount: Int) -> (
        controller: RemindersSettingsViewController, viewModel: VMLibraryViewModel
    ) {
        let viewModel = makeViewModel()
        for index in 1...vmCount {
            viewModel.library.admitFixture(name: "VM \(index)", guestOS: .macOS)
        }
        let controller = RemindersSettingsViewController(viewModel: viewModel, visibleFrame: offDesktopVisibleFrame)
        _ = controller.view
        controller.refreshContent()
        controller.viewWillAppear()
        controller.view.setFrameSize(controller.preferredContentSize)
        controller.view.layoutSubtreeIfNeeded()
        return (controller, viewModel)
    }

    /// A laid-out pane hosted in an on-screen window, for the flash assertions.
    ///
    /// The window has to be up before the geometry settles: the cue only fires
    /// against a visible window, so measuring it off screen would count flashes
    /// the app never shows.
    private func makeShownPane(vmCount: Int) -> RemindersSettingsViewController {
        let viewModel = makeViewModel()
        for index in 1...vmCount {
            viewModel.library.admitFixture(name: "VM \(index)", guestOS: .macOS)
        }
        let controller = RemindersSettingsViewController(viewModel: viewModel, visibleFrame: offDesktopVisibleFrame)
        // Measure while detached, exactly as the pane does before the tab
        // controller sizes the window, then hand the window that measurement.
        controller.refreshContent()
        controller.viewWillAppear()
        showInTestWindow(controller.view, size: controller.preferredContentSize)
        controller.view.layoutSubtreeIfNeeded()
        // Stands in for the tab container's `viewDidAppear`. Ordering a window on
        // screen changes no geometry, so nothing re-runs the cue on its own — the
        // arrival hook is what spends the flash once there is something to see.
        controller.rearmScrollMoreCue()
        return controller
    }

    /// Every switch in the pane wired to `action`, in row order.
    private func switches(action name: String, in controller: RemindersSettingsViewController)
        -> [NSSwitch]
    {
        allSubviews(NSSwitch.self, in: controller.view) {
            $0.action.map(NSStringFromSelector) == name
        }
    }

    private func vmSwitches(in controller: RemindersSettingsViewController) -> [NSSwitch] {
        switches(action: "vmReminderToggled:", in: controller)
    }

    /// Flips the app-wide install-reminder switch the way a click does, so the
    /// pane's own action wiring is what drives the change.
    private func setAppWideInstallReminder(
        on: Bool, in controller: RemindersSettingsViewController
    ) throws {
        let toggle = try #require(
            switches(action: "agentInstallToggled", in: controller).first)
        let action = try #require(toggle.action)
        toggle.state = on ? .on : .off
        let delivered = NSApp.sendAction(action, to: toggle.target, from: toggle)
        #expect(delivered)
    }

    /// The app reminders share a card; the Virtual Machine section's governing
    /// switch heads its own.
    @Test("The app reminders share a card apart from the install reminder's")
    func remindersAreSeparateCards() throws {
        let controller = makeLaidOutController(vmCount: 2)
        defer { controller.viewDidDisappear() }

        #expect(findLabel(withText: "Menu bar quit reminder", in: controller.view) != nil)
        #expect(findLabel(withText: "Duplicate machine ID question", in: controller.view) != nil)
        #expect(findLabel(withText: "Guest agent install reminder", in: controller.view) != nil)
        #expect(findLabel(withText: "Ephemeral Mode settings banner", in: controller.view) != nil)
        // Four app-wide switches plus one per VM.
        #expect(allSubviews(NSSwitch.self, in: controller.view).count == 6)

        let menuBarToggle = try #require(
            switches(action: "menuBarQuitToggled", in: controller).first)
        let agentToggle = try #require(
            switches(action: "agentInstallToggled", in: controller).first)
        let menuBarCard = try #require(enclosingGroupedFormCard(of: menuBarToggle))
        let agentCard = try #require(enclosingGroupedFormCard(of: agentToggle))
        let questionToggle = try #require(
            switches(action: "duplicateIDQuestionToggled", in: controller).first)
        #expect(menuBarCard !== agentCard)
        #expect(enclosingGroupedFormCard(of: questionToggle) === menuBarCard)
        let ephemeralToggle = try #require(
            switches(action: "ephemeralSettingsBannerToggled", in: controller).first)
        #expect(enclosingGroupedFormCard(of: ephemeralToggle) === menuBarCard)
        #expect(allSubviews(NSSwitch.self, in: menuBarCard).count == 3)
        #expect(allSubviews(NSSwitch.self, in: agentCard).count == 1)
    }

    // MARK: - Each switch's message

    private func info(about row: String, in controller: RemindersSettingsViewController) throws
        -> [InfoPopoverParagraph]
    {
        try #require(infoButton(about: row, in: controller.view)).paragraphs
    }

    @Test("The quit reminder's info opens with the title and text the reminder shows")
    func quitReminderInfoShowsTheReminder() throws {
        let controller = makeLaidOutController(vmCount: 1)
        defer { controller.viewDidDisappear() }
        let reminder = MenuBarQuitReminderViewController(onStopReminding: {})
        reminder.loadViewIfNeeded()

        let info = try info(about: "Menu bar quit reminder", in: controller)

        #expect(
            info.prefix(2) == [
                .headline("Kernova is still running in the menu bar."),
                .body("Your virtual machines keep running. Quit Kernova fully from this menu bar item."),
            ])
        #expect(findLabel(withText: MenuBarQuitReminderViewController.title, in: reminder.view) != nil)
        #expect(findLabel(withText: MenuBarQuitReminderViewController.text, in: reminder.view) != nil)
    }

    @Test("The question's info opens with the question naming no virtual machine, Apple's claim included")
    func questionInfoShowsTheQuestion() throws {
        let controller = makeLaidOutController(vmCount: 1)
        defer { controller.viewDidDisappear() }

        let info = try info(about: "Duplicate machine ID question", in: controller)

        let question = DuplicateMachineIDQuestion.prompt(verb: nil, names: nil)
        #expect(info.prefix(2) == [.headline(question.title), .body(question.message)])
        #expect(question.message.hasSuffix(DuplicateMachineIDQuestion.vendorClaim))
    }

    @Test("The install reminder's info opens with the title the sidebar prompt shows")
    func installReminderInfoShowsThePrompt() throws {
        let controller = makeLaidOutController(vmCount: 1)
        defer { controller.viewDidDisappear() }

        let info = try info(about: "Guest agent install reminder", in: controller)

        #expect(info.first == .headline("Set up the Kernova guest agent"))
        #expect(info.first == .headline(GuestAgentStatusViewController.title(for: .waiting)))
    }

    // MARK: - The duplicate machine ID question

    private func questionSwitch(in controller: RemindersSettingsViewController) throws -> NSSwitch {
        try #require(switches(action: "duplicateIDQuestionToggled", in: controller).first)
    }

    @Test("While the duplicate machine ID setting is off, the question's row is disabled and says why")
    func questionRowDisabledWhileTheSettingIsOff() throws {
        preferences.allowsDuplicateMachineIDOverride = false
        let (controller, viewModel) = makeLaidOutPane(vmCount: 1)
        defer { controller.viewDidDisappear() }

        let toggle = try questionSwitch(in: controller)
        #expect(toggle.state == .on)
        #expect(!toggle.isEnabled)
        #expect(
            findLabel(
                withText: "No effect while Offer to start duplicate machine IDs anyway is off.",
                in: controller.view)?.isHidden == false)

        // Still disabled, still showing the choice, once one is saved.
        viewModel.duplicateMachineIDQuestionDismissed = true
        controller.refreshContent()
        #expect(toggle.state == .off)
        #expect(!toggle.isEnabled)
    }

    /// Flips the duplicate machine ID question's switch the way a click does,
    /// so the pane's own action wiring is what drives the change.
    private func setQuestion(on: Bool, in controller: RemindersSettingsViewController) throws {
        let toggle = try questionSwitch(in: controller)
        toggle.state = on ? .on : .off
        #expect(NSApp.sendAction(try #require(toggle.action), to: toggle.target, from: toggle))
    }

    @Test("Turning the question's switch off saves the choice not to be asked, and on clears it")
    func theQuestionsSwitchWorksBothWays() throws {
        preferences.allowsDuplicateMachineIDOverride = true
        let (controller, viewModel) = makeLaidOutPane(vmCount: 1)
        defer { controller.viewDidDisappear() }
        let toggle = try questionSwitch(in: controller)
        #expect(toggle.state == .on)
        #expect(toggle.isEnabled)

        try setQuestion(on: false, in: controller)

        #expect(viewModel.duplicateMachineIDQuestionDismissed)
        #expect(preferences.duplicateMachineIDQuestionDismissed)
        #expect(toggle.isEnabled)

        try setQuestion(on: true, in: controller)

        #expect(viewModel.duplicateMachineIDQuestionDismissed == false)
        #expect(preferences.duplicateMachineIDQuestionDismissed == false)
        #expect(toggle.isEnabled)
    }

    @Test("The Ephemeral banner's switch follows the view model both ways, and reset turns it back on")
    func ephemeralBannerSwitchWorksBothWays() throws {
        let (controller, viewModel) = makeLaidOutPane(vmCount: 1)
        defer { controller.viewDidDisappear() }
        let toggle = try #require(switches(action: "ephemeralSettingsBannerToggled", in: controller).first)
        #expect(toggle.state == .on)

        toggle.state = .off
        #expect(NSApp.sendAction(try #require(toggle.action), to: toggle.target, from: toggle))
        #expect(viewModel.ephemeralSettingsBannerDismissed)
        #expect(preferences.ephemeralSettingsBannerDismissed)

        let reset = try #require(
            allSubviews(NSButton.self, in: controller.view) { $0.title == "Reset All Reminders" }.first)
        #expect(NSApp.sendAction(try #require(reset.action), to: reset.target, from: reset))
        #expect(viewModel.ephemeralSettingsBannerDismissed == false)
        #expect(toggle.state == .on)
    }

    @Test("Turning the app-wide install reminder off disables and explains the per-VM rows")
    func appWideDisableGreysPerVMRows() throws {
        let (controller, viewModel) = makeLaidOutPane(vmCount: 2)
        defer { controller.viewDidDisappear() }

        #expect(vmSwitches(in: controller).allSatisfy { $0.isEnabled })
        // A state note holds no text while its state is off.
        #expect(findLabel(containing: "No effect while the reminder above is off", in: controller.view) == nil)

        try setAppWideInstallReminder(on: false, in: controller)

        #expect(viewModel.agentInstallPromptDisabled == true)
        #expect(vmSwitches(in: controller).allSatisfy { !$0.isEnabled })
        let explanation = try #require(
            findLabel(containing: "No effect while the reminder above is off", in: controller.view))
        #expect(!explanation.isHidden)

        try setAppWideInstallReminder(on: true, in: controller)

        #expect(viewModel.agentInstallPromptDisabled == false)
        #expect(vmSwitches(in: controller).allSatisfy { $0.isEnabled })
        #expect(explanation.isHidden)
    }

    /// The window is sized once per tab selection.
    ///
    /// So the caption appearing grows the content in place with nothing to say
    /// the pane now overflows; re-arming the indicator is what lets the scroller
    /// flash again.
    @Test("Revealing the override caption flashes the scroller again")
    func revealingOverrideCaptionRearmsFlash() throws {
        let controller = makeShownPane(vmCount: overflowingVMCount())
        defer { controller.viewDidDisappear() }
        let indicator = try #require(controller.scrollMoreIndicatorForTesting)

        // The pane overflows the height cap, so appearing flashes — exactly
        // once, against the pane's settled geometry rather than the zero-height
        // frame the first row build runs under.
        #expect(indicator.flashCountForTesting == 1)

        // The latch is one-shot, so without a re-arm the caption could grow the
        // content with no cue at all.
        try setAppWideInstallReminder(on: false, in: controller)
        #expect(indicator.flashCountForTesting == 2)

        // A refresh that moves neither the row count nor the caption must not
        // re-arm, or an unrelated toggle would flash the scroller for nothing.
        try setAppWideInstallReminder(on: false, in: controller)
        #expect(indicator.flashCountForTesting == 2)
    }

    /// A tab switch adopts the pane into the already-visible Settings window
    /// before its appearance pass runs.
    ///
    /// The appearance pass's layout churn therefore recomputes overflow against
    /// a window the flash may fire in — while the tab transition still hides the
    /// pane. The first visit must hold the cue for the container's arrival hook:
    /// one spent here plays its fade-in where nobody can see, and the arrival
    /// re-arm then meets a scroller already at full alpha — solid, then a bare
    /// fade-out, unlike every later visit.
    @Test("The first visit holds the flash for the arrival cue")
    func firstVisitHoldsFlashForArrivalCue() throws {
        let viewModel = makeViewModel()
        for index in 1...overflowingVMCount() {
            viewModel.library.admitFixture(name: "VM \(index)", guestOS: .macOS)
        }
        let controller = RemindersSettingsViewController(viewModel: viewModel, visibleFrame: offDesktopVisibleFrame)
        _ = controller.view

        // Host the pane in an on-screen window first, as the tab view does — and
        // sized, because the tab view pins the adopted view to its own bounds
        // (the outgoing pane's height) before any appearance callback runs. The
        // pre-appearance row build and measurement layout therefore both run
        // against real, overflowing geometry in a visible window.
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 400))
        showInTestWindow(host)
        defer { controller.viewDidDisappear() }
        controller.view.setFrameSize(NSSize(width: 520, height: 400))
        host.addSubview(controller.view)
        controller.refreshContent()
        controller.viewWillAppear()
        controller.view.layoutSubtreeIfNeeded()

        let indicator = try #require(controller.scrollMoreIndicatorForTesting)
        #expect(indicator.flashCountForTesting == 0)

        // The container's arrival hook spends it — the first flash anyone sees.
        controller.rearmScrollMoreCue()
        #expect(indicator.flashCountForTesting == 1)
    }

    /// The row reads the key's gate, as VM Settings' switch does, so it doesn't
    /// offer a flip the configuration verb would refuse.
    @Test("A per-VM row is disabled while its VM's state takes no live edit, and follows it")
    func perVMRowFollowsTheLiveGate() async throws {
        let (controller, viewModel) = makeLaidOutPane(vmCount: 1)
        defer { controller.viewDidDisappear() }
        let instance = viewModel.instances[0]
        #expect(try #require(vmSwitches(in: controller).first).isEnabled)

        instance.activity.placeForTesting(.operating(.saving, from: .running(sessionID: UUID())))
        #expect(
            !viewModel.capabilities.isAvailable(
                VMConfigurationKeyRegistry.agentInstallReminder, writing: "false", on: instance))

        // The pane's observation loop applies on a later turn.
        try await waitUntil { vmSwitches(in: controller).first?.isEnabled == false }

        instance.activity.placeForTesting(.stopped)
        try await waitUntil { vmSwitches(in: controller).first?.isEnabled == true }
    }

    @Test("Only a VM the install reminder applies to gets a per-VM row")
    func onlyMacOSVMsGetARow() throws {
        let viewModel = makeViewModel()
        viewModel.library.admitFixture(name: "Mac", guestOS: .macOS)
        viewModel.library.admitFixture(name: "Tux", guestOS: .linux)
        let controller = RemindersSettingsViewController(viewModel: viewModel, visibleFrame: offDesktopVisibleFrame)
        _ = controller.view
        controller.refreshContent()
        controller.viewWillAppear()
        defer { controller.viewDidDisappear() }

        #expect(vmSwitches(in: controller).count == 1)
        #expect(findLabel(withText: "Mac", in: controller.view) != nil)
        #expect(findLabel(withText: "Tux", in: controller.view) == nil)
    }

    @Test("A per-VM switch whose edit does not land goes back to what its VM holds")
    func unsavedPerVMEditRepaintsTheSwitch() throws {
        let viewModel = makeViewModel()
        let storage = try #require(viewModel.storageService as? MockVMStorageService)
        let instance = viewModel.library.admitFixture(name: "Mac", guestOS: .macOS, files: storage.files)
        storage.setSaveHostStateError(CocoaError(.fileWriteNoPermission))
        let controller = RemindersSettingsViewController(viewModel: viewModel, visibleFrame: offDesktopVisibleFrame)
        _ = controller.view
        controller.refreshContent()
        controller.viewWillAppear()
        defer { controller.viewDidDisappear() }
        let toggle = try #require(vmSwitches(in: controller).first)

        toggle.state = .off
        toggle.sendAction(toggle.action, to: toggle.target)

        #expect(!instance.hostState.agentInstallNudgeDismissed)
        #expect(toggle.state == .on)
    }

    /// The Reminders tab of a Settings window holding seven VMs — taller than
    /// the pane is wide — its window fitting whatever `visibleFrame` returns
    /// when the pane publishes.
    private func showRemindersTab(
        visibleFrame: @escaping @MainActor (NSWindow?) -> NSRect?
    ) throws -> (window: NSWindow, controller: RemindersSettingsViewController) {
        let viewModel = makeViewModel()
        for index in 1...7 {
            viewModel.library.admitFixture(name: "VM \(index)", guestOS: .macOS)
        }
        let tabController = SettingsTabViewController(viewModel: viewModel, visibleFrame: visibleFrame)
        let window = makeTestWindow(styleMask: [.titled, .closable])
        window.contentViewController = tabController
        window.orderFront(nil)
        let item = try #require(
            tabController.tabViewItems.first { $0.viewController is RemindersSettingsViewController })
        tabController.tabView.selectTabViewItem(item)
        let controller = try #require(item.viewController as? RemindersSettingsViewController)
        window.layoutIfNeeded()
        return (window, controller)
    }

    private func overrideNote(in controller: RemindersSettingsViewController) throws -> NSTextField {
        try #require(findLabel(containing: "No effect while the reminder above is off", in: controller.view))
    }

    /// A visible frame a test changes while the pane is up.
    private final class VisibleFrame {
        var frame = WindowStage.offDesktopVisibleFrame
    }

    @Test("On a display too short for the override note, the window stops at the cap and the pane scrolls")
    func overrideNoteOnShortDisplayScrolls() throws {
        let visibleFrame = VisibleFrame()
        let (window, controller) = try showRemindersTab(visibleFrame: { _ in visibleFrame.frame })
        defer { controller.viewDidDisappear() }
        let paneBefore = controller.preferredContentSize.height
        let windowBefore = window.contentLayoutRect.height
        // One point of room below the window: less than any note needs.
        let chrome = window.frame.height - window.contentRect(forFrameRect: window.frame).height
        visibleFrame.frame.size.height = paneBefore + 1 + chrome

        try setAppWideInstallReminder(on: false, in: controller)
        window.layoutIfNeeded()

        #expect(try overrideNote(in: controller).frame.height > 1)
        #expect(controller.preferredContentSize.height == paneBefore + 1)
        #expect(window.contentLayoutRect.height == windowBefore + 1)
        let scrollView = try #require((controller.view as? SettingsPaneRootView)?.content as? NSScrollView)
        let documentView = try #require(scrollView.documentView)
        #expect(documentView.frame.height > scrollView.frame.height)
    }
}
