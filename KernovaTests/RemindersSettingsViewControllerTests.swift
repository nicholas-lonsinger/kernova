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
        let controller = makeLaidOutPane(vmCount: 9).controller
        defer { controller.viewDidDisappear() }
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
