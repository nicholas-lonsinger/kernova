import AppKit
import Foundation
import KernovaTestSupport
import Testing

@testable import Kernova

/// Behavioral tests for the pure-AppKit sidebar.
///
/// Covers the non-trivial logic that survives the SwiftUI→AppKit port: the
/// status-dot color mapping, the guest-agent indicator gating, the
/// drag-reorder index math, and the status-dependent context menu. Pure
/// layout/rendering is left to manual verification, per the project's testing
/// guidance.
@Suite("Sidebar Tests", .serialized)
@MainActor
struct SidebarViewControllerTests {
    /// Isolated, pre-cleaned preferences for this suite's global state.
    ///
    /// Shared by the view model (selection/order) and the sidebar's own use of
    /// `AppPreferences` (expanded sections + the advanced-options toggle), so no
    /// test reads or writes the real `.standard` domain. Fresh per test (the
    /// struct is re-instantiated), so each starts clean.
    private let preferences: AppPreferences

    init() {
        self.preferences = makeEphemeralPreferences(suiteName: "test.kernova.sidebar")
    }

    private func makeViewModel(storageService: MockVMStorageService = MockVMStorageService())
        -> VMLibraryViewModel
    {
        VMLibraryViewModel(
            storageService: storageService,
            diskImageService: MockDiskImageService(),
            virtualizationService: MockVirtualizationService(),
            installService: MockMacOSInstallService(),
            ipswService: MockIPSWService(),
            usbDeviceService: MockUSBDeviceService(),
            preferences: preferences
        )
    }

    private func makeInstance(
        name: String = "Test VM",
        guestOS: VMGuestOS = .linux,
        status: VMStatus = .stopped
    ) -> VMInstance {
        let config = VMConfiguration(name: name, guestOS: guestOS, bootMode: .efi)
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(config.id.uuidString, isDirectory: true)
        let instance = VMInstance(configuration: config, bundleURL: bundleURL)
        instance.status = status
        return instance
    }

    private func titles(of menu: NSMenu) -> [String] {
        menu.items.map(\.title)
    }

    private func menuItem(_ title: String, in menu: NSMenu) -> NSMenuItem? {
        menu.items.first { $0.title == title }
    }

    private func findOutlineView(in view: NSView) -> NSOutlineView? {
        if let outline = view as? NSOutlineView { return outline }
        for subview in view.subviews {
            if let found = findOutlineView(in: subview) { return found }
        }
        return nil
    }

    // MARK: - Status icon color

    @Test("statusDisplayNSColor maps each lifecycle state")
    func statusColorMapping() {
        let instance = makeInstance(status: .stopped)
        // Concrete gray (not `.secondaryLabelColor`) so the OS icon keeps its
        // stopped color on the selection highlight instead of inverting to white.
        #expect(instance.statusDisplayNSColor == .systemGray)

        instance.status = .running
        #expect(instance.statusDisplayNSColor == .systemGreen)

        instance.status = .error
        #expect(instance.statusDisplayNSColor == .systemRed)

        instance.status = .starting
        #expect(instance.statusDisplayNSColor == .systemOrange)
    }

    @Test("statusDisplayNSColor is orange for cold-paused and preparing")
    func statusColorColdPausedAndPreparing() {
        let coldPaused = makeInstance(status: .paused)  // no live VM ⇒ cold-paused
        #expect(coldPaused.isColdPaused)
        #expect(coldPaused.statusDisplayNSColor == .systemOrange)

        let preparing = makeInstance(status: .stopped)
        preparing.preparingState = VMInstance.PreparingState(operation: .cloning, task: Task {})
        #expect(preparing.statusDisplayNSColor == .systemOrange)
    }

    // MARK: - Agent indicator gating

    @Test("Agent indicator hidden for Linux guests")
    func agentHiddenForLinux() {
        let instance = makeInstance(guestOS: .linux, status: .running)
        #expect(SidebarVMRowCellView.visibleAgentStatus(for: instance) == nil)
    }

    @Test("Agent indicator shows .waiting for a running macOS VM without an agent")
    func agentWaitingVisibleForRunningMac() {
        let instance = makeInstance(guestOS: .macOS, status: .running)
        #expect(SidebarVMRowCellView.visibleAgentStatus(for: instance) == .waiting)
    }

    @Test("Agent indicator suppressed once the install nudge is dismissed")
    func agentSuppressedWhenDismissed() {
        let instance = makeInstance(guestOS: .macOS, status: .running)
        instance.configuration.agentInstallNudgeDismissed = true
        #expect(SidebarVMRowCellView.visibleAgentStatus(for: instance) == nil)
    }

    @Test("Agent indicator suppressed for a stopped macOS VM")
    func agentSuppressedWhenStopped() {
        // Neither a VM that has never had an agent nor one that has: with no
        // live control channel, `.waiting` means "unknown", not "not installed".
        let fresh = makeInstance(guestOS: .macOS, status: .stopped)
        #expect(SidebarVMRowCellView.visibleAgentStatus(for: fresh) == nil)

        let seen = makeInstance(guestOS: .macOS, status: .stopped)
        seen.configuration.lastSeenAgentVersion = "1.2.3"
        #expect(SidebarVMRowCellView.visibleAgentStatus(for: seen) == nil)
    }

    @Test(
        "Agent indicator suppressed outside a live session",
        arguments: [VMStatus.starting, .saving, .restoring, .error, .initialBoot]
    )
    func agentSuppressedWhenNotInLiveSession(status: VMStatus) {
        let instance = makeInstance(guestOS: .macOS, status: status)
        #expect(SidebarVMRowCellView.visibleAgentStatus(for: instance) == nil)
    }

    @Test("Agent indicator suppressed for a cold-paused VM")
    func agentSuppressedWhenColdPaused() {
        let instance = makeInstance(guestOS: .macOS, status: .paused)  // no live VM
        #expect(instance.isColdPaused)
        #expect(SidebarVMRowCellView.visibleAgentStatus(for: instance) == nil)
    }

    /// The live-session gate must not swallow the *louder* agent states — only
    /// the `.waiting` install nudge is dismissible, so a gate that over-reached
    /// would silently drop the "didn't reconnect" affordance.
    @Test("Agent indicator surfaces .expectedMissing on a running VM")
    func agentExpectedMissingVisibleWhenRunning() {
        let instance = makeInstance(guestOS: .macOS, status: .running)
        instance.configuration.lastSeenAgentVersion = "1.2.3"
        instance.agentExpectedButMissing = true
        #expect(
            SidebarVMRowCellView.visibleAgentStatus(for: instance)
                == .expectedMissing(expected: "1.2.3")
        )

        // Even a dismissed install nudge doesn't suppress it — the dismissal
        // gate is scoped to `.waiting`.
        instance.configuration.agentInstallNudgeDismissed = true
        #expect(
            SidebarVMRowCellView.visibleAgentStatus(for: instance)
                == .expectedMissing(expected: "1.2.3")
        )
    }

    // MARK: - Reorder index math

    @Test("reorderTarget maps drops and skips no-ops")
    func reorderTargetMapping() {
        // Move down / up: the proposed gap maps straight through.
        #expect(SidebarViewController.reorderTarget(sourceIndex: 0, proposedIndex: 3, count: 5) == 3)
        #expect(SidebarViewController.reorderTarget(sourceIndex: 4, proposedIndex: 1, count: 5) == 1)

        // Dropped into its own gap (above itself or just below) — no-op.
        #expect(SidebarViewController.reorderTarget(sourceIndex: 2, proposedIndex: 2, count: 5) == nil)
        #expect(SidebarViewController.reorderTarget(sourceIndex: 2, proposedIndex: 3, count: 5) == nil)

        // Dropped "on" the group row appends to the end.
        #expect(
            SidebarViewController.reorderTarget(
                sourceIndex: 0, proposedIndex: NSOutlineViewDropOnItemIndex, count: 5) == 5
        )
    }

    // MARK: - Context menu

    @Test("Context menu for a stopped VM offers Start and enables management")
    func contextMenuStopped() {
        let viewModel = makeViewModel()
        let instance = makeInstance(status: .stopped)
        viewModel.instances.append(instance)
        let controller = SidebarViewController(viewModel: viewModel, preferences: preferences)

        let menu = controller.buildContextMenu(for: instance)
        let menuTitles = titles(of: menu)

        #expect(menuTitles.contains("Start"))
        #expect(!menuTitles.contains("Pause"))
        #expect(!menuTitles.contains("Stop"))
        #expect(menuItem("Rename", in: menu)?.isEnabled == true)
        #expect(menuItem("Clone", in: menu)?.isEnabled == true)
        #expect(menuItem("Move to Trash…", in: menu)?.isEnabled == true)
    }

    @Test("Context menu for a running VM offers Pause/Stop/Suspend and disables editing")
    func contextMenuRunning() {
        let viewModel = makeViewModel()
        let instance = makeInstance(status: .running)
        viewModel.instances.append(instance)
        let controller = SidebarViewController(viewModel: viewModel, preferences: preferences)

        let menu = controller.buildContextMenu(for: instance)
        let menuTitles = titles(of: menu)

        #expect(menuTitles.contains("Pause"))
        #expect(menuTitles.contains("Stop"))
        #expect(menuTitles.contains("Suspend"))
        #expect(!menuTitles.contains("Start"))
        #expect(menuItem("Clone", in: menu)?.isEnabled == false)
        #expect(menuItem("Move to Trash…", in: menu)?.isEnabled == false)
        #expect(menuItem("Rename", in: menu)?.isEnabled == true)
    }

    @Test("Context menu for a cold-paused VM offers Discard Saved State, not Stop/Suspend")
    func contextMenuColdPaused() {
        let viewModel = makeViewModel()
        let instance = makeInstance(status: .paused)  // no live VM ⇒ cold-paused
        viewModel.instances.append(instance)
        let controller = SidebarViewController(viewModel: viewModel, preferences: preferences)

        let menu = controller.buildContextMenu(for: instance)
        let menuTitles = titles(of: menu)

        #expect(menuTitles.contains("Discard Saved State…"))
        #expect(menuTitles.contains("Resume"))
        #expect(!menuTitles.contains("Force Stop…"))
        #expect(!menuTitles.contains("Stop"))
        #expect(!menuTitles.contains("Suspend"))
    }

    @Test("Force Stop is the Option-alternate of Stop on a running VM (advanced options off)")
    func contextMenuForceStopIsOptionAlternate() {
        preferences.alwaysShowAdvancedOptions = false
        let viewModel = makeViewModel()
        let instance = makeInstance(status: .running)
        viewModel.instances.append(instance)
        let controller = SidebarViewController(viewModel: viewModel, preferences: preferences)

        let menu = controller.buildContextMenu(for: instance)

        // Both rows exist in the item array; AppKit collapses them into one visible
        // "Stop" row and swaps in "Force Stop" only while Option is held.
        let stop = menuItem("Stop", in: menu)
        let forceStop = menuItem("Force Stop…", in: menu)
        #expect(stop != nil)
        #expect(forceStop != nil)
        // Keyless Option-reveal: the alternate carries [.option] and isAlternate, and
        // the primary's default [.command] mask is cleared so AppKit merges the pair.
        #expect(forceStop?.isAlternate == true)
        #expect(forceStop?.keyEquivalentModifierMask == [.option])
        #expect(stop?.keyEquivalentModifierMask == [])
    }

    @Test("Force Stop is a plain always-visible item when advanced options are on")
    func contextMenuForceStopVisibleWhenAdvanced() {
        preferences.alwaysShowAdvancedOptions = true
        let viewModel = makeViewModel()
        let instance = makeInstance(status: .running)
        viewModel.instances.append(instance)
        let controller = SidebarViewController(viewModel: viewModel, preferences: preferences)

        let menu = controller.buildContextMenu(for: instance)

        let forceStop = menuItem("Force Stop…", in: menu)
        #expect(menuItem("Stop", in: menu) != nil)
        #expect(forceStop != nil)
        #expect(forceStop?.isAlternate == false)
    }

    @Test("Transient (starting) VM offers a standalone Force Stop, not an Option-alternate")
    func contextMenuForceStopStandaloneDuringTransition() {
        preferences.alwaysShowAdvancedOptions = false
        let viewModel = makeViewModel()
        let instance = makeInstance(status: .starting)
        viewModel.instances.append(instance)
        let controller = SidebarViewController(viewModel: viewModel, preferences: preferences)

        let menu = controller.buildContextMenu(for: instance)
        let menuTitles = titles(of: menu)

        // No graceful "Stop" to pair with, so "Force Stop" stands alone and stays
        // visible without holding Option.
        #expect(!menuTitles.contains("Stop"))
        #expect(menuItem("Force Stop…", in: menu)?.isAlternate == false)
    }

    @Test("Delete Immediately is the Option-alternate of Move to Trash (advanced options off)")
    func contextMenuDeleteImmediatelyIsOptionAlternate() {
        preferences.alwaysShowAdvancedOptions = false
        let viewModel = makeViewModel()
        let instance = makeInstance(status: .stopped)
        viewModel.instances.append(instance)
        let controller = SidebarViewController(viewModel: viewModel, preferences: preferences)

        let menu = controller.buildContextMenu(for: instance)

        // Both rows exist; AppKit collapses them into one visible "Move to Trash…" row
        // and swaps in "Delete Immediately…" only while Option is held.
        let trash = menuItem("Move to Trash…", in: menu)
        let deleteImmediately = menuItem("Delete Immediately…", in: menu)
        #expect(trash != nil)
        #expect(deleteImmediately != nil)
        #expect(deleteImmediately?.isAlternate == true)
        #expect(deleteImmediately?.keyEquivalentModifierMask == [.option])
        #expect(trash?.keyEquivalentModifierMask == [])
        // The alternate shares the primary's enablement gate.
        #expect(deleteImmediately?.isEnabled == true)
    }

    @Test("Delete Immediately is a plain always-visible item when advanced options are on")
    func contextMenuDeleteImmediatelyVisibleWhenAdvanced() {
        preferences.alwaysShowAdvancedOptions = true
        let viewModel = makeViewModel()
        let instance = makeInstance(status: .stopped)
        viewModel.instances.append(instance)
        let controller = SidebarViewController(viewModel: viewModel, preferences: preferences)

        let menu = controller.buildContextMenu(for: instance)

        let deleteImmediately = menuItem("Delete Immediately…", in: menu)
        #expect(menuItem("Move to Trash…", in: menu) != nil)
        #expect(deleteImmediately != nil)
        #expect(deleteImmediately?.isAlternate == false)
    }

    @Test("Context menu for a preparing VM offers only Cancel and Show in Finder")
    func contextMenuPreparing() {
        let viewModel = makeViewModel()
        let instance = makeInstance()
        instance.preparingState = VMInstance.PreparingState(operation: .cloning, task: Task {})
        viewModel.instances.append(instance)
        let controller = SidebarViewController(viewModel: viewModel, preferences: preferences)

        let menu = controller.buildContextMenu(for: instance)
        let menuTitles = titles(of: menu)

        #expect(menuTitles.contains("Cancel Clone"))
        #expect(menuTitles.contains("Show in Finder"))
        #expect(!menuTitles.contains("Start"))
        #expect(!menuTitles.contains("Rename"))
    }

    // MARK: - Content-fit width

    @Test("contentWidth grows with name length")
    func contentWidthGrowsWithName() {
        let short = SidebarVMRowCellView.contentWidth(forName: "A", showsAgentAccessory: false)
        let long = SidebarVMRowCellView.contentWidth(
            forName: "A much longer virtual machine name", showsAgentAccessory: false)
        #expect(long > short)
    }

    @Test("contentWidth adds the agent accessory width and gap")
    func contentWidthAccessoryDelta() {
        let withoutBadge = SidebarVMRowCellView.contentWidth(
            forName: "Test VM", showsAgentAccessory: false)
        let withBadge = SidebarVMRowCellView.contentWidth(
            forName: "Test VM", showsAgentAccessory: true)
        // The accessory adds its 16pt width plus the small inter-element gap.
        #expect(withBadge - withoutBadge == Spacing.small + 16)
    }

    @Test("widthToFitLongestRow is nil with no VMs")
    func fitWidthNilWhenEmpty() {
        let viewModel = makeViewModel()
        let controller = SidebarViewController(viewModel: viewModel, preferences: preferences)
        controller.loadViewIfNeeded()
        #expect(controller.widthToFitLongestRow() == nil)
    }

    @Test("widthToFitLongestRow grows with the longest VM name")
    func fitWidthTracksLongestName() {
        let shortModel = makeViewModel()
        shortModel.instances.append(makeInstance(name: "VM"))
        let shortController = SidebarViewController(viewModel: shortModel, preferences: preferences)
        shortController.loadViewIfNeeded()
        shortController.view.layoutSubtreeIfNeeded()

        let longModel = makeViewModel()
        longModel.instances.append(makeInstance(name: "An extremely long virtual machine name"))
        let longController = SidebarViewController(viewModel: longModel, preferences: preferences)
        longController.loadViewIfNeeded()
        longController.view.layoutSubtreeIfNeeded()

        guard let shortWidth = shortController.widthToFitLongestRow(),
            let longWidth = longController.widthToFitLongestRow()
        else {
            Issue.record("Expected a fit width for both controllers")
            return
        }
        #expect(longWidth > shortWidth)
    }

    // MARK: - View loading

    @Test("Outline view loads the group with its VM rows expanded")
    func outlineViewLoadsRows() {
        let viewModel = makeViewModel()
        viewModel.instances.append(makeInstance(name: "Alpha"))
        viewModel.instances.append(makeInstance(name: "Beta"))
        let controller = SidebarViewController(viewModel: viewModel, preferences: preferences)
        controller.loadViewIfNeeded()
        controller.view.layoutSubtreeIfNeeded()

        guard let outline = findOutlineView(in: controller.view) else {
            Issue.record("Expected an NSOutlineView in the sidebar view tree")
            return
        }
        // One group row plus the two VM rows (group expanded by default).
        #expect(outline.numberOfRows == 3)
        #expect(outline.item(atRow: 0) is SidebarSection)
        #expect(outline.item(atRow: 1) is VMInstance)
    }

    // MARK: - Clone completion refresh (#575)

    @Test("A cloned VM's preparing row settling routes through the sidebar's reload cycle")
    func clonedRowSettlingTriggersReload() async throws {
        let storage = MockVMStorageService()
        let viewModel = makeViewModel(storageService: storage)
        let source = makeInstance(name: "Source", guestOS: .macOS)
        // Registered with the mock storage so the view model's real
        // `VMDirectoryWatcher` — which fires on the clone's directory actually
        // landing on disk (the mock now creates it, matching production) —
        // doesn't mistake the never-persisted source for a bundle that vanished
        // and reconcile it away, confounding the reload count below.
        storage.bundles[source.bundleURL] = source.configuration
        viewModel.instances.append(source)
        let controller = SidebarViewController(viewModel: viewModel, preferences: preferences)
        controller.loadViewIfNeeded()
        controller.viewDidAppear()

        let reloadsBeforeClone = controller.reloadInstancesCallCountForTesting
        viewModel.cloneVM(source)
        guard let phantom = viewModel.instances.first(where: { $0.id != source.id }) else {
            Issue.record("Expected a cloned phantom instance")
            return
        }

        // Await the production Task the row's preparing state is held on, per
        // docs/TESTING.md's "await the production Task" seam, rather than
        // polling the flag it flips. (The mock's copy settles fast enough that
        // polling for an intermediate "still preparing" reload count would
        // race it — the two reloads below can both have landed by the first
        // poll tick.)
        await phantom.preparingState?.task.value
        #expect(!phantom.isPreparing)

        // Exactly two reloads are expected end to end: one for the phantom's
        // initial registration (an id-list change) and one for its
        // `isPreparing` settle — the fix under test (#575). The settle's
        // reload has no dedicated Observable signal at the controller layer to
        // hang a `waitForChange` off of (it fires through an internal
        // `ObservationLoop` cascade), so poll the counter.
        //
        // RATIONALE: genuine no-signal predicate (docs/TESTING.md) — the
        // reload count is driven by an internal `ObservationLoop` cascade with
        // no test-facing signal to await; `==`, not `>=`, so a stray extra
        // reload (e.g. an unrelated `VMDirectoryWatcher` reconciliation) fails
        // the test instead of being silently masked by a looser bound.
        try await waitUntil {
            controller.reloadInstancesCallCountForTesting == reloadsBeforeClone + 2
        }

        // The reload count above is the regression guard; the row's actual
        // rendered badge is left to manual verification, per this file's
        // top-level doc comment — `NSOutlineView` never realizes a row's cell
        // view in this off-screen test harness (confirmed: `view(atColumn:
        // row:makeIfNecessary: false)` is always nil here), so an assertion on
        // it would silently never execute.
    }
}
