import Testing
import AppKit
import KernovaTestSupport
@testable import Kernova

@Suite("AgentStatusPopoverContentViewController Tests", .caseScoped)
@MainActor
struct AgentStatusPopoverContentViewControllerTests {
    @Test("default state — title/body/action-button reflect .waiting")
    func defaultState() {
        let vc = AgentStatusPopoverContentViewController()
        vc.update(status: .waiting, isInstallerMounted: false, vmName: "TestVM", hasDismissAction: true)
        vc.loadViewIfNeeded()

        #expect(titleLabel(in: vc.view)?.stringValue == "Set up the Kernova guest agent")
        #expect(actionButton(in: vc.view)?.title == "Install Guest Agent…")
        #expect(bodyLabel(in: vc.view)?.stringValue.contains("TestVM") == true)
    }

    @Test("update() swaps title, body, and action button per status")
    func updatePerStatus() {
        let vc = AgentStatusPopoverContentViewController()
        vc.loadViewIfNeeded()

        let cases:
            [(
                status: AgentStatus, title: String, action: String, bodyContains: String
            )] = [
                (.waiting, "Set up the Kernova guest agent", "Install Guest Agent…", "clipboard sync"),
                (
                    .outdated(installed: "0.9.1", bundled: "0.9.2"),
                    "Update available", "Update Guest Agent…", "0.9.1"
                ),
                (.current(version: "0.9.2"), "Guest agent connected", "Manage Guest Agent…", "0.9.2"),
                (
                    .unresponsive(version: "0.9.2"),
                    "Guest agent unresponsive", "Manage Guest Agent…", "stopped responding"
                ),
                (
                    .connecting(expected: "0.9.2"),
                    "Connecting to guest agent", "Done", "Waiting for guest agent"
                ),
                (
                    .expectedMissing(expected: "0.9.2"),
                    "Guest agent didn't reconnect", "Reinstall Guest Agent…", "isn't connected now"
                ),
            ]

        for testCase in cases {
            vc.update(status: testCase.status, isInstallerMounted: false, vmName: "TestVM", hasDismissAction: false)
            #expect(titleLabel(in: vc.view)?.stringValue == testCase.title)
            #expect(actionButton(in: vc.view)?.title == testCase.action)
            #expect(bodyLabel(in: vc.view)?.stringValue.contains(testCase.bodyContains) == true)
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

        vc.update(status: .waiting, isInstallerMounted: false, vmName: "TestVM", hasDismissAction: true)
        #expect(dismissButton(in: vc.view)?.isHidden == false)

        vc.update(status: .waiting, isInstallerMounted: false, vmName: "TestVM", hasDismissAction: false)
        #expect(dismissButton(in: vc.view)?.isHidden == true)
    }

    /// Clicks the action button for `status` and returns what reached the
    /// delegate, alongside the title the button carried.
    private func tapAction(status: AgentStatus, isInstallerMounted: Bool) -> (
        title: String?, delegate: MockDelegate
    ) {
        let vc = AgentStatusPopoverContentViewController()
        let delegate = MockDelegate()
        vc.delegate = delegate
        vc.update(
            status: status, isInstallerMounted: isInstallerMounted, vmName: "TestVM",
            hasDismissAction: false)
        vc.loadViewIfNeeded()
        let button = actionButton(in: vc.view)
        button?.performClick(nil)
        return (button?.title, delegate)
    }

    @Test(
        "With the installer attached the button ejects, whatever the status",
        arguments: [
            AgentStatus.waiting,
            .outdated(installed: "0.9.1", bundled: "0.9.2"),
            .expectedMissing(expected: "0.9.2"),
            .unresponsive(version: "0.9.2"),
            .connecting(expected: "0.9.2"),
        ])
    func installerAttachedEjects(status: AgentStatus) {
        let (title, delegate) = tapAction(status: status, isInstallerMounted: true)
        #expect(title == "Eject Guest Agent Media")
        #expect(
            GuestAgentDiskControl.model(status: status, isInstallerMounted: true).action == .eject)
        #expect(delegate.diskControlCount == 1)
        #expect(delegate.doneCount == 0)
    }

    @Test("An unresponsive agent is offered Manage, which re-mounts the disk")
    func unresponsiveOffersManage() {
        let status = AgentStatus.unresponsive(version: "0.9.2")
        let (title, delegate) = tapAction(status: status, isInstallerMounted: false)
        #expect(title == "Manage Guest Agent…")
        #expect(
            GuestAgentDiskControl.model(status: status, isInstallerMounted: false).action
                == .mount(.manage))
        #expect(delegate.diskControlCount == 1)
        #expect(delegate.doneCount == 0)
    }

    @Test("While the control is disabled the button reads Done and only closes")
    func disabledControlIsDone() {
        let (title, delegate) = tapAction(
            status: .connecting(expected: "0.9.2"), isInstallerMounted: false)
        #expect(title == "Done")
        #expect(delegate.doneCount == 1)
        #expect(delegate.diskControlCount == 0)
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

    @Test("dismiss button click fires delegate")
    func dismissFiresDelegate() {
        let vc = AgentStatusPopoverContentViewController()
        let delegate = MockDelegate()
        vc.delegate = delegate
        vc.update(status: .waiting, isInstallerMounted: false, vmName: "TestVM", hasDismissAction: true)
        vc.loadViewIfNeeded()

        dismissButton(in: vc.view)?.performClick(nil)
        #expect(delegate.dismissCount == 1)
        #expect(delegate.diskControlCount == 0)
        #expect(delegate.doneCount == 0)
    }

    // MARK: - Helpers

    @MainActor
    private final class MockDelegate: AgentStatusPopoverContentViewControllerDelegate {
        var diskControlCount = 0
        var doneCount = 0
        var dismissCount = 0

        func agentStatusPopoverDidTapDiskControl(_ vc: AgentStatusPopoverContentViewController) {
            diskControlCount += 1
        }

        func agentStatusPopoverDidTapDone(_ vc: AgentStatusPopoverContentViewController) {
            doneCount += 1
        }

        func agentStatusPopoverDidTapDismiss(_ vc: AgentStatusPopoverContentViewController) {
            dismissCount += 1
        }
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
