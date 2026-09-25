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
@Suite("Sidebar Tests", .serialized, .admissionGated, .scopedWindows)
@MainActor
struct SidebarViewControllerTests {
    /// Shared by the view model (selection/order) and the sidebar's own use of
    /// `AppPreferences` (expanded sections + the advanced-options toggle).
    ///
    /// Fresh per test (the struct is re-instantiated), so each starts clean.
    private let preferences: AppPreferences

    init() {
        self.preferences = makeTestPreferences()
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
            removableMediaDeviceService: MockRemovableMediaDeviceService(),
            fileSystem: MockFileSystem(),
            downloadsDirectory: nil,
            preferences: preferences,
            vmnetNetworks: MockVmnetNetworkProvider(), arpTable: ScriptedARPTable(), entitlements: .entitled
        )
    }

    /// The sidebar badge gate with the app-wide install prompt left on, which is
    /// every case but the ones exercising that preference.
    private func visibleAgentStatus(for instance: VMInstance) -> AgentStatus? {
        SidebarVMRowCellView.visibleAgentStatus(for: instance, installPromptDisabled: false)
    }

    private func titles(of menu: NSMenu) -> [String] {
        menu.items.map(\.title)
    }

    /// `name`'s laid-out width in `font`, through a field configured like the
    /// row's name label.
    ///
    /// An oracle independent of the cell's own measuring path, so a test using it
    /// checks the fonts rather than re-running the code under test.
    private func measuredWidth(of name: String, at font: NSFont) -> CGFloat {
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.isEditable = false
        field.lineBreakMode = .byTruncatingTail
        field.maximumNumberOfLines = 1
        field.cell?.usesSingleLineMode = true
        field.font = font
        field.stringValue = name
        return ceil(field.fittingSize.width)
    }

    private func menuItem(_ title: String, in menu: NSMenu) -> NSMenuItem? {
        menu.items.first { $0.title == title }
    }

    // MARK: - Status icon color

    @Test("statusDisplayNSColor maps each lifecycle state")
    func statusColorMapping() {
        let instance = VMInstanceFixture.make(phase: .stopped)
        // Concrete gray (not `.secondaryLabelColor`) so the OS icon keeps its
        // stopped color on the selection highlight instead of inverting to white.
        #expect(instance.statusDisplayNSColor == .systemGray)

        instance.activity.placeForTesting(.running(sessionID: UUID()))
        #expect(instance.statusDisplayNSColor == .systemGreen)

        instance.activity.placeForTesting(.failed(message: "Test failure"))
        #expect(instance.statusDisplayNSColor == .systemRed)

        instance.activity.placeForTesting(.starting(sessionID: nil))
        #expect(instance.statusDisplayNSColor == .systemOrange)
    }

    @Test("statusDisplayNSColor is orange for cold-paused")
    func statusColorColdPaused() {
        let coldPaused = VMInstanceFixture.make(phase: .suspended)  // no live VM ⇒ cold-paused
        #expect(coldPaused.isColdPaused)
        #expect(coldPaused.statusDisplayNSColor == .systemOrange)
    }

    // MARK: - Agent indicator gating

    @Test("Agent indicator hidden for Linux guests")
    func agentHiddenForLinux() {
        let instance = VMInstanceFixture.make(guestOS: .linux, phase: .running(sessionID: UUID()))
        #expect(visibleAgentStatus(for: instance) == nil)
    }

    @Test("Agent indicator shows .waiting for a running macOS VM without an agent")
    func agentWaitingVisibleForRunningMac() {
        let instance = VMInstanceFixture.make(guestOS: .macOS, phase: .running(sessionID: UUID()))
        #expect(visibleAgentStatus(for: instance) == .waiting)
    }

    @Test("Agent indicator suppressed once the install nudge is dismissed")
    func agentSuppressedWhenDismissed() {
        let instance = VMInstanceFixture.make(
            guestOS: .macOS, phase: .running(sessionID: UUID()),
            hostState: VMHostState(agentInstallNudgeDismissed: true))
        #expect(visibleAgentStatus(for: instance) == nil)
    }

    @Test("Agent indicator suppressed for a stopped macOS VM")
    func agentSuppressedWhenStopped() {
        // Neither a VM that has never had an agent nor one that has: with no
        // live control channel, `.waiting` means "unknown", not "not installed".
        let fresh = VMInstanceFixture.make(guestOS: .macOS, phase: .stopped)
        #expect(visibleAgentStatus(for: fresh) == nil)

        let seen = VMInstanceFixture.make(guestOS: .macOS, phase: .stopped) {
            $0.lastSeenAgentVersion = "1.2.3"
        }
        #expect(visibleAgentStatus(for: seen) == nil)
    }

    @Test(
        "Agent indicator suppressed outside a live session",
        arguments: [
            VMLifecyclePhase.starting(sessionID: UUID()), .saving(sessionID: UUID()),
            .restoringSavedState(sessionID: UUID()), .failed(message: "Boot failed."),
            .initialBoot,
        ]
    )
    func agentSuppressedWhenNotInLiveSession(phase: VMLifecyclePhase) {
        let instance = VMInstanceFixture.make(guestOS: .macOS, phase: phase)
        #expect(visibleAgentStatus(for: instance) == nil)
    }

    @Test("Agent indicator suppressed for a cold-paused VM")
    func agentSuppressedWhenColdPaused() {
        let instance = VMInstanceFixture.make(guestOS: .macOS, phase: .suspended)  // no live VM
        #expect(instance.isColdPaused)
        #expect(visibleAgentStatus(for: instance) == nil)
    }

    /// The live-session gate must not swallow the *louder* agent states — only
    /// the `.waiting` install nudge is dismissible, so a gate that over-reached
    /// would silently drop the "didn't reconnect" affordance.
    @Test("Agent indicator surfaces .expectedMissing on a running VM")
    func agentExpectedMissingVisibleWhenRunning() {
        let instance = VMInstanceFixture.make(guestOS: .macOS, phase: .running(sessionID: UUID())) {
            $0.lastSeenAgentVersion = "1.2.3"
        }
        let library = makeWiredLibrary(holding: [instance])
        instance.beginSessionContext().agentExpectedButMissing = true
        #expect(
            visibleAgentStatus(for: instance)
                == .expectedMissing(expected: "1.2.3")
        )

        // Even a dismissed install nudge doesn't suppress it — the dismissal
        // gate is scoped to `.waiting`.
        library.editHostState(of: instance) { $0.agentInstallNudgeDismissed = true }
        #expect(
            visibleAgentStatus(for: instance)
                == .expectedMissing(expected: "1.2.3")
        )
    }

    @Test("The app-wide preference suppresses .waiting without touching the per-VM flag")
    func agentSuppressedWhenPromptDisabledAppWide() {
        let instance = VMInstanceFixture.make(guestOS: .macOS, phase: .running(sessionID: UUID()))
        #expect(
            SidebarVMRowCellView.visibleAgentStatus(for: instance, installPromptDisabled: true)
                == nil)
        // The per-VM flag is overridden, never written: turning the preference
        // back on must restore what this VM was set to.
        #expect(instance.hostState.agentInstallNudgeDismissed == false)
        #expect(visibleAgentStatus(for: instance) == .waiting)
    }

    /// The app-wide preference carries the same scope as the per-VM switch —
    /// only the gentle install nudge.
    ///
    /// A gate that over-reached would silence the "didn't reconnect" and
    /// "update available" affordances app-wide.
    @Test("The app-wide preference leaves the louder agent states alone")
    func agentLouderStatesSurviveAppWideDisable() {
        let missing = VMInstanceFixture.make(guestOS: .macOS, phase: .running(sessionID: UUID())) {
            $0.lastSeenAgentVersion = "1.2.3"
        }
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
        let busyInstance = VMInstanceFixture.make(phase: .running(sessionID: UUID()))
        let busy = makeBusyStateRow(instance: busyInstance, isBusy: true)
        #expect(firstSubview(NSProgressIndicator.self, in: busy)?.isHidden == false)
        #expect(firstSubview(NSImageView.self, in: busy)?.isHidden == true)

        let idleInstance = VMInstanceFixture.make(phase: .running(sessionID: UUID()))
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
        viewModel.library.admitForTesting(VMInstanceFixture.make(guestOS: .macOS, phase: .running(sessionID: UUID())))
        let controller = SidebarViewController(viewModel: viewModel)
        controller.loadViewIfNeeded()
        controller.viewDidAppear()

        controller.viewWillDisappear()
        let reloadsWhileOffScreen = controller.reloadInstancesCallCountForTesting
        viewModel.agentInstallPromptDisabled = true
        #expect(controller.reloadInstancesCallCountForTesting == reloadsWhileOffScreen)

        controller.viewDidAppear()

        #expect(controller.reloadInstancesCallCountForTesting > reloadsWhileOffScreen)
    }

    // MARK: - Inline rename

    /// The row's name label, which is also the box a rename opens.
    private func nameLabel(in cell: SidebarVMRowCellView) throws -> InlineEditableLabel {
        try #require(firstSubview(InlineEditableLabel.self, in: cell))
    }

    private func makeRenamingRow(
        instance: VMInstance, onCommitRename: @escaping (String, Bool) -> Void = { _, _ in }
    ) -> SidebarVMRowCellView {
        let cell = SidebarVMRowCellView()
        cell.configure(
            instance: instance,
            isRenaming: true,
            installPromptDisabled: false,
            isBusy: { false },
            onCommitRename: onCommitRename,
            onCancelRename: {},
            onMountAgent: {},
            onDismissAgentNudge: {})
        return cell
    }

    /// During `reloadData` the row is configured — rename and all — before it
    /// joins the outline view's window, so the focus has to be re-established
    /// when it does.
    @Test("A rename armed off-window takes focus once the row joins one")
    func renameArmedOffWindowTakesFocusOnJoin() throws {
        let instance = VMInstanceFixture.make()
        let cell = makeRenamingRow(instance: instance)
        let label = try nameLabel(in: cell)

        #expect(cell.isRenaming)
        #expect(label.isEditable)
        #expect(label.currentEditor() == nil)

        let window = makeTestWindow(styleMask: [.titled])
        window.contentView = cell

        #expect(label.currentEditor() != nil)
        #expect(cell.isRenaming)
    }

    /// The controller restores sidebar focus only for a keyboard Return, so the
    /// flag has to survive the trip out of the shared label.
    @Test("A Return-terminated rename reports that it ended by Return")
    func renameCommitReportsEndedByReturn() throws {
        let instance = VMInstanceFixture.make()
        var commits: [(name: String, endedByReturn: Bool)] = []
        let cell = makeRenamingRow(instance: instance) { commits.append(($0, $1)) }
        let window = makeTestWindow(styleMask: [.titled])
        window.contentView = cell
        let label = try nameLabel(in: cell)

        label.currentEditor()?.string = "Renamed"
        label.stringValue = "Renamed"
        label.controlTextDidEndEditing(
            Notification(
                name: NSControl.textDidEndEditingNotification, object: label,
                userInfo: ["NSTextMovement": NSTextMovement.return.rawValue]))

        #expect(commits.count == 1)
        #expect(commits.first?.name == "Renamed")
        #expect(commits.first?.endedByReturn == true)
        #expect(!cell.isRenaming)
    }

    /// A recycled row carries typed text belonging to the VM it used to show,
    /// so the reuse teardown must drop it rather than commit it.
    @Test("Recycling a row mid-rename commits nothing")
    func recyclingARenamingRowCommitsNothing() throws {
        let instance = VMInstanceFixture.make()
        var commits = 0
        let cell = makeRenamingRow(instance: instance) { _, _ in commits += 1 }
        let window = makeTestWindow(styleMask: [.titled])
        window.contentView = cell
        let label = try nameLabel(in: cell)
        label.currentEditor()?.string = "Half-typed"
        label.stringValue = "Half-typed"

        cell.prepareForReuse()

        #expect(commits == 0)
        #expect(!cell.isRenaming)
        #expect(!label.isEditable)
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
        let instance = VMInstanceFixture.make(phase: .stopped)
        viewModel.library.admitForTesting(instance)
        let controller = SidebarViewController(viewModel: viewModel)

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
        let instance = VMInstanceFixture.make(phase: .running(sessionID: UUID()))
        viewModel.library.admitForTesting(instance)
        let controller = SidebarViewController(viewModel: viewModel)

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

    @Test("Context menu keeps Clone enabled while a different VM is being copied")
    func contextMenuCloneIgnoresAnotherVMsCopy() async {
        let viewModel = makeViewModel()
        let instance = VMInstanceFixture.make(name: "Settled", phase: .stopped)
        viewModel.library.admitForTesting(instance)
        let gate = GatedArrivalWrite()
        let copying = viewModel.library.beginGatedArrival(
            .cloning(sourceID: UUID()), named: "Copying", gate: gate)
        let controller = SidebarViewController(viewModel: viewModel)

        let menu = controller.buildContextMenu(for: instance)

        // Overlapping clones and imports are a supported case — the copy in
        // flight belongs to another VM and says nothing about this one.
        #expect(viewModel.arrivals.map(\.id) == [copying.id])
        #expect(menuItem("Clone", in: menu)?.isEnabled == true)

        gate.release()
        await copying.settle()
    }

    @Test("Context menu for a cold-paused VM offers Discard Saved State, not Stop/Suspend")
    func contextMenuColdPaused() throws {
        let viewModel = makeViewModel()
        let instance = VMInstanceFixture.make(phase: .suspended)  // no live VM ⇒ cold-paused
        // A suspend slot on disk: every predicate a suspended VM is judged by
        // reads the file, not the status.
        defer { VMInstanceFixture.removeBundle(of: instance) }
        try VMInstanceFixture.writeSaveFile(for: instance)
        viewModel.library.admitForTesting(instance)
        let controller = SidebarViewController(viewModel: viewModel)

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

    /// One slot, one command: the title says what the VM's state makes of a
    /// stop, and the consent a discard needs is the refusal the verb raises.
    @Test("The stop slot dispatches the same command under either title")
    func stopSlotDispatchesOneCommand() throws {
        let viewModel = makeViewModel()
        let running = VMInstanceFixture.make(name: "Running", phase: .running(sessionID: UUID()))
        let suspended = VMInstanceFixture.make(name: "Suspended", phase: .suspended)
        defer { VMInstanceFixture.removeBundle(of: suspended) }
        try VMInstanceFixture.writeSaveFile(for: suspended)
        viewModel.library.admitForTesting([running, suspended])
        let controller = SidebarViewController(viewModel: viewModel)
        let runningMenu = controller.buildContextMenu(for: running)

        let stop = menuItem("Stop", in: runningMenu)
        let discard = menuItem(
            "Discard Saved State…", in: controller.buildContextMenu(for: suspended))

        #expect(stop?.action != nil)
        #expect(discard?.action == stop?.action)
        // Force Stop is a command of its own, which is why it keeps its own item.
        #expect(menuItem("Force Stop…", in: runningMenu)?.action != stop?.action)
    }

    @Test("A cold-paused VM's stop slot raises the discard confirmation once")
    func stopSlotOnAColdPausedVMAsksOnce() async throws {
        let viewModel = makeViewModel()
        let presenter = MockVMLibraryPresenting()
        viewModel.presenter = presenter
        let suspended = VMInstanceFixture.make(name: "Suspended", phase: .suspended)
        defer { VMInstanceFixture.removeBundle(of: suspended) }
        try VMInstanceFixture.writeSaveFile(for: suspended)
        viewModel.library.admitForTesting(suspended)
        let controller = SidebarViewController(viewModel: viewModel)
        let discard = try #require(
            menuItem("Discard Saved State…", in: controller.buildContextMenu(for: suspended)))

        _ = NSApp.sendAction(try #require(discard.action), to: discard.target, from: discard)
        // The item's action runs the verb in a task of its own, and a mock
        // presenter is no observable to await, so the sheet's arrival is polled.
        try await waitUntil { presenter.forceStopInstances.count == 1 }
        // Then let whatever is still queued run, so the count below reads
        // "exactly once" rather than "once so far": a main-queue barrier for
        // anything dispatched there, and a few cooperative hops for a task
        // still waiting to be scheduled.
        await drainMainQueue()
        for _ in 0..<3 { await Task.yield() }

        #expect(presenter.forceStopInstances.map(\.id) == [suspended.id])
    }

    @Test("Context menu enables delete for a cold-paused VM but keeps Clone disabled")
    func contextMenuColdPausedEnablesDelete() throws {
        let viewModel = makeViewModel()
        let instance = VMInstanceFixture.make(phase: .suspended)  // no live VM ⇒ cold-paused
        defer { VMInstanceFixture.removeBundle(of: instance) }
        try VMInstanceFixture.writeSaveFile(for: instance)
        viewModel.library.admitForTesting(instance)
        let controller = SidebarViewController(viewModel: viewModel)

        let menu = controller.buildContextMenu(for: instance)

        // The saved state is a file inside the bundle, so deleting takes no
        // Discard Saved State pass first.
        #expect(menuItem("Move to Trash…", in: menu)?.isEnabled == true)
        #expect(menuItem("Delete Immediately…", in: menu)?.isEnabled == true)
        // A clone carries no suspend slot, so the saved state pins it out.
        #expect(menuItem("Clone", in: menu)?.isEnabled == false)
    }

    @Test("Context menu disables delete for a live-paused VM")
    func contextMenuLivePausedDisablesDelete() {
        let viewModel = makeViewModel()
        let instance = VMInstanceFixture.make(phase: .livePaused(sessionID: UUID()))
        viewModel.library.admitForTesting(instance)
        let controller = SidebarViewController(viewModel: viewModel)

        let menu = controller.buildContextMenu(for: instance)

        #expect(instance.isLivePaused)
        #expect(menuItem("Move to Trash…", in: menu)?.isEnabled == false)
        #expect(menuItem("Delete Immediately…", in: menu)?.isEnabled == false)
    }

    @Test("Force Stop is the Option-alternate of Stop on a running VM (advanced options off)")
    func contextMenuForceStopIsOptionAlternate() {
        preferences.alwaysShowAdvancedOptions = false
        let viewModel = makeViewModel()
        let instance = VMInstanceFixture.make(phase: .running(sessionID: UUID()))
        viewModel.library.admitForTesting(instance)
        let controller = SidebarViewController(viewModel: viewModel)

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
        let instance = VMInstanceFixture.make(phase: .running(sessionID: UUID()))
        viewModel.library.admitForTesting(instance)
        let controller = SidebarViewController(viewModel: viewModel)

        let menu = controller.buildContextMenu(for: instance)

        let forceStop = menuItem("Force Stop…", in: menu)
        #expect(menuItem("Stop", in: menu) != nil)
        #expect(forceStop != nil)
        #expect(forceStop?.isAlternate == false)
    }

    @Test(
        "A VM mid-operation offers neither stop — Virtualization takes a termination from neither",
        arguments: [
            VMLifecyclePhase.starting(sessionID: UUID()), .saving(sessionID: UUID()),
            .restoringSavedState(sessionID: UUID()), .capturingLive(sessionID: UUID()),
        ])
    func contextMenuOffersNoStopWhileVirtualizationWouldRefuseOne(phase: VMLifecyclePhase) {
        preferences.alwaysShowAdvancedOptions = false
        let viewModel = makeViewModel()
        let instance = VMInstanceFixture.make(phase: phase)
        viewModel.library.admitForTesting(instance)
        let controller = SidebarViewController(viewModel: viewModel)

        let menuTitles = titles(of: controller.buildContextMenu(for: instance))

        #expect(!menuTitles.contains("Stop"), "\(phase)")
        #expect(!menuTitles.contains("Force Stop…"), "\(phase)")
    }

    @Test("A disks-only capture offers no Force Stop — there is no VM to terminate")
    func contextMenuNoForceStopDuringAColdCapture() {
        let viewModel = makeViewModel()
        let instance = VMInstanceFixture.make(phase: .capturingAtRest)
        viewModel.library.admitForTesting(instance)
        let controller = SidebarViewController(viewModel: viewModel)

        let menuTitles = titles(of: controller.buildContextMenu(for: instance))

        #expect(!menuTitles.contains("Force Stop…"))
    }

    @Test("Delete Immediately is the Option-alternate of Move to Trash (advanced options off)")
    func contextMenuDeleteImmediatelyIsOptionAlternate() {
        preferences.alwaysShowAdvancedOptions = false
        let viewModel = makeViewModel()
        let instance = VMInstanceFixture.make(phase: .stopped)
        viewModel.library.admitForTesting(instance)
        let controller = SidebarViewController(viewModel: viewModel)

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
        let instance = VMInstanceFixture.make(phase: .stopped)
        viewModel.library.admitForTesting(instance)
        let controller = SidebarViewController(viewModel: viewModel)

        let menu = controller.buildContextMenu(for: instance)

        let deleteImmediately = menuItem("Delete Immediately…", in: menu)
        #expect(menuItem("Move to Trash…", in: menu) != nil)
        #expect(deleteImmediately != nil)
        #expect(deleteImmediately?.isAlternate == false)
    }

    @Test("An arrival's row shows its name and label, and its menu offers only its Cancel")
    func arrivalRowShowsItsLabelAndOffersOnlyCancel() async throws {
        let viewModel = makeViewModel()
        let gate = GatedArrivalWrite()
        let arrival = viewModel.library.beginGatedArrival(
            .cloning(sourceID: UUID()), named: "Copying", gate: gate)
        let controller = SidebarViewController(viewModel: viewModel)

        let cell = SidebarArrivalRowCellView()
        cell.configure(arrival: arrival)
        #expect(cell.textField?.stringValue == "Copying")
        #expect(cell.toolTip == "Cloning\u{2026}")

        let menu = controller.buildContextMenu(for: arrival)

        // Nothing is at the destination until the write is published, so a
        // reveal would open Finder on a path that does not exist.
        #expect(titles(of: menu) == ["Cancel Clone"])

        #expect(arrival.requestCancel() == .cancelled)
        // The cell's observation applies on a later main-actor turn, with no
        // observable of its own to await.
        try await waitUntil { cell.toolTip == "Cancelling\u{2026}" }

        gate.release()
        await arrival.settle()
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

    @Test("emphasizedNameFont lays out as the font a selected source-list row draws")
    func emphasizedFontMatchesSelectedRowRendering() {
        // The oracle for the whole fix: the measuring font has to agree with what
        // a real source-list outline view puts on screen for a selected row. It
        // is asserted on laid-out width rather than font identity because AppKit
        // spells the same resolved face differently — it keeps the body text
        // style's usage attribute and adds an explicit 0.3 weight trait, where
        // the conversion names the emphasized text style — so the two fonts are
        // the same `.SFNS-Semibold` at the same size but are not `==`.
        let name = "Ubuntu Desktop 26.04"
        let probe = SelectedRowFontProbe(instance: VMInstanceFixture.make(name: name))

        guard let label = probe.selectedRowLabel() else {
            Issue.record("Expected the probe outline view to vend a configured row cell")
            return
        }
        guard
            let drawn = label.cell?.attributedStringValue.attribute(
                .font, at: 0, effectiveRange: nil) as? NSFont
        else {
            Issue.record("Expected the selected row's drawn string to carry a font")
            return
        }

        let renderedWidth = ceil(label.fittingSize.width)
        let measuring = SidebarVMRowCellView.emphasizedNameFont
        #expect(drawn.fontName == measuring.fontName)
        #expect(drawn.pointSize == measuring.pointSize)
        // The load-bearing property: the snap width is only right if the font it
        // measures with lays the name out to the width the row renders it at.
        #expect(measuredWidth(of: name, at: measuring) == renderedWidth)
        // Discriminating. `NSFontManager.convert` returns its input untouched
        // when that input already carries the trait, so a body font that ever
        // went bold would silently make the conversion a no-op; the regular
        // weight measures this name narrower, which fails here.
        #expect(measuredWidth(of: name, at: Typography.body) < renderedWidth)
        // Also keeps the probe — which the outline view references weakly — alive
        // across every assertion above.
        #expect(probe.outlineView.selectedRow == 0)
    }

    @Test("contentWidth measures names at the weight a selected row draws them")
    func contentWidthUsesEmphasizedWeight() {
        // A source-list outline view draws the selected row's name in the
        // emphasized variant of its font, so a fit width measured at the regular
        // weight leaves the selected name's tail under the trailing accessory.
        let emphasized = NSFontManager.shared.convert(Typography.body, toHaveTrait: .boldFontMask)
        #expect(emphasized != Typography.body)

        let long = "An extremely long virtual machine name"
        let short = "W"

        // The row chrome is identical for both names, so differencing the two
        // content widths leaves exactly the two measured name widths.
        func contentWidth(_ name: String) -> CGFloat {
            SidebarVMRowCellView.contentWidth(
                forName: name, showsAgentAccessory: false, showsEphemeralAccessory: false)
        }
        let measuredDelta = contentWidth(long) - contentWidth(short)

        #expect(
            measuredDelta
                == measuredWidth(of: long, at: emphasized)
                - measuredWidth(of: short, at: emphasized))
        // Discriminating: the emphasized weight is genuinely wider here, so the
        // assertion above fails if the measurement falls back to the body font.
        #expect(
            measuredDelta
                > measuredWidth(of: long, at: Typography.body)
                - measuredWidth(of: short, at: Typography.body))
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
        let controller = SidebarViewController(viewModel: viewModel)
        controller.loadViewIfNeeded()
        #expect(controller.widthToFitLongestRow() == nil)
    }

    @Test("widthToFitLongestRow grows with the longest VM name")
    func fitWidthTracksLongestName() {
        let shortModel = makeViewModel()
        shortModel.library.admitForTesting(VMInstanceFixture.make(name: "VM"))
        let shortController = SidebarViewController(viewModel: shortModel)
        shortController.loadViewIfNeeded()
        shortController.view.layoutSubtreeIfNeeded()

        let longModel = makeViewModel()
        longModel.library.admitForTesting(VMInstanceFixture.make(name: "An extremely long virtual machine name"))
        let longController = SidebarViewController(viewModel: longModel)
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
        viewModel.library.admitForTesting(VMInstanceFixture.make(name: "Alpha"))
        viewModel.library.admitForTesting(VMInstanceFixture.make(name: "Beta"))
        let controller = SidebarViewController(viewModel: viewModel)
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

    @Test("An arrival's row becomes its VM's row when it settles, keeping its place and selection")
    func settlingArrivalReloadsIntoAVMRow() async throws {
        let viewModel = makeViewModel()
        let before = VMInstanceFixture.make(name: "Before")
        viewModel.library.admitForTesting(before)
        let gate = GatedArrivalWrite()
        let arrival = viewModel.library.beginGatedArrival(named: "Arriving", gate: gate)
        let controller = SidebarViewController(viewModel: viewModel)
        controller.loadViewIfNeeded()
        controller.viewDidAppear()
        let outline = try #require(firstSubview(NSOutlineView.self, in: controller.view))
        #expect((outline.item(atRow: 1) as? VMInstance) === before)
        #expect((outline.item(atRow: 2) as? VMArrival) === arrival)
        #expect(viewModel.selectedID == arrival.id)
        // The outline view offers no observable to await its selection by.
        try await waitUntil { outline.selectedRow == 2 }

        gate.release()
        let instance = try #require(await arrival.settle())

        try await waitUntil { (outline.item(atRow: 2) as? VMInstance) === instance }
        #expect(outline.numberOfRows == 3)
        #expect(outline.row(forItem: instance) == 2)
        #expect(outline.selectedRow == 2)
        #expect(viewModel.selectedID == arrival.id)
    }

    // MARK: - Clone completion refresh (#575)

    @Test("A cloned VM's arrival row settling routes through the sidebar's reload cycle")
    func clonedRowSettlingTriggersReload() async throws {
        let storage = MockVMStorageService()
        let viewModel = makeViewModel(storageService: storage)
        let source = VMInstanceFixture.make(name: "Source", guestOS: .macOS)
        // Registered with the mock storage so the view model's real
        // `VMDirectoryWatcher` — which fires on the clone's directory actually
        // landing on disk (the mock now creates it, matching production) —
        // doesn't mistake the never-persisted source for a bundle that vanished
        // and reconcile it away, confounding the reload count below.
        storage.bundles[source.bundleURL] = source.configuration
        viewModel.library.admitForTesting(source)
        let controller = SidebarViewController(viewModel: viewModel)
        controller.loadViewIfNeeded()
        controller.viewDidAppear()

        let reloadsBeforeClone = controller.reloadInstancesCallCountForTesting
        viewModel.cloneVM(source)
        // The clone registers its arrival and is adopted in place under the
        // same identifier, so its settle is the second VM in the library.
        try await waitForChange { viewModel.instances.count == 2 }
        #expect(viewModel.arrivals.isEmpty)

        // Exactly two reloads are expected end to end: one for the arrival's
        // registration and one for its adoption, which replaces the entry
        // under the same id — the fix under test (#575). The adoption's reload
        // has no dedicated Observable signal at the controller layer to hang a
        // `waitForChange` off of (it fires through an internal
        // `ObservationLoop` cascade), so poll the counter.
        //
        // Genuine no-signal predicate — the reload count is driven by an
        // internal `ObservationLoop` cascade with no test-facing signal to
        // await; `==`, not `>=`, so a stray extra reload (e.g. an unrelated
        // `VMDirectoryWatcher` reconciliation) fails the test instead of being
        // silently masked by a looser bound.
        try await waitUntil {
            controller.reloadInstancesCallCountForTesting == reloadsBeforeClone + 2
        }

        // The reload count above is the regression guard; the row's actual
        // rendered cell is left to manual verification, per this file's
        // top-level doc comment — `NSOutlineView` never realizes a row's cell
        // view in this off-screen test harness (confirmed: `view(atColumn:
        // row:makeIfNecessary: false)` is always nil here), so an assertion on
        // it would silently never execute.
    }
}

/// A minimal source-list `NSOutlineView` holding one configured VM row, used to
/// read back the font AppKit actually draws that row's name in once selected.
///
/// Window-less and never displayed: `reloadData`, selecting the row and a layout
/// pass are enough for AppKit to install the emphasized string, so the probe
/// stays synchronous and needs no run-loop spin.
@MainActor
private final class SelectedRowFontProbe: NSObject, NSOutlineViewDataSource,
    NSOutlineViewDelegate
{
    let outlineView = NSOutlineView()
    private let instance: VMInstance

    init(instance: VMInstance) {
        self.instance = instance
        super.init()

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        column.width = 280
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.style = .sourceList
        outlineView.headerView = nil
        outlineView.frame = NSRect(x: 0, y: 0, width: 300, height: 100)
        outlineView.dataSource = self
        outlineView.delegate = self
    }

    /// The name label of the single row, with that row selected.
    func selectedRowLabel() -> NSTextField? {
        outlineView.reloadData()
        outlineView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        outlineView.layoutSubtreeIfNeeded()
        let cell = outlineView.view(atColumn: 0, row: 0, makeIfNecessary: true)
        return (cell as? SidebarVMRowCellView)?.textField
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        item == nil ? 1 : 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        instance
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { false }

    func outlineView(
        _ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any
    ) -> NSView? {
        let cell = SidebarVMRowCellView()
        cell.configure(
            instance: instance,
            isRenaming: false,
            installPromptDisabled: true,
            isBusy: { false },
            onCommitRename: { _, _ in },
            onCancelRename: {},
            onMountAgent: {},
            onDismissAgentNudge: {}
        )
        return cell
    }
}
