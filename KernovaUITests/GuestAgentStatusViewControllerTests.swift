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

    @Test("default state — title and action button reflect .waiting")
    func defaultState() {
        let vc = GuestAgentStatusViewController()
        vc.update(
            presentation: GuestAgentPresentation(hub: .empty), diskControl: Self.install, hasDismissAction: true)
        vc.loadViewIfNeeded()

        #expect(titleLabel(in: vc.view)?.stringValue == "Set up the Kernova guest agent")
        #expect(actionButton(in: vc.view)?.title == "Install Guest Agent…")
    }

    @Test("Each status has its own title")
    func titlePerStatus() {
        let cases: [(status: AgentStatus, title: String)] = [
            (.waiting, "Set up the Kernova guest agent"),
            (.outdated(installed: "0.9.1", bundled: "0.9.2"), "Update available"),
            (.updating(installed: "0.9.1", bundled: "0.9.2"), "Updating guest agent"),
            (.current(version: "0.9.2"), "Guest agent connected"),
            (.connected(version: "0.9.2"), "Guest agent connected"),
            (.unresponsive(version: "0.9.2"), "Guest agent unresponsive"),
            (.connecting(expected: "0.9.2"), "Connecting to guest agent"),
            (.expectedMissing(expected: "0.9.2"), "Guest agent didn't reconnect"),
        ]
        for testCase in cases {
            #expect(GuestAgentStatusViewController.title(for: testCase.status) == testCase.title)
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
                presentation: GuestAgentPresentation(hub: .empty), diskControl: control, hasDismissAction: false)
            #expect(actionButton(in: vc.view)?.title == title)
        }
    }

    @Test("Don't show again button visibility tracks hasDismissAction")
    func dismissButtonVisibility() {
        let vc = GuestAgentStatusViewController()
        vc.loadViewIfNeeded()

        vc.update(
            presentation: GuestAgentPresentation(hub: .empty), diskControl: Self.install, hasDismissAction: true)
        #expect(dismissButton(in: vc.view)?.isHidden == false)

        vc.update(
            presentation: GuestAgentPresentation(hub: .empty), diskControl: Self.install, hasDismissAction: false)
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
            presentation: GuestAgentPresentation(hub: .empty),
            diskControl: diskControl, hasDismissAction: false)
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
            presentation: GuestAgentPresentation(hub: .empty), diskControl: Self.install, hasDismissAction: true)
        vc.loadViewIfNeeded()

        dismissButton(in: vc.view)?.performClick(nil)
        #expect(dismissCount == 1)
        #expect(diskControlCount == 0)
        #expect(doneCount == 0)
    }

    @Test("A presentation shows a line per agent and its capability rows")
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
            presentation: GuestAgentPresentation(hub: snapshot), diskControl: Self.withheld, hasDismissAction: false)

        #expect(titleLabel(in: vc.view)?.stringValue == "Guest agent connected")
        #expect(
            visibleTexts(in: vc.view) == [
                "Guest agent connected", "Session agent — pbear", "Up to date", "Status", "Connected",
                "Guest logs in Console", "Turned off in Settings.", "Automatic agent updates",
                "This agent doesn't offer it.",
            ])
    }

    @Test("An attached disk opened from a terminal shows its command with a Copy button; none otherwise")
    func installCommandRow() {
        let vc = GuestAgentStatusViewController()
        vc.loadViewIfNeeded()
        let command = #"sh "$(findmnt -nro TARGET LABEL=KERNOVA_AGENT)/install.sh""#
        var eject = Self.eject
        eject.installGuidance = .command(command)
        vc.update(
            presentation: GuestAgentPresentation(hub: .empty), diskControl: eject,
            hasDismissAction: false)
        #expect(visibleTexts(in: vc.view).contains(command))
        #expect(visibleTexts(in: vc.view).contains(LinuxAgentDisk.installCommandPrecondition))
        let copy = firstSubview(NSButton.self, in: vc.view) { $0.accessibilityLabel() == "Copy Install Command" }
        #expect(copy?.isHidden == false)
        #expect(vc.installGuidance == .command(command))

        vc.update(
            presentation: GuestAgentPresentation(hub: .empty), diskControl: Self.install,
            hasDismissAction: false)
        #expect(!visibleTexts(in: vc.view).contains(command))
        #expect(vc.installGuidance == nil)
    }

    @Test("An attached macOS disk shows the step that installs from it, with nothing to copy")
    func installStepRow() {
        let vc = GuestAgentStatusViewController()
        vc.loadViewIfNeeded()
        var eject = Self.eject
        eject.installGuidance = .step(GuestAgentDiskControl.macOSInstallStep)
        vc.update(
            presentation: GuestAgentPresentation(hub: .empty), diskControl: eject,
            hasDismissAction: false)
        let texts = visibleTexts(in: vc.view)
        #expect(texts.contains(GuestAgentDiskControl.macOSInstallStep))
        #expect(!texts.contains(LinuxAgentDisk.installCommandPrecondition))
        let copy = firstSubview(NSButton.self, in: vc.view) { $0.accessibilityLabel() == "Copy Install Command" }
        #expect(copy?.isHidden == true)
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
    private func actionButton(in view: NSView) -> NSButton? {
        // Action button has Return as its key equivalent.
        firstSubview(NSButton.self, in: view) { $0.keyEquivalent == "\r" }
    }

    @MainActor
    private func dismissButton(in view: NSView) -> NSButton? {
        findButton(titled: "Don't show again", in: view)
    }
}
