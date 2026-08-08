import AppKit
import Foundation
import Testing

@testable import Kernova

/// Layout tests for the Reminders settings pane.
///
/// The pane hugs its content when short and scrolls past a height cap. The
/// regression risk is the capped state: the pane's frame is fixed by the tab
/// controller, and a hug constraint that outranks the text's compression
/// resistance resolves the shortfall by collapsing every section header and
/// caption to zero height instead of scrolling.
@Suite("Reminders Settings Tests", .serialized)
@MainActor
struct RemindersSettingsViewControllerTests {
    private let preferences: AppPreferences

    init() {
        self.preferences = makeEphemeralPreferences(suiteName: "test.kernova.reminders-settings")
    }

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

    private func makeInstance(name: String) -> VMInstance {
        let config = VMConfiguration(name: name, guestOS: .macOS, bootMode: .efi)
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(config.id.uuidString, isDirectory: true)
        return VMInstance(configuration: config, bundleURL: bundleURL)
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
            viewModel.instances.append(makeInstance(name: "VM \(index)"))
        }
        let controller = RemindersSettingsViewController(
            preferences: preferences, viewModel: viewModel)
        _ = controller.view
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
    private func makeShownPane(vmCount: Int) -> (
        controller: RemindersSettingsViewController, window: NSWindow
    ) {
        let viewModel = makeViewModel()
        for index in 1...vmCount {
            viewModel.instances.append(makeInstance(name: "VM \(index)"))
        }
        let controller = RemindersSettingsViewController(
            preferences: preferences, viewModel: viewModel)
        // Measure while detached, exactly as the pane does before the tab
        // controller sizes the window, then hand the window that measurement.
        controller.viewWillAppear()
        let window = showInTestWindow(controller.view, size: controller.preferredContentSize)
        controller.view.layoutSubtreeIfNeeded()
        // Stands in for the tab container's `viewDidAppear`. Ordering a window on
        // screen changes no geometry, so nothing re-runs the cue on its own — the
        // arrival hook is what spends the flash once there is something to see.
        controller.rearmScrollMoreCue()
        return (controller, window)
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

    /// The grouped-form card `control` sits in — the nearest ancestor carrying
    /// the card's rounded `NSBox` background.
    ///
    /// Keyed on the corner radius, not on `NSBox` alone: a multi-row card's
    /// inter-row hairlines are `NSBox`es too, so the looser test stops at the
    /// card's inner stack and reports an edge inset by the card's padding.
    private func card(containing control: NSView) -> NSView? {
        var candidate = control.superview
        while let view = candidate {
            if view.subviews.contains(where: { ($0 as? NSBox)?.cornerRadius ?? 0 > 0 }) {
                return view
            }
            candidate = view.superview
        }
        return nil
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

    private func expectHeadersAndCaptionsVisible(in root: NSView) {
        for text in ["App Reminders", "Virtual Machine Reminders"] {
            let header = findLabel(withText: text, in: root)
            #expect(header != nil, "header '\(text)' missing from the view tree")
            if let header {
                #expect(header.frame.height > 0, "header '\(text)' collapsed: \(header.frame)")
            }
        }
        for fragment in [
            "Appears when you quit",
            "sidebar prompt to install",
            "stop its own reminder",
            "Turns every reminder above back on",
        ] {
            let caption = findLabel(containing: fragment, in: root)
            #expect(caption != nil, "caption '\(fragment)…' missing from the view tree")
            if let caption {
                #expect(
                    caption.frame.height > 0, "caption '\(fragment)…' collapsed: \(caption.frame)")
            }
        }
    }

    @Test("A VM list past the height cap scrolls instead of collapsing the text")
    func cappedPaneScrollsAndKeepsText() throws {
        let controller = makeLaidOutController(vmCount: 9)
        defer { controller.viewDidDisappear() }

        expectHeadersAndCaptionsVisible(in: controller.view)

        // The content must keep its natural height and overflow the capped
        // pane — a squeezed document exactly matching the pane's height is the
        // collapse bug, not scrolling.
        let scrollView = try #require(controller.view as? NSScrollView)
        let documentView = try #require(scrollView.documentView)
        #expect(documentView.frame.height > scrollView.frame.height)
    }

    /// Each governing switch owns a card, so its caption sits directly under it
    /// and needs no "The <name> reminder…" prefix to say what it describes.
    @Test("Each reminder switch is its own single-row card")
    func remindersAreSeparateCards() throws {
        let controller = makeLaidOutController(vmCount: 2)
        defer { controller.viewDidDisappear() }

        #expect(findLabel(withText: "Menu Bar Quit Reminder", in: controller.view) != nil)
        #expect(findLabel(withText: "Guest Agent Install Reminder", in: controller.view) != nil)
        // Two app-wide switches plus one per VM.
        #expect(allSubviews(NSSwitch.self, in: controller.view).count == 4)

        let menuBarToggle = try #require(
            switches(action: "menuBarQuitToggled", in: controller).first)
        let agentToggle = try #require(
            switches(action: "agentInstallToggled", in: controller).first)
        let menuBarCard = try #require(card(containing: menuBarToggle))
        let agentCard = try #require(card(containing: agentToggle))
        #expect(menuBarCard !== agentCard)
        #expect(allSubviews(NSSwitch.self, in: menuBarCard).count == 1)
        #expect(allSubviews(NSSwitch.self, in: agentCard).count == 1)
    }

    /// Apple's guidance for showing that one control governs others is to indent
    /// the subordinates beneath it.
    ///
    /// The greying only speaks while the governing switch is off; the indent
    /// states the relationship at all times.
    @Test("The per-VM rows are indented beneath the switch that governs them")
    func perVMRowsIndentUnderGoverningSwitch() throws {
        let controller = makeLaidOutController(vmCount: 2)
        defer { controller.viewDidDisappear() }

        let agentToggle = try #require(
            switches(action: "agentInstallToggled", in: controller).first)
        let governingCard = try #require(card(containing: agentToggle))
        let vmToggle = try #require(vmSwitches(in: controller).first)
        let vmCard = try #require(card(containing: vmToggle))

        let root = controller.view
        let governingLeading = governingCard.convert(governingCard.bounds, to: root).minX
        let subordinateLeading = vmCard.convert(vmCard.bounds, to: root).minX
        #expect(subordinateLeading - governingLeading == groupedFormSubOptionIndent)
    }

    @Test("Turning the app-wide install reminder off disables and explains the per-VM rows")
    func appWideDisableGreysPerVMRows() throws {
        let (controller, viewModel) = makeLaidOutPane(vmCount: 2)
        defer { controller.viewDidDisappear() }

        #expect(vmSwitches(in: controller).allSatisfy { $0.isEnabled })
        let explanation = try #require(
            findLabel(containing: "so these have no effect", in: controller.view))
        #expect(explanation.isHidden)

        try setAppWideInstallReminder(on: false, in: controller)

        #expect(viewModel.agentInstallPromptDisabled == true)
        #expect(vmSwitches(in: controller).allSatisfy { !$0.isEnabled })
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
        let (controller, window) = makeShownPane(vmCount: 9)
        defer {
            controller.viewDidDisappear()
            window.orderOut(nil)
        }
        let indicator = try #require(controller.scrollMoreIndicatorForTesting)

        // A 9-VM pane overflows the height cap, so appearing flashes — exactly
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
        for index in 1...9 {
            viewModel.instances.append(makeInstance(name: "VM \(index)"))
        }
        let controller = RemindersSettingsViewController(
            preferences: preferences, viewModel: viewModel)
        _ = controller.view

        // Host the pane in an on-screen window first, as the tab view does — and
        // sized, because the tab view pins the adopted view to its own bounds
        // (the outgoing pane's height) before any appearance callback runs. The
        // pre-appearance row build and measurement layout therefore both run
        // against real, overflowing geometry in a visible window.
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 400))
        let window = showInTestWindow(host)
        defer {
            controller.viewDidDisappear()
            window.orderOut(nil)
        }
        controller.view.setFrameSize(NSSize(width: 520, height: 400))
        host.addSubview(controller.view)
        controller.viewWillAppear()
        controller.view.layoutSubtreeIfNeeded()

        let indicator = try #require(controller.scrollMoreIndicatorForTesting)
        #expect(indicator.flashCountForTesting == 0)

        // The container's arrival hook spends it — the first flash anyone sees.
        controller.rearmScrollMoreCue()
        #expect(indicator.flashCountForTesting == 1)
    }

    /// Both captions describe the per-VM switches, so with none on screen they
    /// point at nothing — "these have no effect" directly under "No virtual
    /// machines yet." reads as a bug.
    @Test("Neither per-VM caption shows when there are no virtual machines")
    func perVMCaptionsHideWithoutVMs() throws {
        let controller = RemindersSettingsViewController(
            preferences: preferences, viewModel: makeViewModel())
        _ = controller.view
        controller.viewWillAppear()
        defer { controller.viewDidDisappear() }
        controller.view.setFrameSize(controller.preferredContentSize)
        controller.view.layoutSubtreeIfNeeded()

        // Turning the app-wide reminder off is what would reveal the override
        // caption; the empty state has to suppress it anyway.
        try setAppWideInstallReminder(on: false, in: controller)

        let visible = allSubviews(NSTextField.self, in: controller.view) { !$0.isHidden }
            .map(\.stringValue)
        #expect(visible.contains { $0.hasPrefix("No virtual machines yet") })
        #expect(!visible.contains { $0.contains("have no effect") })
        #expect(!visible.contains { $0.contains("Turn a virtual machine off") })
    }

    /// The disabled rows keep showing each VM's own setting, so turning the
    /// app-wide reminder back on restores what the user had chosen.
    @Test("A disabled per-VM row still reflects its VM's dismissed flag")
    func disabledPerVMRowKeepsItsState() throws {
        let (controller, viewModel) = makeLaidOutPane(vmCount: 2)
        defer { controller.viewDidDisappear() }
        viewModel.instances[0].configuration.agentInstallNudgeDismissed = true
        viewModel.agentInstallPromptDisabled = true
        controller.viewWillAppear()

        let switches = vmSwitches(in: controller)
        #expect(switches.count == 2)
        #expect(switches[0].state == .off)
        #expect(switches[1].state == .on)
    }

    @Test("A short VM list hugs the content with the text laid out")
    func shortPaneHugsContentAndKeepsText() throws {
        let controller = makeLaidOutController(vmCount: 2)
        defer { controller.viewDidDisappear() }

        expectHeadersAndCaptionsVisible(in: controller.view)

        // Hugged: everything fits, so nothing scrolls.
        let scrollView = try #require(controller.view as? NSScrollView)
        let documentView = try #require(scrollView.documentView)
        #expect(documentView.frame.height <= scrollView.frame.height)
    }
}
