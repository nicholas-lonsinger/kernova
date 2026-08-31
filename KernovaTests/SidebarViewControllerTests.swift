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
@Suite("Sidebar Tests", .serialized, .admissionGated)
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

    /// The sidebar badge gate with the app-wide install prompt left on, which is
    /// every case but the ones exercising that preference.
    private func visibleAgentStatus(for instance: VMInstance) -> AgentStatus? {
        SidebarVMRowCellView.visibleAgentStatus(for: instance, installPromptDisabled: false)
    }

    private func titles(of menu: NSMenu) -> [String] {
        menu.items.map(\.title)
    }

    private func menuItem(_ title: String, in menu: NSMenu) -> NSMenuItem? {
        menu.items.first { $0.title == title }
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
        #expect(visibleAgentStatus(for: instance) == nil)
    }

    @Test("Agent indicator shows .waiting for a running macOS VM without an agent")
    func agentWaitingVisibleForRunningMac() {
        let instance = makeInstance(guestOS: .macOS, status: .running)
        #expect(visibleAgentStatus(for: instance) == .waiting)
    }

    @Test("Agent indicator suppressed once the install nudge is dismissed")
    func agentSuppressedWhenDismissed() {
        let instance = makeInstance(guestOS: .macOS, status: .running)
        instance.configuration.agentInstallNudgeDismissed = true
        #expect(visibleAgentStatus(for: instance) == nil)
    }

    @Test("Agent indicator suppressed for a stopped macOS VM")
    func agentSuppressedWhenStopped() {
        // Neither a VM that has never had an agent nor one that has: with no
        // live control channel, `.waiting` means "unknown", not "not installed".
        let fresh = makeInstance(guestOS: .macOS, status: .stopped)
        #expect(visibleAgentStatus(for: fresh) == nil)

        let seen = makeInstance(guestOS: .macOS, status: .stopped)
        seen.configuration.lastSeenAgentVersion = "1.2.3"
        #expect(visibleAgentStatus(for: seen) == nil)
    }

    @Test(
        "Agent indicator suppressed outside a live session",
        arguments: [VMStatus.starting, .saving, .restoring, .error, .initialBoot]
    )
    func agentSuppressedWhenNotInLiveSession(status: VMStatus) {
        let instance = makeInstance(guestOS: .macOS, status: status)
        #expect(visibleAgentStatus(for: instance) == nil)
    }

    @Test("Agent indicator suppressed for a cold-paused VM")
    func agentSuppressedWhenColdPaused() {
        let instance = makeInstance(guestOS: .macOS, status: .paused)  // no live VM
        #expect(instance.isColdPaused)
        #expect(visibleAgentStatus(for: instance) == nil)
    }

    /// The live-session gate must not swallow the *louder* agent states — only
    /// the `.waiting` install nudge is dismissible, so a gate that over-reached
    /// would silently drop the "didn't reconnect" affordance.
    @Test("Agent indicator surfaces .expectedMissing on a running VM")
    func agentExpectedMissingVisibleWhenRunning() {
        let instance = makeInstance(guestOS: .macOS, status: .running)
        instance.configuration.lastSeenAgentVersion = "1.2.3"
        instance.beginSessionContext().agentExpectedButMissing = true
        #expect(
            visibleAgentStatus(for: instance)
                == .expectedMissing(expected: "1.2.3")
        )

        // Even a dismissed install nudge doesn't suppress it — the dismissal
        // gate is scoped to `.waiting`.
        instance.configuration.agentInstallNudgeDismissed = true
        #expect(
            visibleAgentStatus(for: instance)
                == .expectedMissing(expected: "1.2.3")
        )
    }

    @Test("The app-wide preference suppresses .waiting without touching the per-VM flag")
    func agentSuppressedWhenPromptDisabledAppWide() {
        let instance = makeInstance(guestOS: .macOS, status: .running)
        #expect(
            SidebarVMRowCellView.visibleAgentStatus(for: instance, installPromptDisabled: true)
                == nil)
        // The per-VM flag is overridden, never written: turning the preference
        // back on must restore what this VM was set to.
        #expect(instance.configuration.agentInstallNudgeDismissed == false)
        #expect(visibleAgentStatus(for: instance) == .waiting)
    }

    /// The app-wide preference carries the same scope as the per-VM switch —
    /// only the gentle install nudge.
    ///
    /// A gate that over-reached would silence the "didn't reconnect" and
    /// "update available" affordances app-wide.
    @Test("The app-wide preference leaves the louder agent states alone")
    func agentLouderStatesSurviveAppWideDisable() {
        let missing = makeInstance(guestOS: .macOS, status: .running)
        missing.configuration.lastSeenAgentVersion = "1.2.3"
        missing.beginSessionContext().agentExpectedButMissing = true
        #expect(
            SidebarVMRowCellView.visibleAgentStatus(for: missing, installPromptDisabled: true)
                == .expectedMissing(expected: "1.2.3"))
    }

    // MARK: - Row busy state

    /// The cell holds its instance weakly, so the caller keeps `instance` alive:
    /// binding a temporary would leave the row on a deallocated VM, and its
    /// observation loop registering nothing.
    private func makeBusyStateRow(instance: VMInstance, isBusy: Bool) -> SidebarVMRowCellView {
        let cell = SidebarVMRowCellView()
        cell.configure(
            instance: instance,
            isRenaming: false,
            installPromptDisabled: false,
            isBusy: { isBusy },
            onCommitRename: { _, _ in },
            onCancelRename: {},
            onMountAgent: {},
            onDismissAgentNudge: {})
        return cell
    }

    /// The row is the only surface that can show a settling pause or resume, so
    /// its spinner follows the view model's busy read rather than the status —
    /// which stays `.running` (pause) or `.paused` (resume) throughout.
    @Test("The row swaps its OS icon for the spinner while busy")
    func rowSpinsWhileBusy() {
        let busyInstance = makeInstance(status: .running)
        let busy = makeBusyStateRow(instance: busyInstance, isBusy: true)
        #expect(firstSubview(NSProgressIndicator.self, in: busy)?.isHidden == false)
        #expect(firstSubview(NSImageView.self, in: busy)?.isHidden == true)

        let idleInstance = makeInstance(status: .running)
        let idle = makeBusyStateRow(instance: idleInstance, isBusy: false)
        #expect(firstSubview(NSProgressIndicator.self, in: idle)?.isHidden == true)
        #expect(firstSubview(NSImageView.self, in: idle)?.isHidden == false)
    }

    /// Re-arming an observation reports only changes made *after* it registers.
    ///
    /// So anything that moved while the sidebar was off screen — a collapsed
    /// split item, a closed main window — arrives unobserved. The install-prompt
    /// preference is the sharpest case: each cell snapshots it at configure
    /// time, so without a reload on appear the badges keep answering from the
    /// value the preference held before the user changed it in Settings.
    @Test("Appearing reloads rows so state changed while off screen isn't stale")
    func appearingReloadsAfterOffScreenChange() {
        let viewModel = makeViewModel()
        viewModel.instances.append(makeInstance(guestOS: .macOS, status: .running))
        let controller = SidebarViewController(viewModel: viewModel, preferences: preferences)
        controller.loadViewIfNeeded()
        controller.viewDidAppear()

        controller.viewWillDisappear()
        let reloadsWhileOffScreen = controller.reloadInstancesCallCountForTesting
        viewModel.agentInstallPromptDisabled = true
        #expect(controller.reloadInstancesCallCountForTesting == reloadsWhileOffScreen)

        controller.viewDidAppear()

        #expect(controller.reloadInstancesCallCountForTesting > reloadsWhileOffScreen)
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
        // A disks-only capture is offered while stopped; Suspend is not.
        #expect(menuItem("Take Snapshot…", in: menu)?.isEnabled == true)
        #expect(!menuTitles.contains("Suspend"))
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
    func contextMenuColdPaused() throws {
        let viewModel = makeViewModel()
        let instance = makeInstance(status: .paused)  // no live VM ⇒ cold-paused
        // A capturable suspend slot: `canTakeSnapshot` for a cold-paused VM
        // needs one on disk, not just the status.
        try FileManager.default.createDirectory(
            at: instance.bundleURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: instance.bundleURL) }
        FileManager.default.createFile(
            atPath: instance.saveFileURL.path(percentEncoded: false),
            contents: Data("fake save".utf8))
        viewModel.instances.append(instance)
        let controller = SidebarViewController(viewModel: viewModel, preferences: preferences)

        let menu = controller.buildContextMenu(for: instance)
        let menuTitles = titles(of: menu)

        #expect(menuTitles.contains("Discard Saved State…"))
        #expect(menuTitles.contains("Resume"))
        #expect(!menuTitles.contains("Force Stop…"))
        #expect(!menuTitles.contains("Stop"))
        #expect(!menuTitles.contains("Suspend"))
        // The suspend slot itself can be captured, with no VZ work.
        #expect(menuTitles.contains("Take Snapshot…"))
    }

    @Test("Context menu enables delete for a cold-paused VM but keeps Clone disabled")
    func contextMenuColdPausedEnablesDelete() {
        let viewModel = makeViewModel()
        let instance = makeInstance(status: .paused)  // no live VM ⇒ cold-paused
        viewModel.instances.append(instance)
        let controller = SidebarViewController(viewModel: viewModel, preferences: preferences)

        let menu = controller.buildContextMenu(for: instance)

        // The saved state is a file inside the bundle, so deleting takes no
        // Discard Saved State pass first.
        #expect(menuItem("Move to Trash…", in: menu)?.isEnabled == true)
        #expect(menuItem("Delete Immediately…", in: menu)?.isEnabled == true)
        // Clone still needs a settled bundle, so it stays on `canEditSettings`.
        #expect(menuItem("Clone", in: menu)?.isEnabled == false)
    }

    @Test("Context menu disables delete for a live-paused VM")
    func contextMenuLivePausedDisablesDelete() {
        let viewModel = makeViewModel()
        let instance = makeInstance(status: .paused)
        instance.hasLiveVirtualMachineOverrideForTesting = true
        viewModel.instances.append(instance)
        let controller = SidebarViewController(viewModel: viewModel, preferences: preferences)

        let menu = controller.buildContextMenu(for: instance)

        #expect(instance.isLivePaused)
        #expect(menuItem("Move to Trash…", in: menu)?.isEnabled == false)
        #expect(menuItem("Delete Immediately…", in: menu)?.isEnabled == false)
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
        // Force Stop acts on the live VZ VM, which a start has by the time it is
        // running the guest.
        instance.hasLiveVirtualMachineOverrideForTesting = true
        viewModel.instances.append(instance)
        let controller = SidebarViewController(viewModel: viewModel, preferences: preferences)

        let menu = controller.buildContextMenu(for: instance)
        let menuTitles = titles(of: menu)

        // No graceful "Stop" to pair with, so "Force Stop" stands alone and stays
        // visible without holding Option.
        #expect(!menuTitles.contains("Stop"))
        #expect(menuItem("Force Stop…", in: menu)?.isAlternate == false)
    }

    @Test("A disks-only capture offers no Force Stop — there is no VM to terminate")
    func contextMenuNoForceStopDuringAColdCapture() {
        let viewModel = makeViewModel()
        let instance = makeInstance(status: .snapshotting)
        instance.hasLiveVirtualMachineOverrideForTesting = false
        viewModel.instances.append(instance)
        let controller = SidebarViewController(viewModel: viewModel, preferences: preferences)

        let menuTitles = titles(of: controller.buildContextMenu(for: instance))

        #expect(!menuTitles.contains("Force Stop…"))
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
        let short = SidebarVMRowCellView.contentWidth(
            forName: "A", showsAgentAccessory: false, showsEphemeralAccessory: false)
        let long = SidebarVMRowCellView.contentWidth(
            forName: "A much longer virtual machine name", showsAgentAccessory: false,
            showsEphemeralAccessory: false)
        #expect(long > short)
    }

    @Test("contentWidth adds the agent accessory width and gap")
    func contentWidthAccessoryDelta() {
        let withoutBadge = SidebarVMRowCellView.contentWidth(
            forName: "Test VM", showsAgentAccessory: false, showsEphemeralAccessory: false)
        let withBadge = SidebarVMRowCellView.contentWidth(
            forName: "Test VM", showsAgentAccessory: true, showsEphemeralAccessory: false)
        // The accessory adds its 16pt width plus the small inter-element gap.
        #expect(withBadge - withoutBadge == Spacing.small + 16)
    }

    @Test("contentWidth adds the ephemeral accessory width and gap")
    func contentWidthEphemeralAccessoryDelta() {
        let plain = SidebarVMRowCellView.contentWidth(
            forName: "Test VM", showsAgentAccessory: false, showsEphemeralAccessory: false)
        let withEphemeral = SidebarVMRowCellView.contentWidth(
            forName: "Test VM", showsAgentAccessory: false, showsEphemeralAccessory: true)
        #expect(withEphemeral - plain == Spacing.small + SidebarEphemeralBadgeView.width)
    }

    @Test("contentWidth reserves a slot for each accessory when both show")
    func contentWidthBothAccessories() {
        let plain = SidebarVMRowCellView.contentWidth(
            forName: "Test VM", showsAgentAccessory: false, showsEphemeralAccessory: false)
        let both = SidebarVMRowCellView.contentWidth(
            forName: "Test VM", showsAgentAccessory: true, showsEphemeralAccessory: true)
        #expect(
            both - plain
                == (Spacing.small + SidebarEphemeralBadgeView.width)
                + (Spacing.small + SidebarAgentStatusButtonView.width))
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

        guard let outline = firstSubview(NSOutlineView.self, in: controller.view) else {
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
