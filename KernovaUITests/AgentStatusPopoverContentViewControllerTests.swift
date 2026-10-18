import AppKit
import KernovaTestSupport
@testable import KernovaCore
@testable import KernovaUI
import Testing

@Suite("AgentStatusPopoverContentViewController Tests", .caseScoped)
@MainActor
struct AgentStatusPopoverContentViewControllerTests {
    private static let install = GuestAgentDiskControl.Model(
        title: "Install Guest Agent…", isEnabled: true, action: .mount(.install))
    private static let eject = GuestAgentDiskControl.Model(
        title: "Eject Guest Agent Media", isEnabled: true, action: .eject)
    private static let withheld = GuestAgentDiskControl.Model(
        title: GuestAgentDiskControl.unavailableTitle, isEnabled: false, action: .mount(.install))

    @Test("default state — title/body/action-button reflect .waiting")
    func defaultState() {
        let vc = AgentStatusPopoverContentViewController()
        vc.update(
            status: .waiting, isInstallerMounted: false, diskControl: Self.install, vmName: "TestVM",
            hasDismissAction: true)
        vc.loadViewIfNeeded()

        #expect(titleLabel(in: vc.view)?.stringValue == "Set up the Kernova guest agent")
        #expect(actionButton(in: vc.view)?.title == "Install Guest Agent…")
        #expect(bodyLabel(in: vc.view)?.stringValue.contains("TestVM") == true)
    }

    @Test("update() swaps title and body per status")
    func updatePerStatus() {
        let vc = AgentStatusPopoverContentViewController()
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
                status: testCase.status, isInstallerMounted: false, diskControl: Self.install,
                vmName: "TestVM", hasDismissAction: false)
            #expect(titleLabel(in: vc.view)?.stringValue == testCase.title)
            #expect(bodyLabel(in: vc.view)?.stringValue.contains(testCase.bodyContains) == true)
        }
    }

    @Test("The action button carries the disk control it is handed")
    func actionButtonFollowsDiskControl() {
        let vc = AgentStatusPopoverContentViewController()
        vc.loadViewIfNeeded()

        let cases: [(control: GuestAgentDiskControl.Model, title: String)] = [
            (Self.install, "Install Guest Agent…"),
            (Self.eject, "Eject Guest Agent Media"),
            (Self.withheld, "Done"),
        ]
        for (control, title) in cases {
            vc.update(
                status: .waiting, isInstallerMounted: false, diskControl: control, vmName: "TestVM",
                hasDismissAction: false)
            #expect(actionButton(in: vc.view)?.title == title)
        }
    }

    @Test("Body copy for a missing agent describes no particular cause")
    func absentAgentCopyIsCauseAgnostic() {
        // Both states are reached after a mid-session death as well as after a
        // boot, so neither may claim a boot happened, nor guess why the agent
        // is gone.
        let connecting = AgentStatusPopoverContentViewController.bodyText(
            for: .connecting(expected: "0.9.2"), isInstallerMounted: false, vmName: "TestVM")
        #expect(!connecting.contains("boot"))

        let missing = AgentStatusPopoverContentViewController.bodyText(
            for: .expectedMissing(expected: "0.9.2"), isInstallerMounted: false, vmName: "TestVM")
        #expect(!missing.contains("boot"))
        #expect(!missing.contains("LaunchAgent"))
    }

    @Test("Don't show again button visibility tracks hasDismissAction")
    func dismissButtonVisibility() {
        let vc = AgentStatusPopoverContentViewController()
        vc.loadViewIfNeeded()

        vc.update(
            status: .waiting, isInstallerMounted: false, diskControl: Self.install, vmName: "TestVM",
            hasDismissAction: true)
        #expect(dismissButton(in: vc.view)?.isHidden == false)

        vc.update(
            status: .waiting, isInstallerMounted: false, diskControl: Self.install, vmName: "TestVM",
            hasDismissAction: false)
        #expect(dismissButton(in: vc.view)?.isHidden == true)
    }

    /// Clicks the action button presenting `diskControl` and returns how often
    /// each callback fired, alongside the title the button carried.
    private func tapAction(diskControl: GuestAgentDiskControl.Model) -> (
        title: String?, diskControlCount: Int, doneCount: Int
    ) {
        let vc = AgentStatusPopoverContentViewController()
        var diskControlCount = 0
        var doneCount = 0
        vc.onDiskControl = { diskControlCount += 1 }
        vc.onDone = { doneCount += 1 }
        vc.update(
            status: .waiting, isInstallerMounted: diskControl.action == .eject,
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
        let body = AgentStatusPopoverContentViewController.bodyText(
            for: status, isInstallerMounted: true, vmName: "TestVM")
        #expect(body.contains("installer disk is attached"))
        #expect(!body.contains("Mounting"))
        #expect(!body.contains("Reinstalling presents"))
    }

    @Test("dismiss button click fires onDismiss")
    func dismissFiresCallback() {
        let vc = AgentStatusPopoverContentViewController()
        var diskControlCount = 0
        var doneCount = 0
        var dismissCount = 0
        vc.onDiskControl = { diskControlCount += 1 }
        vc.onDone = { doneCount += 1 }
        vc.onDismiss = { dismissCount += 1 }
        vc.update(
            status: .waiting, isInstallerMounted: false, diskControl: Self.install, vmName: "TestVM",
            hasDismissAction: true)
        vc.loadViewIfNeeded()

        dismissButton(in: vc.view)?.performClick(nil)
        #expect(dismissCount == 1)
        #expect(diskControlCount == 0)
        #expect(doneCount == 0)
    }

    // MARK: - Helpers

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
