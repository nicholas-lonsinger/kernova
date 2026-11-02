import AppKit
import KernovaAgentCore
import KernovaAgentHost
import KernovaTestSupport
@testable import KernovaCore
@testable import KernovaUI
import Testing

@Suite("GuestAgentStatusViewController Tests", .caseScoped)
@MainActor
struct GuestAgentStatusViewControllerTests {
    private static let install = GuestAgentDiskControl.Model(
        title: "Install Guest Agent…", isEnabled: true, action: .mount(.install))
    private static let eject = GuestAgentDiskControl.Model(
        title: "Eject Guest Agent Media", isEnabled: true, action: .eject)
    private static let withheld = GuestAgentDiskControl.Model(
        title: GuestAgentDiskControl.unavailableTitle, isEnabled: false, action: .mount(.install))

    @Test("default state — title/body/action-button reflect .waiting")
    func defaultState() {
        let vc = GuestAgentStatusViewController()
        vc.update(
            presentation: GuestAgentPresentation(macOSAgent: .waiting), isInstallerMounted: false,
            diskControl: Self.install, vmName: "TestVM",
            hasDismissAction: true)
        vc.loadViewIfNeeded()

        #expect(titleLabel(in: vc.view)?.stringValue == "Set up the Kernova guest agent")
        #expect(actionButton(in: vc.view)?.title == "Install Guest Agent…")
        #expect(bodyLabel(in: vc.view)?.stringValue.contains("TestVM") == true)
    }

    @Test("update() swaps title and body per status")
    func updatePerStatus() {
        let vc = GuestAgentStatusViewController()
        vc.loadViewIfNeeded()

        let cases: [(status: AgentStatus, title: String, bodyContains: String)] = [
            (.waiting, "Set up the Kernova guest agent", "clipboard sync"),
            (.outdated(installed: "0.9.1", bundled: "0.9.2"), "Update available", "0.9.1"),
            (.current(version: "0.9.2"), "Guest agent connected", "0.9.2"),
            (.unresponsive(version: "0.9.2"), "Guest agent unresponsive", "stopped responding"),
            (.connecting(expected: "0.9.2"), "Connecting to guest agent", "Waiting for guest agent"),
            (.expectedMissing(expected: "0.9.2"), "Guest agent didn't reconnect", "isn't connected now"),
        ]

        for testCase in cases {
            vc.update(
                presentation: GuestAgentPresentation(macOSAgent: testCase.status), isInstallerMounted: false,
                diskControl: Self.install,
                vmName: "TestVM", hasDismissAction: false)
            #expect(titleLabel(in: vc.view)?.stringValue == testCase.title)
            #expect(bodyLabel(in: vc.view)?.stringValue.contains(testCase.bodyContains) == true)
        }
    }

    @Test("The action button carries the disk control it is handed")
    func actionButtonFollowsDiskControl() {
        let vc = GuestAgentStatusViewController()
        vc.loadViewIfNeeded()

        let cases: [(control: GuestAgentDiskControl.Model, title: String)] = [
            (Self.install, "Install Guest Agent…"),
            (Self.eject, "Eject Guest Agent Media"),
            (Self.withheld, "Done"),
        ]
        for (control, title) in cases {
            vc.update(
                presentation: GuestAgentPresentation(macOSAgent: .waiting), isInstallerMounted: false,
                diskControl: control, vmName: "TestVM",
                hasDismissAction: false)
            #expect(actionButton(in: vc.view)?.title == title)
        }
    }

    @Test("Body copy for a missing agent describes no particular cause")
    func absentAgentCopyIsCauseAgnostic() {
        // Both states are reached after a mid-session death as well as after a
        // boot, so neither may claim a boot happened, nor guess why the agent
        // is gone.
        let connecting = GuestAgentStatusViewController.bodyText(
            for: .connecting(expected: "0.9.2"), isInstallerMounted: false, vmName: "TestVM")
        #expect(!connecting.contains("boot"))

        let missing = GuestAgentStatusViewController.bodyText(
            for: .expectedMissing(expected: "0.9.2"), isInstallerMounted: false, vmName: "TestVM")
        #expect(!missing.contains("boot"))
        #expect(!missing.contains("LaunchAgent"))
    }

    @Test("Don't show again button visibility tracks hasDismissAction")
    func dismissButtonVisibility() {
        let vc = GuestAgentStatusViewController()
        vc.loadViewIfNeeded()

        vc.update(
            presentation: GuestAgentPresentation(macOSAgent: .waiting), isInstallerMounted: false,
            diskControl: Self.install, vmName: "TestVM",
            hasDismissAction: true)
        #expect(dismissButton(in: vc.view)?.isHidden == false)

        vc.update(
            presentation: GuestAgentPresentation(macOSAgent: .waiting), isInstallerMounted: false,
            diskControl: Self.install, vmName: "TestVM",
            hasDismissAction: false)
        #expect(dismissButton(in: vc.view)?.isHidden == true)
    }

    /// Clicks the action button presenting `diskControl` and returns how often
    /// each callback fired, alongside the title the button carried.
    private func tapAction(diskControl: GuestAgentDiskControl.Model) -> (
        title: String?, diskControlCount: Int, doneCount: Int
    ) {
        let vc = GuestAgentStatusViewController()
        var diskControlCount = 0
        var doneCount = 0
        vc.onDiskControl = { diskControlCount += 1 }
        vc.onDone = { doneCount += 1 }
        vc.update(
            presentation: GuestAgentPresentation(macOSAgent: .waiting),
            isInstallerMounted: diskControl.action == .eject,
            diskControl: diskControl, vmName: "TestVM", hasDismissAction: false)
        vc.loadViewIfNeeded()
        let button = actionButton(in: vc.view)
        button?.performClick(nil)
        return (button?.title, diskControlCount, doneCount)
    }

    @Test("An enabled control's button fires the disk control")
    func enabledControlFires() {
        let (title, diskControlCount, doneCount) = tapAction(diskControl: Self.eject)
        #expect(title == "Eject Guest Agent Media")
        #expect(diskControlCount == 1)
        #expect(doneCount == 0)
    }

    @Test("While the control is disabled the button reads Done and only closes")
    func disabledControlIsDone() {
        let (title, diskControlCount, doneCount) = tapAction(diskControl: Self.withheld)
        #expect(title == "Done")
        #expect(doneCount == 1)
        #expect(diskControlCount == 0)
    }

    @Test(
        "With the installer attached the body says so instead of telling the user to mount it",
        arguments: [
            AgentStatus.waiting,
            .outdated(installed: "0.9.1", bundled: "0.9.2"),
            .expectedMissing(expected: "0.9.2"),
        ])
    func installerAttachedBody(status: AgentStatus) {
        let body = GuestAgentStatusViewController.bodyText(
            for: status, isInstallerMounted: true, vmName: "TestVM")
        #expect(body.contains("installer disk is attached"))
        #expect(!body.contains("Mounting"))
        #expect(!body.contains("Reinstalling presents"))
    }

    @Test("dismiss button click fires onDismiss")
    func dismissFiresCallback() {
        let vc = GuestAgentStatusViewController()
        var diskControlCount = 0
        var doneCount = 0
        var dismissCount = 0
        vc.onDiskControl = { diskControlCount += 1 }
        vc.onDone = { doneCount += 1 }
        vc.onDismiss = { dismissCount += 1 }
        vc.update(
            presentation: GuestAgentPresentation(macOSAgent: .waiting), isInstallerMounted: false,
            diskControl: Self.install, vmName: "TestVM",
            hasDismissAction: true)
        vc.loadViewIfNeeded()

        dismissButton(in: vc.view)?.performClick(nil)
        #expect(dismissCount == 1)
        #expect(diskControlCount == 0)
        #expect(doneCount == 0)
    }

    @Test("A hub presentation shows a line per agent and its capability rows in place of the body")
    func hubRows() {
        let vc = GuestAgentStatusViewController()
        vc.loadViewIfNeeded()
        let snapshot = AgentHubSnapshot(
            peers: [
                PeerSummary(
                    handle: PeerHandle(rawValue: 1), role: .sessionPeer, scope: .user, os: .linux, sessionID: "2",
                    userName: "pbear", console: .on, versionLabel: "1.0", standing: .current, isResponsive: true)
            ], features: FeatureStatusTable([(feature: .logs, status: .absent(.disabledByPolicy, debugDetail: ""))]))

        vc.update(
            presentation: GuestAgentPresentation(hub: snapshot), isInstallerMounted: false,
            diskControl: Self.withheld, vmName: "TestVM", hasDismissAction: false)

        #expect(titleLabel(in: vc.view)?.stringValue == "Guest agent connected")
        #expect(bodyLabel(in: vc.view)?.isHidden == true)
        #expect(
            visibleTexts(in: vc.view) == [
                "Guest agent connected", "Session agent — pbear", "Up to date", "Status", "Connected",
                "Guest logs in Console", "Turned off in Settings.",
            ])

        vc.update(
            presentation: GuestAgentPresentation(macOSAgent: .current(version: "0.9.2")), isInstallerMounted: false,
            diskControl: Self.withheld, vmName: "TestVM", hasDismissAction: false)
        #expect(bodyLabel(in: vc.view)?.isHidden == false)
        #expect(!visibleTexts(in: vc.view).contains("Status"))
    }

    @Test("An attached disk opened from a terminal shows its command with a Copy button; none otherwise")
    func installCommandRow() {
        let vc = GuestAgentStatusViewController()
        vc.loadViewIfNeeded()
        let command = #"sh "$(findmnt -nro TARGET LABEL=KERNOVA_AGENT)/install.sh""#
        var eject = Self.eject
        eject.installCommand = command
        vc.update(
            presentation: GuestAgentPresentation(hub: .empty), isInstallerMounted: true, diskControl: eject,
            vmName: "Ubuntu", hasDismissAction: false)
        #expect(visibleTexts(in: vc.view).contains(command))
        #expect(visibleTexts(in: vc.view).contains(LinuxAgentDisk.installCommandPrecondition))
        let copy = firstSubview(NSButton.self, in: vc.view) { $0.accessibilityLabel() == "Copy Install Command" }
        #expect(copy?.isHidden == false)
        #expect(vc.installCommand == command)

        vc.update(
            presentation: GuestAgentPresentation(hub: .empty), isInstallerMounted: false, diskControl: Self.install,
            vmName: "Ubuntu", hasDismissAction: false)
        #expect(!visibleTexts(in: vc.view).contains(command))
        #expect(vc.installCommand == nil)
    }

    // MARK: - Helpers

    /// The text of every label on screen, in document order: none under a hidden view.
    @MainActor
    private func visibleTexts(in view: NSView) -> [String] {
        guard !view.isHidden else { return [] }
        var texts: [String] = []
        if let field = view as? NSTextField, !field.isEditable { texts.append(field.stringValue) }
        for subview in view.subviews { texts += visibleTexts(in: subview) }
        return texts
    }

    @MainActor
    private func titleLabel(in view: NSView) -> NSTextField? {
        // Title is the first NSTextField in document order, and the only
        // one rendered with the `.headline` font.
        firstSubview(NSTextField.self, in: view) {
            $0.font == .preferredFont(forTextStyle: .headline)
        }
    }

    @MainActor
    private func bodyLabel(in view: NSView) -> NSTextField? {
        // Body label uses `.callout` font.
        firstSubview(NSTextField.self, in: view) {
            $0.font == .preferredFont(forTextStyle: .callout)
        }
    }

    @MainActor
    private func actionButton(in view: NSView) -> NSButton? {
        // Action button has Return as its key equivalent.
        firstSubview(NSButton.self, in: view) { $0.keyEquivalent == "\r" }
    }

    @MainActor
    private func dismissButton(in view: NSView) -> NSButton? {
        findButton(titled: "Don't show again", in: view)
    }
}
