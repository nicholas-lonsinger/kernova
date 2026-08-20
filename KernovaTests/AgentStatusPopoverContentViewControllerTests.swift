import Testing
import AppKit
@testable import Kernova

@Suite("AgentStatusPopoverContentViewController Tests", .admissionGated)
@MainActor
struct AgentStatusPopoverContentViewControllerTests {
    @Test("default state — title/body/action-button reflect .waiting")
    func defaultState() {
        let vc = AgentStatusPopoverContentViewController()
        vc.update(status: .waiting, vmName: "TestVM", hasDismissAction: true)
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
                (.current(version: "0.9.2"), "Guest agent connected", "Done", "0.9.2"),
                (
                    .unresponsive(version: "0.9.2"),
                    "Guest agent unresponsive", "Done", "stopped responding"
                ),
                (
                    .connecting(expected: "0.9.2"),
                    "Connecting to guest agent", "Done", "Waiting for guest agent"
                ),
                (
                    .expectedMissing(expected: "0.9.2"),
                    "Guest agent didn't reconnect", "Reinstall Guest Agent…", "installed previously"
                ),
            ]

        for testCase in cases {
            vc.update(status: testCase.status, vmName: "TestVM", hasDismissAction: false)
            #expect(titleLabel(in: vc.view)?.stringValue == testCase.title)
            #expect(actionButton(in: vc.view)?.title == testCase.action)
            #expect(bodyLabel(in: vc.view)?.stringValue.contains(testCase.bodyContains) == true)
        }
    }

    @Test("Body copy for a missing agent describes no particular cause")
    func absentAgentCopyIsCauseAgnostic() {
        // Both states are reached after a mid-session death as well as after a
        // boot, so neither may claim a boot happened (#706). The escalation the
        // `.connecting` copy promises is what the re-armed watchdog delivers.
        let connecting = AgentStatusPopoverContentViewController.bodyText(
            for: .connecting(expected: "0.9.2"), vmName: "TestVM")
        #expect(!connecting.contains("boot"))
        #expect(connecting.contains("didn't reconnect"))

        let missing = AgentStatusPopoverContentViewController.bodyText(
            for: .expectedMissing(expected: "0.9.2"), vmName: "TestVM")
        #expect(!missing.contains("boot"))
    }

    @Test("Don't show again button visibility tracks hasDismissAction")
    func dismissButtonVisibility() {
        let vc = AgentStatusPopoverContentViewController()
        vc.loadViewIfNeeded()

        vc.update(status: .waiting, vmName: "TestVM", hasDismissAction: true)
        #expect(dismissButton(in: vc.view)?.isHidden == false)

        vc.update(status: .waiting, vmName: "TestVM", hasDismissAction: false)
        #expect(dismissButton(in: vc.view)?.isHidden == true)
    }

    @Test("action button click fires delegate")
    func actionFiresDelegate() {
        let vc = AgentStatusPopoverContentViewController()
        let delegate = MockDelegate()
        vc.delegate = delegate
        vc.update(status: .waiting, vmName: "TestVM", hasDismissAction: true)
        vc.loadViewIfNeeded()

        actionButton(in: vc.view)?.performClick(nil)
        #expect(delegate.actionCount == 1)
        #expect(delegate.dismissCount == 0)
    }

    @Test("dismiss button click fires delegate")
    func dismissFiresDelegate() {
        let vc = AgentStatusPopoverContentViewController()
        let delegate = MockDelegate()
        vc.delegate = delegate
        vc.update(status: .waiting, vmName: "TestVM", hasDismissAction: true)
        vc.loadViewIfNeeded()

        dismissButton(in: vc.view)?.performClick(nil)
        #expect(delegate.dismissCount == 1)
        #expect(delegate.actionCount == 0)
    }

    @Test("requiresMountAction true for .waiting/.outdated/.expectedMissing only")
    func requiresMountAction() {
        let mountStatuses: [AgentStatus] = [
            .waiting,
            .outdated(installed: "0.9.1", bundled: "0.9.2"),
            .expectedMissing(expected: "0.9.2"),
        ]
        let noMountStatuses: [AgentStatus] = [
            .current(version: "0.9.2"),
            .unresponsive(version: "0.9.2"),
            .connecting(expected: "0.9.2"),
        ]
        for status in mountStatuses {
            #expect(AgentStatusPopoverContentViewController.requiresMountAction(for: status))
        }
        for status in noMountStatuses {
            #expect(!AgentStatusPopoverContentViewController.requiresMountAction(for: status))
        }
    }

    // MARK: - Helpers

    @MainActor
    private final class MockDelegate: AgentStatusPopoverContentViewControllerDelegate {
        var actionCount = 0
        var dismissCount = 0

        func agentStatusPopoverDidTapAction(_ vc: AgentStatusPopoverContentViewController) {
            actionCount += 1
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
