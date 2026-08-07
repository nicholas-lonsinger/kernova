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
            "Menu Bar Quit Reminder appears",
            "stop its sidebar reminder",
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

    @Test("The app card carries the Menu Bar Quit and Guest Agent Install rows")
    func appCardHasBothRows() throws {
        let controller = makeLaidOutController(vmCount: 2)
        defer { controller.viewDidDisappear() }

        #expect(findLabel(withText: "Menu Bar Quit Reminder", in: controller.view) != nil)
        #expect(findLabel(withText: "Guest Agent Install Reminder", in: controller.view) != nil)
        // Two app-wide switches plus one per VM: an extra would mean a third row
        // crept into the app card.
        #expect(allSubviews(NSSwitch.self, in: controller.view).count == 4)
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
